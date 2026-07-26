defmodule LocalSIMBAFeedbackTREC.Atomic do
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

defmodule LocalSIMBAFeedbackTREC.Contract do
  @contract_sha256 "1f29446db7aa4ac99683422f3833f313912445ec7c2c9d44776e84f26530d3b8"
  @labels ~w(DESC ENTY)

  def load!(imp, path) do
    unless sha256_file(path) == @contract_sha256, do: raise("SIMBA task contract drift")
    contract = path |> File.read!() |> Jason.decode!()
    unless contract["schema_version"] == 1, do: raise("unsupported SIMBA task contract")

    source = contract["source"]
    data_path = Path.join(imp, source["data_path"])
    provenance_path = Path.join(imp, source["provenance_path"])

    verify_digest!(data_path, source["data_sha256"], "TREC data")
    verify_digest!(provenance_path, source["provenance_sha256"], "TREC provenance")

    rows = data_path |> File.stream!() |> Enum.map(&Jason.decode!/1)
    by_id = Map.new(rows, &{&1["id"], &1})
    if map_size(by_id) != length(rows), do: raise("TREC source contains duplicate row IDs")

    excluded_source_ids =
      contract["source_exclusions"]
      |> Enum.flat_map(fn exclusion ->
        path = Path.join(imp, exclusion["path"])
        verify_digest!(path, exclusion["sha256"], "predecessor task slice")

        prior = path |> File.read!() |> Jason.decode!()
        Enum.flat_map(~w(train validation held_out), &prior[&1])
      end)
      |> MapSet.new(& &1["source_id"])

    splits = contract["splits"]

    selected = %{
      train: resolve!(by_id, splits["train_ids"]),
      validation: resolve!(by_id, splits["validation_ids"]),
      held_out: resolve!(by_id, splits["held_out_ids"])
    }

    validate!(selected, excluded_source_ids, contract["route_mapping"])
    Map.put(selected, :contract, contract)
  end

  def contract_sha256, do: @contract_sha256

  defp resolve!(by_id, ids) when is_list(ids) do
    Enum.map(ids, fn id -> Map.fetch!(by_id, id) end)
  rescue
    KeyError -> raise "task contract references an absent TREC row"
  end

  defp validate!(splits, excluded_source_ids, mapping) do
    all = splits.train ++ splits.validation ++ splits.held_out
    ids = Enum.map(all, & &1["id"])
    groups = Enum.map(all, & &1["group_id"])

    unless {length(splits.train), length(splits.validation), length(splits.held_out)} ==
             {20, 6, 40} and length(ids) == length(Enum.uniq(ids)) and
             length(groups) == length(Enum.uniq(groups)) do
      raise "task split size, row identity, or group isolation drift"
    end

    if Enum.any?(all, &MapSet.member?(excluded_source_ids, &1["source_id"])),
      do: raise("task contract reuses a predecessor source row")

    unless Enum.all?(splits.train ++ splits.validation, &(&1["split"] == "calibration")) and
             Enum.all?(splits.held_out, &(&1["split"] == "heldout")) do
      raise "task contract crossed the official train/test source boundary"
    end

    unless Map.keys(mapping) |> Enum.sort() == Enum.sort(@labels),
      do: raise("task route mapping drift")

    for {name, rows, per_label} <- [
          {:train, splits.train, 10},
          {:validation, splits.validation, 3},
          {:held_out, splits.held_out, 20}
        ],
        label <- @labels do
      unless Enum.count(rows, &(coarse_label(&1) == label)) == per_label,
        do: raise("#{name} is no longer balanced for #{label}")
    end

    :ok
  end

  defp verify_digest!(path, expected, label) do
    unless sha256_file(path) == expected, do: raise("#{label} digest drift")
  end

  defp sha256_file(path), do: path |> File.read!() |> sha256()
  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  defp coarse_label(row), do: row["label"] |> String.split(":", parts: 2) |> hd()
end

defmodule LocalSIMBAFeedbackTREC.Observer do
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

defmodule LocalSIMBAFeedbackTREC.ObservedLM do
  defstruct [:inner, :observer, :role]

  def generate(lm, messages, opts) do
    LocalSIMBAFeedbackTREC.Observer.call(lm.observer, lm.role, messages)
    Imp.LM.generate(lm.inner, messages, opts)
  end

  def response_format_capability(%__MODULE__{inner: inner}),
    do: Imp.LM.response_format_capability(inner)
end

defmodule LocalSIMBAFeedbackTREC.Audit do
  def parameter_snapshot(program) do
    Enum.map(Imp.ProgramParameters.predictors(program), fn %{name: name, predictor: predictor} ->
      %{name: name, instruction: predictor.signature.instructions, demos: predictor.demos}
    end)
  end

  def selection_kind(baseline, selected) do
    if parameter_snapshot(selected) == parameter_snapshot(baseline),
      do: "baseline",
      else: "mutated_rule"
  end

  def verify_selected_artifact!(artifact, baseline, selected, report) do
    selected_parameters = parameter_snapshot(selected)
    applied = artifact |> Imp.Optimizer.Artifact.apply(baseline) |> parameter_snapshot()

    unless applied == selected_parameters,
      do: raise("selected artifact champion does not match selected program")

    unless Enum.any?(report.metadata.final_candidates, fn finalist ->
             finalist.score == report.best_score and finalist.parameters == selected_parameters
           end),
           do: raise("artifact champion is not a best-scoring SIMBA finalist")

    :ok
  end

  def mutated_rules(finalists, baseline) do
    Enum.filter(finalists, fn finalist ->
      finalist.finalist_index > 0 and
        Enum.zip(finalist.parameters, baseline)
        |> Enum.any?(fn {candidate, source} ->
          candidate.name == source.name and candidate.instruction != source.instruction and
            candidate.demos == source.demos
        end)
    end)
  end
end

defmodule LocalSIMBAFeedbackTREC.Runner do
  alias Imp.Optimizer.{Artifact, Report, SIMBA}
  alias LocalSIMBAFeedbackTREC.{Atomic, Audit, Contract, ObservedLM, Observer}

  @contract "task-contract.json"
  @treatment_id "local-simba-feedback-trec-schema-decode-v3"
  @routes ~w(K11 K47)
  @max_optimization_transports 130

  def run do
    cond do
      System.get_env("IMP_SIMBA_FEEDBACK_TREC_FRESH") == "1" -> fresh()
      System.get_env("IMP_SIMBA_FEEDBACK_TREC_PREFLIGHT_ONLY") == "1" -> preflight_only()
      true -> parent()
    end
  end

  defp preflight_only do
    paths = paths!()
    rows = preflight!(paths)

    IO.puts(
      Jason.encode!(%{
        status: "preflight_complete",
        treatment_id: @treatment_id,
        contract_sha256: Contract.contract_sha256(),
        split_sizes: %{
          train: length(rows.train),
          validation: length(rows.validation),
          held_out: length(rows.held_out)
        },
        model: rows.contract["model"]["id"],
        max_total_transports: @max_optimization_transports + 120
      })
    )
  end

  defp parent do
    paths = paths!()
    rows = preflight!(paths)
    observer = observer!()

    try do
      source = source_program(rows.contract)
      :ok = Imp.save!(source, paths.program)
      baseline = observe_program(source, observer)
      Observer.phase(observer, "optimization")
      optimizer = optimizer(rows.contract, observer)

      selected =
        SIMBA.compile(
          optimizer,
          baseline,
          examples(rows.train, rows.contract, true),
          examples(rows.validation, rows.contract, false)
        )

      report = Report.fetch(selected)
      artifact = Artifact.from_optimized_program(selected, artifact_id: rows.contract["task_id"])
      :ok = Audit.verify_selected_artifact!(artifact, baseline, selected, report)
      :ok = Artifact.write!(artifact, paths.artifact)

      optimization = optimization_stage(baseline, selected, report, observer)
      Atomic.write!(Path.join(paths.output, "01-optimization.json"), optimization)
      require_optimization!(optimization)

      Observer.phase(observer, "baseline_held_out")

      baseline_test =
        evaluate(baseline, rows.held_out, rows.contract, observer, "baseline_held_out")

      Atomic.write!(Path.join(paths.output, "02-baseline-held-out.json"), baseline_test)
      require_evaluation!(baseline_test)

      Observer.phase(observer, "selected_held_out")

      selected_test =
        evaluate(selected, rows.held_out, rows.contract, observer, "selected_held_out")

      Atomic.write!(Path.join(paths.output, "03-selected-held-out.json"), selected_test)
      require_evaluation!(selected_test)

      fresh_path = Path.join(paths.output, "04-fresh-held-out.json")
      {fresh_output, status} = fresh_process(paths, fresh_path)
      if status != 0, do: raise("fresh OS BEAM failed: #{fresh_output}")
      fresh_test = fresh_path |> File.read!() |> Jason.decode!()

      unless fresh_test["reproduction_sha256"] == selected_test.reproduction_sha256,
        do: raise("fresh selected predictions/errors differ")

      unless fresh_test["selected_parameters_sha256"] == optimization.selected_parameters_sha256,
        do: raise("fresh selected parameters differ")

      result = %{
        status: "complete",
        treatment_id: @treatment_id,
        task_id: rows.contract["task_id"],
        contract_sha256: Contract.contract_sha256(),
        model: rows.contract["model"]["id"],
        splits: %{train: 20, validation: 6, held_out: 40},
        search: Map.drop(optimization, [:report]),
        held_out: %{
          baseline: Map.take(baseline_test, [:accuracy, :macro_f1, :errors]),
          selected: Map.take(selected_test, [:accuracy, :macro_f1, :errors])
        },
        fresh_process: %{byte_identical: true, model_identity: fresh_test["model_identity"]},
        claim_boundary:
          "One source-disjoint TREC task/model SIMBA rule search and lifecycle; not general effectiveness, DSPy parity, or BEAM superiority."
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
      source = Imp.load!(paths.program)
      assert_runtime!(source, rows.contract)
      baseline = observe_program(source, observer)
      selected = paths.artifact |> Artifact.read!() |> Artifact.apply(baseline)
      Observer.phase(observer, "fresh_selected_held_out")

      stage =
        evaluate(selected, rows.held_out, rows.contract, observer, "fresh_selected_held_out")

      stage =
        Map.merge(stage, %{
          model_identity: model_identity(selected),
          selected_parameters_sha256: sha256_term(Audit.parameter_snapshot(selected))
        })

      Atomic.write!(System.fetch_env!("IMP_SIMBA_FEEDBACK_TREC_FRESH_OUTPUT"), stage)
      require_evaluation!(stage)
    after
      :telemetry.detach({__MODULE__, self()})
    end
  end

  def load_contract_rows! do
    paths = paths!()
    Contract.load!(paths.imp, paths.contract)
  end

  def source_program(contract) do
    model = contract["model"]["id"]

    Imp.predict(
      Imp.signature(
        "question -> route: enum[K11,K47]",
        "Route the question to exactly one internal answer service. Return only its service code."
      ),
      lm:
        Imp.req_llm(model,
          cache: false,
          temperature: 0,
          max_tokens: 32,
          max_retries: 0,
          timeout: 120_000,
          req_http_options: [retry: false, max_retries: 0]
        ),
      adapter: Imp.Adapter.SingleField,
      config: [json_fallback: false]
    )
  end

  def metric(mapping) do
    fn example, prediction ->
      expected = Imp.Example.get(example, :route)
      source_label = Imp.Example.get(example, :source_label)
      actual = Imp.Prediction.get(prediction, :route)
      expected_meaning = mapping[source_label]["meaning"]

      actual_meaning =
        Enum.find_value(mapping, "unknown service", fn {_label, info} ->
          if info["route"] == actual, do: info["meaning"]
        end)

      score = if actual == expected, do: 1.0, else: 0.0

      if Imp.Example.get(example, :feedback_allowed) do
        %{
          score: score,
          feedback:
            if(score == 1.0,
              do: "Correct: #{expected} handles #{expected_meaning}.",
              else:
                "Expected #{expected} for #{expected_meaning}; #{actual} represents #{actual_meaning}."
            ),
          metadata: %{
            expected_route: expected,
            predicted_route: actual,
            source_label: source_label
          }
        }
      else
        score
      end
    end
  end

  defp preflight!(paths) do
    rows = Contract.load!(paths.imp, paths.contract)
    verify_ollama!(rows.contract)

    Atomic.write!(Path.join(paths.output, "00-preflight.json"), %{
      status: "complete",
      treatment_id: @treatment_id,
      contract_sha256: Contract.contract_sha256(),
      model: rows.contract["model"],
      train_ids: Enum.map(rows.train, & &1["id"]),
      validation_ids: Enum.map(rows.validation, & &1["id"]),
      held_out_ids: Enum.map(rows.held_out, & &1["id"])
    })

    rows
  end

  defp optimizer(contract, observer) do
    config = contract["optimizer"]

    SIMBA.new(metric(contract["route_mapping"]),
      bsize: config["bsize"],
      num_candidates: config["num_candidates"],
      max_steps: config["max_steps"],
      max_demos: config["max_demos"],
      prompt_lm: observed(reflection_lm(contract), observer, :reflection),
      max_concurrency: 1,
      timeout: 120_000,
      seed: config["seed"]
    )
  end

  defp reflection_lm(contract) do
    Imp.req_llm(contract["model"]["id"],
      cache: false,
      temperature: 0,
      max_tokens: 768,
      max_retries: 0,
      timeout: 120_000,
      req_http_options: [retry: false, max_retries: 0]
    )
  end

  defp observe_program(program, observer),
    do:
      Imp.Predict.Predict.with_lm(
        program,
        observed(Imp.ProgramAccess.lm(program), observer, :task)
      )

  defp observed(inner, observer, role),
    do: %ObservedLM{inner: inner, observer: observer, role: role}

  defp optimization_stage(baseline, selected, report, observer) do
    snapshot = Observer.snapshot(observer)
    baseline_parameters = Audit.parameter_snapshot(baseline)
    selected_parameters = Audit.parameter_snapshot(selected)
    mutated = Audit.mutated_rules(report.metadata.final_candidates, baseline_parameters)
    task_calls = Enum.filter(snapshot.calls, &(&1.phase == "optimization" and &1.role == :task))

    reflection_calls =
      Enum.filter(snapshot.calls, &(&1.phase == "optimization" and &1.role == :reflection))

    rendered_rule_calls =
      Enum.count(task_calls, fn call ->
        Enum.any?(mutated, fn finalist ->
          Enum.any?(finalist.parameters, fn parameter ->
            source = Enum.find(baseline_parameters, &(&1.name == parameter.name))

            parameter.instruction != source.instruction and
              Imp.Adapter.Instructions.rendered_objective?(parameter.instruction, call.messages)
          end)
        end)
      end)

    feedback_reflection_calls =
      Enum.count(reflection_calls, fn call ->
        rendered = Enum.map_join(call.messages, "\n", & &1.content)
        rendered =~ "Expected K" and rendered =~ "question"
      end)

    %{
      status: "complete",
      baseline_score: report.metadata.baseline_score,
      selected_score: report.best_score,
      selected: Audit.selection_kind(baseline, selected),
      candidate_count: report.candidate_count,
      mutated_rule_finalists: length(mutated),
      rendered_rule_calls: rendered_rule_calls,
      feedback_reflection_calls: feedback_reflection_calls,
      task_calls: length(task_calls),
      reflection_calls: length(reflection_calls),
      logical_calls: length(snapshot.calls),
      transport_attempts: Enum.count(snapshot.transports, &(&1.phase == "optimization")),
      selected_parameters_sha256: sha256_term(selected_parameters),
      report: Report.json_safe(report)
    }
  end

  defp require_optimization!(stage) do
    unless stage.candidate_count > 0 and stage.mutated_rule_finalists > 0 and
             stage.rendered_rule_calls > 0 and stage.feedback_reflection_calls > 0 and
             stage.logical_calls == stage.transport_attempts and
             stage.transport_attempts <= @max_optimization_transports do
      raise "SIMBA did not complete bounded feedback-informed rule search: #{inspect(stage)}"
    end
  end

  defp evaluate(program, rows, contract, observer, phase) do
    before = Observer.snapshot(observer)

    results =
      Enum.map(rows, fn row ->
        expected = contract["route_mapping"][coarse_label(row)]["route"]

        case Imp.call(program, %{question: row["text"]}) do
          {:ok, prediction} ->
            %{id: row["id"], expected: expected, actual: Imp.get(prediction, :route), error: nil}

          {:error, reason} ->
            %{id: row["id"], expected: expected, actual: nil, error: inspect(reason)}
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

  defp examples(rows, contract, feedback_allowed) do
    Enum.map(rows, fn row ->
      source_label = coarse_label(row)
      route = contract["route_mapping"][source_label]["route"]

      Imp.Example.new(%{
        question: row["text"],
        route: route,
        source_label: source_label,
        feedback_allowed: feedback_allowed
      })
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

  defp assert_runtime!(program, contract) do
    lm = Imp.ProgramAccess.lm(program)

    unless program.adapter == Imp.Adapter.SingleField and lm.model == contract["model"]["id"] and
             Keyword.get(lm.opts, :cache) == false and Keyword.get(lm.opts, :max_retries) == 0 and
             Keyword.get(lm.opts, :req_http_options) == [retry: false, max_retries: 0] do
      raise "saved program changed adapter, model, cache, or retry identity"
    end
  end

  defp model_identity(program) do
    case Imp.ProgramAccess.lm(program) do
      %ObservedLM{inner: inner} -> inner.model
      lm -> lm.model
    end
  end

  defp verify_ollama!(contract) do
    model = contract["model"]
    models = Req.get!("http://127.0.0.1:11434/api/tags", retry: false).body["models"]

    unless Enum.any?(
             models,
             &(&1["name"] == model["inventory_name"] and &1["digest"] == model["digest"])
           ),
           do: raise("pinned local Ollama model is absent or changed")
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

  defp fresh_process(paths, output_path) do
    System.cmd("mix", ["run", "--no-compile", "--no-deps-check", __ENV__.file],
      cd: paths.imp,
      env: [
        {"MIX_ENV", "dev"},
        {"IMP_PATH", paths.imp},
        {"IMP_SIMBA_FEEDBACK_TREC_OUTPUT", paths.output},
        {"IMP_SIMBA_FEEDBACK_TREC_CONTRACT", paths.contract},
        {"IMP_SIMBA_FEEDBACK_TREC_FRESH", "1"},
        {"IMP_SIMBA_FEEDBACK_TREC_FRESH_OUTPUT", output_path}
      ],
      stderr_to_stdout: true
    )
  end

  defp paths! do
    imp = System.get_env("IMP_PATH", Path.expand("../..", __DIR__)) |> Path.expand()

    output =
      System.get_env("IMP_SIMBA_FEEDBACK_TREC_OUTPUT", "/tmp/imp-local-simba-feedback-trec")
      |> Path.expand()

    %{
      imp: imp,
      output: output,
      contract:
        System.get_env("IMP_SIMBA_FEEDBACK_TREC_CONTRACT", Path.join(__DIR__, @contract))
        |> Path.expand(),
      program: Path.join(output, "source-program.json"),
      artifact: Path.join(output, "selected-parameters.json")
    }
  end

  defp sha256_term(term), do: term |> Jason.encode!() |> sha256()
  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  defp coarse_label(row), do: row["label"] |> String.split(":", parts: 2) |> hd()
end

unless System.get_env("IMP_SIMBA_FEEDBACK_TREC_DEFINE_ONLY") == "1" do
  LocalSIMBAFeedbackTREC.Runner.run()
end
