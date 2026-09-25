defmodule LocalGEPABanking77.Atomic do
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

defmodule LocalGEPABanking77.Observer do
  def start_link, do: Agent.start_link(fn -> %{phase: "startup", calls: [], transports: []} end)
  def phase(pid, phase), do: Agent.update(pid, &%{&1 | phase: phase})

  def call(pid, role, messages) do
    Agent.update(pid, fn state ->
      call = %{phase: state.phase, role: role, messages: messages}
      %{state | calls: [call | state.calls]}
    end)
  end

  def transport(pid, metadata) do
    Agent.update(pid, fn state ->
      transport = %{phase: state.phase, metadata: inspect(metadata, limit: 30)}
      %{state | transports: [transport | state.transports]}
    end)
  end

  def snapshot(pid) do
    Agent.get(pid, fn state ->
      %{state | calls: Enum.reverse(state.calls), transports: Enum.reverse(state.transports)}
    end)
  end
end

defmodule LocalGEPABanking77.ObservedLM do
  defstruct [:inner, :observer, :role]

  def generate(lm, messages, opts) do
    LocalGEPABanking77.Observer.call(lm.observer, lm.role, messages)
    Imp.LM.generate(lm.inner, messages, opts)
  end

  def response_format_capability(%__MODULE__{inner: inner}),
    do: Imp.LM.response_format_capability(inner)
end

defmodule LocalGEPABanking77.Router do
  @behaviour Imp.Module
  defstruct [:analyze_intent, :classify_route]

  def new(analyzer_lm, classifier_lm) do
    %__MODULE__{
      analyze_intent:
        Imp.predict(
          Imp.signature(
            "utterance -> evidence",
            "Summarize the customer request as concise evidence for a route classifier."
          ),
          lm: analyzer_lm,
          adapter: Imp.Adapter.Chat,
          config: [json_fallback: false]
        ),
      classify_route:
        Imp.predict(
          Imp.signature(
            "utterance, evidence -> route: enum[R17,R42,R68,R93]",
            "Choose exactly one opaque route code from the utterance and evidence."
          ),
          lm: classifier_lm,
          adapter: Imp.Adapter.Chat,
          config: [json_fallback: false]
        )
    }
  end

  @impl true
  def optimizer_predictors(router),
    do: [analyze_intent: router.analyze_intent, classify_route: router.classify_route]

  @impl true
  def update_optimizer_predictor(router, :analyze_intent, update),
    do: %{router | analyze_intent: update.(router.analyze_intent)}

  def update_optimizer_predictor(router, :classify_route, update),
    do: %{router | classify_route: update.(router.classify_route)}

  @impl true
  def call(router, inputs) when is_map(inputs) or is_list(inputs) do
    inputs = Map.new(inputs)
    utterance = Map.get(inputs, :utterance, Map.get(inputs, "utterance"))

    with true <- is_binary(utterance) || {:error, {:missing_input_fields, [:utterance]}},
         {:ok, analysis} <- Imp.call(router.analyze_intent, %{utterance: utterance}),
         evidence <- Imp.Prediction.fetch!(analysis, :evidence),
         {:ok, classification} <-
           Imp.call(router.classify_route, %{utterance: utterance, evidence: evidence}) do
      {:ok, classification}
    end
  end

  def call(_router, inputs), do: {:error, {:invalid_router_inputs, inputs}}
end

defmodule LocalGEPABanking77.Runner do
  alias Imp.Clients.{MLXLMDeployment, TrainingJob}
  alias Imp.Optimizer.{Artifact, GEPA}
  alias LocalGEPABanking77.{Atomic, ObservedLM, Observer, Router}

  @routes ["R17", "R42", "R68", "R93"]
  @data_sha256 "1703f59bf336df8dc35590275531b67bb6ee43a5d0c96eb44696c219af5cfc18"
  @ollama_model "llama3.2:3b"
  @ollama_digest "a80c4f17acd55265feec403c7aef86be0c25983ab279d83f3bcd3abbcb5b8b72"

  def run do
    if System.get_env("IMP_GEPA_FRESH") == "1", do: fresh(), else: parent()
  end

  defp parent do
    paths = paths!()
    {job, rows} = preflight!(paths)
    observer = observer!()

    try do
      {analyzer_lm, reflection_lm, classifier_lm} = local_lms!(job, observer)
      baseline = Router.new(analyzer_lm, classifier_lm)
      Observer.phase(observer, "optimization")

      {selected, report, artifact} =
        GEPA.new(metric(),
          reflection_lm: reflection_lm,
          generations: 1,
          module_selector: :all,
          minibatch_size: 4,
          seed: 0,
          use_merge: false,
          num_threads: 1,
          timeout: 120_000,
          proposal_timeout: 120_000,
          max_metric_calls: 64,
          max_full_evaluations: 3,
          max_reflection_calls: 2,
          raise_on_exception: false
        )
        |> GEPA.compile_with_artifact(
          baseline,
          examples(rows.train),
          examples(rows.selection),
          artifact_id: "local-gepa-banking77-selected",
          provenance: %{
            dataset_sha256: @data_sha256,
            train_ids: Enum.map(rows.train, & &1["id"]),
            selection_ids: Enum.map(rows.selection, & &1["id"]),
            fused_artifact: job.result_model
          }
        )

      artifact_path = Path.join(paths.output, "selected-parameters.json")
      :ok = Artifact.write!(artifact, artifact_path)
      optimization = optimization_stage(baseline, selected, report, observer, artifact_path, job)
      Atomic.write!(Path.join(paths.output, "01-optimization.json"), optimization)
      require_completed_proposal!(optimization)

      baseline_test = evaluate_stage(baseline, rows.test, observer, "baseline_test")
      Atomic.write!(Path.join(paths.output, "02-baseline-test.json"), baseline_test)

      selected_test = evaluate_stage(selected, rows.test, observer, "selected_test")
      require_instruction_use!(selected_test, selected)
      Atomic.write!(Path.join(paths.output, "03-selected-test.json"), selected_test)

      :ok = TrainingJob.save!(job, Path.join(paths.output, "training-job.json"))
      :ok = MLXLMDeployment.stop(job)

      fresh_path = Path.join(paths.output, "04-fresh-test.json")
      {output, status} = fresh_process(paths, artifact_path, fresh_path)
      if status != 0, do: raise("fresh OS BEAM failed: #{output}")
      fresh_test = fresh_path |> File.read!() |> Jason.decode!()

      unless fresh_test["reproduction_sha256"] == selected_test.reproduction_sha256,
        do: raise("fresh selected predictions/errors differ")

      unless fresh_test["artifact_identity"] == job.result_model,
        do: raise("fresh process served a different artifact")

      result = %{
        status: "complete",
        artifact_identity: job.result_model,
        selected_parameters_sha256: sha256_file(artifact_path),
        selection_score: report.best_score,
        baseline_test: Map.take(baseline_test, [:accuracy, :macro_f1, :errors]),
        selected_test: Map.take(selected_test, [:accuracy, :macro_f1, :errors]),
        fresh_byte_identical: true,
        instructions: instructions(selected)
      }

      Atomic.write!(Path.join(paths.output, "result.json"), result)
      IO.puts(Jason.encode!(result, pretty: true))
    after
      MLXLMDeployment.stop(job)
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
    {job, rows} = preflight!(paths)
    observer = observer!()

    try do
      {analyzer_lm, _reflection_lm, classifier_lm} = local_lms!(job, observer)

      selected =
        System.fetch_env!("IMP_GEPA_ARTIFACT")
        |> Artifact.read!()
        |> Artifact.apply(Router.new(analyzer_lm, classifier_lm))

      stage = evaluate_stage(selected, rows.test, observer, "fresh_selected_test")
      require_instruction_use!(stage, selected)

      Atomic.write!(System.fetch_env!("IMP_GEPA_FRESH_OUTPUT"), %{
        status: "complete",
        artifact_identity: job.result_model,
        rows: stage.rows,
        accuracy: stage.accuracy,
        macro_f1: stage.macro_f1,
        errors: stage.errors,
        instructions: instructions(selected),
        reproduction_sha256: stage.reproduction_sha256
      })
    after
      MLXLMDeployment.stop(job)
      :telemetry.detach({__MODULE__, self()})
    end
  end

  defp preflight!(paths) do
    unless sha256_file(paths.data) == @data_sha256, do: raise("Banking77 data digest drift")
    verify_ollama!()
    job = TrainingJob.read!(paths.job)
    {:ok, _manifest} = Imp.Clients.MLXLMTrainer.verify_job(job)
    rows = split_rows!(paths.data)

    Atomic.write!(Path.join(paths.output, "00-preflight.json"), %{
      status: "complete",
      data_sha256: @data_sha256,
      train_ids: Enum.map(rows.train, & &1["id"]),
      selection_ids: Enum.map(rows.selection, & &1["id"]),
      test_ids: Enum.map(rows.test, & &1["id"]),
      ollama_model: @ollama_model,
      ollama_digest: @ollama_digest,
      fused_artifact: job.result_model,
      fused_artifact_sha256: job.metadata[:artifact_sha256]
    })

    {job, rows}
  end

  defp local_lms!(job, observer) do
    analyzer = observed(ollama_lm(128), observer, :analyzer)
    reflection = observed(ollama_lm(768), observer, :reflection)

    source =
      Imp.predict(
        Imp.signature(
          "utterance, evidence -> route: enum[R17,R42,R68,R93]",
          "Choose exactly one opaque route code from the utterance and evidence."
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
    classifier = rebound.lm |> observed(observer, :classifier)
    {analyzer, reflection, classifier}
  end

  defp ollama_lm(max_tokens) do
    Imp.req_llm("ollama:" <> @ollama_model,
      cache: false,
      temperature: 0,
      max_tokens: max_tokens,
      max_retries: 0,
      timeout: 120_000,
      req_http_options: [retry: false, max_retries: 0]
    )
  end

  defp observed(inner, observer, role),
    do: %ObservedLM{inner: inner, observer: observer, role: role}

  defp metric do
    fn example, prediction ->
      expected = Imp.Example.get(example, :route)

      actual =
        if match?(%Imp.Prediction{}, prediction), do: Imp.Prediction.get(prediction, :route)

      correct? = actual == expected

      %{
        score: if(correct?, do: 1.0, else: 0.0),
        feedback:
          if(correct?,
            do: "The route is correct.",
            else:
              "Expected #{expected}; received #{inspect(actual)}. Improve the named instructions."
          )
      }
    end
  end

  defp optimization_stage(baseline, selected, report, observer, artifact_path, job) do
    baseline_row = Enum.find(report.candidates, &(&1.mutation == "baseline"))
    snapshot = Observer.snapshot(observer)

    %{
      status: "complete",
      baseline_score: baseline_row && baseline_row.score,
      selected_score: report.best_score,
      candidate_count: report.candidate_count,
      metric_calls: report.metadata.metric_calls,
      reflection_calls: report.metadata.reflection_calls,
      baseline_instructions: instructions(baseline),
      selected_instructions: instructions(selected),
      artifact_path: artifact_path,
      artifact_identity: job.result_model,
      logical_calls: Enum.count(snapshot.calls, &(&1.phase == "optimization")),
      transport_attempts: Enum.count(snapshot.transports, &(&1.phase == "optimization"))
    }
  end

  defp require_completed_proposal!(stage) do
    unless stage.reflection_calls == 2 and stage.logical_calls == stage.transport_attempts do
      raise "GEPA did not complete the one declared two-component proposal: #{inspect(stage)}"
    end
  end

  defp evaluate_stage(program, rows, observer, phase) do
    before = Observer.snapshot(observer)
    Observer.phase(observer, phase)

    results =
      Enum.map(rows, fn row ->
        case Imp.call(program, %{utterance: row["utterance"]}) do
          {:ok, prediction} ->
            actual = Imp.Prediction.get(prediction, :route)
            %{id: row["id"], expected: row["route"], actual: actual, error: nil}

          {:error, reason} ->
            %{id: row["id"], expected: row["route"], actual: nil, error: inspect(reason)}
        end
      end)

    after_snapshot = Observer.snapshot(observer)
    calls = Enum.drop(after_snapshot.calls, length(before.calls))
    transports = Enum.drop(after_snapshot.transports, length(before.transports))
    if length(calls) != length(transports), do: raise("#{phase} call/transport mismatch")

    %{
      status: "complete",
      phase: phase,
      rows: results,
      accuracy: Enum.count(results, &(&1.actual == &1.expected)) / length(results),
      macro_f1: macro_f1(results),
      errors: Enum.count(results, &(not is_nil(&1.error))),
      logical_calls: length(calls),
      transport_attempts: length(transports),
      rendered_instructions: rendered_instruction_counts(program, calls),
      reproduction_sha256: sha256_term(Enum.map(results, &Map.take(&1, [:id, :actual, :error])))
    }
  end

  defp require_instruction_use!(stage, program) do
    Enum.each(Imp.ProgramParameters.predictors(program), fn %{name: name} ->
      unless Map.fetch!(stage.rendered_instructions, Atom.to_string(name)) > 0,
        do: raise("#{name} selected instruction was not rendered")
    end)
  end

  defp rendered_instruction_counts(program, calls) do
    Map.new(Imp.ProgramParameters.predictors(program), fn %{name: name, predictor: predictor} ->
      count =
        Enum.count(calls, fn call ->
          call.role == role(name) and
            Imp.Adapter.Instructions.rendered_objective?(
              predictor.signature.instructions,
              call.messages
            )
        end)

      {Atom.to_string(name), count}
    end)
  end

  defp role(:analyze_intent), do: :analyzer
  defp role(:classify_route), do: :classifier

  defp examples(rows) do
    Enum.map(rows, fn row ->
      Imp.Example.new(%{utterance: row["utterance"], route: row["route"]})
      |> Imp.Example.with_inputs([:utterance])
    end)
  end

  defp split_rows!(path) do
    data = path |> File.read!() |> Jason.decode!()
    grouped = Enum.group_by(data["train"], & &1["route"])
    train = Enum.flat_map(@routes, &(grouped[&1] |> Enum.take(4)))
    selection = Enum.flat_map(@routes, &(grouped[&1] |> Enum.slice(4, 2)))
    test = data["held_out"]
    ids = Enum.map(train ++ selection ++ test, & &1["id"])
    if length(ids) != 64 or length(Enum.uniq(ids)) != 64, do: raise("split overlap or drift")
    %{train: train, selection: selection, test: test}
  end

  defp instructions(program) do
    Map.new(Imp.ProgramParameters.predictors(program), fn %{name: name, predictor: predictor} ->
      {Atom.to_string(name), predictor.signature.instructions}
    end)
  end

  defp macro_f1(rows) do
    @routes
    |> Enum.map(fn route ->
      tp = Enum.count(rows, &(&1.expected == route and &1.actual == route))
      fp = Enum.count(rows, &(&1.expected != route and &1.actual == route))
      fn_count = Enum.count(rows, &(&1.expected == route and &1.actual != route))
      denominator = 2 * tp + fp + fn_count
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
        fn _event, _measurements, metadata, target -> Observer.transport(target, metadata) end,
        observer
      )

    observer
  end

  defp verify_ollama! do
    models = Req.get!("http://127.0.0.1:11434/api/tags", retry: false).body["models"]

    unless Enum.any?(models, &(&1["name"] == @ollama_model and &1["digest"] == @ollama_digest)),
      do: raise("pinned Ollama model is absent or changed")
  end

  defp fresh_process(paths, artifact_path, output_path) do
    System.cmd("mix", ["run", "--no-compile", "--no-deps-check", __ENV__.file],
      cd: paths.imp,
      env: [
        {"MIX_ENV", "dev"},
        {"IMP_PATH", paths.imp},
        {"IMP_MLX_JOB", Path.join(paths.output, "training-job.json")},
        {"IMP_BANKING77_DATA", paths.data},
        {"IMP_GEPA_OUTPUT", paths.output},
        {"IMP_GEPA_FRESH", "1"},
        {"IMP_GEPA_ARTIFACT", artifact_path},
        {"IMP_GEPA_FRESH_OUTPUT", output_path}
      ],
      stderr_to_stdout: true
    )
  end

  defp paths! do
    imp = System.get_env("IMP_PATH", Path.expand("../..", __DIR__)) |> Path.expand()

    %{
      imp: imp,
      job: System.fetch_env!("IMP_MLX_JOB") |> Path.expand(),
      data:
        System.get_env(
          "IMP_BANKING77_DATA",
          Path.join(imp, "benchmarks/data/provider-training-banking77-v1.json")
        )
        |> Path.expand(),
      output: System.get_env("IMP_GEPA_OUTPUT", "/tmp/imp-local-gepa-banking77") |> Path.expand()
    }
  end

  defp sha256_file(path), do: path |> File.read!() |> sha256()
  defp sha256_term(term), do: term |> Jason.encode!() |> sha256()
  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end

unless System.get_env("IMP_GEPA_DEFINE_ONLY") == "1" do
  LocalGEPABanking77.Runner.run()
end
