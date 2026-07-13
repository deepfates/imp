defmodule DSEx.Optimizer.GEPA.Stopper do
  @moduledoc """
  Explicit, composable stopping policies for GEPA optimization.

  `check/4` is state-threaded and never stores counters in the Process
  dictionary. `dump/1` omits runtime monotonic timestamps; `load!/2` rebases
  timeout accounting onto an injected monotonic clock, preserving elapsed run
  time without persisting VM-specific clock values.
  """

  defmodule State do
    @moduledoc "Explicit checkpointable state for a composed stopping policy."

    defstruct nodes: %{}

    @type path :: [non_neg_integer()]
    @type node_state ::
            %{kind: :timeout, elapsed_ms: non_neg_integer(), observed_at_ms: integer()}
            | %{
                kind: :no_improvement,
                best_score: number(),
                iterations_without_improvement: non_neg_integer()
              }
    @type t :: %__MODULE__{nodes: %{optional(path()) => node_state()}}
  end

  @type context :: map()
  @type reason ::
          {:max_metric_calls, non_neg_integer(), non_neg_integer()}
          | {:timeout, non_neg_integer(), non_neg_integer()}
          | {:deadline, integer(), integer()}
          | {:no_improvement, non_neg_integer(), pos_integer(), number()}
          | {:score_threshold, number(), number()}
          | {:file, Path.t()}
          | {:manual, term()}
  @type decision :: {:stop, [reason()], State.t()} | {:continue, State.t()}
  @type clock :: (-> integer())
  @type policy ::
          {:max_metric_calls, non_neg_integer()}
          | {:timeout, non_neg_integer()}
          | {:deadline, integer()}
          | {:no_improvement, pos_integer()}
          | {:score_threshold, number()}
          | {:file, Path.t(), (Path.t() -> boolean())}
          | {:manual, (context() -> term())}
          | {:any | :all, [policy()]}

  @doc "Stops once observed metric calls reach the inclusive limit."
  @spec max_metric_calls(non_neg_integer()) :: policy()
  def max_metric_calls(limit) when is_integer(limit) and limit >= 0,
    do: {:max_metric_calls, limit}

  @doc "Stops once checkpoint-aware elapsed monotonic time reaches `timeout_ms`."
  @spec timeout(non_neg_integer()) :: policy()
  def timeout(timeout_ms) when is_integer(timeout_ms) and timeout_ms >= 0,
    do: {:timeout, timeout_ms}

  @doc "Stops at an absolute deadline in the injected monotonic clock's units."
  @spec deadline(integer()) :: policy()
  def deadline(deadline_ms) when is_integer(deadline_ms), do: {:deadline, deadline_ms}

  @doc "Stops after `patience` consecutive checks without a strict score improvement."
  @spec no_improvement(pos_integer()) :: policy()
  def no_improvement(patience) when is_integer(patience) and patience > 0,
    do: {:no_improvement, patience}

  @doc "Stops when `context.best_score` reaches the inclusive threshold."
  @spec score_threshold(number()) :: policy()
  def score_threshold(threshold) when is_number(threshold), do: {:score_threshold, threshold}

  @doc "Stops when the path exists; `:exists?` may inject a deterministic file probe."
  @spec file(Path.t(), keyword()) :: policy()
  def file(path, opts \\ []) when is_binary(path) and is_list(opts) do
    exists? = Keyword.get(opts, :exists?, &File.exists?/1)

    unless is_function(exists?, 1) do
      raise ArgumentError, ":exists? must be a one-argument function"
    end

    {:file, path, exists?}
  end

  @doc "Builds a manually controlled callback stopper."
  @spec manual((context() -> term())) :: policy()
  def manual(callback) when is_function(callback, 1), do: {:manual, callback}

  @doc "Stops when any child policy stops."
  @spec any([policy()]) :: policy()
  def any(policies) when is_list(policies) and policies != [], do: {:any, policies}

  @doc "Stops when every child policy stops on the same check."
  @spec all([policy()]) :: policy()
  def all(policies) when is_list(policies) and policies != [], do: {:all, policies}

  @doc "Initializes explicit policy state using the injected monotonic time."
  @spec new(policy(), keyword()) :: State.t()
  def new(policy, opts \\ []) when is_list(opts) do
    validate_policy!(policy)
    now = now_ms(opts)
    %State{nodes: initialize_nodes(policy, [], now, %{})}
  end

  @doc "Evaluates a policy and returns its updated explicit state."
  @spec check(policy(), State.t(), context(), keyword()) :: decision()
  def check(policy, %State{} = state, context, opts \\ [])
      when is_map(context) and is_list(opts) do
    validate_policy!(policy)
    now = now_ms(opts)
    {stopped?, reasons, nodes} = evaluate(policy, [], state.nodes, context, now)
    state = %{state | nodes: nodes}

    if stopped?, do: {:stop, reasons, state}, else: {:continue, state}
  end

  @doc "Dumps policy counters to JSON-safe checkpoint data."
  @spec dump(State.t()) :: map()
  def dump(%State{} = state) do
    nodes =
      state.nodes
      |> Enum.sort_by(fn {path, _node} -> path end)
      |> Enum.map(fn {path, node} -> dump_node(path, node) end)

    %{"schema_version" => 1, "nodes" => nodes}
  end

  @doc "Loads policy counters and rebases timeout observations onto the current clock."
  @spec load!(map(), keyword()) :: State.t()
  def load!(checkpoint, opts \\ [])

  def load!(checkpoint, opts) when is_map(checkpoint) and is_list(opts) do
    unless Map.get(checkpoint, "schema_version") == 1 and is_list(checkpoint["nodes"]) do
      raise ArgumentError, "invalid GEPA stopper checkpoint"
    end

    now = now_ms(opts)

    nodes =
      Map.new(checkpoint["nodes"], fn node ->
        {path, restored} = load_node!(node, now)
        {path, restored}
      end)

    if map_size(nodes) != length(checkpoint["nodes"]) do
      raise ArgumentError, "GEPA stopper checkpoint contains duplicate node paths"
    end

    %State{nodes: nodes}
  end

  def load!(checkpoint, _opts) do
    raise ArgumentError, "GEPA stopper checkpoint must be a map, got: #{inspect(checkpoint)}"
  end

  defp evaluate({:any, policies}, path, nodes, context, now) do
    {results, nodes} = evaluate_children(policies, path, nodes, context, now)
    reasons = for {true, child_reasons} <- results, reason <- child_reasons, do: reason
    {reasons != [], reasons, nodes}
  end

  defp evaluate({:all, policies}, path, nodes, context, now) do
    {results, nodes} = evaluate_children(policies, path, nodes, context, now)
    stopped? = Enum.all?(results, fn {child_stopped?, _reasons} -> child_stopped? end)
    reasons = if stopped?, do: Enum.flat_map(results, &elem(&1, 1)), else: []
    {stopped?, reasons, nodes}
  end

  defp evaluate({:max_metric_calls, limit}, _path, nodes, context, _now) do
    calls = fetch_non_negative_integer!(context, :metric_calls)

    {calls >= limit, [{:max_metric_calls, calls, limit}], nodes}
    |> suppress_reason_unless_stopped()
  end

  defp evaluate({:deadline, deadline}, _path, nodes, _context, now) do
    {now >= deadline, [{:deadline, now, deadline}], nodes}
    |> suppress_reason_unless_stopped()
  end

  defp evaluate({:timeout, timeout_ms}, path, nodes, _context, now) do
    node = Map.get(nodes, path, %{kind: :timeout, elapsed_ms: 0, observed_at_ms: now})
    elapsed = node.elapsed_ms + max(now - node.observed_at_ms, 0)
    updated = %{node | elapsed_ms: elapsed, observed_at_ms: now}

    {elapsed >= timeout_ms, [{:timeout, elapsed, timeout_ms}], Map.put(nodes, path, updated)}
    |> suppress_reason_unless_stopped()
  end

  defp evaluate({:no_improvement, patience}, path, nodes, context, _now) do
    score = fetch_number!(context, :best_score)

    node =
      case Map.get(nodes, path) do
        nil ->
          %{kind: :no_improvement, best_score: score, iterations_without_improvement: 0}

        %{best_score: best_score} = node when score > best_score ->
          %{node | best_score: score, iterations_without_improvement: 0}

        node ->
          Map.update!(node, :iterations_without_improvement, &(&1 + 1))
      end

    count = node.iterations_without_improvement

    {count >= patience, [{:no_improvement, count, patience, node.best_score}],
     Map.put(nodes, path, node)}
    |> suppress_reason_unless_stopped()
  end

  defp evaluate({:score_threshold, threshold}, _path, nodes, context, _now) do
    score = fetch_number!(context, :best_score)

    {score >= threshold, [{:score_threshold, score, threshold}], nodes}
    |> suppress_reason_unless_stopped()
  end

  defp evaluate({:file, path, exists?}, _node_path, nodes, _context, _now) do
    {exists?.(path), [{:file, path}], nodes}
    |> suppress_reason_unless_stopped()
  end

  defp evaluate({:manual, callback}, _path, nodes, context, _now) do
    case callback.(context) do
      true -> {true, [{:manual, true}], nodes}
      :stop -> {true, [{:manual, :stop}], nodes}
      {:stop, detail} -> {true, [{:manual, detail}], nodes}
      false -> {false, [], nodes}
      :continue -> {false, [], nodes}
      {:continue, _detail} -> {false, [], nodes}
      invalid -> raise ArgumentError, "invalid GEPA manual stopper decision: #{inspect(invalid)}"
    end
  end

  defp evaluate_children(policies, path, nodes, context, now) do
    policies
    |> Enum.with_index()
    |> Enum.map_reduce(nodes, fn {policy, index}, nodes ->
      {stopped?, reasons, nodes} = evaluate(policy, path ++ [index], nodes, context, now)
      {{stopped?, reasons}, nodes}
    end)
  end

  defp suppress_reason_unless_stopped({true, reasons, nodes}), do: {true, reasons, nodes}
  defp suppress_reason_unless_stopped({false, _reasons, nodes}), do: {false, [], nodes}

  defp initialize_nodes({:timeout, _timeout_ms}, path, now, nodes) do
    Map.put(nodes, path, %{kind: :timeout, elapsed_ms: 0, observed_at_ms: now})
  end

  defp initialize_nodes({mode, policies}, path, now, nodes) when mode in [:any, :all] do
    policies
    |> Enum.with_index()
    |> Enum.reduce(nodes, fn {policy, index}, nodes ->
      initialize_nodes(policy, path ++ [index], now, nodes)
    end)
  end

  defp initialize_nodes(_policy, _path, _now, nodes), do: nodes

  defp dump_node(path, %{kind: :timeout, elapsed_ms: elapsed_ms}) do
    %{"path" => path, "kind" => "timeout", "elapsed_ms" => elapsed_ms}
  end

  defp dump_node(path, %{kind: :no_improvement} = node) do
    %{
      "path" => path,
      "kind" => "no_improvement",
      "best_score" => node.best_score,
      "iterations_without_improvement" => node.iterations_without_improvement
    }
  end

  defp load_node!(%{"path" => path, "kind" => "timeout", "elapsed_ms" => elapsed}, now) do
    validate_path!(path)
    validate_non_negative_integer!(elapsed, "elapsed_ms")
    {path, %{kind: :timeout, elapsed_ms: elapsed, observed_at_ms: now}}
  end

  defp load_node!(
         %{
           "path" => path,
           "kind" => "no_improvement",
           "best_score" => score,
           "iterations_without_improvement" => count
         },
         _now
       ) do
    validate_path!(path)

    unless is_number(score) do
      raise ArgumentError, "GEPA stopper best_score must be numeric"
    end

    validate_non_negative_integer!(count, "iterations_without_improvement")

    {path, %{kind: :no_improvement, best_score: score, iterations_without_improvement: count}}
  end

  defp load_node!(node, _now) do
    raise ArgumentError, "invalid GEPA stopper checkpoint node: #{inspect(node)}"
  end

  defp validate_policy!({:max_metric_calls, limit})
       when is_integer(limit) and limit >= 0,
       do: :ok

  defp validate_policy!({:timeout, timeout_ms})
       when is_integer(timeout_ms) and timeout_ms >= 0,
       do: :ok

  defp validate_policy!({:deadline, deadline}) when is_integer(deadline), do: :ok

  defp validate_policy!({:no_improvement, patience}) when is_integer(patience) and patience > 0,
    do: :ok

  defp validate_policy!({:score_threshold, threshold}) when is_number(threshold), do: :ok

  defp validate_policy!({:file, path, exists?})
       when is_binary(path) and is_function(exists?, 1),
       do: :ok

  defp validate_policy!({:manual, callback}) when is_function(callback, 1), do: :ok

  defp validate_policy!({mode, policies}) when mode in [:any, :all] and policies != [] do
    Enum.each(policies, &validate_policy!/1)
  end

  defp validate_policy!(policy) do
    raise ArgumentError, "invalid GEPA stopper policy: #{inspect(policy)}"
  end

  defp now_ms(opts) do
    case Keyword.get(opts, :now, fn -> System.monotonic_time(:millisecond) end) do
      now when is_integer(now) ->
        now

      clock when is_function(clock, 0) ->
        clock.()

      invalid ->
        raise ArgumentError,
              ":now must be an integer or zero-argument function, got: #{inspect(invalid)}"
    end
  end

  defp fetch_non_negative_integer!(context, key) do
    value = Map.get(context, key)
    validate_non_negative_integer!(value, key)
    value
  end

  defp fetch_number!(context, key) do
    value = Map.get(context, key)

    unless is_number(value) do
      raise ArgumentError, "GEPA stopper context #{inspect(key)} must be numeric"
    end

    value
  end

  defp validate_non_negative_integer!(value, _name) when is_integer(value) and value >= 0,
    do: :ok

  defp validate_non_negative_integer!(value, name) do
    raise ArgumentError,
          "GEPA stopper #{inspect(name)} must be a non-negative integer, got: #{inspect(value)}"
  end

  defp validate_path!(path)
       when is_list(path) and path != [] do
    if Enum.all?(path, &(is_integer(&1) and &1 >= 0)) do
      :ok
    else
      raise ArgumentError, "GEPA stopper checkpoint path must contain non-negative integers"
    end
  end

  defp validate_path!(path) when path == [], do: :ok

  defp validate_path!(_path) do
    raise ArgumentError, "GEPA stopper checkpoint path must be a list"
  end
end
