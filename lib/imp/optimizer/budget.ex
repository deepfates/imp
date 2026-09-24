defmodule Imp.Optimizer.Budget do
  @moduledoc """
  Prospective request, token, and cost limits for live optimizer work.

  A budget reserves the worst-case input, output, and price envelope before an
  LM request begins, records provider-reported usage, and exposes a portable
  snapshot suitable for an experiment Result or Artifact. Resuming from a
  snapshot conservatively charges unresolved reservations once, so a crash
  cannot silently restore spend capacity.

  Use `Imp.budgeted_lm/3` to wrap every task and proposal LM participating in
  the workflow. The wrapper disables hidden transport retries, counts the
  actual Req transport attempt, and records provider telemetry in the calling
  process, keeping a logical request from escaping the declared ceilings.
  """

  use GenServer

  @credential_marker ~r/(?:api[_-]?key|authorization|proxy[_-]?authorization|bearer(?:[_-]?token)?|access[_-]?token|refresh[_-]?token|id[_-]?token|session(?:[_-]?token)?|secret(?:[_-]?(?:access[_-]?key|key))?|client[_-]?secret|private[_-]?(?:key|token)|password|credential(?:s)?)/i
  @secret_shape ~r/(?:sk-(?:proj-)?[A-Za-z0-9_-]{12,}|AKIA[0-9A-Z]{12,}|-----BEGIN [A-Z ]*PRIVATE KEY-----)/

  @type limit :: non_neg_integer() | number() | :infinity

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def reserve(server, messages, opts) do
    GenServer.call(server, {:reserve, messages, opts})
  end

  def release(server, reservation), do: GenServer.call(server, {:release, reservation})
  def record_usage(server, usage), do: GenServer.call(server, {:usage, usage})

  def authorize_transport_attempt(server),
    do: GenServer.call(server, :authorize_transport_attempt)

  def snapshot(server), do: GenServer.call(server, :snapshot)

  @doc false
  def validate_pricing_source_url!(url) when is_binary(url) do
    uri = URI.parse(url)

    valid? =
      url == String.trim(url) and not String.contains?(url, ["\\", "\0", "\r", "\n"]) and
        uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" and
        is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment) and
        ordinary_port?(uri.port) and
        Enum.all?([uri.host, uri.path], &credential_free_component?/1)

    unless valid? do
      raise ArgumentError,
            "optimizer pricing source_url must be an ordinary credential-free HTTP(S) documentation URL"
    end

    url
  end

  def validate_pricing_source_url!(_url) do
    raise ArgumentError,
          "optimizer pricing source_url must be an ordinary credential-free HTTP(S) documentation URL"
  end

  defp credential_free_component?(nil), do: true

  defp credential_free_component?(component) when is_binary(component) do
    case decoded_forms(component) do
      {:ok, forms} ->
        Enum.all?(forms, fn decoded ->
          Imp.Redaction.redact(decoded) == decoded and
            not Regex.match?(@credential_marker, decoded) and
            not Regex.match?(@secret_shape, decoded)
        end)

      :error ->
        false
    end
  rescue
    ArgumentError -> false
  end

  defp decoded_forms(component), do: decode_component(component, [component], 0)
  defp decode_component(_current, _forms, 8), do: :error

  defp decode_component(current, forms, depth) do
    decoded = current |> URI.decode() |> URI.decode_www_form()

    cond do
      decoded == current -> {:ok, forms}
      decoded in forms -> :error
      true -> decode_component(decoded, [decoded | forms], depth + 1)
    end
  end

  defp ordinary_port?(nil), do: true
  defp ordinary_port?(port), do: is_integer(port) and port in 1..65_535

  @doc false
  def evidence_digest(value) do
    encoded = :erlang.term_to_binary(value, [:deterministic])
    "sha256:" <> (:crypto.hash(:sha256, encoded) |> Base.encode16(case: :lower))
  end

  def attach_req_llm(server, opts \\ []) do
    owner = Keyword.get(opts, :owner)

    unless is_nil(owner) or is_pid(owner) do
      raise ArgumentError, "campaign budget telemetry :owner must be a pid or nil"
    end

    id = {__MODULE__, server, make_ref()}
    handler_config = if(is_nil(owner), do: {server, id}, else: {server, id, owner})

    :ok =
      :telemetry.attach(
        id,
        [:req_llm, :token_usage],
        &__MODULE__.handle_req_llm_usage_event/4,
        handler_config
      )

    id
  end

  def handle_req_llm_usage_event(event, measurements, metadata, {server, id, owner})
      when is_pid(owner) do
    if Imp.Telemetry.emitted_for?(owner),
      do: handle_req_llm_usage_event(event, measurements, metadata, {server, id}),
      else: :ok
  end

  @doc false
  def handle_req_llm_usage_event(_event, measurements, _metadata, {server, id})
      when is_pid(server) do
    usage = usage_from_measurements(measurements)

    if Process.alive?(server) do
      try do
        record_usage(server, usage)
      catch
        :exit, reason ->
          if Process.alive?(server), do: exit(reason), else: detach_handler(id)
      end
    else
      detach_handler(id)
    end

    :ok
  end

  @doc false
  def handle_req_llm_usage_event(_event, measurements, _metadata, server) do
    if Process.alive?(server) do
      record_usage(server, usage_from_measurements(measurements))
    end

    :ok
  end

  @impl true
  def init(opts) do
    limits = Keyword.fetch!(opts, :limits)
    pricing = Keyword.fetch!(opts, :pricing)
    default_max_output_tokens = Keyword.fetch!(opts, :default_max_output_tokens)
    initial = opts |> Keyword.get(:initial, %{}) |> validate_initial!()
    on_change = Keyword.get(opts, :on_change)

    unless is_nil(on_change) or is_function(on_change, 1) do
      raise ArgumentError, "campaign budget :on_change must be an arity-one function or nil"
    end

    unless is_integer(default_max_output_tokens) and default_max_output_tokens >= 0 do
      raise ArgumentError, "default_max_output_tokens must be a non-negative integer"
    end

    reservations = initial_reservations!(initial)

    state = %{
      limits: validate_limits!(limits),
      pricing: validate_pricing!(pricing),
      default_max_output_tokens: default_max_output_tokens,
      requests: initial_requests!(initial),
      transport_attempts: initial_transport_attempts!(initial),
      single_attempt_transport_enforced: initial_transport_guard!(initial),
      usage: initial_usage!(initial) |> reconcile_reservations(reservations),
      reservations: %{},
      exhausted: nil,
      on_change: on_change
    }

    state = %{state | exhausted: observed_exhausted_dimension(state)}
    {:ok, notify_change(state)}
  end

  @impl true
  def handle_call({:reserve, messages, opts}, _from, state) do
    bounds = reservation_bounds(state, messages, opts)

    case exhausted_dimension(state, bounds) do
      nil ->
        id = reservation_id()

        reservation = %{"bounds" => bounds}

        state = %{
          state
          | requests: state.requests + 1,
            reservations: Map.put(state.reservations, id, reservation)
        }

        {:reply, {:ok, id}, notify_change(state)}

      dimension ->
        {:reply, {:error, dimension}, notify_change(%{state | exhausted: dimension})}
    end
  end

  def handle_call({:release, id}, _from, state) do
    state = %{state | reservations: Map.delete(state.reservations, id)}
    {:reply, :ok, notify_change(state)}
  end

  def handle_call({:usage, usage}, _from, state) do
    state = %{
      state
      | usage: sum_usage(state.usage, normalize_usage!(usage))
    }

    exhausted = state.exhausted || observed_exhausted_dimension(state)
    {:reply, :ok, notify_change(%{state | exhausted: exhausted})}
  end

  def handle_call(:authorize_transport_attempt, _from, state) do
    if state.transport_attempts < state.limits.requests do
      state = %{
        state
        | transport_attempts: state.transport_attempts + 1,
          single_attempt_transport_enforced: true
      }

      {:reply, :ok, notify_change(state)}
    else
      state = %{state | exhausted: :requests}
      {:reply, {:error, :requests}, notify_change(state)}
    end
  end

  def handle_call(:snapshot, _from, state) do
    reserved = reserved_totals(state.reservations)

    snapshot = %{
      "reservation_ledger_version" => 2,
      "limits" => stringify_limits(state.limits),
      "pricing" => state.pricing,
      "requests" => state.requests,
      "transport_attempts" => state.transport_attempts,
      "single_attempt_transport_enforced" => state.single_attempt_transport_enforced,
      "usage" => state.usage,
      "reserved" => reserved,
      "active_reservations" => map_size(state.reservations),
      "reservations" => dump_reservations(state.reservations),
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

  defp observed_exhausted_dimension(state) do
    Enum.find([:input_tokens, :output_tokens, :usd], fn key ->
      limit = Map.fetch!(state.limits, key)
      observed = state.usage[Atom.to_string(key)]
      limit != :infinity and observed > limit
    end)
  end

  defp reserved_totals(reservations) do
    Enum.reduce(reservations, empty_usage(), fn {_id, reservation}, total ->
      sum_usage(total, reservation["bounds"])
    end)
  end

  defp dump_reservations(reservations) do
    Enum.map(reservations, fn {id, reservation} ->
      %{
        "id" => id,
        "bounds" => reservation["bounds"]
      }
    end)
    |> Enum.sort_by(& &1["id"])
  end

  defp initial_reservations!(initial) when map_size(initial) == 0, do: []

  defp initial_reservations!(initial) do
    case Map.get(initial, "reservations", Map.get(initial, :reservations)) do
      reservations when is_list(reservations) ->
        Enum.map(reservations, &normalize_reservation!/1)

      other ->
        raise ArgumentError,
              "initial campaign reservations must be a list, got: #{inspect(other)}"
    end
  end

  defp normalize_reservation!(%{"id" => id, "bounds" => bounds})
       when is_binary(id) and id != "" do
    %{"id" => id, "bounds" => normalize_usage!(bounds)}
  end

  defp normalize_reservation!(other),
    do: raise(ArgumentError, "initial campaign reservation is invalid: #{inspect(other)}")

  defp reconcile_reservations(usage, reservations) do
    Enum.reduce(reservations, usage, fn reservation, usage ->
      sum_usage(usage, reservation["bounds"])
    end)
  end

  defp reservation_id do
    "reservation-" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
  end

  defp detach_handler(id) do
    :telemetry.detach(id)
    :ok
  end

  defp notify_change(%{on_change: nil} = state), do: state

  defp notify_change(%{on_change: callback} = state) do
    callback.(snapshot_for_state(state))
    state
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
       when is_number(input) and input >= 0 and is_number(output) and output >= 0 do
    case Map.get(pricing, "source_url", Map.get(pricing, :source_url)) do
      nil -> :ok
      source_url -> validate_pricing_source_url!(source_url)
    end

    pricing
  end

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

  defp initial_requests!(initial) when is_map(initial) do
    requests = Map.get(initial, "requests", Map.get(initial, :requests, 0))

    if is_integer(requests) and requests >= 0,
      do: requests,
      else: raise(ArgumentError, "initial campaign requests must be a non-negative integer")
  end

  defp initial_transport_attempts!(initial) when is_map(initial) do
    attempts =
      Map.get(
        initial,
        "transport_attempts",
        Map.get(initial, :transport_attempts, initial_requests!(initial))
      )

    if is_integer(attempts) and attempts >= 0,
      do: attempts,
      else: raise(ArgumentError, "initial transport attempts must be a non-negative integer")
  end

  defp initial_transport_guard!(initial) when is_map(initial) do
    Map.get(
      initial,
      "single_attempt_transport_enforced",
      Map.get(initial, :single_attempt_transport_enforced, false)
    ) == true
  end

  defp validate_initial!(initial) when is_map(initial), do: initial

  defp validate_initial!(other),
    do: raise(ArgumentError, "initial campaign budget must be a map, got: #{inspect(other)}")

  defp initial_usage!(initial) do
    initial
    |> Map.get("usage", Map.get(initial, :usage, empty_usage()))
    |> normalize_usage!()
  end

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

  defp snapshot_for_state(state) do
    reserved = reserved_totals(state.reservations)

    %{
      "reservation_ledger_version" => 2,
      "limits" => stringify_limits(state.limits),
      "pricing" => state.pricing,
      "requests" => state.requests,
      "transport_attempts" => state.transport_attempts,
      "single_attempt_transport_enforced" => state.single_attempt_transport_enforced,
      "usage" => state.usage,
      "reserved" => reserved,
      "active_reservations" => map_size(state.reservations),
      "reservations" => dump_reservations(state.reservations),
      "exhausted" => state.exhausted && Atom.to_string(state.exhausted)
    }
  end
end

defmodule Imp.LM.Budgeted do
  @moduledoc """
  An LM decorator that enforces an `Imp.Optimizer.Budget` before transport.

  Construct it with `Imp.budgeted_lm/3`; direct struct construction is public
  but the facade validates the common options more clearly.
  """

  @behaviour Imp.LM

  defstruct [:inner, :budget, :max_output_tokens, record_usage: true]

  @impl true
  def generate(_messages, _opts), do: {:error, :budgeted_lm_instance_required}

  def generate(%__MODULE__{} = lm, messages, opts) do
    with {:ok, bounded_opts} <- bound_output_tokens(lm.max_output_tokens, opts),
         {:ok, reservation} <-
           Imp.Optimizer.Budget.reserve(lm.budget, messages, bounded_opts) do
      telemetry_id =
        if lm.record_usage,
          do: Imp.Optimizer.Budget.attach_req_llm(lm.budget, owner: self()),
          else: nil

      try do
        inner = sanitize_inner(lm.inner)
        guarded_opts = install_transport_guard(inner, bounded_opts, lm.budget)
        Imp.LM.generate(inner, messages, guarded_opts)
      after
        if telemetry_id, do: :telemetry.detach(telemetry_id)
        Imp.Optimizer.Budget.release(lm.budget, reservation)
      end
    else
      {:error, {:max_output_tokens_exceeded, _requested, _limit}} = error ->
        error

      {:error, {:invalid_max_output_tokens, _value}} = error ->
        error

      {:error, dimension} ->
        {:error, {:campaign_budget_exhausted, dimension}}
    end
  end

  def response_format_capability(%__MODULE__{inner: inner}),
    do: Imp.LM.response_format_capability(inner)

  defp bound_output_tokens(nil, opts), do: {:ok, opts}

  defp bound_output_tokens(limit, opts) when is_integer(limit) and limit > 0 do
    requested =
      [:max_tokens, :max_completion_tokens]
      |> Enum.flat_map(fn key ->
        case Keyword.fetch(opts, key) do
          {:ok, value} -> [{key, value}]
          :error -> []
        end
      end)

    case Enum.find(requested, fn {_key, value} ->
           not (is_integer(value) and value >= 0)
         end) do
      {key, value} ->
        {:error, {:invalid_max_output_tokens, {key, value}}}

      nil ->
        case Enum.find(requested, fn {_key, value} -> value > limit end) do
          {_key, value} ->
            {:error, {:max_output_tokens_exceeded, value, limit}}

          nil ->
            effective =
              Keyword.get(opts, :max_completion_tokens, Keyword.get(opts, :max_tokens, limit))

            bounded_opts =
              opts
              |> scrub_nested_transport_controls()
              |> Keyword.delete(:max_completion_tokens)
              |> Keyword.put(:max_tokens, effective)
              |> Keyword.put(:max_retries, 0)
              |> Keyword.put(:cache, false)

            {:ok, bounded_opts}
        end
    end
  end

  defp bound_output_tokens(limit, _opts),
    do: {:error, {:invalid_max_output_tokens, limit}}

  defp sanitize_inner(%Imp.Clients.ReqLLM{} = inner) do
    %{inner | opts: scrub_transport_controls(inner.opts)}
  end

  defp sanitize_inner(%{module: _module, opts: opts} = inner) when is_list(opts) do
    %{inner | opts: scrub_transport_controls(opts)}
  end

  defp sanitize_inner(inner), do: inner

  defp install_transport_guard(
         %Imp.Clients.ReqLLM{opts: inner_opts},
         opts,
         budget
       ) do
    inner_http_opts = Keyword.get(inner_opts, :req_http_options, [])
    call_http_opts = Keyword.get(opts, :req_http_options, [])

    http_opts = merge_http_opts(inner_http_opts, call_http_opts)

    unless Keyword.keyword?(http_opts) do
      raise ArgumentError, "campaign LM :req_http_options must be a keyword list"
    end

    plugins = Keyword.get(http_opts, :plugins, [])

    unless is_list(plugins) do
      raise ArgumentError, "campaign LM Req :plugins must be a list"
    end

    guard = fn request ->
      Req.Request.append_request_steps(request,
        imp_campaign_single_attempt_transport:
          {__MODULE__, :enforce_single_transport_attempt, [budget]}
      )
    end

    guarded_http_opts = Keyword.put(http_opts, :plugins, plugins ++ [guard])
    Keyword.put(opts, :req_http_options, guarded_http_opts)
  end

  defp install_transport_guard(_inner, opts, _budget), do: opts

  defp merge_http_opts(inner, call) do
    unless Keyword.keyword?(inner) and Keyword.keyword?(call) do
      raise ArgumentError, "campaign LM :req_http_options must be keyword lists"
    end

    inner_plugins = Keyword.get(inner, :plugins, [])
    call_plugins = Keyword.get(call, :plugins, [])

    unless is_list(inner_plugins) and is_list(call_plugins) do
      raise ArgumentError, "campaign LM Req :plugins must be lists"
    end

    inner
    |> Keyword.merge(call)
    |> Keyword.put(:plugins, inner_plugins ++ call_plugins)
  end

  @doc false
  def enforce_single_transport_attempt(%Req.Request{} = request, budget) do
    adapter = request.adapter

    guarded_adapter = fn guarded_request ->
      case Imp.Optimizer.Budget.authorize_transport_attempt(budget) do
        :ok ->
          run_adapter(adapter, guarded_request)

        {:error, :requests} ->
          {guarded_request, RuntimeError.exception("campaign transport-attempt budget exhausted")}
      end
    end

    request
    |> Req.Request.merge_options(retry: false, max_retries: 0)
    |> Map.put(:adapter, guarded_adapter)
  end

  defp run_adapter(adapter, request) when is_function(adapter, 1), do: adapter.(request)

  # Req 0.7 names adapters with a module that exports `run/1`; Req 0.6 and
  # earlier passed a captured function.
  defp run_adapter(adapter, request) when is_atom(adapter), do: adapter.run(request)

  defp run_adapter({module, function, args}, request)
       when is_atom(module) and is_atom(function) and is_list(args),
       do: apply(module, function, [request | args])

  defp scrub_transport_controls(opts) do
    opts
    |> scrub_nested_transport_controls()
    |> Keyword.drop([:max_tokens, :max_completion_tokens, :max_retries, :cache])
  end

  defp scrub_nested_transport_controls(opts) do
    opts
    |> then(fn acc ->
      if Keyword.has_key?(acc, :provider_options) do
        Keyword.update!(acc, :provider_options, fn
          nested when is_list(nested) ->
            Keyword.drop(nested, [:max_tokens, :max_completion_tokens, :max_retries, :cache])

          nested when is_map(nested) ->
            Map.drop(nested, [
              :max_tokens,
              :max_completion_tokens,
              :max_retries,
              :cache,
              "max_tokens",
              "max_completion_tokens",
              "max_retries",
              "cache"
            ])

          _other ->
            []
        end)
      else
        acc
      end
    end)
    |> Keyword.delete(:request_options)
  end
end
