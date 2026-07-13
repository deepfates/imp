defmodule DSEx.BenchmarkTruth.CampaignBudget do
  @moduledoc false

  use GenServer

  @type limit :: non_neg_integer() | number() | :infinity

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def reserve(server, messages, opts) do
    GenServer.call(server, {:reserve, messages, opts})
  end

  def release(server, reservation), do: GenServer.call(server, {:release, reservation})
  def record_usage(server, usage), do: GenServer.call(server, {:usage, usage})
  def snapshot(server), do: GenServer.call(server, :snapshot)

  def attach_req_llm(server) do
    id = {__MODULE__, server, make_ref()}

    :ok =
      :telemetry.attach(
        id,
        [:req_llm, :token_usage],
        fn _event, measurements, _metadata, pid ->
          record_usage(pid, usage_from_measurements(measurements))
        end,
        server
      )

    id
  end

  @impl true
  def init(opts) do
    limits = Keyword.fetch!(opts, :limits)
    pricing = Keyword.fetch!(opts, :pricing)
    default_max_output_tokens = Keyword.fetch!(opts, :default_max_output_tokens)

    unless is_integer(default_max_output_tokens) and default_max_output_tokens >= 0 do
      raise ArgumentError, "default_max_output_tokens must be a non-negative integer"
    end

    {:ok,
     %{
       limits: validate_limits!(limits),
       pricing: validate_pricing!(pricing),
       default_max_output_tokens: default_max_output_tokens,
       requests: 0,
       usage: empty_usage(),
       reservations: %{},
       exhausted: nil
     }}
  end

  @impl true
  def handle_call({:reserve, messages, opts}, _from, state) do
    bounds = reservation_bounds(state, messages, opts)

    case exhausted_dimension(state, bounds) do
      nil ->
        id = make_ref()

        {:reply, {:ok, id},
         %{
           state
           | requests: state.requests + 1,
             reservations: Map.put(state.reservations, id, bounds)
         }}

      dimension ->
        {:reply, {:error, dimension}, %{state | exhausted: dimension}}
    end
  end

  def handle_call({:release, id}, _from, state) do
    {:reply, :ok, %{state | reservations: Map.delete(state.reservations, id)}}
  end

  def handle_call({:usage, usage}, _from, state) do
    {:reply, :ok, %{state | usage: sum_usage(state.usage, normalize_usage!(usage))}}
  end

  def handle_call(:snapshot, _from, state) do
    reserved = reserved_totals(state.reservations)

    snapshot = %{
      "limits" => stringify_limits(state.limits),
      "pricing" => state.pricing,
      "requests" => state.requests,
      "usage" => state.usage,
      "reserved" => reserved,
      "active_reservations" => map_size(state.reservations),
      "exhausted" => state.exhausted && Atom.to_string(state.exhausted)
    }

    {:reply, snapshot, state}
  end

  defp reservation_bounds(state, messages, opts) do
    input_tokens = messages |> :erlang.term_to_binary() |> byte_size() |> Kernel.+(256)
    output_tokens = Keyword.get(opts, :max_tokens, state.default_max_output_tokens)

    unless is_integer(output_tokens) and output_tokens >= 0 do
      raise ArgumentError, "campaign LM :max_tokens must be a non-negative integer"
    end

    usd =
      input_tokens / 1_000_000 * state.pricing["input_per_million"] +
        output_tokens / 1_000_000 * state.pricing["output_per_million"]

    %{"input_tokens" => input_tokens, "output_tokens" => output_tokens, "usd" => usd}
  end

  defp exhausted_dimension(state, bounds) do
    reserved = reserved_totals(state.reservations)

    totals = %{
      requests: state.requests + 1,
      input_tokens:
        state.usage["input_tokens"] + reserved["input_tokens"] + bounds["input_tokens"],
      output_tokens:
        state.usage["output_tokens"] + reserved["output_tokens"] + bounds["output_tokens"],
      usd: state.usage["usd"] + reserved["usd"] + bounds["usd"]
    }

    Enum.find([:requests, :input_tokens, :output_tokens, :usd], fn key ->
      limit = Map.fetch!(state.limits, key)
      limit != :infinity and Map.fetch!(totals, key) > limit
    end)
  end

  defp reserved_totals(reservations) do
    Enum.reduce(reservations, empty_usage(), fn {_id, bounds}, total ->
      sum_usage(total, bounds)
    end)
  end

  defp validate_limits!(limits) when is_map(limits) do
    normalized = %{
      requests: fetch_limit(limits, :requests),
      input_tokens: fetch_limit(limits, :input_tokens),
      output_tokens: fetch_limit(limits, :output_tokens),
      usd: fetch_limit(limits, :usd)
    }

    Enum.each(normalized, fn
      {_key, :infinity} ->
        :ok

      {key, value} when is_number(value) and value >= 0 ->
        if key != :usd and not is_integer(value),
          do: raise(ArgumentError, "campaign #{key} limit must be a non-negative integer")

      {key, _value} ->
        raise ArgumentError, "campaign #{key} limit must be non-negative or :infinity"
    end)

    normalized
  end

  defp validate_limits!(other),
    do: raise(ArgumentError, "campaign limits must be a map, got: #{inspect(other)}")

  defp validate_pricing!(
         %{
           "input_per_million" => input,
           "output_per_million" => output
         } = pricing
       )
       when is_number(input) and input >= 0 and is_number(output) and output >= 0,
       do: pricing

  defp validate_pricing!(other),
    do:
      raise(
        ArgumentError,
        "campaign pricing must contain non-negative input_per_million and output_per_million, got: #{inspect(other)}"
      )

  defp fetch_limit(limits, key) do
    Map.get(limits, key, Map.get(limits, Atom.to_string(key), :infinity))
  end

  defp stringify_limits(limits) do
    Map.new(limits, fn {key, value} ->
      {Atom.to_string(key), if(value == :infinity, do: "infinity", else: value)}
    end)
  end

  defp normalize_usage!(usage) when is_map(usage) do
    normalized = %{
      "input_tokens" => number(usage, :input_tokens),
      "output_tokens" => number(usage, :output_tokens),
      "usd" => number(usage, :usd)
    }

    unless is_integer(normalized["input_tokens"]) and normalized["input_tokens"] >= 0 and
             is_integer(normalized["output_tokens"]) and normalized["output_tokens"] >= 0 and
             is_number(normalized["usd"]) and normalized["usd"] >= 0 do
      raise ArgumentError, "campaign usage must contain non-negative token counts and usd"
    end

    normalized
  end

  defp number(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key), 0))

  defp usage_from_measurements(measurements) do
    tokens = Map.get(measurements, :tokens, %{})

    %{
      input_tokens: trunc(first_number(tokens, [:input_tokens, :input])),
      output_tokens: trunc(first_number(tokens, [:output_tokens, :output])),
      usd: first_number(measurements, [:total_cost, :cost])
    }
  end

  defp first_number(map, keys) do
    Enum.find_value(keys, 0, fn key ->
      value = Map.get(map, key, Map.get(map, Atom.to_string(key)))
      if is_number(value), do: value
    end)
  end

  defp sum_usage(left, right) do
    %{
      "input_tokens" => left["input_tokens"] + right["input_tokens"],
      "output_tokens" => left["output_tokens"] + right["output_tokens"],
      "usd" => left["usd"] + right["usd"]
    }
  end

  defp empty_usage, do: %{"input_tokens" => 0, "output_tokens" => 0, "usd" => 0.0}
end

defmodule DSEx.BenchmarkTruth.BudgetedLM do
  @moduledoc false

  @behaviour DSEx.LM

  defstruct [:inner, :budget]

  @impl true
  def generate(_messages, _opts), do: {:error, :budgeted_lm_instance_required}

  def generate(%__MODULE__{} = lm, messages, opts) do
    case DSEx.BenchmarkTruth.CampaignBudget.reserve(lm.budget, messages, opts) do
      {:ok, reservation} ->
        try do
          DSEx.LM.generate(lm.inner, messages, opts)
        after
          DSEx.BenchmarkTruth.CampaignBudget.release(lm.budget, reservation)
        end

      {:error, dimension} ->
        {:error, {:campaign_budget_exhausted, dimension}}
    end
  end
end
