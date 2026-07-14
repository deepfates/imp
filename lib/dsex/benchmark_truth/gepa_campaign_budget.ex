defmodule DSEx.BenchmarkTruth.GepaCampaignBudget do
  @moduledoc false

  use GenServer

  alias DSEx.BenchmarkTruth.GepaCampaignBudgetedLM

  @dimensions [:requests, :input_tokens, :output_tokens, :usd]
  @default_max_tokens 16_384

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def wrap_lm(lm, server, shard), do: GepaCampaignBudgetedLM.new(lm, server, shard)

  def reserve(server, shard, messages, opts),
    do: GenServer.call(server, {:reserve, shard, messages, opts})

  def release(server, reservation), do: GenServer.call(server, {:release, reservation})

  def snapshot(server), do: GenServer.call(server, :snapshot)

  def attach_req_llm(server, shard) do
    id = {__MODULE__, server, shard, make_ref()}

    :ok =
      :telemetry.attach(
        id,
        [:req_llm, :token_usage],
        &__MODULE__.handle_req_llm_usage_event/4,
        {server, shard}
      )

    id
  end

  @doc false
  def handle_req_llm_usage_event(_event, measurements, _metadata, {server, shard}) do
    GenServer.call(server, {:usage, shard, usage_from_measurements(measurements)})
  end

  @impl true
  def init(opts) do
    identity = Keyword.fetch!(opts, :identity)
    checkpoint_path = Keyword.fetch!(opts, :checkpoint_path)
    limits = normalize_limits!(Keyword.fetch!(opts, :limits), "aggregate")
    shard_limits = normalize_shard_limits!(Keyword.fetch!(opts, :shard_limits))
    pricing = normalize_pricing!(Keyword.fetch!(opts, :pricing))

    state =
      case File.read(checkpoint_path) do
        {:ok, contents} ->
          load_checkpoint!(contents, checkpoint_path, identity, limits, shard_limits, pricing)

        {:error, :enoent} ->
          empty_state(identity, checkpoint_path, limits, shard_limits, pricing)

        {:error, reason} ->
          raise File.Error,
            reason: reason,
            action: "read GEPA budget checkpoint",
            path: checkpoint_path
      end

    state = reconcile_reservations!(state)
    ensure_observed_within_limits!(state)

    {:ok, state}
  end

  @impl true
  def handle_call({:reserve, shard, messages, opts}, _from, state) do
    ensure_shard!(state, shard)
    bounds = reservation_bounds(state, messages, opts)
    shard_state = Map.fetch!(state.shards, shard)
    aggregate_reserved = reserved_totals(state.reservations)

    shard_reserved =
      state.reservations
      |> Enum.filter(fn {_id, reservation} -> reservation.shard == shard end)
      |> Map.new()
      |> reserved_totals()

    with :ok <- available(state, state.aggregate, aggregate_reserved, bounds, :aggregate),
         :ok <- available(state, shard_state, shard_reserved, bounds, {:shard, shard}) do
      id = make_ref()
      reservation = %{id: id, shard: shard, bounds: bounds}

      updated =
        state
        |> Map.update!(:aggregate, &%{&1 | requests: &1.requests + 1})
        |> Map.update!(
          :shards,
          &Map.update!(&1, shard, fn value -> %{value | requests: value.requests + 1} end)
        )
        |> Map.put(:reservations, Map.put(state.reservations, id, reservation))

      persist!(updated)
      {:reply, {:ok, id}, updated}
    else
      {:error, dimension} ->
        {:reply, {:error, dimension}, %{state | exhausted: dimension}}
    end
  end

  def handle_call({:release, id}, _from, state) do
    case Map.pop(state.reservations, id) do
      {nil, _} ->
        {:reply, :ok, state}

      {_reservation, reservations} ->
        updated = %{state | reservations: reservations}
        persist!(updated)
        {:reply, :ok, updated}
    end
  end

  def handle_call({:usage, shard, usage}, _from, state) do
    ensure_shard!(state, shard)
    usage = normalize_usage!(usage)
    aggregate = add_usage(state.aggregate, usage)
    shard_state = state.shards |> Map.fetch!(shard) |> add_usage(usage)
    exhausted = state.exhausted || observed_exhausted(aggregate, state.limits)

    updated = %{
      state
      | aggregate: aggregate,
        shards: Map.put(state.shards, shard, shard_state),
        exhausted: exhausted
    }

    persist!(updated)
    {:reply, :ok, updated}
  end

  def handle_call(:snapshot, _from, state) do
    {:reply,
     %{
       "identity" => state.identity,
       "limits" => stringify_limits(state.limits),
       "aggregate" => dump_account(state.aggregate),
       "shards" =>
         Map.new(state.shards, fn {family, account} ->
           {family, dump_snapshot_account(account, state.shard_limits[family])}
         end),
       "shard_exhausted" =>
         Map.new(state.shards, fn {family, account} ->
           {family, dump_exhausted(observed_exhausted(account, state.shard_limits[family]))}
         end),
       "active_reservations" => map_size(state.reservations),
       "exhausted" => dump_exhausted(state.exhausted),
       "reconciliations" => state.reconciliations
     }, state}
  end

  defp empty_state(identity, checkpoint_path, limits, shard_limits, pricing) do
    %{
      identity: identity,
      checkpoint_path: checkpoint_path,
      limits: limits,
      shard_limits: shard_limits,
      pricing: pricing,
      aggregate: empty_account(),
      shards: Map.new(shard_limits, fn {family, _limits} -> {family, empty_account()} end),
      reservations: %{},
      reconciliations: [],
      exhausted: nil
    }
  end

  defp load_checkpoint!(contents, path, identity, limits, shard_limits, pricing) do
    checkpoint = Jason.decode!(contents)

    unless checkpoint["schema_version"] == 1 and checkpoint["identity"] == identity do
      raise ArgumentError, "GEPA budget checkpoint identity mismatch: #{path}"
    end

    unless checkpoint["limits"] == stringify_limits(limits) and
             checkpoint["shard_limits"] == stringify_shard_limits(shard_limits) and
             checkpoint["pricing"] == pricing do
      raise ArgumentError, "GEPA budget checkpoint ceiling or pricing mismatch: #{path}"
    end

    reservations = decode_reservations!(checkpoint["reservations"], path)
    shards = decode_accounts!(checkpoint["shards"], shard_limits, path)

    %{
      identity: identity,
      checkpoint_path: path,
      limits: limits,
      shard_limits: shard_limits,
      pricing: pricing,
      aggregate: decode_account!(checkpoint["aggregate"], path),
      shards: shards,
      reservations: reservations,
      reconciliations: checkpoint["reconciliations"] || [],
      exhausted: load_exhausted(checkpoint["exhausted"])
    }
  rescue
    error in [Jason.DecodeError, KeyError] ->
      raise ArgumentError, "invalid GEPA budget checkpoint #{path}: #{Exception.message(error)}"
  end

  defp reservation_bounds(state, messages, opts) do
    input_tokens = messages |> :erlang.term_to_binary() |> byte_size() |> Kernel.+(256)
    output_tokens = Keyword.get(opts, :max_tokens, @default_max_tokens)

    unless is_integer(output_tokens) and output_tokens >= 0,
      do: raise(ArgumentError, "GEPA campaign :max_tokens must be a non-negative integer")

    usd =
      input_tokens / 1_000_000 * state.pricing["input_per_million"] +
        output_tokens / 1_000_000 * state.pricing["output_per_million"]

    %{"input_tokens" => input_tokens, "output_tokens" => output_tokens, "usd" => usd}
  end

  defp available(state, account, reserved, bounds, scope) do
    totals = %{
      requests: account.requests + 1,
      input_tokens:
        account.usage["input_tokens"] + reserved["input_tokens"] + bounds["input_tokens"],
      output_tokens:
        account.usage["output_tokens"] + reserved["output_tokens"] + bounds["output_tokens"],
      usd: account.usage["usd"] + reserved["usd"] + bounds["usd"]
    }

    Enum.find_value(@dimensions, :ok, fn dimension ->
      limit =
        if scope == :aggregate,
          do: state.limits[dimension],
          else: state.shard_limits[elem(scope, 1)][dimension]

      if limit != :infinity and totals[dimension] > limit, do: {:error, dimension}
    end)
  end

  defp observed_exhausted(account, limits) do
    Enum.find(@dimensions, fn dimension ->
      value =
        if dimension == :requests,
          do: account.requests,
          else: account.usage[Atom.to_string(dimension)]

      limit = limits[dimension]
      limit != :infinity and value > limit
    end)
  end

  defp ensure_observed_within_limits!(state) do
    case observed_exhausted(state.aggregate, state.limits) do
      nil ->
        Enum.each(state.shards, fn {family, account} ->
          case observed_exhausted(account, state.shard_limits[family]) do
            nil ->
              :ok

            dimension ->
              raise ArgumentError,
                    "GEPA budget reconciliation exhausted shard #{family} at #{dimension}"
          end
        end)

      dimension ->
        raise ArgumentError, "GEPA budget reconciliation exhausted aggregate at #{dimension}"
    end
  end

  defp reconcile_reservations!(%{reservations: reservations} = state)
       when map_size(reservations) == 0,
       do: state

  defp reconcile_reservations!(state) do
    ordered = Enum.sort_by(state.reservations, fn {id, _reservation} -> inspect(id) end)

    {aggregate, shards, records} =
      Enum.reduce(ordered, {state.aggregate, state.shards, []}, fn {id, reservation},
                                                                   {aggregate, shards, records} ->
        shard = reservation.shard
        updated_aggregate = add_usage(aggregate, reservation.bounds)
        updated_shard = shards |> Map.fetch!(shard) |> add_usage(reservation.bounds)

        record = %{
          "reservation_id" => inspect(id),
          "shard" => shard,
          "charged" => reservation.bounds,
          "reason" => "restart_reconciliation"
        }

        {updated_aggregate, Map.put(shards, shard, updated_shard), [record | records]}
      end)

    updated = %{
      state
      | aggregate: aggregate,
        shards: shards,
        reservations: %{},
        reconciliations: state.reconciliations ++ Enum.reverse(records)
    }

    persist!(updated)
    updated
  end

  defp reserved_totals(reservations) do
    Enum.reduce(reservations, empty_usage(), fn {_id, reservation}, total ->
      add_usage(total, reservation.bounds)
    end)
  end

  defp add_usage(account, usage) when is_map(account) and is_map_key(account, :usage),
    do: %{account | usage: add_usage(account.usage, usage)}

  defp add_usage(left, right) do
    %{
      "input_tokens" => left["input_tokens"] + right["input_tokens"],
      "output_tokens" => left["output_tokens"] + right["output_tokens"],
      "usd" => left["usd"] + right["usd"]
    }
  end

  defp dump_account(account) do
    %{
      "requests" => account.requests,
      "usage" => account.usage,
      "active_reservations" => map_size(account.reservations)
    }
  end

  defp dump_snapshot_account(account, limits) do
    dump_account(account)
    |> Map.put("limits", stringify_limits(limits))
    |> Map.put("exhausted", dump_exhausted(observed_exhausted(account, limits)))
  end

  defp dump_exhausted(nil), do: nil
  defp dump_exhausted(dimension), do: Atom.to_string(dimension)

  defp load_exhausted(nil), do: nil

  defp load_exhausted(value) when is_binary(value) do
    value = String.trim_leading(value, ":")

    if value in Enum.map(@dimensions, &Atom.to_string/1),
      do: String.to_existing_atom(value),
      else: raise(ArgumentError, "invalid GEPA budget exhausted dimension: #{inspect(value)}")
  end

  defp load_exhausted(value),
    do: raise(ArgumentError, "invalid GEPA budget exhausted dimension: #{inspect(value)}")

  defp empty_account, do: %{requests: 0, usage: empty_usage(), reservations: %{}}
  defp empty_usage, do: %{"input_tokens" => 0, "output_tokens" => 0, "usd" => 0.0}

  defp persist!(state) do
    checkpoint = %{
      "schema_version" => 1,
      "identity" => state.identity,
      "limits" => stringify_limits(state.limits),
      "shard_limits" => stringify_shard_limits(state.shard_limits),
      "pricing" => state.pricing,
      "aggregate" => dump_account(state.aggregate),
      "shards" =>
        Map.new(state.shards, fn {family, account} -> {family, dump_account(account)} end),
      "reservations" =>
        Enum.map(state.reservations, fn {id, reservation} ->
          %{"id" => inspect(id), "shard" => reservation.shard, "bounds" => reservation.bounds}
        end),
      "exhausted" => dump_exhausted(state.exhausted),
      "reconciliations" => state.reconciliations
    }

    temporary = state.checkpoint_path <> ".tmp-#{System.unique_integer([:positive])}"
    File.mkdir_p!(Path.dirname(state.checkpoint_path))
    File.write!(temporary, Jason.encode!(checkpoint, pretty: true) <> "\n", [:sync])
    File.rename!(temporary, state.checkpoint_path)
  end

  defp decode_account!(
         %{"requests" => requests, "usage" => usage, "active_reservations" => active},
         path
       )
       when is_integer(active) and active >= 0,
       do: validate_account!(%{requests: requests, usage: usage, reservations: %{}}, path)

  defp decode_account!(account, path),
    do: raise(ArgumentError, "invalid GEPA budget account: #{path}: #{inspect(account)}")

  defp decode_accounts!(accounts, shard_limits, path) when is_map(accounts) do
    unless Map.keys(accounts) |> Enum.sort() == Map.keys(shard_limits) |> Enum.sort(),
      do: raise(ArgumentError, "GEPA budget checkpoint shard identity mismatch: #{path}")

    Map.new(shard_limits, fn {family, _limits} ->
      {family, decode_account!(Map.fetch!(accounts, family), path)}
    end)
  end

  defp decode_accounts!(_accounts, _limits, path),
    do: raise(ArgumentError, "invalid GEPA budget checkpoint shards: #{path}")

  defp decode_reservations!([], _path), do: %{}

  defp decode_reservations!(reservations, path) when is_list(reservations) do
    Map.new(reservations, fn
      %{"id" => id, "shard" => shard, "bounds" => bounds} ->
        {id, %{id: id, shard: shard, bounds: normalize_usage!(bounds)}}

      value ->
        raise(ArgumentError, "invalid GEPA budget reservation #{path}: #{inspect(value)}")
    end)
  end

  defp decode_reservations!(value, path),
    do: raise(ArgumentError, "invalid GEPA budget reservations #{path}: #{inspect(value)}")

  defp validate_account!(account, path) do
    unless is_integer(account.requests) and account.requests >= 0 and valid_usage?(account.usage),
      do: raise(ArgumentError, "invalid GEPA budget account #{path}")

    account
  end

  defp normalize_limits!(limits, label) when is_map(limits) do
    normalized =
      Map.new(@dimensions, fn key ->
        {key, Map.get(limits, key, Map.get(limits, Atom.to_string(key), :infinity))}
      end)

    Enum.each(normalized, fn
      {_key, :infinity} ->
        :ok

      {key, value} when key == :usd and is_number(value) and value >= 0 ->
        :ok

      {_key, value} when is_integer(value) and value >= 0 ->
        :ok

      {key, value} ->
        raise(
          ArgumentError,
          "GEPA #{label} #{key} ceiling must be non-negative: #{inspect(value)}"
        )
    end)

    normalized
  end

  defp normalize_limits!(_limits, label),
    do: raise(ArgumentError, "GEPA #{label} ceilings must be a map")

  defp normalize_shard_limits!(limits) when is_map(limits),
    do:
      Map.new(limits, fn {family, value} ->
        family = if is_atom(family), do: Atom.to_string(family), else: family
        {family, normalize_limits!(value, "shard #{family}")}
      end)

  defp normalize_shard_limits!(_limits),
    do: raise(ArgumentError, "GEPA per-shard ceilings must be a map")

  defp normalize_pricing!(
         %{"input_per_million" => input, "output_per_million" => output} = pricing
       )
       when is_number(input) and input >= 0 and is_number(output) and output >= 0,
       do: pricing

  defp normalize_pricing!(value),
    do: raise(ArgumentError, "GEPA budget reservation pricing is invalid: #{inspect(value)}")

  defp normalize_usage!(usage) when is_map(usage) do
    normalized = %{
      "input_tokens" => Map.get(usage, "input_tokens", 0),
      "output_tokens" => Map.get(usage, "output_tokens", 0),
      "usd" => Map.get(usage, "usd", 0.0)
    }

    if valid_usage?(normalized),
      do: normalized,
      else: raise(ArgumentError, "invalid GEPA budget usage")
  end

  defp normalize_usage!(value),
    do: raise(ArgumentError, "invalid GEPA budget usage: #{inspect(value)}")

  defp valid_usage?(usage),
    do:
      is_integer(usage["input_tokens"]) and usage["input_tokens"] >= 0 and
        is_integer(usage["output_tokens"]) and usage["output_tokens"] >= 0 and
        is_number(usage["usd"]) and usage["usd"] >= 0

  defp usage_from_measurements(measurements) do
    tokens = Map.get(measurements, :tokens, %{})

    %{
      "input_tokens" => trunc(first_number(tokens, [:input_tokens, :input])),
      "output_tokens" => trunc(first_number(tokens, [:output_tokens, :output])),
      "usd" => first_number(measurements, [:total_cost, :cost])
    }
  end

  defp first_number(map, keys) do
    Enum.find_value(keys, 0, fn key ->
      value = Map.get(map, key, Map.get(map, Atom.to_string(key)))
      if is_number(value) and value >= 0, do: value
    end)
  end

  defp ensure_shard!(state, shard) do
    unless Map.has_key?(state.shards, shard),
      do:
        raise(
          ArgumentError,
          "GEPA campaign family is not an immutable budget shard: #{inspect(shard)}"
        )
  end

  defp stringify_limits(limits),
    do:
      Map.new(limits, fn {key, value} ->
        {Atom.to_string(key), if(value == :infinity, do: "infinity", else: value)}
      end)

  defp stringify_shard_limits(limits),
    do: Map.new(limits, fn {family, value} -> {family, stringify_limits(value)} end)
end

defmodule DSEx.BenchmarkTruth.GepaCampaignBudgetedLM do
  @moduledoc false

  @behaviour DSEx.LM

  defstruct [:inner, :budget, :shard]

  def new(inner, budget, shard), do: %__MODULE__{inner: inner, budget: budget, shard: shard}

  @impl true
  def generate(_messages, _opts), do: {:error, :budgeted_lm_instance_required}

  def generate(%__MODULE__{} = lm, messages, opts) do
    case DSEx.BenchmarkTruth.GepaCampaignBudget.reserve(lm.budget, lm.shard, messages, opts) do
      {:ok, reservation} ->
        try do
          DSEx.LM.generate(lm.inner, messages, opts)
        after
          DSEx.BenchmarkTruth.GepaCampaignBudget.release(lm.budget, reservation)
        end

      {:error, dimension} ->
        {:error, {:campaign_budget_exhausted, dimension}}
    end
  end
end
