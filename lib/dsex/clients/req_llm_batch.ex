defmodule DSEx.Clients.ReqLLMBatch do
  @moduledoc """
  Provider-neutral, bounded, resumable execution for durable LM batches.

  Requests have stable caller-supplied IDs and JSON-safe payloads. A dispatcher
  receives each normalized request plus attempt metadata and must return one of:

    * `{:ok, output}`
    * `{:transient, reason}`
    * `{:terminal, reason}`
    * `{:malformed, reason}`

  The checkpoint is an auditable JSON document. Every dispatch intent and
  outcome is appended to its event history before execution continues. Writes
  use a synced temporary file followed by an atomic rename. On resume, a
  request that was dispatched but has no committed outcome becomes
  `:ambiguous` and is never replayed automatically.
  """

  alias DSEx.Clients.ReqLLM

  @type request :: %{required(:id) => String.t(), required(:payload) => term()}
  @type context :: %{required(:request_id) => String.t(), required(:attempt) => pos_integer()}
  @type outcome ::
          {:ok, term()}
          | {:transient, term()}
          | {:terminal, term()}
          | {:malformed, term()}
  @type dispatcher :: (request(), context() -> outcome())

  @type summary :: %{
          checkpoint: Path.t(),
          complete?: boolean(),
          counts: %{atom() => non_neg_integer()},
          requests: [map()]
        }

  @schema_version 1
  @type_name "dsex_req_llm_batch"
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

  Runtime options are `:max_concurrency` (default `4`), `:max_attempts`
  (default `3`), `:timeout` (default `30_000`), and `:validate_output`, an
  optional arity-one callback returning `:ok` or `{:error, reason}`.
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
  accepts only runtime options: `:max_concurrency`, `:timeout`, and
  `:validate_output`.
  """
  @spec resume(Path.t(), dispatcher(), keyword()) :: {:ok, summary()} | {:error, term()}
  def resume(checkpoint, dispatcher, opts \\ [])

  def resume(checkpoint, dispatcher, opts)
      when is_binary(checkpoint) and is_function(dispatcher, 2) do
    with {:ok, runtime} <- validate_resume_options(checkpoint, opts),
         {:ok, state} <- read_checkpoint(checkpoint),
         {:ok, state} <- reconcile_ambiguous(state, checkpoint) do
      execute(state, dispatcher, runtime)
    end
  end

  def resume(_checkpoint, _dispatcher, _opts), do: {:error, :invalid_batch_arguments}

  @doc """
  Builds a dispatcher backed by an existing `ReqLLM` client.

  Request payloads may be a message list or `%{"messages" => messages}`. The
  adapter is provider-neutral because provider and model selection remain in
  the client (`"openai:..."`, `"anthropic:..."`, or `"gemini:..."`).
  """
  @spec req_llm_dispatcher(ReqLLM.t(), keyword()) :: dispatcher()
  def req_llm_dispatcher(%ReqLLM{} = client, call_opts \\ []) when is_list(call_opts) do
    unless Keyword.keyword?(call_opts) do
      raise ArgumentError, "ReqLLMBatch.req_llm_dispatcher/2 expects keyword call options"
    end

    fn request, _context ->
      messages = Map.get(request, :payload)
      messages = if is_map(messages), do: Map.get(messages, "messages"), else: messages

      case messages do
        messages when is_list(messages) ->
          case ReqLLM.generate(client, messages, call_opts) do
            {:ok, output} -> {:ok, output}
            {:error, reason} -> {:transient, reason}
          end

        _other ->
          {:malformed, :req_llm_batch_messages_required}
      end
    end
  end

  defp execute(state, dispatcher, runtime) do
    case runnable_requests(state) do
      [] ->
        {:ok, summarize(state, runtime.checkpoint)}

      runnable ->
        wave = Enum.take(runnable, runtime.max_concurrency)
        {state, dispatched} = mark_dispatched(state, wave)

        with :ok <- write_checkpoint(runtime.checkpoint, state) do
          results = dispatch_wave(dispatched, dispatcher, runtime)

          case commit_results(state, results, runtime) do
            {:ok, state} -> execute(state, dispatcher, runtime)
            {:error, _reason} = error -> error
          end
        end
    end
  end

  defp dispatch_wave(requests, dispatcher, runtime) do
    requests
    |> Task.async_stream(
      fn request -> invoke_dispatcher(dispatcher, request, runtime.validate_output) end,
      max_concurrency: runtime.max_concurrency,
      ordered: true,
      timeout: runtime.timeout,
      on_timeout: :kill_task
    )
    |> Enum.zip(requests)
    |> Enum.map(fn {task_result, request} ->
      outcome =
        case task_result do
          {:ok, outcome} -> outcome
          {:exit, reason} -> {:transient, normalize_json({:dispatcher_exit, inspect(reason)})}
        end

      {request["id"], request["attempts"], outcome}
    end)
  end

  defp invoke_dispatcher(dispatcher, request, validator) do
    public_request = %{id: request["id"], payload: request["payload"]}
    context = %{request_id: request["id"], attempt: request["attempts"]}

    dispatcher.(public_request, context)
    |> normalize_outcome(validator)
  rescue
    error -> {:transient, normalize_json({:dispatcher_exception, Exception.message(error)})}
  catch
    kind, reason -> {:transient, normalize_json({:dispatcher_throw, kind, inspect(reason)})}
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

  defp normalize_outcome(other, _validator),
    do: {:malformed, normalize_json({:invalid_dispatcher_return, other})}

  defp normalize_success(output) do
    case json_round_trip(output) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, reason} -> {:malformed, normalize_json({:non_json_output, reason})}
    end
  end

  defp commit_results(state, results, runtime) do
    Enum.reduce_while(results, {:ok, state}, fn {id, attempt, outcome}, {:ok, current} ->
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
        (request["status"] == "transient_failure" and request["attempts"] < max_attempts)
    end)
  end

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
    allowed = [:max_concurrency, :timeout, :validate_output | extra_keys]

    with true <- Keyword.keyword?(opts),
         [] <- Keyword.keys(opts) -- allowed,
         max_concurrency when is_integer(max_concurrency) and max_concurrency > 0 <-
           Keyword.get(opts, :max_concurrency, 4),
         timeout when timeout == :infinity or (is_integer(timeout) and timeout > 0) <-
           Keyword.get(opts, :timeout, 30_000),
         validator when is_nil(validator) or is_function(validator, 1) <-
           Keyword.get(opts, :validate_output) do
      {:ok, %{max_concurrency: max_concurrency, timeout: timeout, validate_output: validator}}
    else
      _other -> {:error, :invalid_batch_options}
    end
  end

  defp validate_runtime_options(_opts, _extra_keys), do: {:error, :invalid_batch_options}

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
         "schema_version" => @schema_version,
         "max_attempts" => max_attempts,
         "requests" => requests,
         "events" => events
       })
       when is_integer(max_attempts) and max_attempts > 0 and is_list(requests) and
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
