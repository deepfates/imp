defmodule DSEx.BenchmarkTruth.ProviderTrainingCampaign do
  @moduledoc false

  alias DSEx.Clients.{OpenAITrainer, Trainer, TrainingJob}

  @terminal [:succeeded, :failed, :cancelled, :artifact_missing]
  @instruction "Route the customer query to exactly one opaque routing code. The valid codes are R17, R42, R68, and R93. Return no explanation."

  def run!(opts) when is_list(opts) do
    dataset_path = Keyword.fetch!(opts, :dataset)
    checkpoint_path = Keyword.fetch!(opts, :checkpoint)
    artifact_path = Keyword.fetch!(opts, :artifact)
    program_path = Keyword.fetch!(opts, :program)
    api_key = Keyword.fetch!(opts, :api_key)
    model = Keyword.get(opts, :model, "openai:gpt-4.1-mini-2025-04-14")
    poll_ms = Keyword.get(opts, :poll_ms, 30_000)
    max_polls = Keyword.get(opts, :max_polls, 360)
    concurrency = Keyword.get(opts, :concurrency, 8)

    dataset = load_dataset!(dataset_path)
    signature = signature(dataset["route_codes"])
    base_program = program(signature, model, api_key)

    state =
      if File.exists?(checkpoint_path) do
        resume_state!(checkpoint_path, artifact_path, api_key, dataset, model)
      else
        state =
          if File.exists?(artifact_path) do
            load_state!(artifact_path, dataset, model)
          else
            baseline = evaluate(base_program, dataset["held_out"], concurrency)

            campaign_state(dataset_path, dataset, model, baseline)
            |> write_json!(artifact_path)

            load_state!(artifact_path, dataset, model)
          end

        job = submit!(base_program, signature, dataset["train"], api_key, opts)
        TrainingJob.save!(job, checkpoint_path)

        state =
          state
          |> Map.put("status", "submitted")
          |> Map.put("job", public_job(job))

        write_json!(artifact_path, state)
        state
      end

    job = TrainingJob.load!(checkpoint_path, api_key: api_key)
    job = await_terminal!(job, checkpoint_path, artifact_path, state, poll_ms, max_polls)

    if job.status != :succeeded do
      raise "provider training ended with #{inspect(job.status)}"
    end

    {:ok, _rebound} = TrainingJob.rebind(job, base_program, path: program_path)
    loaded = DSEx.load!(program_path)
    trained = evaluate(loaded, dataset["held_out"], concurrency)
    smoke = evaluate(loaded, [hd(dataset["held_out"])], 1)

    final =
      state
      |> Map.put("status", "complete")
      |> Map.put("completed_at", DateTime.utc_now() |> DateTime.to_iso8601())
      |> Map.put("job", public_job(job))
      |> Map.put("trained", trained)
      |> Map.put("reloaded_program_smoke", smoke)
      |> Map.put("effect", effect(state["baseline"], trained))
      |> Map.put("program_artifact_sha256", file_sha256(program_path))

    write_json!(artifact_path, final)
    final
  end

  defp submit!(program, signature, rows, api_key, opts) do
    trainer =
      OpenAITrainer.new(
        api_key: api_key,
        retry_backoff_ms: Keyword.get(opts, :retry_backoff_ms, 1_000)
      )

    examples = Enum.map(rows, &example/1)

    call_opts = [
      method: :sft,
      suffix: Keyword.get(opts, :suffix, "dsex-route-v1"),
      hyperparameters: [n_epochs: Keyword.get(opts, :epochs, 3)],
      example_encoder: training_encoder(signature),
      idempotency_key: Keyword.get(opts, :idempotency_key, "dsex-banking77-route-v2")
    ]

    call_opts =
      case Keyword.get(opts, :training_file) do
        nil -> call_opts
        file_id -> Keyword.put(call_opts, :training_file, file_id)
      end

    case Trainer.finetune(trainer, DSEx.ProgramAccess.lm(program), examples, call_opts) do
      {:ok, job} -> job
      {:error, reason} -> raise "provider training submission failed: #{inspect(reason)}"
    end
  end

  defp await_terminal!(job, checkpoint_path, artifact_path, state, poll_ms, max_polls) do
    Enum.reduce_while(1..max_polls, job, fn poll, current ->
      if current.status in @terminal do
        {:halt, current}
      else
        if poll > 1, do: Process.sleep(poll_ms)

        case TrainingJob.refresh(current) do
          {:ok, refreshed} ->
            TrainingJob.save!(refreshed, checkpoint_path)

            state
            |> Map.put("status", "training")
            |> Map.put("polls", poll)
            |> Map.put("job", public_job(refreshed))
            |> write_json!(artifact_path)

            if refreshed.status in @terminal,
              do: {:halt, refreshed},
              else: {:cont, refreshed}

          {:error, reason} ->
            raise "provider training refresh failed: #{inspect(reason)}"
        end
      end
    end)
    |> case do
      %TrainingJob{status: status} = terminal when status in @terminal -> terminal
      %TrainingJob{} -> raise "provider training did not finish within #{max_polls} polls"
    end
  end

  defp resume_state!(checkpoint_path, artifact_path, api_key, dataset, model) do
    _job = TrainingJob.load!(checkpoint_path, api_key: api_key)

    case File.read(artifact_path) do
      {:ok, _json} ->
        load_state!(artifact_path, dataset, model)

      {:error, reason} ->
        raise "campaign checkpoint exists without readable artifact: #{inspect(reason)}"
    end
  end

  defp evaluate(program, rows, concurrency) do
    started = System.monotonic_time()

    results =
      rows
      |> Task.async_stream(
        fn row -> evaluate_row(program, row) end,
        max_concurrency: concurrency,
        timeout: 120_000,
        ordered: true
      )
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, reason} -> %{"status" => "task_exit", "error" => inspect(reason)}
      end)

    correct = Enum.count(results, &(&1["correct"] == true))
    failures = Enum.count(results, &(&1["status"] != "ok"))

    %{
      "accuracy" => correct / length(rows),
      "correct" => correct,
      "failures" => failures,
      "latency_ms" => elapsed_ms(started),
      "macro_f1" => macro_f1(results),
      "rows" => results,
      "total" => length(rows),
      "usage" => aggregate_usage(results)
    }
  end

  defp evaluate_row(program, row) do
    started = System.monotonic_time()

    case DSEx.call(program, %{utterance: row["utterance"]}) do
      {:ok, prediction} ->
        actual = DSEx.get(prediction, :route)

        %{
          "actual" => actual,
          "correct" => actual == row["route"],
          "expected" => row["route"],
          "id" => row["id"],
          "latency_ms" => elapsed_ms(started),
          "status" => "ok",
          "usage" => prediction.metadata[:usage] || prediction.metadata["usage"]
        }

      {:error, reason} ->
        %{
          "correct" => false,
          "error" => reason |> DSEx.Redaction.redact() |> inspect(),
          "expected" => row["route"],
          "id" => row["id"],
          "latency_ms" => elapsed_ms(started),
          "status" => "error"
        }
    end
  end

  defp effect(baseline, trained) do
    delta = trained["accuracy"] - baseline["accuracy"]

    %{
      "accuracy_delta" => delta,
      "macro_f1_delta" => trained["macro_f1"] - baseline["macro_f1"],
      "trained_better" => delta > 0,
      "trained_not_worse" => delta >= 0,
      "all_trained_calls_succeeded" => trained["failures"] == 0
    }
  end

  defp program(signature, model, api_key) do
    lm =
      DSEx.req_llm(model,
        api_key: api_key,
        temperature: 0,
        max_tokens: 32,
        timeout: 120_000
      )

    evaluation_program(signature, lm)
  end

  @doc false
  def evaluation_program(signature, lm),
    do: DSEx.predict(signature, lm: lm, adapter: DSEx.Adapter.Chat)

  defp signature(routes) do
    DSEx.signature(
      %{
        inputs: [%{name: :utterance, type: :string}],
        outputs: [
          %{name: :route, type: :string, constraints: %{enum: routes}}
        ]
      },
      @instruction
    )
  end

  defp example(row) do
    DSEx.example(utterance: row["utterance"], route: row["route"])
    |> DSEx.with_inputs(:utterance)
  end

  defp training_encoder(signature) do
    fn example ->
      {:ok, %{messages: Enum.map(training_messages(signature, example), &provider_message/1)}}
    end
  end

  @doc false
  def training_messages(signature, example) do
    messages =
      DSEx.Adapter.Chat.format(signature, %{},
        demos: [example],
        response_instruction: false
      )

    {systems, turn} = Enum.split_while(messages, &(role(&1) == :system))

    case turn do
      [user, %{role: :assistant} = assistant | _rest] -> systems ++ [user, assistant]
      _other -> raise ArgumentError, "training messages are unavailable for the example"
    end
  end

  defp provider_message(message),
    do: %{role: message |> role() |> Atom.to_string(), content: message.content}

  defp role(%{role: role}) when is_atom(role), do: role
  defp role(%{role: role}) when is_binary(role), do: String.to_existing_atom(role)

  defp load_dataset!(path) do
    data = path |> File.read!() |> Jason.decode!()

    unless valid_dataset?(data) do
      raise "invalid provider training dataset"
    end

    data
  end

  @doc false
  def valid_dataset?(data) when is_map(data) do
    payload = Map.delete(data, "payload_sha256")

    data["artifact_type"] == "dsex_provider_training_dataset" and
      data["schema_version"] == 1 and is_list(data["train"]) and
      length(data["train"]) >= 10 and is_list(data["held_out"]) and
      data["held_out"] != [] and data["selection"]["train_held_out_overlap"] == [] and
      data["digests"]["train"] == digest(data["train"]) and
      data["digests"]["held_out"] == digest(data["held_out"]) and
      data["payload_sha256"] == digest(payload)
  rescue
    _error -> false
  end

  def valid_dataset?(_data), do: false

  defp campaign_state(path, dataset, model, baseline) do
    %{
      "artifact_type" => "dsex_paid_provider_training_campaign",
      "schema_version" => 2,
      "status" => "baseline_complete",
      "started_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "provider" => "openai",
      "base_model" => model,
      "dataset" => %{
        "path" => path,
        "payload_sha256" => dataset["payload_sha256"],
        "source" => dataset["source"],
        "train_digest" => dataset["digests"]["train"],
        "held_out_digest" => dataset["digests"]["held_out"],
        "train_rows" => length(dataset["train"]),
        "held_out_rows" => length(dataset["held_out"]),
        "overlap" => dataset["selection"]["train_held_out_overlap"]
      },
      "evaluation_prompt_exposes_route_mapping" => false,
      "evaluation_adapter" => "chat",
      "baseline" => baseline
    }
  end

  defp load_state!(path, dataset, model) do
    state = path |> File.read!() |> Jason.decode!()

    unless state["artifact_type"] == "dsex_paid_provider_training_campaign" and
             state["schema_version"] == 2 and state["base_model"] == model and
             state["evaluation_adapter"] == "chat" and
             get_in(state, ["dataset", "payload_sha256"]) == dataset["payload_sha256"] do
      raise "provider training artifact is incompatible with the current campaign contract"
    end

    state
  end

  defp public_job(job) do
    response = job.metadata["last_status_response"] || job.metadata[:last_status_response] || %{}

    %{
      "id" => job.id,
      "provider" => to_string(job.provider),
      "base_model" => job.model,
      "status" => status_string(job.status),
      "result_model" => job.result_model,
      "trained_tokens" => response["trained_tokens"],
      "created_at" => response["created_at"],
      "finished_at" => response["finished_at"],
      "error" => DSEx.Redaction.redact(response["error"])
    }
  end

  defp status_string({:unknown, value}), do: value
  defp status_string(value) when is_atom(value), do: Atom.to_string(value)

  defp aggregate_usage(results) do
    results
    |> Enum.map(& &1["usage"])
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(%{}, &sum_usage/2)
  end

  defp sum_usage(usage, acc) when is_map(usage) do
    Enum.reduce(usage, acc, fn {key, value}, totals ->
      if is_number(value),
        do: Map.update(totals, to_string(key), value, &(&1 + value)),
        else: totals
    end)
  end

  defp macro_f1(results) do
    labels = ["R17", "R42", "R68", "R93"]

    labels
    |> Enum.map(fn label ->
      tp = Enum.count(results, &(&1["expected"] == label and &1["actual"] == label))
      fp = Enum.count(results, &(&1["expected"] != label and &1["actual"] == label))
      fn_ = Enum.count(results, &(&1["expected"] == label and &1["actual"] != label))
      if 2 * tp + fp + fn_ == 0, do: 0.0, else: 2 * tp / (2 * tp + fp + fn_)
    end)
    |> then(&(Enum.sum(&1) / length(&1)))
  end

  defp elapsed_ms(started) do
    System.convert_time_unit(System.monotonic_time() - started, :native, :microsecond) / 1_000
  end

  defp write_json!(value, path) when is_map(value) and is_binary(path),
    do: write_json!(path, value)

  defp write_json!(path, value) do
    File.mkdir_p!(Path.dirname(path))
    temporary = path <> ".tmp-#{System.unique_integer([:positive])}"

    try do
      File.write!(temporary, Jason.encode!(value, pretty: true) <> "\n", [:sync])
      File.rename!(temporary, path)
    after
      File.rm(temporary)
    end
  end

  defp file_sha256(path) do
    path |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
  end

  defp digest(value) do
    "sha256:" <>
      (value
       |> DSEx.Training.ChatDataset.canonical_json()
       |> then(&:crypto.hash(:sha256, &1))
       |> Base.encode16(case: :lower))
  end
end
