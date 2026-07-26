defmodule LocalSIMBABanking77.Atomic do
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

defmodule LocalSIMBABanking77.Observer do
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

defmodule LocalSIMBABanking77.ObservedLM do
  defstruct [:inner, :observer, :role]

  def generate(lm, messages, opts) do
    LocalSIMBABanking77.Observer.call(lm.observer, lm.role, messages)
    Imp.LM.generate(lm.inner, messages, opts)
  end

  def response_format_capability(%__MODULE__{inner: inner}),
    do: Imp.LM.response_format_capability(inner)
end

defmodule LocalSIMBABanking77.Runner do
  alias Imp.Clients.{MLXLMDeployment, TrainingJob}
  alias Imp.Optimizer.{Artifact, Report, SIMBA}
  alias LocalSIMBABanking77.{Atomic, ObservedLM, Observer}

  @routes ["R17", "R42", "R68", "R93"]
  @data_sha256 "1703f59bf336df8dc35590275531b67bb6ee43a5d0c96eb44696c219af5cfc18"
  @ollama_model "llama3.2:3b"
  @ollama_digest "a80c4f17acd55265feec403c7aef86be0c25983ab279d83f3bcd3abbcb5b8b72"

  def run, do: if(System.get_env("IMP_SIMBA_FRESH") == "1", do: fresh(), else: parent())

  defp parent do
    paths = paths!()
    {job, rows} = preflight!(paths)
    observer = observer!()

    try do
      baseline = program!(job, observer)
      Observer.phase(observer, "optimization")

      selected =
        SIMBA.new(metric(),
          bsize: 4,
          num_candidates: 2,
          max_steps: 1,
          max_demos: 4,
          prompt_lm: observed(ollama_lm(), observer, :reflection),
          max_concurrency: 1,
          timeout: 120_000,
          seed: 23
        )
        |> SIMBA.compile(baseline, examples(rows.train), examples(rows.selection))

      report = Report.fetch(selected)
      artifact = Artifact.from_optimized_program(selected, artifact_id: "local-simba-banking77")
      artifact_path = Path.join(paths.output, "selected-parameters.json")
      :ok = Artifact.write!(artifact, artifact_path)

      optimization = optimization_stage(baseline, selected, report, observer, job)
      Atomic.write!(Path.join(paths.output, "01-optimization.json"), optimization)
      require_search!(optimization)

      Observer.phase(observer, "baseline_test")
      baseline_test = evaluate(baseline, rows.test, observer, "baseline_test")
      Atomic.write!(Path.join(paths.output, "02-baseline-test.json"), baseline_test)
      require_test!(baseline_test)

      Observer.phase(observer, "selected_test")
      selected_test = evaluate(selected, rows.test, observer, "selected_test")
      Atomic.write!(Path.join(paths.output, "03-selected-test.json"), selected_test)
      require_test!(selected_test)

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
        scope: "one local SIMBA Banking77 program lifecycle",
        split_sizes: %{train: 16, selection: 8, untouched_test: 40},
        task_artifact: job.result_model,
        search: %{
          baseline_score: optimization.baseline_score,
          selected_score: optimization.selected_score,
          selected: optimization.selected,
          candidate_count: optimization.candidate_count,
          mutated_candidates: optimization.mutated_candidates,
          task_transports: optimization.task_transports,
          reflection_transports: optimization.reflection_transports
        },
        untouched_test: %{
          baseline: Map.take(baseline_test, [:accuracy, :macro_f1, :errors]),
          selected: Map.take(selected_test, [:accuracy, :macro_f1, :errors])
        },
        fresh_process: %{byte_identical: true, logical_calls: fresh_test["logical_calls"]},
        claim_boundary:
          "Operational mutation, validation selection, artifact application, and fresh consumption on one task/model; not general SIMBA effectiveness, DSPy parity, or BEAM superiority."
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
      selected =
        System.fetch_env!("IMP_SIMBA_ARTIFACT")
        |> Artifact.read!()
        |> Artifact.apply(program!(job, observer))

      Observer.phase(observer, "fresh_selected_test")
      stage = evaluate(selected, rows.test, observer, "fresh_selected_test")

      Atomic.write!(
        System.fetch_env!("IMP_SIMBA_FRESH_OUTPUT"),
        Map.merge(stage, %{artifact_identity: job.result_model})
      )

      require_test!(stage)
    after
      MLXLMDeployment.stop(job)
      :telemetry.detach({__MODULE__, self()})
    end
  end

  defp preflight!(paths) do
    unless sha256_file(paths.data) == @data_sha256, do: raise("Banking77 data digest drift")
    verify_ollama!()
    job = TrainingJob.load!(paths.job)
    {:ok, _manifest} = Imp.Clients.MLXLMTrainer.verify_job(job)
    rows = split_rows!(paths.data)

    Atomic.write!(Path.join(paths.output, "00-preflight.json"), %{
      status: "complete",
      data_sha256: @data_sha256,
      train_ids: Enum.map(rows.train, & &1["id"]),
      selection_ids: Enum.map(rows.selection, & &1["id"]),
      test_ids: Enum.map(rows.test, & &1["id"]),
      artifact_identity: job.result_model,
      artifact_sha256: job.metadata[:artifact_sha256],
      ollama_model: @ollama_model,
      ollama_digest: @ollama_digest
    })

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
    Imp.Predict.Predict.with_lm(rebound, observed(Imp.ProgramAccess.lm(rebound), observer, :task))
  end

  defp ollama_lm do
    Imp.req_llm("ollama:" <> @ollama_model,
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

  defp metric,
    do: fn example, prediction ->
      Imp.Example.get(example, :route) == Imp.Prediction.get(prediction, :route)
    end

  defp optimization_stage(baseline, selected, report, observer, job) do
    snapshot = Observer.snapshot(observer)
    baseline_instruction = baseline.signature.instructions

    mutated_candidates =
      report.metadata.final_candidates
      |> Enum.count(fn candidate ->
        candidate.finalist_index > 0 and
          Enum.any?(candidate.parameters, fn parameter ->
            parameter.name == :main and parameter.instruction != baseline_instruction
          end)
      end)

    task_calls = Enum.filter(snapshot.calls, &(&1.phase == "optimization" and &1.role == :task))

    rendered_mutation_calls =
      Enum.count(task_calls, fn call ->
        Enum.any?(report.metadata.final_candidates, fn candidate ->
          candidate.finalist_index > 0 and
            candidate_parameters_rendered?(candidate, call.messages, baseline_instruction)
        end)
      end)

    %{
      status: "complete",
      artifact_identity: job.result_model,
      baseline_score: report.metadata.baseline_score,
      selected_score: report.best_score,
      selected:
        if(selected.signature.instructions == baseline_instruction,
          do: "baseline",
          else: "mutated"
        ),
      baseline_instruction: baseline_instruction,
      selected_instruction: selected.signature.instructions,
      candidate_count: report.candidate_count,
      mutated_candidates: mutated_candidates,
      rendered_mutation_calls: rendered_mutation_calls,
      task_transports:
        Enum.count(snapshot.transports, &(&1.phase == "optimization")) -
          Enum.count(snapshot.calls, &(&1.phase == "optimization" and &1.role == :reflection)),
      reflection_transports:
        Enum.count(snapshot.calls, &(&1.phase == "optimization" and &1.role == :reflection)),
      report: Report.json_safe(report)
    }
  end

  defp candidate_parameters_rendered?(candidate, messages, baseline_instruction) do
    parameter = Enum.find(candidate.parameters, &(&1.name == :main))

    case parameter do
      %{instruction: instruction}
      when is_binary(instruction) and instruction != baseline_instruction ->
        Imp.Adapter.Instructions.rendered_objective?(instruction, messages)

      %{demos: [_ | _]} ->
        length(messages) >= 4 and
          Enum.any?(messages, &(Map.get(&1, :role) == :assistant))

      _ ->
        false
    end
  end

  defp require_search!(stage) do
    unless stage.candidate_count > 0 and stage.mutated_candidates > 0 and
             stage.rendered_mutation_calls > 0 and stage.task_transports > 0 and
             stage.reflection_transports > 0,
           do: raise("SIMBA did not execute a real rendered mutation: #{inspect(stage)}")
  end

  defp evaluate(program, rows, observer, phase) do
    before = Observer.snapshot(observer)

    results =
      Enum.map(rows, fn row ->
        case Imp.call(program, %{utterance: row["utterance"]}) do
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

    snapshot = Observer.snapshot(observer)
    calls = Enum.drop(snapshot.calls, length(before.calls))
    transports = Enum.drop(snapshot.transports, length(before.transports))

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

  defp require_test!(stage) do
    unless stage.logical_calls == 40 and stage.transport_attempts == 40,
      do: raise("#{stage.phase} did not make one fresh task transport per row")
  end

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
        {"IMP_SIMBA_OUTPUT", paths.output},
        {"IMP_SIMBA_FRESH", "1"},
        {"IMP_SIMBA_ARTIFACT", artifact_path},
        {"IMP_SIMBA_FRESH_OUTPUT", output_path}
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
      output:
        System.get_env("IMP_SIMBA_OUTPUT", "/tmp/imp-local-simba-banking77") |> Path.expand()
    }
  end

  defp sha256_file(path), do: path |> File.read!() |> sha256()
  defp sha256_term(term), do: term |> Jason.encode!() |> sha256()
  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end

unless System.get_env("IMP_SIMBA_DEFINE_ONLY") == "1" do
  LocalSIMBABanking77.Runner.run()
end
