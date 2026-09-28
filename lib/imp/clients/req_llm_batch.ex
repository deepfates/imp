defmodule Imp.Clients.ReqLLMBatch do
  @moduledoc """
  Provider-neutral, bounded, resumable execution for durable LM batches.

  Requests have stable caller-supplied IDs and JSON-safe payloads. A dispatcher
  receives each normalized request plus attempt metadata and must return one of:

    * `{:ok, output}`
    * `{:transient, reason}` - the request did not run and may be sent again
    * `{:terminal, reason}`
    * `{:malformed, reason}`
    * `{:ambiguous, reason}` - the request may have run; it is not sent again

  A request that may already have run is never re-dispatched: sending it again
  could run and bill it twice. Only a `:transient` outcome is retried, up to
  `:max_attempts`. A dispatcher that raises, throws or exits, or that is still
  running at `:timeout`, may have sent its request first, so its outcome is
  `:ambiguous`.

  The batch owns the wait before a retry as well as the retry. When the
  failure carries the provider's `retry-after` header (seconds or an HTTP
  date), the request is not sent again before then; otherwise the wait grows
  exponentially with the attempt, with jitter. A request that is waiting holds
  no dispatch slot: other requests are sent meanwhile, and the batch sleeps
  only when every remaining request is waiting. A process that traps exits
  and is stopped by its parent during that sleep exits at once with the
  parent's reason; a dispatch wave that is running is still waited for, for
  up to `:timeout`. The parent is the first of the process's `$ancestors`,
  which a process started by `Task`, `GenServer` or another OTP behaviour
  has; a process started with bare `spawn/1` or `spawn_link/1` has none, and
  its sleep cannot be interrupted. Backoff is capped at `:max_retry_wait`.
  When the provider asks for longer than `:max_retry_wait`,
  or the wait would end after the `Imp.Deadline` bound to the calling
  process, the request is not retried in this run: it stays
  `:transient_failure` with the attempts it has used, the summary is not
  `complete?`, and `resume/3` retries it. The time a request may be sent
  again is kept in the checkpoint as a UTC time, and `resume/3` waits for it
  under the same rules.

  The checkpoint is an auditable JSON document. Every dispatch intent and
  outcome is appended to its event history before execution continues. Writes
  use a synced temporary file followed by an atomic rename. On resume, a
  request that was dispatched but has no committed outcome becomes
  `:ambiguous` for the same reason.

  A checkpoint written by Imp 0.5.0 (schema version 1) retried timeouts and
  dispatcher crashes as transient failures, and its stored reason does not
  always say which a failure was. On resume, its `:transient_failure`
  requests become `:ambiguous` and are not sent again; the checkpoint is
  rewritten at schema version 2.
  """

  alias Imp.Clients.ReqLLM

  @type request :: %{required(:id) => String.t(), required(:payload) => term()}
  @type context :: %{required(:request_id) => String.t(), required(:attempt) => pos_integer()}
  @type outcome ::
          {:ok, term()}
          | {:transient, term()}
          | {:terminal, term()}
          | {:malformed, term()}
          | {:ambiguous, term()}
  @type dispatcher :: (request(), context() -> outcome())

  @type summary :: %{
          checkpoint: Path.t(),
          complete?: boolean(),
          counts: %{atom() => non_neg_integer()},
          requests: [map()]
        }

  @schema_version 2
  @schema_versions [1, @schema_version]
  @type_name "imp_req_llm_batch"
  @final_statuses ~w(succeeded terminal_failure malformed_output ambiguous)
  @status_atoms %{
    "pending" => :pending,
    "dispatching" => :dispatching,
    "succeeded" => :succeeded,
    "transient_failure" => :transient_failure,
    "terminal_failure" => :terminal_failure,
    "malformed_output" => :malformed_output,
    "ambiguous" => :ambiguous
  }

  @doc """
  Starts a new durable batch.

  Required options:

    * `:checkpoint` - destination for the atomic JSON checkpoint

  Runtime options:

    * `:num_threads` - requests dispatched at once (default `4`)
    * `:max_attempts` - sends per request, retries included (default `3`)
    * `:timeout` - milliseconds one dispatch may run (default `30_000`)
    * `:validate_output` - an optional arity-one callback returning `:ok` or
      `{:error, reason}`
    * `:max_retry_wait` - the longest wait, in milliseconds, before a retry
      (default `60_000`)
    * `:clock` - the time source and sleep the retry wait uses, a map of
      `:now` (monotonic milliseconds), `:utc_now` (a `DateTime`) and `:sleep`
      (milliseconds) functions; it exists so tests need not wait
  """
  @spec run([map()], dispatcher(), keyword()) :: {:ok, summary()} | {:error, term()}
  def run(requests, dispatcher, opts) when is_list(requests) and is_function(dispatcher, 2) do
    with {:ok, runtime} <- validate_run_options(opts),
         :ok <- checkpoint_must_not_exist(runtime.checkpoint),
         {:ok, normalized} <- normalize_requests(requests),
         state <- new_state(normalized, runtime.max_attempts),
         :ok <- write_checkpoint(runtime.checkpoint, state) do
      execute(state, dispatcher, runtime)
    end
  end

  def run(_requests, _dispatcher, _opts), do: {:error, :invalid_batch_arguments}

  @doc """
  Resumes a batch from its checkpoint.

  Persisted requests, attempts, and retry policy are authoritative. Resume
  accepts only runtime options: `:num_threads`, `:timeout`,
  `:validate_output`, `:max_retry_wait` and `:clock`. A request waiting for
  a retry, or whose retry was stopped, is not sent before the `not_before`
  time its checkpoint holds: the batch waits for it when that is within
  `:max_retry_wait` and the deadline, and stops its retry again, unsent,
  when it is not.
  """
  @spec resume(Path.t(), dispatcher(), keyword()) :: {:ok, summary()} | {:error, term()}
  def resume(checkpoint, dispatcher, opts \\ [])

  def resume(checkpoint, dispatcher, opts)
      when is_binary(checkpoint) and is_function(dispatcher, 2) do
    with {:ok, runtime} <- validate_resume_options(checkpoint, opts),
         {:ok, state} <- read_checkpoint(checkpoint),
         {:ok, state} <- migrate_checkpoint(state, checkpoint),
         {:ok, state} <- reconcile_ambiguous(state, checkpoint) do
      with {:ok, state, waits} <- resume_waits(state, runtime) do
        execute(state, dispatcher, runtime, waits)
      end
    end
  end

  def resume(_checkpoint, _dispatcher, _opts), do: {:error, :invalid_batch_arguments}

  @doc """
  Builds a dispatcher backed by an existing `ReqLLM` client.

  Request payloads may be a message list or `%{"messages" => messages}`. The
  adapter is provider-neutral because provider and model selection remain in
  the client (`"openai:..."`, `"anthropic:..."`, or `"gemini:..."`).

  The batch owns retries: every call is made with `max_retries: 0`, so ReqLLM
  sends each attempt once and the error describes the only send.

  A failed call's `Imp.LMError` decides its outcome:

    * `:transient` - the request never reached the provider (the connection
      was refused, or no pooled connection was free), or the provider
      answered that it did not process it and to try later (408, 425, 429,
      503, 529).
    * `:terminal` - the provider rejected it with any other 4xx status, or
      the call failed with no status and no transport reason.
    * `:ambiguous` - it may have run: a 5xx status other than 503 or 529 (500
      included), any other status, or a timeout or closed connection with no
      response.
  """
  @spec req_llm_dispatcher(ReqLLM.t(), keyword()) :: dispatcher()
  def req_llm_dispatcher(%ReqLLM{} = client, call_opts \\ []) when is_list(call_opts) do
    unless Keyword.keyword?(call_opts) do
      raise ArgumentError, "ReqLLMBatch.req_llm_dispatcher/2 expects keyword call options"
    end

    call_opts = Keyword.put(call_opts, :max_retries, 0)

    fn request, _context ->
      messages = Map.get(request, :payload)
      messages = if is_map(messages), do: Map.get(messages, "messages"), else: messages

      case messages do
        messages when is_list(messages) ->
          case ReqLLM.generate(client, messages, call_opts) do
            {:ok, output} -> {:ok, output}
            {:error, error} -> {classify_lm_error(error), error}
          end

        _other ->
          {:malformed, :req_llm_batch_messages_required}
      end
    end
  end

  defp classify_lm_error(%Imp.LMError{status: status}) when is_integer(status) do
    case Imp.Errors.status_outcome(status) do
      :try_later -> :transient
      :refused -> :terminal
      :unknown -> :ambiguous
    end
  end

  defp classify_lm_error(%Imp.LMError{} = error) do
    cond do
      ReqLLM.not_sent?(error) -> :transient
      Imp.Errors.retryable?(error) -> :ambiguous
      true -> :terminal
    end
  end

  # `waits` maps a request waiting to be retried to the monotonic time it may
  # be sent again. It lives only in this run.
  defp execute(state, dispatcher, runtime, waits \\ %{}) do
    now = runtime.clock.now.()
    runnable = runnable_requests(state)
    ready = Enum.filter(runnable, &(Map.get(waits, &1["id"], now) <= now))

    cond do
      runnable == [] ->
        {:ok, summarize(state, runtime.checkpoint)}

      ready == [] ->
        earliest = runnable |> Enum.map(&Map.fetch!(waits, &1["id"])) |> Enum.min()
        runtime.clock.sleep.(earliest - now)
        execute(state, dispatcher, runtime, waits)

      true ->
        wave = Enum.take(ready, runtime.num_threads)
        {state, dispatched} = mark_dispatched(state, wave)

        with :ok <- write_checkpoint(runtime.checkpoint, state) do
          results = dispatch_wave(dispatched, dispatcher, runtime)

          with {:ok, state} <- commit_results(state, results, runtime),
               {:ok, state, waits} <- schedule_retries(state, results, runtime, waits) do
            execute(state, dispatcher, runtime, waits)
          end
        end
    end
  end

  # For each request that failed transiently and has attempts left, decide
  # when it may be sent again, or stop retrying it in this run. The time is
  # also kept in the checkpoint as `not_before`, a UTC time, so a resumed
  # batch waits for it too.
  defp schedule_retries(state, results, runtime, waits) do
    now = runtime.clock.now.()
    utc_now = runtime.clock.utc_now.()
    remaining = Imp.Deadline.remaining(Imp.Deadline.current())
    max_attempts = state["max_attempts"]

    {state, waits} =
      Enum.reduce(results, {state, waits}, fn
        {id, attempt, {:transient, _reason}, raw}, {current, waits}
        when attempt < max_attempts ->
          {source, wait} = retry_wait(raw, attempt, runtime)
          not_before = utc_now |> DateTime.add(wait, :millisecond) |> DateTime.to_iso8601()
          current = update_request(current, id, &Map.put(&1, "not_before", not_before))
          plan_retry(current, waits, id, attempt, now, decide(source, wait, runtime, remaining))

        _result, acc ->
          acc
      end)

    with :ok <- write_checkpoint(runtime.checkpoint, state), do: {:ok, state, waits}
  end

  # On resume, a request with retries left waits until its `not_before`, or
  # is stopped again, unsent, when that is past the caps or the deadline.
  defp resume_waits(state, runtime) do
    now = runtime.clock.now.()
    utc_now = runtime.clock.utc_now.()
    remaining = Imp.Deadline.remaining(Imp.Deadline.current())

    {state, waits} =
      Enum.reduce(state["requests"], {state, %{}}, fn request, {current, waits} ->
        id = request["id"]
        current = update_request(current, id, &Map.delete(&1, "retry_stopped"))

        with "transient_failure" <- request["status"],
             true <- request["attempts"] < state["max_attempts"],
             not_before when is_binary(not_before) <- request["not_before"],
             {:ok, at, _offset} <- DateTime.from_iso8601(not_before) do
          wait = max(DateTime.diff(at, utc_now, :millisecond), 0)
          decision = decide(:retry_after, wait, runtime, remaining)
          plan_retry(current, waits, id, request["attempts"], now, decision)
        else
          _no_wait -> {current, waits}
        end
      end)

    with :ok <- write_checkpoint(runtime.checkpoint, state), do: {:ok, state, waits}
  end

  defp plan_retry(state, waits, id, _attempt, now, {:wait, wait}),
    do: {state, Map.put(waits, id, now + wait)}

  defp plan_retry(state, waits, id, attempt, _now, {:stop, why, wait}) do
    stopped = %{"reason" => why, "wait_ms" => wait}

    state =
      state
      |> update_request(id, &Map.put(&1, "retry_stopped", stopped))
      |> append_event(id, "retry_stopped", "transient_failure", attempt, stopped)

    {state, Map.delete(waits, id)}
  end

  @backoff_base 500

  defp retry_wait(raw, attempt, runtime) do
    case retry_after(raw, runtime.clock) do
      nil -> {:backoff, min(backoff(attempt), runtime.max_retry_wait)}
      wait -> {:retry_after, wait}
    end
  end

  defp decide(:retry_after, wait, runtime, _remaining) when wait > runtime.max_retry_wait,
    do: {:stop, "retry_after_exceeds_max_retry_wait", wait}

  defp decide(_source, wait, _runtime, remaining)
       when remaining != :infinity and wait >= remaining,
       do: {:stop, "deadline", wait}

  defp decide(_source, wait, _runtime, _remaining), do: {:wait, wait}

  # Exponential with equal jitter: attempt n waits between half of and the
  # whole of base * 2^(n - 1), so a later attempt never waits less.
  defp backoff(attempt) do
    ceiling = @backoff_base * Integer.pow(2, attempt - 1)
    half = div(ceiling, 2)
    half + :rand.uniform(half + 1) - 1
  end

  # The provider's `retry-after`, in milliseconds, from the failure's HTTP
  # headers: `Imp.LMError` keeps ReqLLM's error, which keeps the response's.
  defp retry_after(%Imp.LMError{reason: reason}, clock), do: retry_after(reason, clock)

  defp retry_after(%{headers: headers}, clock) when is_map(headers) or is_list(headers) do
    Enum.find_value(headers, fn
      {name, value} ->
        if String.downcase(to_string(name)) == "retry-after",
          do: parse_retry_after(List.wrap(value), clock)

      _other ->
        nil
    end)
  end

  defp retry_after(_reason, _clock), do: nil

  defp parse_retry_after([value | _rest], clock) when is_binary(value) do
    value = String.trim(value)

    case Integer.parse(value) do
      {seconds, ""} when seconds >= 0 -> seconds * 1000
      _not_seconds -> http_date_wait(value, clock)
    end
  end

  defp parse_retry_after(_value, _clock), do: nil

  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  # RFC 9110 has a sender use IMF-fixdate and a recipient accept two obsolete
  # forms as well:
  #
  #   Sun, 06 Nov 1994 08:49:37 GMT    IMF-fixdate
  #   Sunday, 06-Nov-94 08:49:37 GMT   RFC 850
  #   Sun Nov  6 08:49:37 1994         asctime
  defp http_date_wait(value, clock) do
    now = clock.utc_now.()

    fields =
      case String.split(value, ~r/[\s,]+/, trim: true) do
        [_day, day, month, year, time, "GMT"] ->
          {day, month, year, time}

        [_day, date, time, "GMT"] ->
          case String.split(date, "-") do
            [day, month, year] -> {day, month, year, time}
            _other -> nil
          end

        [_day, month, day, time, year] ->
          {day, month, year, time}

        _other ->
          nil
      end

    with {day, month, year, time} <- fields,
         month when is_integer(month) <- Enum.find_index(@months, &(&1 == month)),
         {day, ""} <- Integer.parse(day),
         {year, ""} <- Integer.parse(year),
         {:ok, date} <- Date.new(full_year(year, now), month + 1, day),
         {:ok, time} <- Time.from_iso8601(time),
         {:ok, at} <- DateTime.new(date, time, "Etc/UTC") do
      max(DateTime.diff(at, now, :millisecond), 0)
    else
      _unreadable -> nil
    end
  end

  # An RFC 850 date has a two-digit year. RFC 9110: one that appears to be
  # more than 50 years in the future is the most recent past year with the
  # same last two digits.
  defp full_year(year, _now) when year >= 100, do: year

  defp full_year(year, now) do
    century = div(now.year, 100) * 100
    if century + year > now.year + 50, do: century - 100 + year, else: century + year
  end

  # The retry wait a trapping process can still be stopped in: an exit
  # signal from its parent ends it with the same reason. Other messages stay
  # in the mailbox.
  defp interruptible_sleep(milliseconds) do
    case parent() do
      nil ->
        Process.sleep(milliseconds)

      parent ->
        receive do
          {:EXIT, ^parent, reason} -> exit(reason)
        after
          milliseconds -> :ok
        end
    end
  end

  defp parent do
    case Process.get(:"$ancestors") do
      [parent | _rest] when is_pid(parent) -> parent
      [name | _rest] when is_atom(name) -> Process.whereis(name)
      _none -> nil
    end
  end

  defp dispatch_wave(requests, dispatcher, runtime) do
    requests
    |> Task.async_stream(
      fn request -> invoke_dispatcher(dispatcher, request, runtime.validate_output) end,
      max_concurrency: runtime.num_threads,
      ordered: true,
      timeout: runtime.timeout,
      on_timeout: :kill_task
    )
    |> Enum.zip(requests)
    |> Enum.map(fn {task_result, request} ->
      {outcome, raw} =
        case task_result do
          {:ok, result} ->
            result

          {:exit, reason} ->
            {{:ambiguous, normalize_json({:dispatcher_exit, inspect(reason)})}, nil}
        end

      {request["id"], request["attempts"], outcome, raw}
    end)
  end

  defp invoke_dispatcher(dispatcher, request, validator) do
    public_request = %{id: request["id"], payload: request["payload"]}
    context = %{request_id: request["id"], attempt: request["attempts"]}

    # The raw transient reason goes back with the outcome: its HTTP headers
    # may say how long to wait before a retry.
    case dispatcher.(public_request, context) do
      {:transient, raw} = outcome -> {normalize_outcome(outcome, validator), raw}
      outcome -> {normalize_outcome(outcome, validator), nil}
    end
  rescue
    error ->
      {{:ambiguous, normalize_json({:dispatcher_exception, Exception.message(error)})}, nil}
  catch
    kind, reason ->
      {{:ambiguous, normalize_json({:dispatcher_throw, kind, inspect(reason)})}, nil}
  end

  defp normalize_outcome({:ok, output}, nil), do: normalize_success(output)

  defp normalize_outcome({:ok, output}, validator) do
    case validator.(output) do
      :ok -> normalize_success(output)
      {:error, reason} -> {:malformed, normalize_json(reason)}
      other -> {:malformed, normalize_json({:invalid_validator_return, other})}
    end
  rescue
    error -> {:malformed, normalize_json({:validator_exception, Exception.message(error)})}
  catch
    kind, reason -> {:malformed, normalize_json({:validator_throw, kind, inspect(reason)})}
  end

  defp normalize_outcome({:transient, reason}, _validator),
    do: {:transient, normalize_json(reason)}

  defp normalize_outcome({:terminal, reason}, _validator),
    do: {:terminal, normalize_json(reason)}

  defp normalize_outcome({:malformed, reason}, _validator),
    do: {:malformed, normalize_json(reason)}

  defp normalize_outcome({:ambiguous, reason}, _validator),
    do: {:ambiguous, normalize_json(reason)}

  defp normalize_outcome(other, _validator),
    do: {:malformed, normalize_json({:invalid_dispatcher_return, other})}

  defp normalize_success(output) do
    case json_round_trip(output) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, reason} -> {:malformed, normalize_json({:non_json_output, reason})}
    end
  end

  defp commit_results(state, results, runtime) do
    Enum.reduce_while(results, {:ok, state}, fn {id, attempt, outcome, _raw}, {:ok, current} ->
      next = commit_outcome(current, id, attempt, outcome)

      case write_checkpoint(runtime.checkpoint, next) do
        :ok -> {:cont, {:ok, next}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp commit_outcome(state, id, attempt, outcome) do
    {status, field, value} =
      case outcome do
        {:ok, output} -> {"succeeded", "output", output}
        {:transient, reason} -> {"transient_failure", "reason", reason}
        {:terminal, reason} -> {"terminal_failure", "reason", reason}
        {:malformed, reason} -> {"malformed_output", "reason", reason}
        {:ambiguous, reason} -> {"ambiguous", "reason", reason}
      end

    state
    |> update_request(id, fn request ->
      request
      |> Map.put("status", status)
      |> Map.put(field, value)
    end)
    |> append_event(id, "attempt_outcome", status, attempt, %{field => value})
  end

  defp mark_dispatched(state, requests) do
    Enum.reduce(requests, {state, []}, fn request, {current, dispatched} ->
      attempt = request["attempts"] + 1

      next =
        current
        |> update_request(request["id"], fn item ->
          item
          |> Map.put("attempts", attempt)
          |> Map.put("status", "dispatching")
          |> Map.delete("reason")
          |> Map.delete("not_before")
        end)
        |> append_event(request["id"], "dispatch_intent", "dispatching", attempt, %{})

      marked = request |> Map.put("attempts", attempt) |> Map.put("status", "dispatching")
      {next, [marked | dispatched]}
    end)
    |> then(fn {next, dispatched} -> {next, Enum.reverse(dispatched)} end)
  end

  defp runnable_requests(state) do
    max_attempts = state["max_attempts"]

    Enum.filter(state["requests"], fn request ->
      request["status"] == "pending" or
        (request["status"] == "transient_failure" and request["attempts"] < max_attempts and
           not Map.has_key?(request, "retry_stopped"))
    end)
  end

  # Schema version 1 (Imp 0.5.0) recorded a timeout, a dispatcher crash and a
  # ReqLLM retry that may have sent the request as `transient_failure`.
  defp migrate_checkpoint(%{"schema_version" => 1} = state, checkpoint) do
    reason = "schema_1_transient_failure_may_have_run"

    migrated =
      state["requests"]
      |> Enum.filter(&(&1["status"] == "transient_failure"))
      |> Enum.reduce(state, fn request, current ->
        current
        |> update_request(request["id"], fn item ->
          item
          |> Map.put("status", "ambiguous")
          |> Map.put("reason", %{"migrated_from" => item["reason"], "reason" => reason})
        end)
        |> append_event(request["id"], "schema_migration", "ambiguous", request["attempts"], %{
          "reason" => reason
        })
      end)
      |> Map.put("schema_version", @schema_version)

    with :ok <- write_checkpoint(checkpoint, migrated), do: {:ok, migrated}
  end

  defp migrate_checkpoint(state, _checkpoint), do: {:ok, state}

  defp reconcile_ambiguous(state, checkpoint) do
    dispatching = Enum.filter(state["requests"], &(&1["status"] == "dispatching"))

    reconciled =
      Enum.reduce(dispatching, state, fn request, current ->
        reason = "resume_found_uncommitted_dispatch"

        current
        |> update_request(request["id"], fn item ->
          item |> Map.put("status", "ambiguous") |> Map.put("reason", reason)
        end)
        |> append_event(
          request["id"],
          "resume_reconciliation",
          "ambiguous",
          request["attempts"],
          %{"reason" => reason}
        )
      end)

    case dispatching do
      [] -> {:ok, state}
      _nonempty -> with :ok <- write_checkpoint(checkpoint, reconciled), do: {:ok, reconciled}
    end
  end

  defp new_state(requests, max_attempts) do
    initial = %{
      "type" => @type_name,
      "schema_version" => @schema_version,
      "max_attempts" => max_attempts,
      "requests" =>
        Enum.map(requests, fn request ->
          %{
            "id" => request.id,
            "payload" => request.payload,
            "status" => "pending",
            "attempts" => 0
          }
        end),
      "events" => []
    }

    Enum.reduce(requests, initial, fn request, state ->
      append_event(state, request.id, "request_accepted", "pending", 0, %{})
    end)
  end

  defp append_event(state, id, kind, status, attempt, details) do
    event = %{
      "sequence" => length(state["events"]) + 1,
      "at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "request_id" => id,
      "kind" => kind,
      "status" => status,
      "attempt" => attempt,
      "details" => details
    }

    Map.update!(state, "events", &(&1 ++ [event]))
  end

  defp update_request(state, id, update) do
    Map.update!(state, "requests", fn requests ->
      Enum.map(requests, fn request ->
        if request["id"] == id, do: update.(request), else: request
      end)
    end)
  end

  defp summarize(state, checkpoint) do
    requests =
      Enum.map(state["requests"], fn request ->
        %{
          id: request["id"],
          status: Map.fetch!(@status_atoms, request["status"]),
          attempts: request["attempts"],
          output: request["output"],
          reason: request["reason"]
        }
      end)

    counts = Enum.frequencies_by(requests, & &1.status)

    %{
      checkpoint: checkpoint,
      complete?:
        Enum.all?(state["requests"], &(&1["status"] in @final_statuses or exhausted?(&1, state))),
      counts: counts,
      requests: requests
    }
  end

  defp exhausted?(request, state) do
    request["status"] == "transient_failure" and request["attempts"] >= state["max_attempts"]
  end

  defp normalize_requests(requests) do
    with {:ok, normalized} <- normalize_each_request(requests),
         :ok <- reject_duplicate_ids(normalized) do
      {:ok, normalized}
    end
  end

  defp normalize_each_request(requests) do
    requests
    |> Enum.reduce_while({:ok, []}, fn request, {:ok, acc} ->
      case normalize_request(request) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp normalize_request(request) when is_map(request) do
    id = Map.get(request, :id) || Map.get(request, "id")
    payload_key = if Map.has_key?(request, :payload), do: :payload, else: "payload"

    cond do
      not (is_binary(id) and String.trim(id) != "") ->
        {:error, {:invalid_request_id, id}}

      not Map.has_key?(request, payload_key) ->
        {:error, {:request_payload_required, id}}

      true ->
        case json_round_trip(Map.fetch!(request, payload_key)) do
          {:ok, payload} -> {:ok, %{id: id, payload: payload}}
          {:error, reason} -> {:error, {:non_json_request_payload, id, reason}}
        end
    end
  end

  defp normalize_request(request), do: {:error, {:invalid_request, request}}

  defp reject_duplicate_ids(requests) do
    duplicates =
      requests
      |> Enum.frequencies_by(& &1.id)
      |> Enum.filter(fn {_id, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    if duplicates == [], do: :ok, else: {:error, {:duplicate_request_ids, duplicates}}
  end

  defp validate_run_options(opts) do
    with {:ok, runtime} <- validate_runtime_options(opts, [:checkpoint, :max_attempts]),
         checkpoint when is_binary(checkpoint) and byte_size(checkpoint) > 0 <-
           Keyword.get(opts, :checkpoint),
         max_attempts when is_integer(max_attempts) and max_attempts > 0 <-
           Keyword.get(opts, :max_attempts, 3) do
      {:ok, Map.merge(runtime, %{checkpoint: checkpoint, max_attempts: max_attempts})}
    else
      _other -> {:error, :invalid_batch_options}
    end
  end

  defp validate_resume_options(checkpoint, opts) do
    with {:ok, runtime} <- validate_runtime_options(opts, []) do
      {:ok, Map.put(runtime, :checkpoint, checkpoint)}
    end
  end

  defp validate_runtime_options(opts, extra_keys) when is_list(opts) do
    allowed = [:num_threads, :timeout, :validate_output, :max_retry_wait, :clock | extra_keys]

    with true <- Keyword.keyword?(opts),
         [] <- Keyword.keys(opts) -- allowed,
         num_threads when is_integer(num_threads) and num_threads > 0 <-
           Keyword.get(opts, :num_threads, 4),
         timeout when timeout == :infinity or (is_integer(timeout) and timeout > 0) <-
           Keyword.get(opts, :timeout, 30_000),
         validator when is_nil(validator) or is_function(validator, 1) <-
           Keyword.get(opts, :validate_output),
         max_retry_wait when is_integer(max_retry_wait) and max_retry_wait >= 0 <-
           Keyword.get(opts, :max_retry_wait, 60_000),
         %{now: now, utc_now: utc_now, sleep: sleep} = clock
         when is_function(now, 0) and is_function(utc_now, 0) and is_function(sleep, 1) <-
           Keyword.get_lazy(opts, :clock, &system_clock/0) do
      {:ok,
       %{
         num_threads: num_threads,
         timeout: timeout,
         validate_output: validator,
         max_retry_wait: max_retry_wait,
         clock: clock
       }}
    else
      _other -> {:error, :invalid_batch_options}
    end
  end

  defp validate_runtime_options(_opts, _extra_keys), do: {:error, :invalid_batch_options}

  defp system_clock do
    %{
      now: fn -> System.monotonic_time(:millisecond) end,
      utc_now: &DateTime.utc_now/0,
      sleep: &interruptible_sleep/1
    }
  end

  defp checkpoint_must_not_exist(path) do
    if File.exists?(path), do: {:error, :checkpoint_already_exists}, else: :ok
  end

  defp read_checkpoint(path) do
    with {:ok, body} <- File.read(path),
         {:ok, state} <- Jason.decode(body),
         :ok <- validate_checkpoint(state) do
      {:ok, state}
    else
      {:error, reason} -> {:error, {:invalid_batch_checkpoint, reason}}
    end
  end

  defp validate_checkpoint(%{
         "type" => @type_name,
         "schema_version" => schema_version,
         "max_attempts" => max_attempts,
         "requests" => requests,
         "events" => events
       })
       when schema_version in @schema_versions and is_integer(max_attempts) and max_attempts > 0 and
              is_list(requests) and
              is_list(events) do
    valid_requests? =
      Enum.all?(requests, fn request ->
        is_map(request) and is_binary(request["id"]) and Map.has_key?(request, "payload") and
          is_integer(request["attempts"]) and request["attempts"] >= 0 and
          Map.has_key?(@status_atoms, request["status"])
      end)

    unique_ids? = requests |> Enum.map(& &1["id"]) |> Enum.uniq() |> length() == length(requests)

    valid_events? =
      events
      |> Enum.with_index(1)
      |> Enum.all?(fn {event, sequence} ->
        is_map(event) and event["sequence"] == sequence and is_binary(event["request_id"]) and
          is_binary(event["kind"]) and Map.has_key?(@status_atoms, event["status"]) and
          is_integer(event["attempt"])
      end)

    if valid_requests? and unique_ids? and valid_events?, do: :ok, else: {:error, :invalid_shape}
  end

  defp validate_checkpoint(_state), do: {:error, :invalid_shape}

  defp write_checkpoint(path, state) do
    directory = Path.dirname(path)
    temp = path <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))

    with :ok <- File.mkdir_p(directory),
         {:ok, json} <- Jason.encode(state, pretty: true),
         :ok <- write_synced(temp, json),
         :ok <- File.rename(temp, path),
         :ok <- sync_directory(directory) do
      :ok
    else
      {:error, reason} ->
        File.rm(temp)
        {:error, {:checkpoint_write_failed, reason}}
    end
  end

  defp write_synced(path, contents) do
    case :file.open(String.to_charlist(path), [:write, :binary, :raw, :exclusive]) do
      {:ok, file} ->
        result = with :ok <- :file.write(file, contents), do: :file.sync(file)
        close_result = :file.close(file)
        if result == :ok, do: close_result, else: result

      {:error, _reason} = error ->
        error
    end
  end

  defp sync_directory(path) do
    case :file.open(String.to_charlist(path), [:read, :raw, :directory]) do
      {:ok, directory} ->
        result = :file.sync(directory)
        close_result = :file.close(directory)
        if result == :ok, do: close_result, else: result

      {:error, _reason} = error ->
        error
    end
  end

  defp json_round_trip(value) do
    with {:ok, encoded} <- Jason.encode(value), do: Jason.decode(encoded)
  end

  defp normalize_json(value) do
    case json_round_trip(value) do
      {:ok, normalized} -> normalized
      {:error, _reason} -> inspect(value)
    end
  end
end
