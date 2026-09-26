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
  @treatment_id "model-generated-banking77-json-two-padded-epochs-v1"
  @pre_framing_fix_runner_sha256 "5b3309e4832e4dc484f36c38db16fc5fbda9dcc41922e392553a4366d9bbb34c"
  @base_selection_stage_sha256 "6f38b09ada8f30e6db207392d8438ea2d4f44180ea2811e0000750901d22bd89"
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
    cond do
      System.get_env("IMP_GRPO_FRESH") == "1" -> fresh()
      System.get_env("IMP_GRPO_RESTORE_PREFLIGHT_ONLY") == "1" -> restore_preflight()
      System.get_env("IMP_GRPO_RESUME_PREFLIGHT_ONLY") == "1" -> resume_preflight()
      true -> parent()
    end
  end

  defp resume_preflight do
    paths = paths!()
    require_resume_output!(paths)
    _rows = preflight!(paths, :verify)

    unless sha256_file(Path.join(paths.output, "01-base-selection.json")) ==
             @base_selection_stage_sha256,
           do: raise("retained base-selection stage drift")

    IO.puts("GRPO resume preflight complete")
  end

  defp restore_preflight do
    paths = paths!()
    require_resume_output!(paths)
    rows = preflight!(paths, :verify)
    {_job, _manifest, artifacts} = restore_completed_training!(paths, rows)
    IO.puts("GRPO completed-training restore preflight complete: #{length(artifacts)} steps")
  end

  defp parent do
    paths = paths!()
    resume? = System.get_env("IMP_GRPO_RESUME") == "1"

    if resume?,
      do: require_resume_output!(paths),
      else: require_new_output!(paths.output)

    run_parent(paths, resume?)
  end

  defp run_parent(paths, resume?) do
    rows = preflight!(paths, if(resume?, do: :verify, else: :write))
    trainer = trainer(paths, {:local_grpo_banking77, @seed})
    portable = program(Imp.req_llm("openai:portable-base"))

    base_selection =
      if resume? do
        unless sha256_file(Path.join(paths.output, "01-base-selection.json")) ==
                 @base_selection_stage_sha256,
               do: raise("retained base-selection stage drift")

        load_evaluation_stage!(Path.join(paths.output, "01-base-selection.json"))
      else
        stage = with_base(trainer, fn lm -> evaluate(program(lm), rows.selection) end)
        Atomic.write!(Path.join(paths.output, "01-base-selection.json"), stage)
        stage
      end

    {job, manifest, step_artifacts} =
      if resume? and not File.regular?(Path.join(paths.output, "grpo-checkpoint.bin")) do
        restore_completed_training!(paths, rows)
      else
        train!(paths, rows, trainer)
      end

    final_step = List.last(step_artifacts)
    observation = final_step.observation

    {:ok, trained_program} = TrainingJob.rebind(job, portable, trainer: trainer)

    try do
      trained_selection =
        if resume? and File.regular?(Path.join(paths.output, "03-trained-selection.json")) do
          load_evaluation_stage!(Path.join(paths.output, "03-trained-selection.json"))
        else
          stage = evaluate(trained_program, rows.selection)
          Atomic.write!(Path.join(paths.output, "03-trained-selection.json"), stage)
          stage
        end

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
        treatment_id: @treatment_id,
        scope: "one task/model #{train_steps()}-step ordinary model-generated local GRPO result",
        model: @model,
        adapter: "Elixir.Imp.Adapter.JSON",
        training_generation_mode: "sample",
        evaluation_generation_mode: "greedy",
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
        artifact_sha256: manifest["payload_sha256"],
        selected_validation_step: job.metadata.selected_validation_step,
        selected_validation_score: job.metadata.selected_validation_score,
        validation_history: job.metadata.validation_history,
        trainer_config: %{
          learning_rate: 1.0e-6,
          beta: 0.0,
          loss_type: "dapo",
          scale_rewards: "group"
        }
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

    unless fresh_test["selected_arm"] == selection["selected_arm"],
      do: raise("fresh process reproduced a different selected arm")

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
      Atomic.write!(Path.join(paths.output, "failure.json"), %{
        status: "stopped",
        error: Exception.format(:error, error, __STACKTRACE__)
      })

      reraise error, __STACKTRACE__
  end

  defp train!(paths, rows, trainer) do
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
        train_kwargs: [
          learning_rate: 1.0e-6,
          beta: 0.0,
          loss_type: :dapo,
          scale_rewards: :group
        ],
        checkpoint_selection: :best_validation,
        num_steps_for_val: 1,
        status_poll_interval_ms: 0,
        callback_timeout_ms: 900_000,
        timeout: 120_000,
        checkpoint_path: Path.join(paths.output, "grpo-checkpoint.bin")
      )

    {:ok, result} =
      Imp.train(program(training_lm), optimizer, examples(rows.train),
        validation: examples(rows.selection)
      )

    job = result.job
    {:ok, manifest} = TRLArtifact.verify_job(job)
    step_artifacts = step_artifacts(job)
    final_step = List.last(step_artifacts)

    training_stage = %{
      status: "complete",
      job: encode_job(job),
      artifact_payload_sha256: manifest["payload_sha256"],
      observation: final_step.observation,
      steps: step_artifacts,
      group: final_step.update["groups"],
      selected_train_row_ids:
        Enum.flat_map(step_artifacts, &selected_train_row_ids(&1.update, rows.train))
    }

    Atomic.write!(Path.join(paths.output, "02-training.json"), training_stage)
    {job, manifest, step_artifacts}
  end

  defp restore_completed_training!(paths, rows) do
    stage = read_json!(Path.join(paths.output, "02-training.json"))
    state = Map.fetch!(stage, "job")
    Code.ensure_loaded!(Imp.Optimizer.GRPO)

    unless state["provider"] == "trl" and state["status"] == "succeeded" and
             state["model"] == @model,
           do: raise("retained completed GRPO job identity drift")

    job =
      TrainingJob.new(%{
        id: Map.fetch!(state, "id"),
        provider: :trl,
        model: @model,
        status: :succeeded,
        result_model: Map.fetch!(state, "result_model"),
        metadata: state["metadata"] |> Imp.Optimizer.Report.decode_term()
      })

    {:ok, manifest} = TRLArtifact.verify_job(job)

    unless manifest["payload_sha256"] == stage["artifact_payload_sha256"],
      do: raise("retained completed GRPO artifact drift")

    step_artifacts = step_artifacts(job)

    selected_ids =
      Enum.flat_map(step_artifacts, &selected_train_row_ids(&1.update, rows.train))

    unless selected_ids == stage["selected_train_row_ids"],
      do: raise("retained GRPO source schedule drift")

    {job, manifest, step_artifacts}
  end

  defp step_artifacts(job) do
    Enum.map(1..train_steps(), fn step ->
      path = job.result_model |> Path.dirname() |> Path.join("step-#{step}")

      %{
        step: step,
        path: path,
        observation: path |> Path.join("trl-observation.json") |> read_json!(),
        update: path |> Path.join("update-#{step}.json") |> read_json!()
      }
    end)
  end

  defp fresh do
    paths = paths!()
    rows = preflight!(paths, :verify)
    job = TrainingJob.load!(paths.job)
    portable = Imp.read!(paths.program)
    trainer = trainer(paths, {:local_grpo_banking77_fresh, @seed})
    selection = read_json!(Path.join(paths.output, "04-selection.json"))
    selected_arm = selection["selected_arm"]

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

  defp preflight!(paths, mode) when mode in [:write, :verify] do
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
      treatment_id: @treatment_id,
      model: @model,
      runner_sha256: sha256_file(__ENV__.file),
      contract_sha256: sha256_file(paths.contract),
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

    case mode do
      :write -> Atomic.write!(Path.join(paths.output, "00-preflight.json"), stage)
      :verify -> verify_retained_preflight!(paths, stage)
    end

    %{train: train, selection: selection, test: test}
  end

  defp verify_retained_preflight!(paths, current) do
    retained = read_json!(Path.join(paths.output, "00-preflight.json"))
    retained_runner = Map.fetch!(retained, "runner_sha256")
    current_runner = current.runner_sha256

    unless retained_runner in [current_runner, @pre_framing_fix_runner_sha256],
      do: raise("retained GRPO runner identity is not an approved predecessor")

    retained_identity = Map.delete(retained, "runner_sha256")
    current_identity = current |> stringify_keys() |> Map.delete("runner_sha256")

    unless retained_identity == current_identity,
      do: raise("retained GRPO preflight identity drift")
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
      adapter: Imp.Adapter.JSON,
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
      ["run", "--no-compile", "--no-deps-check", "research/local_grpo_banking77/run.exs"],
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
        "/Users/deepfates/.cache/imp/trl/#{@treatment_id}"
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
          Path.join(repo, "priv/trl_worker/qwen-ten-step-contract.json")
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

  defp load_evaluation_stage!(path) do
    stage = read_json!(path)

    %{
      status: Map.fetch!(stage, "status"),
      rows:
        Enum.map(Map.fetch!(stage, "rows"), fn row ->
          %{
            id: Map.fetch!(row, "id"),
            expected: Map.fetch!(row, "expected"),
            actual: Map.get(row, "actual"),
            error: Map.get(row, "error")
          }
        end),
      accuracy: Map.fetch!(stage, "accuracy"),
      macro_f1: Map.fetch!(stage, "macro_f1"),
      errors: Map.fetch!(stage, "errors"),
      reproduction_sha256: Map.fetch!(stage, "reproduction_sha256")
    }
  end

  defp require_new_output!(path) do
    case File.ls(path) do
      {:error, :enoent} -> :ok
      {:ok, []} -> :ok
      {:ok, _entries} -> raise("IMP_GRPO_OUTPUT must be a new empty directory")
      {:error, reason} -> raise("cannot inspect IMP_GRPO_OUTPUT: #{inspect(reason)}")
    end
  end

  defp require_resume_output!(paths) do
    required = [
      Path.join(paths.output, "00-preflight.json"),
      Path.join(paths.output, "01-base-selection.json"),
      Path.join(paths.output, "grpo-checkpoint.bin")
    ]

    training_complete? =
      File.regular?(Path.join(paths.output, "02-training.json")) and
        File.regular?(Path.join(paths.output, "03-trained-selection.json"))

    unless Enum.all?(Enum.take(required, 2), &File.regular?/1) and
             (File.regular?(List.last(required)) or training_complete?),
           do:
             raise(
               "IMP_GRPO_RESUME requires retained preflight/base plus a checkpoint or completed training stages"
             )

    if File.regular?(Path.join(paths.output, "result.json")),
      do: raise("completed GRPO output cannot be resumed")
  end

  defp train_steps, do: positive_env!("IMP_GRPO_TRAIN_STEPS", 10)
  defp train_width, do: positive_env!("IMP_GRPO_TRAIN_WIDTH", 4)

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

  defp stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value
end

unless System.get_env("IMP_GRPO_DEFINE_ONLY") == "1", do: LocalGRPOBanking77.Runner.run()
