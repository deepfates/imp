defmodule LocalRandomSearchBanking77.Atomic do
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

defmodule LocalRandomSearchBanking77.Metric do
  def exact_route(example, prediction) do
    Imp.Example.get(example, :route) == Imp.Prediction.get(prediction, :route)
  end
end

defmodule LocalRandomSearchBanking77.Observer do
  def start_link, do: Agent.start_link(fn -> %{phase: "startup", calls: [], transports: []} end)
  def phase(pid, phase), do: Agent.update(pid, &%{&1 | phase: phase})

  def call(pid, messages) do
    Agent.update(pid, fn state ->
      %{state | calls: [%{phase: state.phase, messages: messages} | state.calls]}
    end)
  end

  def transport(pid) do
    Agent.update(pid, fn state -> %{state | transports: [state.phase | state.transports]} end)
  end

  def snapshot(pid) do
    Agent.get(pid, fn state ->
      %{state | calls: Enum.reverse(state.calls), transports: Enum.reverse(state.transports)}
    end)
  end
end

defmodule LocalRandomSearchBanking77.ObservedLM do
  defstruct [:inner, :observer]

  def generate(lm, messages, opts) do
    LocalRandomSearchBanking77.Observer.call(lm.observer, messages)
    Imp.LM.generate(lm.inner, messages, opts)
  end

  def response_format_capability(%__MODULE__{inner: inner}),
    do: Imp.LM.response_format_capability(inner)
end

defmodule LocalRandomSearchBanking77.Runner do
  alias Imp.Clients.{MLXLMDeployment, MLXLMTrainer, TrainingJob}
  alias Imp.Optimizer.{BootstrapFewShotWithRandomSearch, Report}
  alias LocalRandomSearchBanking77.{Atomic, Metric, ObservedLM, Observer}

  @routes ["R17", "R42", "R68", "R93"]
  @data_sha256 "1703f59bf336df8dc35590275531b67bb6ee43a5d0c96eb44696c219af5cfc18"
  @teacher_model "llama3.2:3b"
  @teacher_digest "a80c4f17acd55265feec403c7aef86be0c25983ab279d83f3bcd3abbcb5b8b72"
  @run_id "local-random-search-banking77-v1"

  def run, do: if(System.get_env("IMP_RANDOM_SEARCH_FRESH") == "1", do: fresh(), else: parent())

  defp parent do
    paths = paths!()
    require_new_output!(paths.output)
    run_parent(paths)
  end

  defp run_parent(paths) do
    {job, rows} = preflight!(paths, true)
    transport_observer = observer!()
    {:ok, teacher_observer} = Observer.start_link()

    try do
      {source, runtime_lm} = program!(job, transport_observer)
      teacher = teacher!(teacher_observer)
      before_task = Observer.snapshot(transport_observer)
      before_teacher = Observer.snapshot(teacher_observer)
      Observer.phase(transport_observer, "optimization")

      compiled =
        BootstrapFewShotWithRandomSearch.new(&Metric.exact_route/2,
          num_candidate_programs: 1,
          max_bootstrapped_demos: 2,
          max_labeled_demos: 2,
          max_rounds: 1,
          num_threads: 1,
          max_errors: :infinity
        )
        |> then(
          &Imp.optimize!(source, &1, examples(rows.train), examples(rows.selection),
            teacher: teacher
          )
        )

      report = Report.fetch(compiled)
      after_task = Observer.snapshot(transport_observer)
      after_teacher = Observer.snapshot(teacher_observer)

      optimization =
        optimization_stage(report, before_task, after_task, before_teacher, after_teacher)

      Atomic.write!(Path.join(paths.output, "01-optimization.json"), optimization)
      require_real_bootstrap!(optimization)

      selected_test = evaluate(compiled, rows.test, transport_observer, "selected_test")
      Atomic.write!(Path.join(paths.output, "02-selected-test.json"), selected_test)
      require_transports!(selected_test, 40)

      portable = Imp.with_lm(compiled, runtime_lm)
      :ok = TrainingJob.save!(job, paths.saved_job)
      :ok = Imp.save!(portable, paths.saved_program, registry: registry())
      Atomic.write!(Path.join(paths.output, "03-saved.json"), %{status: "complete"})
      :ok = MLXLMDeployment.stop(job)

      fresh_path = Path.join(paths.output, "04-fresh-test.json")
      {output, status} = fresh_process(paths, fresh_path)
      if status != 0, do: raise("fresh OS BEAM failed: #{output}")
      fresh = read_json!(fresh_path)

      unless fresh["reproduction_sha256"] == selected_test.reproduction_sha256,
        do: raise("fresh selected predictions/errors differ")

      unless fresh["artifact_identity"] == job.result_model,
        do: raise("fresh process served a different trained artifact")

      result = %{
        status: "complete",
        run_id: @run_id,
        artifact_identity: job.result_model,
        teacher_model: @teacher_model,
        split_sizes: %{train: 16, selection: 8, frozen_test: 40},
        candidate_scores: optimization.candidate_scores,
        selected_seed: optimization.selected_seed,
        selected_kind: optimization.selected_kind,
        accepted_augmented_demos: optimization.accepted_augmented_demos,
        augmented_demo_rendered_calls: optimization.augmented_demo_rendered_calls,
        optimization_calls: %{
          task: optimization.task_calls,
          teacher: optimization.teacher_calls,
          transports: optimization.transport_attempts
        },
        selected_test: metrics(selected_test),
        fresh_byte_identical: true,
        claim_boundary:
          "One retained-model/task BootstrapFewShotWithRandomSearch lifecycle with real local teacher bootstrap; not general effectiveness, exact RNG parity, reliability, or BEAM superiority."
      }

      Atomic.write!(Path.join(paths.output, "result.json"), result)
      IO.puts(Jason.encode!(result, pretty: true))
    after
      MLXLMDeployment.stop(job)
      :telemetry.detach({__MODULE__, self()})
    end
  rescue
    error ->
      Atomic.write!(Path.join(paths.output, "failure.json"), %{
        status: "stopped",
        error: Exception.format(:error, error, __STACKTRACE__)
      })

      reraise error, __STACKTRACE__
  end

  defp fresh do
    paths = paths!()
    {job, rows} = preflight!(paths, false)
    selected = Imp.read!(paths.saved_program, registry: registry())
    {:ok, rebound} = TrainingJob.rebind(job, selected)
    observer = observer!()

    observed =
      Imp.with_lm(rebound, %ObservedLM{inner: program_lm(rebound), observer: observer})

    try do
      stage = evaluate(observed, rows.test, observer, "fresh_test")
      require_transports!(stage, 40)

      Atomic.write!(System.fetch_env!("IMP_RANDOM_SEARCH_FRESH_OUTPUT"), %{
        status: "complete",
        rows: stage.rows,
        accuracy: stage.accuracy,
        macro_f1: stage.macro_f1,
        errors: stage.errors,
        logical_calls: stage.logical_calls,
        transport_attempts: stage.transport_attempts,
        reproduction_sha256: stage.reproduction_sha256,
        artifact_identity: job.result_model
      })
    after
      MLXLMDeployment.stop(job)
      :telemetry.detach({__MODULE__, self()})
    end
  end

  defp preflight!(paths, persist?) do
    unless sha256_file(paths.data) == @data_sha256, do: raise("Banking77 data digest drift")
    verify_teacher!()
    job = TrainingJob.read!(paths.job)
    {:ok, _manifest} = MLXLMTrainer.verify_job(job)
    rows = split_rows!(paths.data)

    if persist? do
      Atomic.write!(Path.join(paths.output, "00-preflight.json"), %{
        status: "complete",
        run_id: @run_id,
        data_sha256: @data_sha256,
        artifact_identity: job.result_model,
        artifact_sha256: job.metadata[:artifact_sha256],
        teacher_model: @teacher_model,
        teacher_digest: @teacher_digest,
        train_ids: Enum.map(rows.train, & &1["id"]),
        selection_ids: Enum.map(rows.selection, & &1["id"]),
        test_ids: Enum.map(rows.test, & &1["id"])
      })
    end

    {job, rows}
  end

  defp program!(job, observer) do
    source =
      Imp.predict(signature(),
        lm:
          Imp.req_llm(job.result_model,
            cache: false,
            temperature: 0,
            max_tokens: 64,
            max_retries: 0,
            req_http_options: [retry: false, max_retries: 0]
          ),
        adapter: Imp.Adapter.Chat,
        config: [json_fallback: false]
      )

    {:ok, rebound} = TrainingJob.rebind(job, source)
    runtime_lm = program_lm(rebound)
    {Imp.with_lm(rebound, %ObservedLM{inner: runtime_lm, observer: observer}), runtime_lm}
  end

  defp teacher!(observer) do
    lm =
      Imp.req_llm("ollama:" <> @teacher_model,
        cache: false,
        temperature: 0,
        max_tokens: 64,
        max_retries: 0,
        timeout: 120_000,
        req_http_options: [retry: false, max_retries: 0]
      )

    Imp.predict(signature(),
      lm: %ObservedLM{inner: lm, observer: observer},
      adapter: Imp.Adapter.Chat,
      config: [json_fallback: false]
    )
  end

  defp signature do
    Imp.signature(
      "utterance -> route: enum[R17,R42,R68,R93]",
      "Choose exactly one opaque route code for the customer utterance."
    )
  end

  defp optimization_stage(report, before_task, after_task, before_teacher, after_teacher) do
    task_calls = Enum.drop(after_task.calls, length(before_task.calls))
    teacher_calls = Enum.drop(after_teacher.calls, length(before_teacher.calls))
    transports = Enum.drop(after_task.transports, length(before_task.transports))
    augmented = augmented_demos(report)
    selected = hd(report.candidates)

    %{
      status: "complete",
      candidate_count: report.candidate_count,
      candidate_seeds: report.metadata.candidate_seeds,
      candidate_scores: Enum.map(report.candidates, &Map.take(&1, [:seed, :kind, :score])),
      selected_seed: selected.seed,
      selected_kind: selected.kind,
      accepted_augmented_demos: length(augmented),
      augmented_demo_ids: Enum.map(augmented, &demo_identity/1),
      augmented_demo_rendered_calls:
        Enum.count(task_calls, &renders_any?(&1.messages, augmented)),
      task_calls: length(task_calls),
      teacher_calls: length(teacher_calls),
      transport_attempts: length(transports),
      errors: Report.json_safe(report.errors),
      candidates: Report.json_safe(report.candidates)
    }
  end

  defp augmented_demos(report) do
    report.candidates
    |> Enum.flat_map(fn candidate -> candidate.demos |> Map.values() |> List.flatten() end)
    |> Enum.filter(&(Imp.Example.get(&1, :augmented) == true))
    |> Enum.uniq_by(&demo_identity/1)
  end

  defp demo_identity(demo),
    do: %{utterance: Imp.Example.get(demo, :utterance), route: Imp.Example.get(demo, :route)}

  defp renders_any?(messages, demos) do
    rendered = Jason.encode!(messages)

    Enum.any?(demos, fn demo ->
      String.contains?(rendered, Imp.Example.get(demo, :utterance)) and
        String.contains?(rendered, Imp.Example.get(demo, :route))
    end)
  end

  defp require_real_bootstrap!(stage) do
    unless stage.candidate_count == 4 and stage.candidate_seeds == [-3, -2, -1, 0] and
             stage.accepted_augmented_demos > 0 and stage.augmented_demo_rendered_calls > 0 and
             stage.teacher_calls > 0 and stage.task_calls == 32 and
             stage.transport_attempts == stage.task_calls + stage.teacher_calls,
           do: raise("BootstrapFewShotWithRandomSearch did not exercise real rendered bootstrap: #{inspect(stage)}")
  end

  defp evaluate(program, rows, observer, phase) do
    before = Observer.snapshot(observer)
    Observer.phase(observer, phase)
    stage = evaluate_unobserved(program, rows)
    after_snapshot = Observer.snapshot(observer)

    Map.merge(stage, %{
      phase: phase,
      logical_calls: length(after_snapshot.calls) - length(before.calls),
      transport_attempts: length(after_snapshot.transports) - length(before.transports)
    })
  end

  defp evaluate_unobserved(program, rows) do
    results =
      Enum.map(rows, fn row ->
        case Imp.call(program, %{utterance: row["utterance"]}) do
          {:ok, prediction} ->
            %{
              id: row["id"],
              expected: row["route"],
              actual: Imp.Prediction.get(prediction, :route),
              error: nil
            }

          {:error, reason} ->
            %{id: row["id"], expected: row["route"], actual: nil, error: inspect(reason)}
        end
      end)

    %{
      status: "complete",
      rows: results,
      accuracy: Enum.count(results, &(&1.actual == &1.expected)) / length(results),
      macro_f1: macro_f1(results),
      errors: Enum.count(results, &(not is_nil(&1.error))),
      reproduction_sha256: sha256_term(Enum.map(results, &Map.take(&1, [:id, :actual, :error])))
    }
  end

  defp require_transports!(stage, expected) do
    unless stage.logical_calls == expected and stage.transport_attempts == expected,
      do: raise("#{stage.phase} did not make exactly #{expected} single-attempt transports")
  end

  defp examples(rows) do
    Enum.map(rows, fn row ->
      Imp.Example.new(%{utterance: row["utterance"], route: row["route"]})
      |> Imp.Example.with_inputs([:utterance])
    end)
  end

  defp split_rows!(path) do
    data = read_json!(path)
    grouped = Enum.group_by(data["train"], & &1["route"])
    train = Enum.flat_map(@routes, &(grouped[&1] |> Enum.take(4)))
    selection = Enum.flat_map(@routes, &(grouped[&1] |> Enum.slice(4, 2)))
    test = data["held_out"]
    ids = Enum.map(train ++ selection ++ test, & &1["id"])
    if length(ids) != 64 or length(Enum.uniq(ids)) != 64, do: raise("split overlap or drift")
    %{train: train, selection: selection, test: test}
  end

  defp macro_f1(rows) do
    @routes
    |> Enum.map(fn route ->
      tp = Enum.count(rows, &(&1.expected == route and &1.actual == route))
      fp = Enum.count(rows, &(&1.expected != route and &1.actual == route))
      misses = Enum.count(rows, &(&1.expected == route and &1.actual != route))
      denominator = 2 * tp + fp + misses
      if denominator == 0, do: 0.0, else: 2 * tp / denominator
    end)
    |> then(&(Enum.sum(&1) / length(&1)))
  end

  defp verify_teacher! do
    {output, 0} = System.cmd("ollama", ["list"], stderr_to_stdout: true)

    unless String.contains?(output, @teacher_model) and
             String.contains?(output, String.slice(@teacher_digest, 0, 12)),
           do: raise("pinned local teacher is unavailable or its digest drifted")
  end

  defp observer! do
    {:ok, observer} = Observer.start_link()

    :ok =
      :telemetry.attach(
        {__MODULE__, self()},
        [:imp, :lm, :transport, :attempt],
        fn _event, _measurements, _metadata, target -> Observer.transport(target) end,
        observer
      )

    observer
  end

  defp registry, do: Imp.Saving.Registry.new(route_metric: &Metric.exact_route/2)

  defp fresh_process(paths, output_path) do
    System.cmd("mix", ["run", "--no-compile", "--no-deps-check", __ENV__.file],
      cd: paths.imp,
      env: [
        {"MIX_ENV", "dev"},
        {"IMP_RANDOM_SEARCH_FRESH", "1"},
        {"IMP_RANDOM_SEARCH_OUTPUT", paths.output},
        {"IMP_RANDOM_SEARCH_FRESH_OUTPUT", output_path},
        {"IMP_MLX_JOB", paths.saved_job},
        {"IMP_BANKING77_DATA", paths.data}
      ],
      stderr_to_stdout: true
    )
  end

  defp paths! do
    imp = Path.expand("../..", __DIR__)
    output = System.get_env("IMP_RANDOM_SEARCH_OUTPUT", "/tmp/#{@run_id}") |> Path.expand()

    %{
      imp: imp,
      output: output,
      job: System.fetch_env!("IMP_MLX_JOB") |> Path.expand(),
      data:
        System.get_env(
          "IMP_BANKING77_DATA",
          Path.join(imp, "benchmarks/data/provider-training-banking77-v1.json")
        )
        |> Path.expand(),
      saved_job: Path.join(output, "training-job.json"),
      saved_program: Path.join(output, "selected-program.json")
    }
  end

  defp require_new_output!(path) do
    case File.ls(path) do
      {:error, :enoent} -> :ok
      {:ok, []} -> :ok
      {:ok, _} -> raise("IMP_RANDOM_SEARCH_OUTPUT must be a new empty directory")
      {:error, reason} -> raise("cannot inspect IMP_RANDOM_SEARCH_OUTPUT: #{inspect(reason)}")
    end
  end

  defp metrics(stage), do: Map.take(stage, [:accuracy, :macro_f1, :errors])
  defp read_json!(path), do: path |> File.read!() |> Jason.decode!()
  defp sha256_file(path), do: path |> File.read!() |> sha256()
  defp sha256_term(term), do: term |> Jason.encode!() |> sha256()
  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  # The LM of the program's first predictor, through the public parameter view.
  defp program_lm(program),
    do: program |> Imp.ProgramParameters.predictors() |> hd() |> then(& &1.predictor.lm)
end

unless System.get_env("IMP_RANDOM_SEARCH_DEFINE_ONLY") == "1",
  do: LocalRandomSearchBanking77.Runner.run()
