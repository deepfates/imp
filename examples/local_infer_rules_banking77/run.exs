defmodule LocalInferRulesBanking77.Atomic do
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

defmodule LocalInferRulesBanking77.Metric do
  def exact_route(example, prediction) do
    Imp.Example.get(example, :route) == Imp.Prediction.get(prediction, :route)
  end
end

defmodule LocalInferRulesBanking77.Observer do
  def start_link, do: Agent.start_link(fn -> %{phase: "startup", calls: [], transports: []} end)
  def phase(pid, phase), do: Agent.update(pid, &%{&1 | phase: phase})

  def call(pid, role, messages) do
    Agent.update(pid, fn state ->
      entry = %{phase: state.phase, role: role, messages: messages}
      %{state | calls: [entry | state.calls]}
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

defmodule LocalInferRulesBanking77.ObservedLM do
  defstruct [:inner, :observer, :role]

  def generate(lm, messages, opts) do
    LocalInferRulesBanking77.Observer.call(lm.observer, lm.role, messages)
    Imp.LM.generate(lm.inner, messages, opts)
  end

  def response_format_capability(%__MODULE__{inner: inner}),
    do: Imp.LM.response_format_capability(inner)
end

defmodule LocalInferRulesBanking77.Runner do
  alias Imp.Clients.{MLXLMDeployment, MLXLMTrainer, TrainingJob}
  alias Imp.Optimizer.{InferRules, Report}
  alias LocalInferRulesBanking77.{Atomic, Metric, ObservedLM, Observer}

  @routes ["R17", "R42", "R68", "R93"]
  @data_sha256 "1703f59bf336df8dc35590275531b67bb6ee43a5d0c96eb44696c219af5cfc18"
  @rule_model "llama3.2:3b"
  @rule_digest "a80c4f17acd55265feec403c7aef86be0c25983ab279d83f3bcd3abbcb5b8b72"
  @run_id "local-infer-rules-banking77-v2-source-protected"

  def run, do: if(System.get_env("IMP_INFER_FRESH") == "1", do: fresh(), else: parent())

  defp parent do
    paths = paths!()
    require_new_output!(paths.output)
    run_parent(paths)
  end

  defp run_parent(paths) do
    {job, rows} = preflight!(paths, true)
    observer = observer!()

    try do
      {source, runtime_lm} = program!(job, observer)
      source_selection = evaluate(source, rows.selection, observer, "source_selection")
      Atomic.write!(Path.join(paths.output, "01-source-selection.json"), source_selection)
      require_transports!(source_selection, 8)

      Observer.phase(observer, "optimization")
      before = Observer.snapshot(observer)

      compiled =
        InferRules.new(&Metric.exact_route/2,
          rule_lm: observed(rule_lm(), observer, :rule),
          num_candidates: 1,
          num_rules: 6,
          num_threads: 1,
          max_bootstrapped_demos: 4,
          max_labeled_demos: 0,
          max_rounds: 1,
          max_errors: :infinity,
          timeout: 120_000
        )
        |> then(&Imp.optimize!(source, &1, examples(rows.train), examples(rows.selection)))

      report = Report.fetch(compiled)
      after_optimization = Observer.snapshot(observer)
      optimization = optimization_stage(report, before, after_optimization, source, compiled)
      Atomic.write!(Path.join(paths.output, "02-optimization.json"), optimization)
      require_optimization!(optimization)

      compiled_selection =
        evaluate(compiled, rows.selection, observer, "compiled_selection")

      Atomic.write!(Path.join(paths.output, "03-compiled-selection.json"), compiled_selection)
      require_transports!(compiled_selection, 8)
      require_instruction_use!(compiled_selection, compiled)

      source_test = evaluate(source, rows.test, observer, "source_test")
      Atomic.write!(Path.join(paths.output, "04-source-test.json"), source_test)
      require_transports!(source_test, 40)

      compiled_test = evaluate(compiled, rows.test, observer, "compiled_test")
      Atomic.write!(Path.join(paths.output, "05-compiled-test.json"), compiled_test)
      require_transports!(compiled_test, 40)
      require_instruction_use!(compiled_test, compiled)

      portable = Imp.with_lm(compiled, runtime_lm)
      :ok = TrainingJob.save!(job, paths.saved_job)
      :ok = Imp.save!(portable, paths.saved_program)
      Atomic.write!(Path.join(paths.output, "06-saved.json"), %{status: "complete"})
      :ok = MLXLMDeployment.stop(job)

      fresh_path = Path.join(paths.output, "07-fresh-test.json")
      {output, status} = fresh_process(paths, fresh_path)
      if status != 0, do: raise("fresh OS BEAM failed: #{output}")
      fresh = read_json!(fresh_path)

      unless fresh["reproduction_sha256"] == compiled_test.reproduction_sha256,
        do: raise("fresh compiled predictions/errors differ")

      unless fresh["artifact_identity"] == job.result_model,
        do: raise("fresh process served a different trained artifact")

      result = %{
        status: "complete",
        run_id: @run_id,
        artifact_identity: job.result_model,
        proposal_calls: report.metadata.proposal_calls,
        proposal_attempts: report.metadata.proposal_attempts,
        candidate_count: report.candidate_count,
        selected_instruction: compiled.signature.instructions,
        selection: %{source: metrics(source_selection), compiled: metrics(compiled_selection)},
        untouched_test: %{source: metrics(source_test), compiled: metrics(compiled_test)},
        fresh_byte_identical: true,
        claim_boundary:
          "One retained-model/task InferRules lifecycle; not whole-loop equivalence, general effectiveness, reliability, or BEAM superiority."
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
    selected = Imp.read!(paths.saved_program)
    {:ok, rebound} = TrainingJob.rebind(job, selected)
    observer = observer!()
    observed = Imp.with_lm(rebound, observed(rebound.lm, observer, :task))

    try do
      stage = evaluate(observed, rows.test, observer, "fresh_test")
      require_transports!(stage, 40)
      require_instruction_use!(stage, observed)

      Atomic.write!(System.fetch_env!("IMP_INFER_FRESH_OUTPUT"), %{
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
    verify_rule_model!()
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
        rule_model: @rule_model,
        rule_model_digest: @rule_digest,
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
    runtime_lm = rebound.lm
    {Imp.with_lm(rebound, observed(runtime_lm, observer, :task)), runtime_lm}
  end

  defp rule_lm do
    Imp.req_llm("ollama:" <> @rule_model,
      cache: false,
      temperature: 0,
      max_tokens: 512,
      max_retries: 0,
      timeout: 120_000,
      req_http_options: [retry: false, max_retries: 0]
    )
  end

  defp observed(inner, observer, role),
    do: %ObservedLM{inner: inner, observer: observer, role: role}

  defp optimization_stage(report, before, after_snapshot, source, compiled) do
    calls = Enum.drop(after_snapshot.calls, length(before.calls))
    transports = Enum.drop(after_snapshot.transports, length(before.transports))

    induced_rule_candidates =
      Enum.count(report.candidates, fn candidate ->
        candidate[:baseline] == false and candidate[:status] in [:ok, :with_errors] and
          is_map(candidate[:rules]) and map_size(candidate[:rules]) > 0
      end)

    %{
      status: "complete",
      candidate_count: report.candidate_count,
      best_score: report.best_score,
      proposal_calls: report.metadata.proposal_calls,
      proposal_attempts: report.metadata.proposal_attempts,
      induced_rule_candidates: induced_rule_candidates,
      errors: Report.json_safe(report.errors),
      candidates: Report.json_safe(report.candidates),
      source_instruction: source.signature.instructions,
      selected_instruction: compiled.signature.instructions,
      task_calls: Enum.count(calls, &(&1.role == :task)),
      rule_calls: Enum.count(calls, &(&1.role == :rule)),
      transport_attempts: length(transports)
    }
  end

  defp require_optimization!(stage) do
    unless stage.candidate_count == 3 and stage.proposal_calls == 1 and stage.rule_calls == 1 and
             stage.proposal_attempts == 1 and stage.transport_attempts == stage.task_calls + 1 and
             stage.induced_rule_candidates == 1,
           do: raise("InferRules did not complete one real rule candidate: #{inspect(stage)}")
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
      rendered_instruction_count:
        Enum.count(
          calls,
          &Imp.Adapter.Instructions.rendered_objective?(
            program.signature.instructions,
            &1.messages
          )
        )
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

  defp require_instruction_use!(stage, _program) do
    unless stage.rendered_instruction_count == length(stage.rows),
      do: raise("#{stage.phase} did not render the selected instruction on every row")
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

  defp verify_rule_model! do
    models = Req.get!("http://127.0.0.1:11434/api/tags", retry: false).body["models"]

    unless Enum.any?(models, &(&1["name"] == @rule_model and &1["digest"] == @rule_digest)),
      do: raise("pinned local rule model is absent or changed")
  end

  defp fresh_process(paths, output_path) do
    System.cmd("mix", ["run", "--no-compile", "--no-deps-check", __ENV__.file],
      cd: paths.imp,
      env: [
        {"MIX_ENV", "dev"},
        {"IMP_INFER_FRESH", "1"},
        {"IMP_INFER_OUTPUT", paths.output},
        {"IMP_INFER_FRESH_OUTPUT", output_path},
        {"IMP_MLX_JOB", paths.saved_job},
        {"IMP_BANKING77_DATA", paths.data}
      ],
      stderr_to_stdout: true
    )
  end

  defp paths! do
    imp = Path.expand("../..", __DIR__)
    output = System.get_env("IMP_INFER_OUTPUT", "/tmp/#{@run_id}") |> Path.expand()

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
      {:ok, _} -> raise("IMP_INFER_OUTPUT must be a new empty directory")
      {:error, reason} -> raise("cannot inspect IMP_INFER_OUTPUT: #{inspect(reason)}")
    end
  end

  defp metrics(stage), do: Map.take(stage, [:accuracy, :macro_f1, :errors])
  defp read_json!(path), do: path |> File.read!() |> Jason.decode!()
  defp sha256_file(path), do: path |> File.read!() |> sha256()
  defp sha256_term(term), do: term |> Jason.encode!() |> sha256()
  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end

unless System.get_env("IMP_INFER_DEFINE_ONLY") == "1",
  do: LocalInferRulesBanking77.Runner.run()
