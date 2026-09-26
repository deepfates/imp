defmodule LocalCOPROBanking77.Atomic do
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

defmodule LocalCOPROBanking77.Observer do
  def start_link,
    do: Agent.start_link(fn -> %{phase: "startup", calls: [], responses: [], transports: []} end)

  def phase(pid, phase), do: Agent.update(pid, &%{&1 | phase: phase})

  def call(pid, role, messages) do
    Agent.update(pid, fn state ->
      entry = %{phase: state.phase, role: role, messages: messages}
      %{state | calls: [entry | state.calls]}
    end)
  end

  def response(pid, role, result) do
    value =
      case Imp.LM.Result.unwrap(result) do
        {:ok, output} -> output
        {:error, reason} -> %{error: inspect(reason)}
      end

    Agent.update(pid, fn state ->
      entry = %{phase: state.phase, role: role, value: value}
      %{state | responses: [entry | state.responses]}
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
      %{
        state
        | calls: Enum.reverse(state.calls),
          responses: Enum.reverse(state.responses),
          transports: Enum.reverse(state.transports)
      }
    end)
  end
end

defmodule LocalCOPROBanking77.ObservedLM do
  defstruct [:inner, :observer, :role]

  def generate(lm, messages, opts) do
    LocalCOPROBanking77.Observer.call(lm.observer, lm.role, messages)
    result = Imp.LM.generate(lm.inner, messages, opts)
    LocalCOPROBanking77.Observer.response(lm.observer, lm.role, result)
    result
  end

  def response_format_capability(%__MODULE__{inner: inner}),
    do: Imp.LM.response_format_capability(inner)
end

defmodule LocalCOPROBanking77.Runner do
  alias Imp.Clients.{MLXLMDeployment, TrainingJob}
  alias Imp.Optimizer.{Artifact, COPRO, InstructionSearch, Report}
  alias LocalCOPROBanking77.{Atomic, ObservedLM, Observer}

  @routes ["R17", "R42", "R68", "R93"]
  @treatment_id "local-copro-banking77-objective-correct-v2"
  @data_sha256 "1703f59bf336df8dc35590275531b67bb6ee43a5d0c96eb44696c219af5cfc18"
  @ollama_model "llama3.2:3b"
  @ollama_digest "a80c4f17acd55265feec403c7aef86be0c25983ab279d83f3bcd3abbcb5b8b72"

  def run, do: if(System.get_env("IMP_COPRO_FRESH") == "1", do: fresh(), else: parent())

  defp parent do
    paths = paths!()
    {job, rows} = preflight!(paths, true)
    observer = observer!()

    try do
      baseline = program!(job, observer)
      proposer = observed(ollama_lm(), observer, :proposal)
      Observer.phase(observer, "optimization")

      selected =
        COPRO.new(metric(),
          breadth: 2,
          depth: 1,
          init_temperature: 0,
          proposer_lm: proposer,
          proposal_concurrency: 1,
          proposal_response_format: :required
        )
        |> then(
          &Imp.optimize!(baseline, &1, examples(rows.train), num_threads: 1, max_errors: :infinity)
        )

      report = Report.fetch(selected)
      optimization = optimization_stage(baseline, selected, report, observer, job)
      Atomic.write!(Path.join(paths.output, "01-optimization.json"), optimization)
      require_optimization!(optimization)

      artifact = Artifact.from_optimized_program(selected, artifact_id: "local-copro-banking77")
      artifact_path = Path.join(paths.output, "selected-parameters.json")
      :ok = Artifact.write!(artifact, artifact_path)

      baseline_test = evaluate_stage(baseline, rows.test, observer, "baseline_heldout")
      Atomic.write!(Path.join(paths.output, "02-baseline-heldout.json"), baseline_test)
      require_test_stage!(baseline_test, baseline)

      selected_test = evaluate_stage(selected, rows.test, observer, "selected_heldout")
      Atomic.write!(Path.join(paths.output, "03-selected-heldout.json"), selected_test)
      require_test_stage!(selected_test, selected)

      :ok = TrainingJob.save!(job, Path.join(paths.output, "training-job.json"))
      :ok = MLXLMDeployment.stop(job)

      fresh_path = Path.join(paths.output, "04-fresh-heldout.json")
      {output, status} = fresh_process(paths, artifact_path, fresh_path)
      if status != 0, do: raise("fresh OS BEAM failed: #{output}")
      fresh_test = fresh_path |> File.read!() |> Jason.decode!()

      unless fresh_test["reproduction_sha256"] == selected_test.reproduction_sha256,
        do: raise("fresh selected predictions/errors differ")

      unless fresh_test["artifact_identity"] == job.result_model,
        do: raise("fresh process served a different artifact")

      result = %{
        status: "complete",
        treatment_id: @treatment_id,
        split_sizes: %{train_and_selection: 16, optimizer_heldout_test: 40},
        selection_dataset: "trainset",
        task_artifact: job.result_model,
        proposer_model: "ollama:" <> @ollama_model,
        search:
          Map.take(optimization, [
            :baseline_score,
            :candidate_score,
            :selected,
            :candidate_instruction
          ]),
        optimizer_heldout_test: %{
          baseline: Map.take(baseline_test, [:accuracy, :macro_f1, :errors]),
          selected: Map.take(selected_test, [:accuracy, :macro_f1, :errors])
        },
        selected_parameters_sha256: sha256_file(artifact_path),
        fresh_process: %{
          byte_identical: true,
          logical_calls: fresh_test["logical_calls"],
          transport_attempts: fresh_test["transport_attempts"]
        },
        claim_boundary:
          "One task/model run exercises a natural COPRO proposal, trainset selection, a parameter artifact, and fresh-process consumption; not general effectiveness, whole-optimizer parity, or BEAM superiority."
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
    {job, rows} = preflight!(paths, false)
    observer = observer!()

    try do
      selected =
        System.fetch_env!("IMP_COPRO_ARTIFACT")
        |> Artifact.read!()
        |> Artifact.apply(program!(job, observer))

      stage = evaluate_stage(selected, rows.test, observer, "fresh_selected_heldout")

      Atomic.write!(
        System.fetch_env!("IMP_COPRO_FRESH_OUTPUT"),
        Map.merge(stage, %{artifact_identity: job.result_model})
      )

      require_test_stage!(stage, selected)
    after
      MLXLMDeployment.stop(job)
      :telemetry.detach({__MODULE__, self()})
    end
  end

  defp preflight!(paths, verify_proposer?) do
    unless sha256_file(paths.data) == @data_sha256, do: raise("Banking77 data digest drift")
    if verify_proposer?, do: verify_ollama!()
    job = TrainingJob.read!(paths.job)
    {:ok, _manifest} = Imp.Clients.MLXLMTrainer.verify_job(job)
    rows = split_rows!(paths.data)

    Atomic.write!(Path.join(paths.output, "00-preflight.json"), %{
      status: "complete",
      treatment_id: @treatment_id,
      data_sha256: @data_sha256,
      train_ids: Enum.map(rows.train, & &1["id"]),
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
    Imp.Predict.with_lm(rebound, observed(rebound.lm, observer, :task))
  end

  defp ollama_lm do
    Imp.req_llm("ollama:" <> @ollama_model,
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

  defp metric,
    do: fn example, prediction ->
      Imp.Example.get(example, :route) == Imp.Prediction.get(prediction, :route)
    end

  defp optimization_stage(baseline, selected, report, observer, job) do
    snapshot = Observer.snapshot(observer)
    calls = Enum.filter(snapshot.calls, &(&1.phase == "optimization"))
    responses = Enum.filter(snapshot.responses, &(&1.phase == "optimization"))
    transports = Enum.filter(snapshot.transports, &(&1.phase == "optimization"))
    baseline_instruction = InstructionSearch.current_instruction(baseline)
    selected_instruction = InstructionSearch.current_instruction(selected)
    task_calls = Enum.filter(calls, &(&1.role == :task))
    proposer_responses = responses |> Enum.filter(&(&1.role == :proposal)) |> Enum.map(& &1.value)
    proposed_pair = proposal_pair(proposer_responses)

    candidate_record =
      case proposed_pair do
        {instruction, prefix} ->
          Enum.find(
            report.candidates,
            &(&1.instruction == instruction and &1.prefix == prefix)
          )

        nil ->
          nil
      end

    baseline_record = Enum.find(report.candidates, &(&1 != candidate_record))
    candidate_instruction = candidate_record && candidate_record.instruction

    %{
      status: "complete",
      artifact_identity: job.result_model,
      evaluation_dataset: report.metadata.evaluation_dataset,
      proposal_mode: report.metadata.proposal_mode,
      baseline_score: baseline_record && baseline_record.score,
      candidate_score: candidate_record && candidate_record.score,
      candidate_instruction: candidate_instruction,
      selected:
        if(selected_instruction == baseline_instruction, do: "baseline", else: "candidate"),
      selected_instruction: selected_instruction,
      proposer_calls: Enum.count(calls, &(&1.role == :proposal)),
      valid_json_proposal: not is_nil(proposed_pair) and not is_nil(candidate_record),
      prompt_mutated: candidate_instruction != baseline_instruction,
      candidate_rendered_calls:
        Enum.count(task_calls, fn call ->
          is_binary(candidate_instruction) and
            Imp.Adapter.Instructions.rendered_objective?(candidate_instruction, call.messages)
        end),
      task_calls: length(task_calls),
      logical_calls: length(calls),
      transport_attempts: length(transports),
      report: Report.json_safe(report)
    }
  end

  defp proposal_pair([raw]) do
    case proposal_values(raw) do
      [value] -> proposal_value(value)
      _other -> nil
    end
  end

  defp proposal_pair(_responses), do: nil

  defp proposal_values(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, value} when is_list(value) ->
        value

      {:ok, value} when is_map(value) ->
        [value]

      _error ->
        case Regex.run(~r/```(?:json)?\s*\n(.*?)```/is, raw, capture: :all_but_first) do
          [candidate] -> proposal_values(String.trim(candidate))
          nil -> []
        end
    end
  end

  defp proposal_values(raw) when is_list(raw), do: raw
  defp proposal_values(raw) when is_map(raw), do: [raw]
  defp proposal_values(_raw), do: []

  defp proposal_value(value) when is_map(value) do
    instruction = value["proposed_instruction"] || value[:proposed_instruction]
    prefix = value["proposed_prefix_for_output_field"] || value[:proposed_prefix_for_output_field]

    if is_binary(instruction) and is_binary(prefix),
      do: {String.trim(instruction), String.trim(prefix)},
      else: nil
  end

  defp proposal_value(_value), do: nil

  defp require_optimization!(stage) do
    valid =
      stage.evaluation_dataset == :trainset and stage.proposal_mode == :language_model and
        stage.proposer_calls == 1 and stage.valid_json_proposal and
        is_number(stage.baseline_score) and is_number(stage.candidate_score) and
        stage.prompt_mutated and stage.candidate_rendered_calls == 16 and stage.task_calls == 32 and
        stage.logical_calls == 33 and stage.transport_attempts == 33

    unless valid,
      do: raise("COPRO did not complete the declared natural trainset search: #{inspect(stage)}")
  end

  defp evaluate_stage(program, rows, observer, phase) do
    before = Observer.snapshot(observer)
    Observer.phase(observer, phase)

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

    snapshot = Observer.snapshot(observer)
    calls = Enum.drop(snapshot.calls, length(before.calls))
    transports = Enum.drop(snapshot.transports, length(before.transports))
    instruction = InstructionSearch.current_instruction(program)

    %{
      status: "complete",
      phase: phase,
      rows: results,
      accuracy: Enum.count(results, &(&1.actual == &1.expected)) / length(results),
      macro_f1: macro_f1(results),
      errors: Enum.count(results, &(not is_nil(&1.error))),
      logical_calls: length(calls),
      transport_attempts: length(transports),
      rendered_instruction_count:
        Enum.count(calls, &Imp.Adapter.Instructions.rendered_objective?(instruction, &1.messages)),
      reproduction_sha256: sha256_term(Enum.map(results, &Map.take(&1, [:id, :actual, :error])))
    }
  end

  defp require_test_stage!(stage, _program) do
    unless stage.logical_calls == 40 and stage.transport_attempts == 40 and
             stage.rendered_instruction_count == 40,
           do: raise("#{stage.phase} did not make one rendered task transport per row")
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
    test = data["held_out"]
    ids = Enum.map(train ++ test, & &1["id"])
    if length(ids) != 56 or length(Enum.uniq(ids)) != 56, do: raise("split overlap or drift")
    %{train: train, test: test}
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
        {"IMP_COPRO_OUTPUT", paths.output},
        {"IMP_COPRO_FRESH", "1"},
        {"IMP_COPRO_ARTIFACT", artifact_path},
        {"IMP_COPRO_FRESH_OUTPUT", output_path}
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
        System.get_env("IMP_COPRO_OUTPUT", "/tmp/imp-local-copro-banking77") |> Path.expand()
    }
  end

  defp sha256_file(path), do: path |> File.read!() |> sha256()
  defp sha256_term(term), do: term |> Jason.encode!() |> sha256()
  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end

unless System.get_env("IMP_COPRO_DEFINE_ONLY") == "1" do
  LocalCOPROBanking77.Runner.run()
end
