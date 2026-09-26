defmodule Imp.BenchmarkTruth.ProviderTrainingCampaign do
  @moduledoc false

  alias Imp.BenchmarkTruth.{ArtifactFile, RunContext}
  alias Imp.Clients.{OpenAITrainer, Trainer, TrainingJob}

  @terminal [:succeeded, :failed, :cancelled, :artifact_missing]
  @model "openai:gpt-4.1-mini-2025-04-14"
  @dataset_payload_sha256 "sha256:b84958ebf577bc5d57f2c6cf4a6033d7aafcb3a5cf91a79aa826b4345ebb1f3f"
  @training_jsonl_sha256 "7421adbb4673d81408969b76c5d95fb655bba68eb59863b2e88c107c018a25ff"
  @training_jsonl_bytes 55_601
  @training_usd_per_million 5.0
  @pricing_source "https://openai.com/api/pricing/"
  @instruction "Route the customer query to exactly one opaque routing code. The valid codes are R17, R42, R68, and R93. Return no explanation."

  def run!(opts) when is_list(opts) do
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    dataset_path = absolute(cwd, Keyword.fetch!(opts, :dataset))
    checkpoint_path = absolute(cwd, Keyword.fetch!(opts, :checkpoint))
    artifact_path = absolute(cwd, Keyword.fetch!(opts, :artifact))
    program_path = absolute(cwd, Keyword.fetch!(opts, :program))
    state_path = absolute(cwd, Keyword.get(opts, :state, artifact_path <> ".state.json"))
    api_key = Keyword.fetch!(opts, :api_key)
    model = Keyword.get(opts, :model, @model)
    poll_ms = Keyword.get(opts, :poll_ms, 30_000)
    max_polls = Keyword.get(opts, :max_polls, 360)
    concurrency = Keyword.get(opts, :concurrency, 8)
    epochs = Keyword.get(opts, :epochs, 3)
    max_cost_usd = Keyword.get(opts, :max_cost_usd, 5.0)

    context =
      RunContext.capture_git!(
        cwd: cwd,
        require_clean: Keyword.get(opts, :require_clean, true),
        inputs: %{
          "protocol_id" => "provider_training",
          "dataset_payload_sha256" => @dataset_payload_sha256,
          "model" => model,
          "epochs" => epochs
        }
      )

    dataset = load_dataset!(dataset_path)
    require_canonical_dataset!(dataset)
    signature = signature(dataset["route_codes"])
    base_program = program(signature, model, api_key)
    examples = Enum.map(dataset["train"], &example/1)
    encoder = training_encoder(signature)
    {:ok, training_jsonl} = OpenAITrainer.encode_jsonl(examples, encoder)
    upload = upload_evidence(training_jsonl, length(examples), epochs, max_cost_usd)

    recovered_receipt =
      case Keyword.get(opts, :training_file) do
        nil -> nil
        file_id -> verify_uploaded_training_file!(file_id, api_key, upload)
      end

    state =
      if File.exists?(checkpoint_path) do
        resume_state!(checkpoint_path, state_path, api_key, dataset, model, upload)
      else
        state =
          if File.exists?(state_path) do
            load_state!(state_path, dataset, model, upload)
          else
            baseline = evaluate(base_program, dataset["held_out"], concurrency)

            campaign_state(dataset_path, dataset, model, baseline, upload, context)
            |> write_json!(state_path)

            load_state!(state_path, dataset, model, upload)
          end

        state =
          if recovered_receipt do
            state
            |> Map.put("provider_training_file", recovered_receipt["id"])
            |> Map.put("provider_file_receipt", recovered_receipt)
            |> write_json!(state_path)

            load_state!(state_path, dataset, model, upload)
          else
            state
          end

        submit_opts =
          if recovered_receipt,
            do: Keyword.put(opts, :training_file, recovered_receipt["id"]),
            else: opts

        state = recover_dispatch!(state, checkpoint_path)
        dispatch = dispatch_plan(dataset, model, epochs, submit_opts)

        state
        |> Map.put("dispatch_intent", dispatch.intent)
        |> write_json!(state_path)

        job =
          submit!(
            base_program,
            signature,
            dataset["train"],
            api_key,
            Keyword.put(submit_opts, :idempotency_key, dispatch.idempotency_key)
          )

        TrainingJob.save!(job, checkpoint_path)
        assert_secret_absent!([checkpoint_path], api_key)
        training_file = provider_training_file(job)

        receipt =
          recovered_receipt || verify_uploaded_training_file!(training_file, api_key, upload)

        state =
          state
          |> Map.delete("dispatch_intent")
          |> Map.put("status", "submitted")
          |> Map.put("job", public_job(job))
          |> Map.put("provider_training_file", training_file)
          |> Map.put("provider_file_receipt", receipt)
          |> append_history(job, 0)

        write_json!(state_path, state)
        state
      end

    job = TrainingJob.load!(checkpoint_path, api_key: api_key)

    {job, state} =
      await_terminal!(job, checkpoint_path, state_path, state, poll_ms, max_polls, api_key)

    if job.status != :succeeded do
      raise "provider training ended with #{inspect(job.status)}"
    end

    {:ok, rebound} = TrainingJob.rebind(job, base_program, path: program_path)
    direct = evaluate(rebound, dataset["held_out"], concurrency)
    deployment_lm = Imp.ProgramAccess.lm(rebound)
    loaded = program_path |> Imp.read!() |> restore_runtime_credentials!(deployment_lm)
    reloaded = evaluate(loaded, dataset["held_out"], concurrency)
    acceptance = acceptance(state["baseline"], direct, reloaded)
    accounting = accounting(job, state, direct, reloaded, max_cost_usd)

    final =
      state
      |> Map.put("status", "complete")
      |> Map.put("completed_at", DateTime.utc_now() |> DateTime.to_iso8601())
      |> Map.put("job", public_job(job))
      |> Map.put("direct_trained", direct)
      |> Map.put("reloaded", reloaded)
      |> Map.put("effect", effect(state["baseline"], direct))
      |> Map.put("acceptance", acceptance)
      |> Map.put("accounting", accounting)
      |> Map.put("checkpoint_sha256", file_sha256(checkpoint_path))
      |> Map.put("program_artifact_sha256", file_sha256(program_path))

    assert_secret_absent!([checkpoint_path, program_path], api_key)
    File.mkdir_p!(Path.dirname(artifact_path))

    %{artifact: finished, path: written_path} =
      ArtifactFile.write_run_json!(artifact_path, final, context)

    ^finished = ArtifactFile.read_run_json!(written_path)
    {:ok, ^finished} = validate_artifact(finished)
    File.rm(state_path)
    %{artifact: finished, path: written_path}
  end

  @doc "Independently validates a completed paid-provider training artifact."
  def validate_artifact(artifact) when is_map(artifact) do
    with {:ok, verified} <- verify_envelope(artifact) do
      expected_acceptance =
        acceptance(verified["baseline"], verified["direct_trained"], verified["reloaded"])

      expected_effect = effect(verified["baseline"], verified["direct_trained"])

      checks = [
        {:clean_run,
         get_in(verified, ["run_context", "workspace"]) == %{
           "state" => "clean",
           "reproducible" => true
         }},
        {:artifact_contract,
         verified["artifact_type"] == "imp_paid_provider_training_campaign" and
           verified["schema_version"] == 3 and verified["status"] == "complete" and
           verified["provider"] == "openai" and verified["base_model"] == @model},
        {:canonical_dataset, valid_dataset_evidence?(verified["dataset"])},
        {:fresh_upload, valid_upload_evidence?(verified)},
        {:provider_job, valid_job_evidence?(verified["job"])},
        {:ordered_poll_history,
         valid_poll_history?(verified["poll_history"], get_in(verified, ["job", "id"]))},
        {:credential_free_persistence,
         sha256?(verified["checkpoint_sha256"]) and
           sha256?(verified["program_artifact_sha256"])},
        {:cost_accounting, valid_accounting?(verified["accounting"])},
        {:recomputed_acceptance,
         expected_acceptance["admissible"] and verified["acceptance"] == expected_acceptance},
        {:recomputed_effect, json_equal?(verified["effect"], expected_effect)}
      ]

      case for({name, false} <- checks, do: name) do
        [] -> {:ok, verified}
        errors -> {:error, errors}
      end
    end
  end

  def validate_artifact(_artifact), do: {:error, [:invalid_artifact]}

  defp submit!(program, signature, rows, api_key, opts) do
    trainer =
      OpenAITrainer.new(
        api_key: api_key,
        retry_backoff_ms: Keyword.get(opts, :retry_backoff_ms, 1_000)
      )

    examples = Enum.map(rows, &example/1)

    call_opts = [
      method: :sft,
      suffix: Keyword.get(opts, :suffix, "imp-route-v1"),
      hyperparameters: [n_epochs: Keyword.get(opts, :epochs, 3)],
      example_encoder: training_encoder(signature),
      idempotency_key: Keyword.get(opts, :idempotency_key)
    ]

    call_opts =
      case Keyword.get(opts, :training_file) do
        nil -> call_opts
        file_id -> Keyword.put(call_opts, :training_file, file_id)
      end

    case Trainer.finetune(trainer, Imp.ProgramAccess.lm(program), examples, call_opts) do
      {:ok, job} ->
        job

      {:error, reason} ->
        raise "provider training submission failed: #{reason |> Imp.Redaction.redact() |> inspect()}"
    end
  end

  defp await_terminal!(job, checkpoint_path, state_path, state, poll_ms, max_polls, api_key) do
    Enum.reduce_while(1..max_polls, {job, state}, fn poll, {current, current_state} ->
      if current.status in @terminal do
        {:halt, {current, current_state}}
      else
        if poll > 1, do: Process.sleep(poll_ms)

        case TrainingJob.refresh(current) do
          {:ok, refreshed} ->
            TrainingJob.save!(refreshed, checkpoint_path)
            assert_secret_absent!([checkpoint_path], api_key)

            updated_state =
              current_state
              |> Map.put("status", "training")
              |> Map.put("polls", poll)
              |> Map.put("job", public_job(refreshed))
              |> append_history(refreshed, poll)

            write_json!(state_path, updated_state)

            if refreshed.status in @terminal,
              do: {:halt, {refreshed, updated_state}},
              else: {:cont, {refreshed, updated_state}}

          {:error, reason} ->
            raise "provider training refresh failed: #{reason |> Imp.Redaction.redact() |> inspect()}"
        end
      end
    end)
    |> case do
      {%TrainingJob{status: status}, _state} = terminal when status in @terminal ->
        terminal

      {%TrainingJob{}, _state} ->
        raise "provider training did not finish within #{max_polls} polls"
    end
  end

  defp resume_state!(checkpoint_path, state_path, api_key, dataset, model, upload) do
    job = TrainingJob.load!(checkpoint_path, api_key: api_key)

    unless job.model == model do
      raise "provider training checkpoint model mismatch: expected=#{model} got=#{job.model}"
    end

    state =
      case File.read(state_path) do
        {:ok, _json} ->
          load_state!(state_path, dataset, model, upload)

        {:error, reason} ->
          raise "campaign checkpoint exists without readable artifact: #{inspect(reason)}"
      end

    case get_in(state, ["job", "id"]) do
      nil ->
        :ok

      id when id == job.id ->
        :ok

      id ->
        raise "provider training checkpoint identity mismatch: state=#{inspect(id)} job=#{job.id}"
    end

    recovered = recover_dispatch!(state, checkpoint_path)

    if recovered != state do
      write_json!(state_path, recovered)
    end

    recovered
  end

  @doc false
  def dispatch_plan(dataset, model, epochs, opts \\ []) when is_map(dataset) do
    identity = %{
      "protocol_id" => "provider_training",
      "dataset_payload_sha256" => dataset["payload_sha256"],
      "model" => model,
      "epochs" => epochs,
      "method" => "sft",
      "suffix" => Imp.Redaction.redact(Keyword.get(opts, :suffix, "imp-route-v1")),
      "training_file" => Imp.Redaction.redact(Keyword.get(opts, :training_file))
    }

    idempotency_key =
      Keyword.get(opts, :idempotency_key) ||
        "imp-provider-training-" <> sha256(Jason.encode!(identity))

    %{
      idempotency_key: idempotency_key,
      intent: %{
        "protocol" => "fail_closed",
        "schema_version" => 1,
        "status" => "unresolved",
        "identity" => identity,
        "idempotency_key_sha256" => sha256(idempotency_key),
        "recorded_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      }
    }
  end

  @doc false
  def recover_dispatch(state, checkpoint_path)
      when is_map(state) and is_binary(checkpoint_path) do
    cond do
      File.exists?(checkpoint_path) ->
        {:ok, Map.delete(state, "dispatch_intent")}

      Map.has_key?(state, "dispatch_intent") ->
        {:error, {:ambiguous_dispatch, get_in(state, ["dispatch_intent", "identity"]) || %{}}}

      state["status"] in ["submitted", "training", "complete"] ->
        {:error, {:missing_checkpoint, state["status"]}}

      true ->
        {:ok, state}
    end
  end

  defp recover_dispatch!(state, checkpoint_path) do
    case recover_dispatch(state, checkpoint_path) do
      {:ok, recovered} ->
        recovered

      {:error, {:ambiguous_dispatch, identity}} ->
        raise RuntimeError,
              "provider training dispatch has an ambiguous outcome after durable intent; checkpoint is missing, so replay is refused: #{inspect(identity)}"

      {:error, {:missing_checkpoint, status}} ->
        raise RuntimeError,
              "provider training state is #{inspect(status)} but its checkpoint is missing; replay is refused"
    end
  end

  @doc false
  def evaluate(program, rows, concurrency) do
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

    case Imp.call(program, %{utterance: row["utterance"]}) do
      {:ok, prediction} ->
        actual = Imp.get(prediction, :route)

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
          "error" => reason |> Imp.Redaction.redact() |> inspect(),
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
      Imp.req_llm(model,
        api_key: api_key,
        temperature: 0,
        max_tokens: 32,
        timeout: 120_000
      )

    evaluation_program(signature, lm)
  end

  @doc false
  def evaluation_program(signature, lm),
    do: Imp.predict(signature, lm: lm, adapter: Imp.Adapter.Chat)

  @doc false
  def signature(routes) do
    Imp.signature(
      %{
        inputs: [%{name: :utterance, type: :string}],
        outputs: [
          %{name: :route, type: :string, constraints: %{enum: routes}}
        ]
      },
      @instruction
    )
  end

  @doc false
  def example(row) do
    Imp.example(utterance: row["utterance"], route: row["route"])
    |> Imp.with_inputs(:utterance)
  end

  defp training_encoder(signature) do
    fn example ->
      {:ok, %{messages: Enum.map(training_messages(signature, example), &provider_message/1)}}
    end
  end

  @doc false
  def training_messages(signature, example) do
    messages =
      Imp.Adapter.Chat.format(signature, %{},
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
    train_ids = MapSet.new(data["train"], & &1["id"])
    held_out_ids = MapSet.new(data["held_out"], & &1["id"])
    train_utterances = MapSet.new(data["train"], & &1["utterance"])
    held_out_utterances = MapSet.new(data["held_out"], & &1["utterance"])

    data["artifact_type"] in ["imp_provider_training_dataset", "dsex_provider_training_dataset"] and
      data["schema_version"] == 1 and is_list(data["train"]) and
      length(data["train"]) >= 10 and is_list(data["held_out"]) and
      data["held_out"] != [] and data["selection"]["train_held_out_overlap"] == [] and
      data["digests"]["train"] == digest(data["train"]) and
      data["digests"]["held_out"] == digest(data["held_out"]) and
      data["payload_sha256"] == digest(payload) and MapSet.disjoint?(train_ids, held_out_ids) and
      MapSet.disjoint?(train_utterances, held_out_utterances)
  rescue
    _error -> false
  end

  def valid_dataset?(_data), do: false

  defp require_canonical_dataset!(dataset) do
    unless dataset["payload_sha256"] == @dataset_payload_sha256 and
             dataset["route_codes"] == ["R17", "R42", "R68", "R93"] and
             length(dataset["train"]) == 80 and length(dataset["held_out"]) == 40 do
      raise "provider training dataset is not the canonical Banking77 campaign payload"
    end
  end

  defp campaign_state(path, dataset, model, baseline, upload, context) do
    %{
      "artifact_type" => "imp_paid_provider_training_campaign",
      "schema_version" => 3,
      "status" => "baseline_complete",
      "started_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "provider" => "openai",
      "base_model" => model,
      "source_commits" => context.source_commits,
      "workspace_state" => context.workspace_state,
      "upload" => upload,
      "poll_history" => [],
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

  defp load_state!(path, dataset, model, upload) do
    state = path |> File.read!() |> Jason.decode!()

    unless state["artifact_type"] == "imp_paid_provider_training_campaign" and
             state["schema_version"] == 3 and state["base_model"] == model and
             state["evaluation_adapter"] == "chat" and
             get_in(state, ["dataset", "payload_sha256"]) == dataset["payload_sha256"] and
             state["upload"] == upload do
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
      "error" => Imp.Redaction.redact(response["error"])
    }
  end

  defp provider_training_file(job) do
    submit = job.metadata["submit_response"] || job.metadata[:submit_response] || %{}
    submit["training_file"] || submit[:training_file]
  end

  defp append_history(state, job, poll) do
    entry =
      public_job(job)
      |> Map.take([
        "id",
        "status",
        "result_model",
        "trained_tokens",
        "created_at",
        "finished_at",
        "error"
      ])
      |> Map.put("poll", poll)
      |> Map.put("observed_at", DateTime.utc_now() |> DateTime.to_iso8601())

    Map.update(state, "poll_history", [entry], &(&1 ++ [entry]))
  end

  @doc false
  def acceptance(baseline, direct, reloaded) do
    checks = %{
      "complete_held_out" => Enum.all?([baseline, direct, reloaded], &complete_result?/1),
      "metrics_recomputed" => Enum.all?([baseline, direct, reloaded], &metrics_match_rows?/1),
      "trained_improves_accuracy" => direct["accuracy"] > baseline["accuracy"],
      "trained_improves_macro_f1" => direct["macro_f1"] > baseline["macro_f1"],
      "all_trained_calls_succeeded" => direct["failures"] == 0 and reloaded["failures"] == 0,
      "save_load_equivalent" => row_outcomes(direct) == row_outcomes(reloaded),
      "row_identity_preserved" => same_ids?([baseline, direct, reloaded])
    }

    Map.put(checks, "admissible", Enum.all?(checks, fn {_name, passed} -> passed end))
  end

  @doc false
  def restore_runtime_credentials!(loaded, expected_lm) do
    loaded_lm = Imp.ProgramAccess.lm(loaded)
    expected_opts = Keyword.drop(expected_lm.opts, [:api_key, :authorization, :headers])

    unless json_equal?(loaded_lm.model, expected_lm.model) and
             Map.new(loaded_lm.opts) == Map.new(expected_opts) do
      raise "saved provider-trained program changed its credential-free deployment LM"
    end

    Imp.with_lm(loaded, expected_lm)
  end

  defp upload_evidence(jsonl, rows, epochs, max_cost_usd) do
    token_upper_bound = byte_size(jsonl) * epochs
    cost_upper_bound = token_upper_bound / 1_000_000 * @training_usd_per_million

    unless is_number(max_cost_usd) and max_cost_usd > 0 and cost_upper_bound <= max_cost_usd do
      raise "provider training preflight cost upper bound #{cost_upper_bound} exceeds #{inspect(max_cost_usd)} USD"
    end

    %{
      "mode" => "fresh_upload",
      "rows" => rows,
      "jsonl_bytes" => byte_size(jsonl),
      "jsonl_sha256" => sha256(jsonl),
      "epochs" => epochs,
      "training_token_upper_bound" => token_upper_bound,
      "training_cost_upper_bound_usd" => cost_upper_bound,
      "max_cost_usd" => max_cost_usd,
      "pricing" => %{
        "currency" => "USD",
        "training_usd_per_million_tokens" => @training_usd_per_million,
        "source" => @pricing_source,
        "checked_at" => "2026-07-13"
      }
    }
  end

  defp accounting(job, state, direct, reloaded, max_cost_usd) do
    trained_tokens = public_job(job)["trained_tokens"]

    training_cost_usd =
      if is_integer(trained_tokens), do: trained_tokens / 1_000_000 * @training_usd_per_million

    %{
      "currency" => "USD",
      "trained_tokens" => trained_tokens,
      "training_cost_usd" => training_cost_usd,
      "training_cost_within_bound" =>
        is_number(training_cost_usd) and training_cost_usd <= max_cost_usd,
      "max_cost_usd" => max_cost_usd,
      "pricing" => state["upload"]["pricing"],
      "baseline_usage" => state["baseline"]["usage"],
      "direct_trained_usage" => direct["usage"],
      "reloaded_usage" => reloaded["usage"]
    }
  end

  defp verify_envelope(artifact) do
    {:ok, RunContext.verify!(artifact)}
  rescue
    _error -> {:error, [:invalid_run_envelope]}
  end

  defp valid_dataset_evidence?(dataset) when is_map(dataset) do
    dataset["payload_sha256"] == @dataset_payload_sha256 and dataset["train_rows"] == 80 and
      dataset["held_out_rows"] == 40 and dataset["overlap"] == [] and
      get_in(dataset, ["source", "dataset"]) == "PolyAI/banking77"
  end

  defp valid_dataset_evidence?(_dataset), do: false

  defp valid_upload_evidence?(artifact) do
    upload = artifact["upload"] || %{}
    file_id = artifact["provider_training_file"]
    receipt = artifact["provider_file_receipt"] || %{}
    pricing = upload["pricing"] || %{}

    upload["mode"] == "fresh_upload" and upload["rows"] == 80 and upload["epochs"] == 3 and
      upload["jsonl_bytes"] == @training_jsonl_bytes and
      upload["jsonl_sha256"] == @training_jsonl_sha256 and
      is_integer(upload["training_token_upper_bound"]) and
      upload["training_token_upper_bound"] > 0 and
      upload["training_cost_upper_bound_usd"] <= upload["max_cost_usd"] and
      pricing["currency"] == "USD" and
      pricing["training_usd_per_million_tokens"] == @training_usd_per_million and
      pricing["source"] == @pricing_source and is_binary(file_id) and file_id != "" and
      receipt["id"] == file_id and receipt["bytes"] == @training_jsonl_bytes and
      receipt["sha256"] == @training_jsonl_sha256 and receipt["purpose"] == "fine-tune" and
      receipt["status"] == "processed"
  end

  defp valid_job_evidence?(job) when is_map(job) do
    job["provider"] == "openai" and job["status"] == "succeeded" and
      is_binary(job["id"]) and job["id"] != "" and is_binary(job["result_model"]) and
      job["result_model"] != "" and is_integer(job["trained_tokens"]) and
      job["trained_tokens"] > 0 and is_nil(job["error"])
  end

  defp valid_job_evidence?(_job), do: false

  defp valid_poll_history?(history, job_id) when is_list(history) and length(history) >= 2 do
    polls = Enum.map(history, & &1["poll"])

    Enum.all?(history, &(&1["id"] == job_id and is_binary(&1["observed_at"]))) and
      polls == Enum.sort(polls) and List.last(history)["status"] == "succeeded"
  end

  defp valid_poll_history?(_history, _job_id), do: false

  defp valid_accounting?(accounting) when is_map(accounting) do
    expected = accounting["trained_tokens"] / 1_000_000 * @training_usd_per_million

    is_integer(accounting["trained_tokens"]) and accounting["trained_tokens"] > 0 and
      close?(accounting["training_cost_usd"], expected) and
      accounting["training_cost_within_bound"] == true and
      accounting["training_cost_usd"] <= accounting["max_cost_usd"] and
      get_in(accounting, ["pricing", "source"]) == @pricing_source
  rescue
    _error -> false
  end

  defp valid_accounting?(_accounting), do: false

  defp verify_uploaded_training_file!(file_id, api_key, upload) do
    base_url =
      String.trim_trailing(System.get_env("OPENAI_BASE_URL") || "https://api.openai.com/v1", "/")

    headers = [{"authorization", "Bearer #{api_key}"}]

    with {:ok, %{status: 200, body: metadata}} <-
           Req.get("#{base_url}/files/#{file_id}", headers: headers, retry: false),
         {:ok, %{status: 200, body: content}} <-
           Req.get("#{base_url}/files/#{file_id}/content", headers: headers, retry: false),
         true <- is_binary(content),
         true <- metadata["id"] == file_id,
         true <-
           metadata["filename"] ==
             "imp-training-#{String.slice(upload["jsonl_sha256"], 0, 16)}.jsonl",
         true <- metadata["bytes"] == upload["jsonl_bytes"],
         true <- metadata["purpose"] == "fine-tune",
         true <- metadata["status"] == "processed",
         true <- sha256(content) == upload["jsonl_sha256"] do
      %{
        "id" => file_id,
        "filename" => metadata["filename"],
        "bytes" => metadata["bytes"],
        "purpose" => metadata["purpose"],
        "status" => metadata["status"],
        "created_at" => metadata["created_at"],
        "sha256" => upload["jsonl_sha256"],
        "verification" => "provider_metadata_and_downloaded_content"
      }
    else
      other ->
        raise "provider training file verification failed: #{other |> Imp.Redaction.redact() |> inspect()}"
    end
  end

  defp complete_result?(%{"rows" => rows, "total" => 40}) when length(rows) == 40,
    do: Enum.all?(rows, &(is_binary(&1["id"]) and is_boolean(&1["correct"])))

  defp complete_result?(_result), do: false

  defp metrics_match_rows?(result) do
    rows = result["rows"] || []
    correct = Enum.count(rows, &(&1["correct"] == true))
    failures = Enum.count(rows, &(&1["status"] != "ok"))

    result["correct"] == correct and result["failures"] == failures and
      close?(result["accuracy"], correct / max(length(rows), 1)) and
      close?(result["macro_f1"], macro_f1(rows))
  end

  defp row_outcomes(result),
    do: Enum.map(result["rows"], &Map.take(&1, ["id", "expected", "actual", "status", "correct"]))

  defp same_ids?([first | rest]) do
    ids = Enum.map(first["rows"], & &1["id"])

    Enum.uniq(ids) == ids and
      Enum.all?(rest, &(Enum.map(&1["rows"], fn row -> row["id"] end) == ids))
  end

  defp close?(left, right) when is_number(left) and is_number(right),
    do: abs(left - right) < 1.0e-12

  defp close?(_left, _right), do: false

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

  defp assert_secret_absent!(paths, secret) do
    if Enum.any?(paths, &(File.read!(&1) |> :binary.match(secret) != :nomatch)) do
      raise "provider training credential leaked into a persisted artifact"
    end

    :ok
  end

  defp absolute(cwd, path),
    do: if(Path.type(path) == :absolute, do: path, else: Path.join(cwd, path))

  defp sha256(value),
    do: value |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

  defp sha256?(value),
    do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  defp json_equal?(left, right),
    do: json_safe(left) == json_safe(right)

  defp json_safe(value), do: value |> Jason.encode!() |> Jason.decode!()

  defp digest(value) do
    "sha256:" <>
      (value
       |> Imp.Training.ChatDataset.canonical_json()
       |> then(&:crypto.hash(:sha256, &1))
       |> Base.encode16(case: :lower))
  end
end
