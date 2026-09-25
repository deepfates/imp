defmodule LocalKNNFewShotBanking77.Atomic do
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

defmodule LocalKNNFewShotBanking77.Metric do
  def exact_route(example, prediction) do
    Imp.Example.get(example, :route) == Imp.Prediction.get(prediction, :route)
  end
end

defmodule LocalKNNFewShotBanking77.Observer do
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

defmodule LocalKNNFewShotBanking77.ObservedLM do
  defstruct [:inner, :observer]

  def generate(lm, messages, opts) do
    LocalKNNFewShotBanking77.Observer.call(lm.observer, messages)
    Imp.LM.generate(lm.inner, messages, opts)
  end

  def response_format_capability(%__MODULE__{inner: inner}),
    do: Imp.LM.response_format_capability(inner)
end

defmodule LocalKNNFewShotBanking77.Runner do
  alias Imp.Clients.{MLXLMDeployment, MLXLMTrainer, TrainingJob}
  alias LocalKNNFewShotBanking77.{Atomic, Metric, ObservedLM, Observer}

  @routes ["R17", "R42", "R68", "R93"]
  @data_sha256 "1703f59bf336df8dc35590275531b67bb6ee43a5d0c96eb44696c219af5cfc18"
  @run_id "local-knn-few-shot-banking77-v1"

  def run, do: if(System.get_env("IMP_KNN_FRESH") == "1", do: fresh(), else: parent())

  defp parent do
    paths = paths!()
    require_new_output!(paths.output)
    run_parent(paths)
  end

  defp run_parent(paths) do
    {job, rows} = preflight!(paths, true)
    observer = observer!()

    try do
      {baseline, runtime_lm} = program!(job, observer)
      trainset = examples(rows.train)

      knn =
        Imp.Optimizer.KNNFewShot.new(1, trainset,
          vectorizer: Imp.Embeddings.BagOfWords,
          few_shot_bootstrap_args: [
            metric: &Metric.exact_route/2,
            max_bootstrapped_demos: 1,
            max_labeled_demos: 0,
            max_rounds: 1,
            max_errors: :infinity,
            timeout: 120_000
          ]
        )
        |> Imp.Optimizer.KNNFewShot.compile(baseline, teacher: baseline)

      baseline_selection = evaluate(baseline, rows.selection, observer, "baseline_selection")
      Atomic.write!(Path.join(paths.output, "01-baseline-selection.json"), baseline_selection)
      require_transports!(baseline_selection, 8)

      knn_selection = evaluate(knn, rows.selection, observer, "knn_selection")
      Atomic.write!(Path.join(paths.output, "02-knn-selection.json"), knn_selection)
      require_transports!(knn_selection, 16)
      require_demo_use!(knn_selection)

      selection = choose(baseline_selection, knn_selection)
      Atomic.write!(Path.join(paths.output, "03-selection.json"), selection)

      selected = if selection.selected_arm == "knn", do: knn, else: baseline
      selected_test = evaluate(selected, rows.test, observer, "selected_test")
      Atomic.write!(Path.join(paths.output, "04-selected-test.json"), selected_test)
      require_transports!(selected_test, if(selection.selected_arm == "knn", do: 80, else: 40))

      portable = Imp.with_lm(selected, runtime_lm)
      registry = registry()
      :ok = TrainingJob.save!(job, paths.saved_job)
      :ok = Imp.save!(portable, paths.saved_program, registry: registry)
      Atomic.write!(Path.join(paths.output, "05-saved.json"), %{status: "complete"})
      :ok = MLXLMDeployment.stop(job)

      fresh_path = Path.join(paths.output, "06-fresh-test.json")
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
        selection: %{
          baseline: metrics(baseline_selection),
          knn: metrics(knn_selection),
          selected_arm: selection.selected_arm
        },
        selected_test: metrics(selected_test),
        selection_demo_rendered_calls: knn_selection.demo_rendered_calls,
        fresh_byte_identical: true,
        claim_boundary:
          "One retained-model/task KNNFewShot lifecycle; not general effectiveness, parity, reliability, or BEAM superiority."
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
    selected = Imp.load!(paths.saved_program, registry: registry())
    {:ok, rebound} = TrainingJob.rebind(job, selected)
    observer = observer!()

    observed =
      Imp.with_lm(rebound, %ObservedLM{inner: Imp.ProgramAccess.lm(rebound), observer: observer})

    selection = read_json!(Path.join(paths.output, "03-selection.json"))
    expected = if selection["selected_arm"] == "knn", do: 80, else: 40

    try do
      stage = evaluate(observed, rows.test, observer, "fresh_test")
      require_transports!(stage, expected)

      Atomic.write!(System.fetch_env!("IMP_KNN_FRESH_OUTPUT"), %{
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
    job = TrainingJob.load!(paths.job)
    {:ok, _manifest} = MLXLMTrainer.verify_job(job)
    rows = split_rows!(paths.data)

    if persist? do
      Atomic.write!(Path.join(paths.output, "00-preflight.json"), %{
        status: "complete",
        run_id: @run_id,
        data_sha256: @data_sha256,
        artifact_identity: job.result_model,
        artifact_sha256: job.metadata[:artifact_sha256],
        train_ids: Enum.map(rows.train, & &1["id"]),
        selection_ids: Enum.map(rows.selection, & &1["id"]),
        test_ids: Enum.map(rows.test, & &1["id"])
      })
    end

    {job, rows}
  end

  defp program!(job, observer) do
    source =
      Imp.predict(
        Imp.signature(
          "utterance -> route: enum[R17,R42,R68,R93]",
          "Choose exactly one opaque route code for the customer utterance."
        ),
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
    runtime_lm = Imp.ProgramAccess.lm(rebound)
    observed = Imp.with_lm(rebound, %ObservedLM{inner: runtime_lm, observer: observer})
    {observed, runtime_lm}
  end

  defp evaluate(program, rows, observer, phase) do
    before = Observer.snapshot(observer)
    Observer.phase(observer, phase)
    stage = evaluate_unobserved(program, rows)
    after_snapshot = Observer.snapshot(observer)
    calls = Enum.drop(after_snapshot.calls, length(before.calls))
    transports = Enum.drop(after_snapshot.transports, length(before.transports))

    Map.merge(stage, %{
      phase: phase,
      logical_calls: length(calls),
      transport_attempts: length(transports),
      demo_rendered_calls: Enum.count(calls, &demo_rendered?(&1.messages))
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

  defp choose(base, knn) do
    if {knn.accuracy, knn.macro_f1} > {base.accuracy, base.macro_f1},
      do: %{selected_arm: "knn", rule: "accuracy_then_macro_f1_tie_keeps_base"},
      else: %{selected_arm: "base", rule: "accuracy_then_macro_f1_tie_keeps_base"}
  end

  defp require_transports!(stage, expected) do
    unless stage.logical_calls == expected and stage.transport_attempts == expected,
      do: raise("#{stage.phase} did not make exactly #{expected} single-attempt transports")
  end

  defp require_demo_use!(stage) do
    unless stage.demo_rendered_calls > 0,
      do: raise("KNNFewShot retrieved neighbors but rendered no bootstrapped demonstration")
  end

  defp demo_rendered?(messages) do
    Enum.any?(messages, fn message ->
      role = Map.get(message, :role, Map.get(message, "role"))
      role in [:assistant, "assistant"]
    end)
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
        {"IMP_KNN_FRESH", "1"},
        {"IMP_KNN_OUTPUT", paths.output},
        {"IMP_KNN_FRESH_OUTPUT", output_path},
        {"IMP_MLX_JOB", paths.saved_job},
        {"IMP_BANKING77_DATA", paths.data}
      ],
      stderr_to_stdout: true
    )
  end

  defp paths! do
    imp = Path.expand("../..", __DIR__)
    output = System.get_env("IMP_KNN_OUTPUT", "/tmp/#{@run_id}") |> Path.expand()

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
      {:ok, _} -> raise("IMP_KNN_OUTPUT must be a new empty directory")
      {:error, reason} -> raise("cannot inspect IMP_KNN_OUTPUT: #{inspect(reason)}")
    end
  end

  defp metrics(stage), do: Map.take(stage, [:accuracy, :macro_f1, :errors])
  defp read_json!(path), do: path |> File.read!() |> Jason.decode!()
  defp sha256_file(path), do: path |> File.read!() |> sha256()
  defp sha256_term(term), do: term |> Jason.encode!() |> sha256()
  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end

unless System.get_env("IMP_KNN_DEFINE_ONLY") == "1",
  do: LocalKNNFewShotBanking77.Runner.run()
