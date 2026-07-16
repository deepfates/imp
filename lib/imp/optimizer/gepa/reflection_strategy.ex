defmodule Imp.Optimizer.GEPA.ReflectionStrategy do
  @moduledoc false

  alias Imp.Optimizer.GEPA.Candidate

  @enforce_keys [:module, :context]
  defstruct [:module, :context]

  @type proposal :: map()
  @type job :: {Candidate.t(), map(), [Candidate.component_name()]}
  @type semantic_strategy :: module() | (Candidate.t(), map(), [atom()] -> term())
  @type contextual_strategy :: {:contextual, module(), term()}
  @type t :: semantic_strategy() | contextual_strategy() | %__MODULE__{}

  @callback reflect(Candidate.t(), map(), [Candidate.component_name()], term()) ::
              {proposal(), term()} | {:ok, proposal(), term()} | {:error, term()} | proposal()
  @callback reflect_many([job()], term()) ::
              {[proposal()], term()} | {:ok, [proposal()], term()} | {:error, term()}
  @callback total_cost(term()) :: number()
  @callback dump_state(term()) :: term()
  @callback load_state(term()) :: term()
  @optional_callbacks reflect_many: 2, total_cost: 1, dump_state: 1, load_state: 1

  @doc false
  @spec contextual(module(), term()) :: %__MODULE__{}
  def contextual(module, context) when is_atom(module) do
    unless Code.ensure_loaded?(module) and function_exported?(module, :reflect, 4) do
      raise ArgumentError, "contextual GEPA reflection strategy must export reflect/4"
    end

    %__MODULE__{module: module, context: context}
  end

  @doc false
  def validate!(nil), do: nil

  def validate!({:contextual, module, context}), do: contextual(module, context)

  def validate!(%__MODULE__{module: module} = strategy) do
    contextual(module, strategy.context)
  end

  def validate!(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :reflect, 3),
      do: module,
      else: raise(ArgumentError, "GEPA reflection strategy module must export semantic reflect/3")
  end

  def validate!(strategy) when is_function(strategy, 3), do: strategy

  def validate!(strategy) do
    raise ArgumentError,
          "GEPA reflection strategy must be an arity-three function, a module exporting reflect/3, " <>
            "or {:contextual, module, context}; got: #{inspect(strategy)}"
  end

  @doc false
  def reflect(
        %__MODULE__{module: module, context: context} = strategy,
        candidate,
        dataset,
        components
      ) do
    module
    |> apply(:reflect, [candidate, dataset, components, context])
    |> contextual_result(strategy)
  end

  def reflect(module, candidate, dataset, components) when is_atom(module),
    do: module.reflect(candidate, dataset, components)

  def reflect(strategy, candidate, dataset, components) when is_function(strategy, 3),
    do: strategy.(candidate, dataset, components)

  @doc false
  def reflect_many(%__MODULE__{module: module, context: context} = strategy, jobs) do
    if function_exported?(module, :reflect_many, 2) do
      case apply(module, :reflect_many, [jobs, context]) do
        {:ok, proposals, next_context} when is_list(proposals) ->
          {:ok, proposals, %{strategy | context: next_context}}

        {proposals, next_context} when is_list(proposals) ->
          {:ok, proposals, %{strategy | context: next_context}}

        {:error, reason} ->
          {:error, reason}

        other ->
          {:error, {:invalid_contextual_reflect_many_result, other}}
      end
    else
      :unsupported
    end
  end

  def reflect_many(module, jobs) when is_atom(module) do
    if function_exported?(module, :reflect_many, 1),
      do: {:ok, module.reflect_many(jobs), nil},
      else: :unsupported
  end

  def reflect_many(_strategy, _jobs), do: :unsupported

  @doc false
  def observable_cost(source) do
    cost =
      cond do
        match?(%__MODULE__{}, source) ->
          contextual_cost(source)

        is_atom(source) and Code.ensure_loaded?(source) and
            function_exported?(source, :total_cost, 0) ->
          apply(source, :total_cost, [])

        is_struct(source) and function_exported?(source.__struct__, :total_cost, 1) ->
          apply(source.__struct__, :total_cost, [source])

        is_function(source, 0) ->
          source.()

        true ->
          :unobservable
      end

    case cost do
      :unobservable -> :unobservable
      value when is_number(value) and value >= 0 -> {:ok, value * 1.0}
      value -> {:error, {:invalid_reflection_cost, value}}
    end
  end

  @doc false
  def cost_observable?(source), do: match?({:ok, _}, observable_cost(source))

  @doc false
  def dump(nil, nil, _reflection_calls), do: nil

  def dump(
        %__MODULE__{module: module, context: context},
        %__MODULE__{module: module},
        _reflection_calls
      ) do
    unless function_exported?(module, :dump_state, 1) and
             function_exported?(module, :load_state, 1) do
      raise ArgumentError,
            "contextual GEPA reflection strategy #{inspect(module)} is not checkpointable; " <>
              "implement dump_state/1 and load_state/1"
    end

    state = context |> apply_dump(module) |> Imp.Optimizer.Report.encode_term()
    ensure_json_safe!(state, module)

    %{
      "kind" => "contextual",
      "module" => Atom.to_string(module),
      "state" => state
    }
  end

  def dump(module, initial, _reflection_calls) when is_atom(module) and is_atom(initial) do
    %{
      "kind" => "module",
      "initial_module" => Atom.to_string(initial),
      "current_module" => Atom.to_string(module)
    }
  end

  def dump(strategy, initial, 0) when is_function(strategy, 3) and is_function(initial, 3) do
    if strategy === initial do
      %{"kind" => "function_pre_reflection"}
    else
      raise ArgumentError,
            "GEPA reflection strategy returned a non-serializable function successor; " <>
              "use {:contextual, module, context} with state codecs"
    end
  end

  def dump(strategy, initial, reflection_calls)
      when is_function(strategy, 3) and is_function(initial, 3) and reflection_calls > 0 do
    raise ArgumentError,
          "arity-three GEPA reflection functions are not checkpointable after reflection calls; " <>
            "use {:contextual, module, context} with state codecs"
  end

  def dump(strategy, _initial, _reflection_calls) do
    raise ArgumentError,
          "GEPA reflection strategy successor is not checkpointable: #{inspect(strategy)}"
  end

  @doc false
  def load(nil, configured, reflection_calls) do
    if reflection_calls > 0 and not legacy_stateless?(configured) do
      raise ArgumentError,
            "legacy GEPA checkpoint lacks reflection strategy state after reflection calls"
    end

    configured
  end

  def load(%{"kind" => "function_pre_reflection"}, configured, 0)
      when is_function(configured, 3),
      do: configured

  def load(%{"kind" => "stateless_function"}, configured, 0)
      when is_function(configured, 3),
      do: configured

  def load(%{"kind" => kind}, configured, calls)
      when kind in ["function_pre_reflection", "stateless_function"] and
             is_function(configured, 3) and calls > 0 do
    raise ArgumentError,
          "GEPA function reflection strategy checkpoint is invalid after reflection calls"
  end

  def load(
        %{
          "kind" => "module",
          "initial_module" => initial,
          "current_module" => current
        },
        configured,
        _calls
      )
      when is_atom(configured) do
    unless Atom.to_string(configured) == initial do
      raise ArgumentError, "GEPA reflection strategy module mismatch on resume"
    end

    module = String.to_existing_atom(current)
    validate!(module)
  end

  def load(
        %{"kind" => "contextual", "module" => stored_module, "state" => state},
        %__MODULE__{module: module} = configured,
        _calls
      ) do
    unless Atom.to_string(module) == stored_module and function_exported?(module, :load_state, 1) do
      raise ArgumentError, "GEPA contextual reflection strategy mismatch on resume"
    end

    %{
      configured
      | context: apply(module, :load_state, [Imp.Optimizer.Report.decode_term(state)])
    }
  end

  def load(payload, _configured, _calls) do
    raise ArgumentError, "invalid GEPA reflection strategy checkpoint: #{inspect(payload)}"
  end

  defp contextual_result({:ok, proposal, next_context}, strategy),
    do: {:ok, proposal, %{strategy | context: next_context}}

  defp contextual_result({:error, _reason} = error, _strategy), do: error

  defp contextual_result({proposal, next_context}, strategy),
    do: {proposal, %{strategy | context: next_context}}

  defp contextual_result(proposal, strategy), do: {proposal, strategy}

  defp contextual_cost(%__MODULE__{module: module, context: context}) do
    if function_exported?(module, :total_cost, 1),
      do: apply(module, :total_cost, [context]),
      else: :unobservable
  end

  defp apply_dump(context, module), do: apply(module, :dump_state, [context])

  defp ensure_json_safe!(state, module) do
    case Jason.encode(state) do
      {:ok, _json} ->
        :ok

      {:error, reason} ->
        raise ArgumentError,
              "GEPA reflection strategy #{inspect(module)} dump_state/1 returned non-JSON state: " <>
                Exception.message(reason)
    end
  end

  defp legacy_stateless?(nil), do: true
  defp legacy_stateless?(_strategy), do: false
end
