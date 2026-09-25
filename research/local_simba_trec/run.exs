defmodule LocalSIMBATREC.Atomic do
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

defmodule LocalSIMBATREC.Observer do
  def start_link, do: Agent.start_link(fn -> %{phase: "startup", calls: [], transports: []} end)
  def phase(pid, phase), do: Agent.update(pid, &%{&1 | phase: phase})

  def call(pid, role, messages) do
    Agent.update(pid, fn state ->
      entry = %{phase: state.phase, role: role, messages: messages}
      %{state | calls: [entry | state.calls]}
    end)
  end

  def transport(pid, metadata) do
    Agent.update(pid, fn state ->
      entry = %{phase: state.phase, metadata: inspect(metadata, limit: 30)}
      %{state | transports: [entry | state.transports]}
    end)
  end

  def snapshot(pid) do
    Agent.get(pid, fn state ->
      %{state | calls: Enum.reverse(state.calls), transports: Enum.reverse(state.transports)}
    end)
  end
end

defmodule LocalSIMBATREC.ObservedLM do
  defstruct [:inner, :observer, :role]

  def generate(lm, messages, opts) do
    LocalSIMBATREC.Observer.call(lm.observer, lm.role, messages)
    Imp.LM.generate(lm.inner, messages, opts)
  end

  def response_format_capability(%__MODULE__{inner: inner}),
    do: Imp.LM.response_format_capability(inner)
end

defmodule LocalSIMBATREC.Audit do
  def parameter_snapshot(program) do
    Enum.map(Imp.ProgramParameters.predictors(program), fn %{name: name, predictor: predictor} ->
      %{name: name, instruction: predictor.signature.instructions, demos: predictor.demos}
    end)
  end

  def selection_kind(baseline, selected) do
    if parameter_snapshot(selected) == parameter_snapshot(baseline),
      do: "baseline",
      else: "mutated"
  end

  def verify_selected_artifact!(artifact, baseline, selected, report) do
    selected_parameters = parameter_snapshot(selected)

    applied_parameters =
      artifact |> Imp.Optimizer.Artifact.apply(baseline) |> parameter_snapshot()

    unless applied_parameters == selected_parameters,
      do: raise("selected artifact champion does not match the selected program")

    unless Enum.any?(report.metadata.final_candidates, fn finalist ->
             finalist.score == report.best_score and finalist.parameters == selected_parameters
           end) do
      raise "selected artifact champion does not match a best-scoring SIMBA finalist"
    end

    :ok
  end

  def mutated_finalists(finalists, baseline_snapshot) do
    Enum.filter(finalists, fn finalist ->
      finalist.finalist_index > 0 and finalist.parameters != baseline_snapshot
    end)
  end
end

defmodule LocalSIMBATREC.Runner do
  alias Imp.Optimizer.{Artifact, Report, SIMBA}
  alias LocalSIMBATREC.{Atomic, Audit, ObservedLM, Observer}

  @model "llama3.2:3b"
  @model_spec "ollama:" <> @model
  @model_digest "a80c4f17acd55265feec403c7aef86be0c25983ab279d83f3bcd3abbcb5b8b72"
  @data_sha256 "6643645cc3bcd79a5236b7e3920a5c37526be178df2e02f20652d9a16eef51ad"
  @routes ~w(R17 R42 R68 R93)

  def run do
    cond do
      System.get_env("IMP_SIMBA_TREC_FRESH") == "1" -> fresh()
      System.get_env("IMP_SIMBA_TREC_PREFLIGHT_ONLY") == "1" -> preflight_only()
      true -> parent()
    end
  end

  defp preflight_only do
    paths = paths!()
    rows = preflight!(paths)

    IO.puts(
      Jason.encode!(%{
        status: "preflight_complete",
        train: length(rows.train),
        validation: length(rows.validation),
        held_out: length(rows.held_out),
        model: @model_spec,
        adapter: inspect(adapter_module!())
      })
    )
  end

  defp parent do
    paths = paths!()
    rows = preflight!(paths)
    observer = observer!()

    try do
      source = source_program()
      :ok = Imp.save!(source, paths.program)
      baseline = observe_program(source, observer)
      Observer.phase(observer, "optimization")

      selected =
        SIMBA.new(metric(),
          bsize: 8,
          num_candidates: 3,
          max_steps: 3,
          max_demos: 4,
          prompt_lm: observed(reflection_lm(), observer, :reflection),
          num_threads: 1,
          timeout: 120_000,
          seed: 20_260_726
        )
        |> then(&Imp.optimize!(baseline, &1, examples(rows.train), examples(rows.validation)))

      report = Report.fetch(selected)
      artifact = Artifact.from_optimized_program(selected, artifact_id: "local-simba-trec-v1")
      Audit.verify_selected_artifact!(artifact, baseline, selected, report)
      :ok = Artifact.write!(artifact, paths.artifact)

      optimization = optimization_stage(baseline, selected, report, observer)
      Atomic.write!(Path.join(paths.output, "01-optimization.json"), optimization)
      require_optimization!(optimization)

      Observer.phase(observer, "baseline_test")
      baseline_test = evaluate(baseline, rows.held_out, observer, "baseline_test")
      Atomic.write!(Path.join(paths.output, "02-baseline-test.json"), baseline_test)
      require_evaluation!(baseline_test)

      Observer.phase(observer, "selected_test")
      selected_test = evaluate(selected, rows.held_out, observer, "selected_test")
      Atomic.write!(Path.join(paths.output, "03-selected-test.json"), selected_test)
      require_evaluation!(selected_test)

      fresh_path = Path.join(paths.output, "04-fresh-test.json")
      {fresh_output, status} = fresh_process(paths, fresh_path)
      if status != 0, do: raise("fresh OS BEAM failed: #{fresh_output}")
      fresh_test = fresh_path |> File.read!() |> Jason.decode!()

      unless fresh_test["reproduction_sha256"] == selected_test.reproduction_sha256,
        do: raise("fresh selected predictions/errors differ")

      unless fresh_test["model_identity"] == @model_spec,
        do: raise("fresh process loaded a different task LM")

      unless fresh_test["selected_parameters_sha256"] == optimization.selected_parameters_sha256,
        do: raise("fresh process loaded a different selected parameter artifact")

      result = %{
        status: "complete",
        scope: "one local SIMBA opaque-route TREC consumer lifecycle",
        model: @model_spec,
        adapter: inspect(adapter_module!()),
        data_sha256: @data_sha256,
        split_sizes: %{train: 24, validation: 8, held_out_test: 40},
        search:
          Map.take(optimization, [
            :baseline_score,
            :selected_score,
            :selected,
            :candidate_count,
            :mutated_finalists,
            :rendered_mutation_calls,
            :logical_calls,
            :transport_attempts
          ]),
        held_out_test: %{
          baseline: Map.take(baseline_test, [:accuracy, :macro_f1, :errors]),
          selected: Map.take(selected_test, [:accuracy, :macro_f1, :errors])
        },
        fresh_process: %{byte_identical: true, model_identity: fresh_test["model_identity"]},
        claim_boundary:
          "One source-disjoint task/model SIMBA mutation, validation selection, artifact, and fresh-process result; not general SIMBA effectiveness, full DSPy parity, production reliability, or BEAM superiority."
      }

      Atomic.write!(Path.join(paths.output, "result.json"), result)
      IO.puts(Jason.encode!(result, pretty: true))
    after
      :telemetry.detach({__MODULE__, self()})
    end
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
    observer = observer!()

    try do
      source = Imp.read!(paths.program)
      assert_runtime!(source)
      baseline = observe_program(source, observer)
      artifact = Artifact.read!(paths.artifact)
      selected = Artifact.apply(artifact, baseline)
      Observer.phase(observer, "fresh_selected_test")
      stage = evaluate(selected, rows.held_out, observer, "fresh_selected_test")

      stage =
        Map.merge(stage, %{
          model_identity: model_identity(selected),
          selected_parameters_sha256: sha256_term(Audit.parameter_snapshot(selected))
        })

      Atomic.write!(System.fetch_env!("IMP_SIMBA_TREC_FRESH_OUTPUT"), stage)
      require_evaluation!(stage)
    after
      :telemetry.detach({__MODULE__, self()})
    end
  end

  defp preflight!(paths) do
    unless sha256_file(paths.data) == @data_sha256, do: raise("TREC data digest drift")
    verify_ollama!()
    data = paths.data |> File.read!() |> Jason.decode!()

    rows = %{
      train: data["train"],
      validation: data["validation"],
      held_out: data["held_out"]
    }

    ids = Enum.map(rows.train ++ rows.validation ++ rows.held_out, & &1["id"])

    unless {length(rows.train), length(rows.validation), length(rows.held_out)} == {24, 8, 40} and
             length(ids) == length(Enum.uniq(ids)) do
      raise "TREC split size, ordering, or overlap drift"
    end

    Atomic.write!(Path.join(paths.output, "00-preflight.json"), %{
      status: "complete",
      data_sha256: @data_sha256,
      model: @model_spec,
      model_digest: @model_digest,
      adapter: inspect(adapter_module!()),
      train_ids: Enum.map(rows.train, & &1["id"]),
      validation_ids: Enum.map(rows.validation, & &1["id"]),
      held_out_ids: Enum.map(rows.held_out, & &1["id"])
    })

    rows
  end

  def source_program do
    lm =
      Imp.req_llm(@model_spec,
        cache: false,
        temperature: 0,
        max_tokens: 48,
        max_retries: 0,
        timeout: 120_000,
        req_http_options: [retry: false, max_retries: 0]
      )

    Imp.predict(
      Imp.signature(
        "question -> route: enum[R17,R42,R68,R93]",
        "Route the question to exactly one opaque internal answer service. Return only its route code."
      ),
      lm: lm,
      adapter: adapter_module!(),
      config: [json_fallback: false]
    )
  end

  defp observe_program(program, observer) do
    Imp.Predict.with_lm(
      program,
      observed(program_lm(program), observer, :task)
    )
  end

  defp reflection_lm do
    Imp.req_llm(@model_spec,
      cache: false,
      temperature: 0,
      max_tokens: 768,
      max_retries: 0,
      timeout: 120_000,
      req_http_options: [retry: false, max_retries: 0]
    )
  end

  defp observed(inner, observer, role),
    do: %ObservedLM{inner: inner, observer: observer, role: role}

  defp metric do
    fn example, prediction ->
      Imp.Example.get(example, :route) == Imp.Prediction.get(prediction, :route)
    end
  end

  defp optimization_stage(baseline, selected, report, observer) do
    snapshot = Observer.snapshot(observer)
    baseline_parameters = Audit.parameter_snapshot(baseline)
    selected_parameters = Audit.parameter_snapshot(selected)
    mutated = Audit.mutated_finalists(report.metadata.final_candidates, baseline_parameters)
    task_calls = Enum.filter(snapshot.calls, &(&1.phase == "optimization" and &1.role == :task))

    rendered_mutation_calls =
      Enum.count(task_calls, fn call ->
        Enum.any?(
          mutated,
          &parameters_rendered?(&1.parameters, call.messages, baseline_parameters)
        )
      end)

    %{
      status: "complete",
      baseline_score: report.metadata.baseline_score,
      selected_score: report.best_score,
      selected: Audit.selection_kind(baseline, selected),
      candidate_count: report.candidate_count,
      mutated_finalists: length(mutated),
      rendered_mutation_calls: rendered_mutation_calls,
      logical_calls: length(snapshot.calls),
      task_calls: length(task_calls),
      reflection_calls:
        Enum.count(snapshot.calls, &(&1.phase == "optimization" and &1.role == :reflection)),
      transport_attempts: Enum.count(snapshot.transports, &(&1.phase == "optimization")),
      baseline_parameters_sha256: sha256_term(baseline_parameters),
      selected_parameters_sha256: sha256_term(selected_parameters),
      report: Report.json_safe(report)
    }
  end

  defp parameters_rendered?(parameters, messages, baseline_parameters) do
    Enum.any?(parameters, fn parameter ->
      baseline = Enum.find(baseline_parameters, &(&1.name == parameter.name))

      cond do
        parameter.instruction != baseline.instruction ->
          Imp.Adapter.Instructions.rendered_objective?(parameter.instruction, messages)

        parameter.demos != baseline.demos ->
          Enum.any?(messages, &(Map.get(&1, :role) == :assistant))

        true ->
          false
      end
    end)
  end

  defp require_optimization!(stage) do
    unless stage.candidate_count > 0 and stage.mutated_finalists > 0 and
             stage.rendered_mutation_calls > 0 and stage.task_calls > 0 and
             stage.logical_calls == stage.transport_attempts do
      raise "SIMBA did not execute a real one-attempt rendered mutation: #{inspect(stage)}"
    end
  end

  defp evaluate(program, rows, observer, phase) do
    before = Observer.snapshot(observer)

    results =
      Enum.map(rows, fn row ->
        case Imp.call(program, %{question: row["question"]}) do
          {:ok, prediction} ->
            %{
              id: row["id"],
              expected: row["route"],
              actual: Imp.get(prediction, :route),
              error: nil
            }

          {:error, reason} ->
            %{id: row["id"], expected: row["route"], actual: nil, error: inspect(reason)}
        end
      end)

    after_snapshot = Observer.snapshot(observer)
    calls = Enum.drop(after_snapshot.calls, length(before.calls))
    transports = Enum.drop(after_snapshot.transports, length(before.transports))

    %{
      status: "complete",
      phase: phase,
      rows: results,
      accuracy: Enum.count(results, &(&1.actual == &1.expected)) / length(results),
      macro_f1: macro_f1(results),
      errors: Enum.count(results, &(not is_nil(&1.error))),
      logical_calls: length(calls),
      transport_attempts: length(transports),
      reproduction_sha256: sha256_term(Enum.map(results, &Map.take(&1, [:id, :actual, :error])))
    }
  end

  defp require_evaluation!(stage) do
    unless stage.logical_calls == 40 and stage.transport_attempts == 40,
      do: raise("#{stage.phase} did not make one fresh transport per held-out row")
  end

  defp examples(rows) do
    Enum.map(rows, fn row ->
      Imp.Example.new(%{question: row["question"], route: row["route"]})
      |> Imp.Example.with_inputs([:question])
    end)
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

  defp assert_runtime!(program) do
    lm = program_lm(program)

    unless program.adapter == adapter_module!() and lm.model == @model_spec and
             Keyword.get(lm.opts, :cache) == false and
             Keyword.get(lm.opts, :max_retries) == 0 and
             Keyword.get(lm.opts, :req_http_options) == [retry: false, max_retries: 0] do
      raise "saved program changed model, cache, or retry identity"
    end
  end

  defp model_identity(program) do
    case program_lm(program) do
      %ObservedLM{inner: inner} -> inner.model
      lm -> lm.model
    end
  end

  defp adapter_module! do
    case System.get_env("IMP_SIMBA_TREC_ADAPTER", "chat") do
      "chat" -> Imp.Adapter.Chat
      "json" -> Imp.Adapter.JSON
      other -> raise "unsupported SIMBA TREC adapter: #{inspect(other)}"
    end
  end

  defp observer! do
    {:ok, observer} = Observer.start_link()

    :ok =
      :telemetry.attach(
        {__MODULE__, self()},
        [:imp, :lm, :transport, :attempt],
        fn _event, _measurements, metadata, target -> Observer.transport(target, metadata) end,
        observer
      )

    observer
  end

  defp verify_ollama! do
    models = Req.get!("http://127.0.0.1:11434/api/tags", retry: false).body["models"]

    unless Enum.any?(models, &(&1["name"] == @model and &1["digest"] == @model_digest)),
      do: raise("pinned local Ollama model is absent or changed")
  end

  defp fresh_process(paths, output_path) do
    System.cmd("mix", ["run", "--no-compile", "--no-deps-check", __ENV__.file],
      cd: paths.imp,
      env: [
        {"MIX_ENV", "dev"},
        {"IMP_PATH", paths.imp},
        {"IMP_SIMBA_TREC_DATA", paths.data},
        {"IMP_SIMBA_TREC_OUTPUT", paths.output},
        {"IMP_SIMBA_TREC_ADAPTER", System.get_env("IMP_SIMBA_TREC_ADAPTER", "chat")},
        {"IMP_SIMBA_TREC_FRESH", "1"},
        {"IMP_SIMBA_TREC_FRESH_OUTPUT", output_path}
      ],
      stderr_to_stdout: true
    )
  end

  defp paths! do
    imp = System.get_env("IMP_PATH", Path.expand("../..", __DIR__)) |> Path.expand()
    output = System.get_env("IMP_SIMBA_TREC_OUTPUT", "/tmp/imp-local-simba-trec") |> Path.expand()

    %{
      imp: imp,
      output: output,
      data:
        System.get_env(
          "IMP_SIMBA_TREC_DATA",
          Path.join(imp, "benchmarks/data/simba-trec-coarse-v1.json")
        )
        |> Path.expand(),
      program: Path.join(output, "source-program.json"),
      artifact: Path.join(output, "selected-parameters.json")
    }
  end

  defp sha256_file(path), do: path |> File.read!() |> sha256()
  defp sha256_term(term), do: term |> Jason.encode!() |> sha256()
  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  # The LM of the program's first predictor, through the public parameter view.
  defp program_lm(program),
    do: program |> Imp.ProgramParameters.predictors() |> hd() |> then(& &1.predictor.lm)
end

unless System.get_env("IMP_SIMBA_TREC_DEFINE_ONLY") == "1" do
  LocalSIMBATREC.Runner.run()
end
