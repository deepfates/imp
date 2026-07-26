Code.require_file("contract.exs", __DIR__)
Code.require_file("two_phase.exs", __DIR__)
Code.require_file("source_identity.exs", __DIR__)

defmodule MatchedTRECImp.Observer do
  def start_link, do: Agent.start_link(fn -> %{phase: nil, messages: [], transports: []} end)
  def phase(pid, value), do: Agent.update(pid, &%{&1 | phase: value})

  def message(pid, role, messages) do
    Agent.update(pid, fn state ->
      entry = %{phase: state.phase, role: role, messages: messages}
      %{state | messages: state.messages ++ [entry]}
    end)
  end

  def transport(pid, measurements, metadata) do
    Agent.update(pid, fn state ->
      entry = %{
        phase: state.phase,
        measurements: measurements,
        metadata: metadata
      }

      %{state | transports: state.transports ++ [entry]}
    end)
  end

  def snapshot(pid), do: Agent.get(pid, & &1)
end

defmodule MatchedTRECImp.ObservedLM do
  defstruct [:inner, :observer, :role]

  def generate(lm, messages, opts) do
    MatchedTRECImp.Observer.message(lm.observer, lm.role, messages)
    Imp.LM.generate(lm.inner, messages, opts)
  end

  def response_format_capability(%__MODULE__{inner: inner}),
    do: Imp.LM.response_format_capability(inner)
end

defmodule MatchedTRECImp.Runner do
  alias Imp.Optimizer.{Artifact, GEPA, MIPROv2, Report}
  alias MatchedTRECImp.{ObservedLM, Observer}

  @manifest Path.expand("contract.json", __DIR__)
  @output Path.expand(
            System.get_env(
              "IMP_MATCHED_TREC_OUTPUT",
              "../../tmp/matched_instruction_optimizers_trec/imp-result.json"
            ),
            __DIR__
          )
  @selection_output @output <> ".selection-sealed.json"

  def run do
    manifest = MatchedInstructionOptimizersTREC.Contract.load_optimization!(@manifest)
    source_commits = source_commits!(manifest, true)
    verify_models!(manifest)
    # This first pass never decodes held-out lines. Their values cannot be reached by
    # optimizer, metric, selection, or any sealed program before every arm is sealed.
    rows = optimization_rows!(manifest)
    meanings = route_meanings!(manifest)
    {:ok, observer} = Observer.start_link()
    telemetry_id = {__MODULE__, self()}

    :ok =
      :telemetry.attach(
        telemetry_id,
        [:imp, :lm, :transport, :attempt],
        fn _event, measurements, metadata, target ->
          Observer.transport(target, measurements, metadata)
        end,
        observer
      )

    try do
      work_items = for seed <- manifest["seeds"], arm <- manifest["arms"], do: {seed, arm}

      {sealed, held_out} =
        MatchedInstructionOptimizersTREC.TwoPhase.seal_then_load_held_out!(
          work_items,
          &compile_and_seal(&1, manifest, rows, meanings, observer),
          fn selections ->
            atomic_write!(
              @selection_output,
              selection_receipt(manifest, source_commits, selections)
            )
          end,
          fn -> held_out_rows!(manifest) end
        )

      completed = evaluate_held_out(sealed, held_out, observer)

      result = %{
        schema_version: 1,
        runtime: "imp",
        status: "complete",
        manifest_sha256: manifest["manifest_sha256"],
        source_commits: source_commits,
        selection_receipt: @selection_output,
        seeds: completed,
        rendered_messages: Observer.snapshot(observer).messages,
        transport_events: Report.encode_term(Observer.snapshot(observer).transports),
        claim_boundary:
          "task/model-specific matched local evidence; not general parity or effectiveness"
      }

      atomic_write!(@output, result)
      IO.puts(Jason.encode!(result, pretty: true))
    after
      :telemetry.detach(telemetry_id)
    end
  rescue
    error ->
      atomic_write!(@output, %{
        schema_version: 1,
        runtime: "imp",
        status: "stopped",
        source_commits: source_commits_for_stopped_output(),
        error: Exception.format(:error, error, __STACKTRACE__)
      })

      reraise error, __STACKTRACE__
  end

  defp compile_and_seal({seed, arm}, manifest, rows, meanings, observer) do
    task_lm = observed(task_lm(manifest), observer, :task)
    optimizer_lm = observed(optimizer_lm(manifest), observer, :optimizer)
    baseline = program(task_lm)
    Observer.phase(observer, %{seed: seed, arm: arm, phase: "compile"})

    selected = compile(arm, baseline, rows, seed, optimizer_lm, task_lm, manifest, meanings)

    selection =
      evaluate(
        selected,
        rows.selection,
        observer,
        seed,
        arm,
        "selection",
        manifest["models"]["task"]
      )

    score = aggregate(selection)
    artifact_path = artifact_path(seed, arm)

    provenance = %{
      manifest_sha256: manifest["manifest_sha256"],
      source_commits: source_commits!(manifest, false),
      seed: seed,
      arm: arm
    }

    artifact =
      case Report.fetch(selected) do
        nil ->
          Artifact.parameter_candidate("#{seed}-#{arm}", selected,
            score: score.accuracy,
            metadata: %{runtime: "imp", seed: seed, arm: arm, split: "selection"}
          )
          |> Artifact.new([], provenance: provenance)

        _report ->
          Artifact.from_optimized_program(selected,
            artifact_id: "#{seed}-#{arm}",
            provenance: provenance
          )
      end

    Artifact.write!(artifact, artifact_path)

    %{
      seed: seed,
      arm: arm,
      program: selected,
      selection: score,
      selection_rows: selection,
      selected_parameters: parameter_snapshot(selected),
      optimizer_report: report_json(selected),
      artifact_path: artifact_path,
      artifact_sha256: sha256_file(artifact_path),
      artifact_payload_sha256: artifact["payload_sha256"],
      task_model: manifest["models"]["task"]
    }
  end

  defp selection_receipt(manifest, source_commits, sealed) do
    %{
      schema_version: 1,
      runtime: "imp",
      status: "selection_sealed",
      held_out_loaded: false,
      manifest_sha256: manifest["manifest_sha256"],
      source_commits: source_commits,
      selections: Enum.map(sealed, &Map.drop(&1, [:program]))
    }
  end

  defp evaluate_held_out(sealed, held_out, observer) do
    sealed
    |> Enum.group_by(& &1.seed)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {seed, entries} ->
      arms =
        Enum.map(entries, fn selected ->
          rows =
            evaluate(
              selected.program,
              held_out,
              observer,
              seed,
              selected.arm,
              "held_out",
              selected.task_model
            )

          selected
          |> Map.drop([:program, :selection_rows])
          |> Map.put(:rows, %{selection: selected.selection_rows, held_out: rows})
          |> Map.put(:held_out, aggregate(rows))
        end)

      %{seed: seed, arms: arms}
    end)
  end

  defp compile("baseline", program, _rows, _seed, _optimizer_lm, _task_lm, _manifest, _meanings),
    do: program

  defp compile("gepa", program, rows, seed, optimizer_lm, _task_lm, manifest, meanings) do
    config = manifest["optimizer"]["gepa"]

    GEPA.new(metric(meanings),
      reflection_lm: optimizer_lm,
      generations: config["iterations"],
      minibatch_size: config["minibatch_size"],
      seed: seed,
      candidate_selection_strategy: :pareto,
      module_selector: :round_robin,
      acceptance_policy: :strict_improvement,
      selection_strategy: :all_improvements,
      use_merge: false,
      max_concurrency: 1,
      timeout: 120_000,
      proposal_timeout: 120_000,
      max_reflection_calls: config["iterations"],
      raise_on_exception: true
    )
    |> GEPA.compile(program, examples(rows.train, true), examples(rows.selection, false))
  end

  defp compile("mipro_v2", program, rows, seed, optimizer_lm, task_lm, manifest, meanings) do
    config = manifest["optimizer"]["mipro_v2"]

    MIPROv2.new(scalar_metric(),
      auto: nil,
      num_candidates: config["instruction_candidates"],
      num_instruct_candidates: config["instruction_candidates"],
      num_fewshot_candidates: config["fewshot_candidates"],
      num_trials: config["trials"],
      minibatch: false,
      max_bootstrapped_demos: 0,
      max_labeled_demos: 0,
      startup_trials: config["startup_trials"],
      prompt_lm: optimizer_lm,
      task_lm: task_lm,
      max_concurrency: 1,
      timeout: 120_000,
      max_errors: 0,
      seed: seed
    )
    |> MIPROv2.compile(program, examples(rows.train, true), examples(rows.selection, false))
  end

  defp program(lm) do
    Imp.predict(
      Imp.signature(
        "text: string -> route: enum[K11,K47]",
        "Route the question to exactly one opaque code. Return only the required structured route."
      ),
      lm: lm,
      adapter: Imp.Adapter.Chat,
      config: [cache: false, json_fallback: false]
    )
  end

  defp metric(meanings) do
    fn example, prediction ->
      expected = Imp.Example.get(example, :route)
      actual = Imp.Prediction.get(prediction, :route)
      expected_meaning = meanings[expected]
      actual_meaning = meanings[actual] || "unknown service"
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
          metadata: %{expected_route: expected, predicted_route: actual}
        }
      else
        score
      end
    end
  end

  defp scalar_metric do
    fn example, prediction ->
      if Imp.Example.get(example, :route) == Imp.Prediction.get(prediction, :route),
        do: 1.0,
        else: 0.0
    end
  end

  defp examples(rows, feedback_allowed) do
    Enum.map(rows, fn row ->
      Imp.Example.new(%{
        text: row.text,
        route: row.route,
        feedback_allowed: feedback_allowed
      })
      |> Imp.Example.with_inputs([:text])
    end)
  end

  defp evaluate(program, rows, observer, seed, arm, phase, expected_model) do
    Observer.phase(observer, %{seed: seed, arm: arm, phase: phase})

    Enum.map(rows, fn row ->
      before = Observer.snapshot(observer)
      started = System.monotonic_time()
      result = Imp.call(program, %{text: row.text})
      after_call = Observer.snapshot(observer)
      messages = Enum.drop(after_call.messages, length(before.messages))
      transports = Enum.drop(after_call.transports, length(before.transports))

      {actual, error, metadata} =
        case result do
          {:ok, prediction} ->
            {Imp.Prediction.get(prediction, :route), nil, prediction.metadata}

          {:error, reason} ->
            {nil, reason, nil}
        end

      unless length(messages) == 1 and length(transports) == 1,
        do: raise("#{arm}/#{phase}/#{row.id} did not use exactly one logical/transport call")

      transport = hd(transports)
      req_llm = metadata && map_get(metadata, :req_llm)
      usage = req_llm && map_get(req_llm, :usage)
      actual_model = req_llm && map_get(req_llm, :model)
      actual_route = req_llm && map_get(req_llm, :provider)
      attempts = map_get(transport.measurements, :count)
      retry = map_get(transport.metadata, :retry)
      input_tokens = usage && (map_get(usage, :input_tokens) || map_get(usage, :prompt_tokens))

      output_tokens =
        usage && (map_get(usage, :output_tokens) || map_get(usage, :completion_tokens))

      finish_reason = req_llm && map_get(req_llm, :finish_reason)
      raw_response = req_llm && map_get(req_llm, :content)
      provider_cost = usage && (map_get(usage, :total_cost) || map_get(usage, :cost))

      cost =
        if is_number(provider_cost),
          do: %{value: provider_cost, authority: "provider_reported"},
          else: %{value: nil, authority: "local_ollama_no_billing", external_api_spend: 0}

      validate_transport_evidence!(
        %{
          model: actual_model,
          route: actual_route,
          attempts: attempts,
          retry: retry,
          input_tokens: input_tokens,
          output_tokens: output_tokens,
          finish_reason: finish_reason,
          content: raw_response,
          provider_cost: provider_cost
        },
        expected_model,
        "#{arm}/#{phase}/#{row.id}"
      )

      %{
        source_id: row.id,
        expected: row.route,
        parsed_route: actual,
        correct: actual == row.route,
        error: Report.encode_term(error),
        raw_response: raw_response,
        prediction_metadata: Report.encode_term(metadata),
        rendered_messages: hd(messages).messages,
        transport: Report.encode_term(transport),
        actual_model: actual_model,
        actual_route: actual_route,
        transport_attempts: attempts,
        input_tokens: input_tokens,
        output_tokens: output_tokens,
        finish_reason: finish_reason,
        cost: cost,
        wall_seconds: elapsed(started)
      }
    end)
  end

  defp aggregate(rows) do
    accuracy = Enum.count(rows, & &1.correct) / length(rows)

    %{
      accuracy: accuracy,
      macro_f1: macro_f1(rows),
      parse_errors: Enum.count(rows, &(not is_nil(&1.error))),
      count: length(rows)
    }
  end

  defp macro_f1(rows) do
    ["K11", "K47"]
    |> Enum.map(fn route ->
      tp = Enum.count(rows, &(&1.expected == route and &1.parsed_route == route))
      fp = Enum.count(rows, &(&1.expected != route and &1.parsed_route == route))
      fn_ = Enum.count(rows, &(&1.expected == route and &1.parsed_route != route))
      if 2 * tp + fp + fn_ == 0, do: 0.0, else: 2 * tp / (2 * tp + fp + fn_)
    end)
    |> then(&(Enum.sum(&1) / 2))
  end

  defp parameter_snapshot(program) do
    Enum.map(Imp.ProgramParameters.predictors(program), fn %{name: name, predictor: predictor} ->
      %{
        name: name,
        instruction: predictor.signature.instructions,
        demos: Report.encode_term(predictor.demos)
      }
    end)
  end

  defp optimization_rows!(manifest) do
    splits = manifest["dataset"]["splits"]

    %{
      train: split_rows!(manifest["dataset"]["train_path"], splits["train_ids"]),
      selection: split_rows!(manifest["dataset"]["selection_path"], splits["validation_ids"])
    }
  end

  defp held_out_rows!(manifest) do
    unless sha256_file(manifest["dataset"]["held_out_path"]) ==
             manifest["dataset"]["held_out_sha256"],
           do: raise("held-out split digest drift")

    ids = manifest["dataset"]["splits"]["held_out_ids"]
    split_rows!(manifest["dataset"]["held_out_path"], ids)
  end

  defp split_rows!(path, expected_ids) do
    rows = path |> File.stream!() |> Enum.map(&(Jason.decode!(&1) |> row!()))

    unless Enum.map(rows, & &1.id) == expected_ids,
      do: raise("frozen split file ID/order drift: #{path}")

    rows
  end

  defp row!(row) do
    prefix = row["label"] |> String.split(":", parts: 2) |> hd()
    route = Map.fetch!(%{"DESC" => "K11", "ENTY" => "K47"}, prefix)
    %{id: row["id"], text: row["text"], route: route}
  end

  defp route_meanings!(manifest) do
    contract = manifest["dataset"]["contract_path"] |> File.read!() |> Jason.decode!()

    Map.new(contract["route_mapping"], fn {_label, value} ->
      {Map.fetch!(value, "route"), Map.fetch!(value, "meaning")}
    end)
  end

  defp task_lm(manifest),
    do: local_lm(manifest["models"]["task"], manifest["execution"]["request"]["task"])

  defp optimizer_lm(manifest),
    do: local_lm(manifest["models"]["optimizer"], manifest["execution"]["request"]["optimizer"])

  defp local_lm(model, request) do
    Imp.req_llm(model["imp"],
      cache: false,
      temperature: request["temperature"],
      max_tokens: request["max_tokens"],
      max_retries: 0,
      timeout: 120_000,
      req_http_options: [retry: false, max_retries: 0]
    )
  end

  defp observed(inner, observer, role),
    do: %ObservedLM{inner: inner, observer: observer, role: role}

  defp verify_models!(manifest) do
    models = Req.get!("http://127.0.0.1:11434/api/tags", retry: false).body["models"]

    Enum.each(~w(task optimizer), fn role ->
      expected = manifest["models"][role]
      name = expected["imp"] |> String.replace_prefix("ollama:", "")

      unless Enum.any?(models, &(&1["name"] == name and &1["digest"] == expected["digest"])),
        do: raise("pinned local #{role} model is absent or changed")
    end)
  end

  defp report_json(program) do
    case Report.fetch(program) do
      nil -> nil
      report -> Report.json_safe(report)
    end
  end

  defp validate_transport_evidence!(evidence, expected, context) do
    configured = expected["imp"]
    local_name = String.replace_prefix(configured, "ollama:", "")

    unless evidence.model in [configured, local_name] and evidence.route in ["ollama", :ollama] and
             evidence.attempts == 1 and evidence.retry == false and
             is_number(evidence.input_tokens) and
             is_number(evidence.output_tokens) and is_binary(evidence.finish_reason) and
             is_binary(evidence.content) and
             (is_nil(evidence.provider_cost) or
                (is_number(evidence.provider_cost) and evidence.provider_cost == 0)) do
      raise "#{context} lacks exact route/model/attempt/token/finish/content transport evidence: #{inspect(evidence)}"
    end
  end

  defp artifact_path(seed, arm),
    do: Path.join(Path.dirname(@output), "sealed/imp-#{seed}-#{arm}.json")

  defp source_commits!(manifest, clean?) do
    pinned = %{
      "dspy" => manifest["authorities"]["dspy"]["commit"],
      "gepa" => manifest["authorities"]["gepa"]["commit"]
    }

    root = Path.expand("../..", __DIR__)

    if clean?,
      do: MatchedInstructionOptimizersTREC.SourceIdentity.capture_clean!(root, pinned),
      else: MatchedInstructionOptimizersTREC.SourceIdentity.current(root, pinned)
  end

  defp source_commits_for_stopped_output do
    manifest = @manifest |> File.read!() |> Jason.decode!()
    source_commits!(manifest, false)
  rescue
    _error -> %{"imp" => "unavailable", "dspy" => "unavailable", "gepa" => "unavailable"}
  end

  defp map_get(value, key) when is_map(value),
    do: Map.get(value, key) || Map.get(value, Atom.to_string(key))

  defp map_get(_value, _key), do: nil

  defp atomic_write!(path, value) do
    File.mkdir_p!(Path.dirname(path))
    temporary = path <> ".tmp-#{System.unique_integer([:positive])}"

    try do
      File.write!(temporary, Jason.encode!(value, pretty: true) <> "\n", [:sync])
      File.rename!(temporary, path)
    after
      File.rm(temporary)
    end
  end

  defp sha256_file(path),
    do: path |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

  defp elapsed(started) do
    (System.monotonic_time() - started)
    |> System.convert_time_unit(:native, :microsecond)
    |> Kernel./(1_000_000)
  end
end

MatchedTRECImp.Runner.run()
