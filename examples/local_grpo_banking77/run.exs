defmodule LocalGRPOBanking77.Atomic do
  def write!(path, value) do
    File.mkdir_p!(Path.dirname(path))
    temporary = path <> ".tmp-#{System.unique_integer([:positive])}"

    try do
      File.write!(temporary, Jason.encode!(value, pretty: true) <> "\n", [:sync])
      File.rename!(temporary, path)
    after
      File.rm(temporary)
    end
  end
end

defmodule LocalGRPOBanking77.Reward do
  def exact_route(expected, prediction, %{}) do
    if Imp.get(prediction, :route) == Imp.get(expected, :route), do: 1.0, else: 0.0
  end
end

defmodule LocalGRPOBanking77.Runner do
  alias Imp.Clients.{TrainingJob, TRLArtifact, TRLDeployment, TRLLM, TRLProtocol, TRLTrainer}
  alias Imp.Optimizer.GRPO.Callback
  alias LocalGRPOBanking77.Atomic

  @data_sha256 "1703f59bf336df8dc35590275531b67bb6ee43a5d0c96eb44696c219af5cfc18"
  @train_sha256 "sha256:ef713f6deb2ee59018bc59c706f9024c5d6d71cad3019ee96bc848d3369fc8b4"
  @selection_sha256 "sha256:83d59093b04671e446308dc8e7cb549432e0c4a719eb3c1d7e987a68530851aa"
  @test_sha256 "sha256:5d70b2ff26f9c30862175e63bc1cb4742f509f49c7571e205f1faf06d5d10fe1"
  @model "Qwen/Qwen2.5-0.5B-Instruct@7ae557604adf67be50417f59c2c2f167def9a775"
  @seed 20_260_725
  @routes ["R17", "R42", "R68", "R93"]
  @train_ids ~w(
    banking77-train-2511 banking77-train-2512 banking77-train-2513 banking77-train-2514
    banking77-train-3482 banking77-train-3483 banking77-train-3484 banking77-train-3485
    banking77-train-5092 banking77-train-5093 banking77-train-5094 banking77-train-5095
    banking77-train-6722 banking77-train-6723 banking77-train-6724 banking77-train-6725
  )
  @selection_ids ~w(
    banking77-train-2515 banking77-train-2516 banking77-train-3486 banking77-train-3487
    banking77-train-5096 banking77-train-5097 banking77-train-6726 banking77-train-6727
  )

  def run do
    if System.get_env("IMP_GRPO_FRESH") == "1", do: fresh(), else: parent()
  end

  defp parent do
    paths = paths!()
    rows = preflight!(paths)
    trainer = trainer(paths, {:local_grpo_banking77, @seed})
    portable = program(Imp.req_llm("openai:portable-base"))

    base_selection = with_base(trainer, fn lm -> evaluate(program(lm), rows.selection) end)
    Atomic.write!(Path.join(paths.output, "01-base-selection.json"), base_selection)

    training_lm = %TRLLM{
      model: @model,
      worker_key: trainer.worker_key,
      response_field: :route,
      timeout: 120_000
    }

    optimizer =
      Imp.Optimizer.GRPO.new(
        Callback.reward(LocalGRPOBanking77.Reward, :exact_route,
          id: "banking77-exact-route-v1",
          config: %{}
        ),
        trainer: trainer,
        num_train_steps: train_steps(),
        num_dspy_examples_per_grpo_step: train_width(),
        num_rollouts_per_grpo_step: 4,
        seed: @seed,
        status_poll_interval_ms: 0,
        callback_timeout_ms: 900_000,
        timeout: 120_000,
        checkpoint_path: Path.join(paths.output, "grpo-checkpoint.bin")
      )

    {:ok, result} = Imp.train(program(training_lm), optimizer, examples(rows.train))
    job = result.job
    {:ok, manifest} = TRLArtifact.verify_job(job)

    step_artifacts =
      Enum.map(1..train_steps(), fn step ->
        path = job.result_model |> Path.dirname() |> Path.join("step-#{step}")

        %{
          step: step,
          path: path,
          observation: path |> Path.join("trl-observation.json") |> read_json!(),
          update: path |> Path.join("update-#{step}.json") |> read_json!()
        }
      end)

    final_step = List.last(step_artifacts)
    observation = final_step.observation
    update = final_step.update

    training_stage = %{
      status: "complete",
      job: encode_job(job),
      artifact_payload_sha256: manifest["payload_sha256"],
      observation: observation,
      steps: step_artifacts,
      group: update["groups"],
      selected_train_row_ids:
        Enum.flat_map(step_artifacts, &selected_train_row_ids(&1.update, rows.train))
    }

    Atomic.write!(Path.join(paths.output, "02-training.json"), training_stage)

    {:ok, trained_program} = TrainingJob.rebind(job, portable, trainer: trainer)

    try do
      trained_selection = evaluate(trained_program, rows.selection)
      Atomic.write!(Path.join(paths.output, "03-trained-selection.json"), trained_selection)

      selection = choose(base_selection, trained_selection)
      Atomic.write!(Path.join(paths.output, "04-selection.json"), selection)

      base_test = with_base(trainer, fn lm -> evaluate(program(lm), rows.test) end)
      Atomic.write!(Path.join(paths.output, "05-base-test.json"), base_test)

      trained_test = evaluate(trained_program, rows.test)
      Atomic.write!(Path.join(paths.output, "06-trained-test.json"), trained_test)

      :ok = TrainingJob.save!(job, paths.job)
      :ok = Imp.save!(portable, paths.program)

      summary = %{
        status: "complete",
        scope: "one task/model #{train_steps()}-step ordinary model-generated local GRPO result",
        model: @model,
        trainable_tensors_changed:
          Enum.any?(step_artifacts, & &1.observation["trainable_tensors_changed"]),
        training_steps:
          Enum.map(step_artifacts, fn artifact ->
            %{
              step: artifact.step,
              rewards: artifact.observation["rewards"],
              advantages: artifact.observation["advantages"],
              training_loss: artifact.observation["training_loss"],
              trainable_tensors_changed: artifact.observation["trainable_tensors_changed"]
            }
          end),
        rewards: observation["rewards"],
        advantages: observation["advantages"],
        training_loss: observation["training_loss"],
        base_selection: metrics(base_selection),
        trained_selection: metrics(trained_selection),
        selected_arm: selection.selected_arm,
        base_test: metrics(base_test),
        trained_test: metrics(trained_test),
        artifact_path: job.result_model,
        artifact_sha256: manifest["payload_sha256"]
      }

      Atomic.write!(Path.join(paths.output, "07-summary-before-fresh.json"), summary)
    after
      :ok = TRLDeployment.stop(job)
    end

    fresh_path = Path.join(paths.output, "08-fresh-selected-test.json")
    {fresh_output, status} = fresh_process(paths, fresh_path)
    if status != 0, do: raise("fresh OS BEAM failed: #{fresh_output}")

    selection = read_json!(Path.join(paths.output, "04-selection.json"))

    selected_test =
      if selection["selected_arm"] == "trained",
        do: read_json!(Path.join(paths.output, "06-trained-test.json")),
        else: read_json!(Path.join(paths.output, "05-base-test.json"))

    fresh_test = read_json!(fresh_path)

    unless fresh_test["reproduction_sha256"] == selected_test["reproduction_sha256"],
      do: raise("fresh selected predictions/errors differ")

    summary =
      paths.output
      |> Path.join("07-summary-before-fresh.json")
      |> read_json!()
      |> Map.merge(%{
        "fresh_selected_arm" => selection["selected_arm"],
        "fresh_byte_identical" => true,
        "fresh_artifact_path" => fresh_test["artifact_path"],
        "fresh_artifact_sha256" => fresh_test["artifact_sha256"]
      })

    Atomic.write!(Path.join(paths.output, "result.json"), summary)
    IO.puts(Jason.encode!(summary, pretty: true))
  rescue
    error ->
      paths = paths!()

      Atomic.write!(Path.join(paths.output, "failure.json"), %{
        status: "stopped",
        error: Exception.format(:error, error, __STACKTRACE__)
      })

      reraise error, __STACKTRACE__
  end

  defp fresh do
    paths = paths!()
    rows = preflight!(paths)
    job = TrainingJob.load!(paths.job)
    portable = Imp.load!(paths.program)
    trainer = trainer(paths, {:local_grpo_banking77_fresh, @seed})
    selection = read_json!(Path.join(paths.output, "04-selection.json"))
    selected_arm = System.get_env("IMP_GRPO_FRESH_ARM", selection["selected_arm"])

    {:ok, deployment, selected} =
      case selected_arm do
        "trained" ->
          {:ok, trained} = TrainingJob.rebind(job, portable, trainer: trainer)
          {:ok, job, trained}

        "base" ->
          {:ok, base} = TRLDeployment.start_base(trainer)
          {:ok, base, program(base.lm)}
      end

    try do
      stage = evaluate(selected, rows.test)

      {artifact_path, artifact_sha256} =
        case deployment do
          %TrainingJob{} ->
            artifact = Imp.ProgramAccess.get_metadata(selected, :training_artifact)
            {artifact.result_model, artifact.artifact_sha256}

          %TRLDeployment{} = base ->
            {base.artifact_path, base.artifact_sha256}
        end

      Atomic.write!(System.fetch_env!("IMP_GRPO_FRESH_OUTPUT"), %{
        status: "complete",
        selected_arm: selected_arm,
        rows: stage.rows,
        accuracy: stage.accuracy,
        macro_f1: stage.macro_f1,
        errors: stage.errors,
        reproduction_sha256: stage.reproduction_sha256,
        artifact_path: artifact_path,
        artifact_sha256: artifact_sha256
      })
    after
      :ok = TRLDeployment.stop(deployment)
    end
  end

  defp preflight!(paths) do
    unless sha256_file(paths.data) == @data_sha256, do: raise("Banking77 data digest drift")
    unless File.regular?(paths.python), do: raise("pinned TRL Python is missing")
    unless File.dir?(paths.model), do: raise("pinned Qwen snapshot is missing")
    unless File.regular?(paths.contract), do: raise("pinned TRL contract is missing")

    source = read_json!(paths.data)
    train = ordered_rows!(source["train"], @train_ids)
    selection = ordered_rows!(source["train"], @selection_ids)
    test = source["held_out"]

    unless TRLProtocol.digest(Enum.map(train, &Imp.Optimizer.Report.encode_term/1)) ==
             @train_sha256,
           do: raise("frozen train split drift")

    unless TRLProtocol.digest(Enum.map(selection, &Imp.Optimizer.Report.encode_term/1)) ==
             @selection_sha256,
           do: raise("frozen selection split drift")

    unless source["digests"]["held_out"] == @test_sha256 and length(test) == 40,
      do: raise("frozen untouched test split drift")

    stage = %{
      status: "complete",
      model: @model,
      data_sha256: @data_sha256,
      train_sha256: @train_sha256,
      selection_sha256: @selection_sha256,
      test_sha256: @test_sha256,
      train_steps: train_steps(),
      train_width: train_width(),
      contract_path: paths.contract,
      train_ids: Enum.map(train, & &1["id"]),
      selection_ids: Enum.map(selection, & &1["id"]),
      test_ids: Enum.map(test, & &1["id"])
    }

    Atomic.write!(Path.join(paths.output, "00-preflight.json"), stage)
    %{train: train, selection: selection, test: test}
  end

  defp trainer(paths, key) do
    TRLTrainer.new(
      python: paths.python,
      model_path: paths.model,
      root: paths.sessions,
      contract_path: paths.contract,
      worker_key: key,
      timeout: 900_000
    )
  end

  defp program(lm) do
    Imp.predict(
      Imp.signature(
        "utterance -> route: enum[R17,R42,R68,R93]",
        """
        Classify the customer request into exactly one opaque route.
        R17: a fee was charged for making a card payment.
        R42: a card payment is not recognized by the customer.
        R68: a card payment is still pending.
        R93: a card payment was reversed or reverted.
        """
      ),
      lm: lm,
      adapter: Imp.Adapter.Chat,
      config: [json_fallback: false]
    )
  end

  defp examples(rows) do
    Enum.map(rows, fn row ->
      Imp.example(utterance: row["utterance"], route: row["route"], source_id: row["id"])
      |> Imp.with_inputs(:utterance)
    end)
  end

  defp with_base(trainer, fun) do
    {:ok, deployment} = TRLDeployment.start_base(trainer)

    try do
      fun.(deployment.lm)
    after
      :ok = TRLDeployment.stop(deployment)
    end
  end

  defp evaluate(program, rows) do
    results =
      Enum.map(rows, fn row ->
        case Imp.call(program, %{utterance: row["utterance"]}) do
          {:ok, prediction} ->
            actual = Imp.get(prediction, :route)
            %{id: row["id"], expected: row["route"], actual: actual, error: nil}

          {:error, reason} ->
            %{id: row["id"], expected: row["route"], actual: nil, error: inspect(reason)}
        end
      end)

    stage = %{
      status: "complete",
      rows: results,
      accuracy: Enum.count(results, &(&1.actual == &1.expected)) / length(results),
      macro_f1: macro_f1(results),
      errors: Enum.count(results, &(not is_nil(&1.error)))
    }

    Map.put(
      stage,
      :reproduction_sha256,
      stage.rows |> Imp.Optimizer.Report.encode_term() |> TRLProtocol.digest()
    )
  end

  defp choose(base, trained) do
    base_key = {base.accuracy, base.macro_f1}
    trained_key = {trained.accuracy, trained.macro_f1}

    if trained_key > base_key do
      %{selected_arm: "trained", rule: "accuracy_then_macro_f1_tie_keeps_base"}
    else
      %{selected_arm: "base", rule: "accuracy_then_macro_f1_tie_keeps_base"}
    end
  end

  defp metrics(stage), do: Map.take(stage, [:accuracy, :macro_f1, :errors])

  defp macro_f1(rows) do
    Enum.map(@routes, fn route ->
      tp = Enum.count(rows, &(&1.expected == route and &1.actual == route))
      fp = Enum.count(rows, &(&1.expected != route and &1.actual == route))
      fn_count = Enum.count(rows, &(&1.expected == route and &1.actual != route))
      denominator = 2 * tp + fp + fn_count
      if denominator == 0, do: 0.0, else: 2 * tp / denominator
    end)
    |> then(&(Enum.sum(&1) / length(&1)))
  end

  defp selected_train_row_ids(update, rows) do
    Enum.map(update["groups"], fn group ->
      prompt = group |> Map.fetch!("prompt") |> Enum.map_join("\n", & &1["content"])

      case Enum.filter(rows, &String.contains?(prompt, &1["utterance"])) do
        [%{"id" => id}] ->
          id

        matches ->
          raise("sealed group did not identify one frozen train row: #{inspect(matches)}")
      end
    end)
  end

  defp encode_job(job) do
    %{
      id: job.id,
      provider: job.provider,
      model: job.model,
      result_model: job.result_model,
      status: job.status,
      metadata: Imp.Optimizer.Report.encode_term(job.metadata)
    }
  end

  defp fresh_process(paths, output) do
    env = [
      {"MIX_ENV", "dev"},
      {"IMP_GRPO_FRESH", "1"},
      {"IMP_GRPO_OUTPUT", paths.output},
      {"IMP_GRPO_FRESH_OUTPUT", output},
      {"IMP_TRL_PYTHON", paths.python},
      {"IMP_TRL_MODEL", paths.model},
      {"IMP_TRL_CONTRACT", paths.contract},
      {"IMP_GRPO_TRAIN_STEPS", Integer.to_string(train_steps())},
      {"IMP_GRPO_TRAIN_WIDTH", Integer.to_string(train_width())},
      {"IMP_BANKING77_DATA", paths.data}
    ]

    System.cmd(
      "mix",
      ["run", "--no-compile", "--no-deps-check", "examples/local_grpo_banking77/run.exs"],
      cd: paths.repo,
      env: env,
      stderr_to_stdout: true
    )
  end

  defp paths! do
    repo = Path.expand("../..", Path.dirname(__ENV__.file))

    output =
      System.get_env(
        "IMP_GRPO_OUTPUT",
        "/Users/deepfates/.cache/imp/trl/model-generated-banking77-v1"
      )

    %{
      repo: repo,
      output: output,
      python:
        System.get_env(
          "IMP_TRL_PYTHON",
          "/Users/deepfates/.cache/imp/trl/feasibility-v1/.venv/bin/python"
        ),
      model:
        System.get_env("IMP_TRL_MODEL", "/Users/deepfates/.cache/imp/trl/feasibility-v1/model"),
      contract:
        System.get_env(
          "IMP_TRL_CONTRACT",
          Path.join(repo, "priv/trl_worker/qwen-one-update-contract.json")
        ),
      data:
        System.get_env(
          "IMP_BANKING77_DATA",
          Path.join(repo, "benchmarks/data/provider-training-banking77-v1.json")
        ),
      sessions: Path.join(output, "sessions"),
      job: Path.join(output, "training-job.json"),
      program: Path.join(output, "portable-program.json")
    }
  end

  defp ordered_rows!(rows, ids) do
    Enum.map(ids, fn id ->
      Enum.find(rows, &(&1["id"] == id)) || raise("missing frozen row #{id}")
    end)
  end

  defp read_json!(path), do: path |> File.read!() |> Jason.decode!()

  defp train_steps, do: positive_env!("IMP_GRPO_TRAIN_STEPS", 1)
  defp train_width, do: positive_env!("IMP_GRPO_TRAIN_WIDTH", 1)

  defp positive_env!(name, default) do
    case System.get_env(name) do
      nil ->
        default

      value ->
        case Integer.parse(value) do
          {number, ""} when number > 0 -> number
          _ -> raise("#{name} must be a positive integer")
        end
    end
  end

  defp sha256_file(path) do
    path |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
  end
end

LocalGRPOBanking77.Runner.run()
