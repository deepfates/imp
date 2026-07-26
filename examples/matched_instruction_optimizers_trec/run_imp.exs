Code.require_file("contract.exs", __DIR__)
Code.require_file("two_phase.exs", __DIR__)
Code.require_file("source_identity.exs", __DIR__)
Code.require_file("response_evidence.exs", __DIR__)
Code.require_file("call_budget.exs", __DIR__)

defmodule MatchedTRECImp.Observer do
  def start_link(manifest),
    do:
      Agent.start_link(fn ->
        %{
          phase: nil,
          messages: [],
          responses: [],
          transports: [],
          call_budgets: %{},
          usd_reserved: 0.0,
          actual_cost: 0.0,
          usd_limit: runtime_usd_limit(manifest),
          role_usd: role_usd(manifest)
        }
      end)

  def phase(pid, value), do: Agent.update(pid, &%{&1 | phase: value})

  def register_budget(pid, seed, arm, ceiling) do
    Agent.update(pid, fn state ->
      key = {seed, arm}

      if Map.has_key?(state.call_budgets, key),
        do: raise("duplicate call-budget registration for #{inspect(key)}")

      budget = %{
        ceiling: ceiling,
        counts: MatchedInstructionOptimizersTREC.CallBudget.zero(),
        refusals: []
      }

      put_in(state, [:call_budgets, key], budget)
    end)
  end

  def reserve_call!(pid, seed, arm, role) when role in [:task, :optimizer] do
    result =
      Agent.get_and_update(pid, fn state ->
        key = {seed, arm}
        budget = Map.fetch!(state.call_budgets, key)
        projected_usd = state.usd_reserved + Map.fetch!(state.role_usd, role)

        try do
          if projected_usd > state.usd_limit + 1.0e-12,
            do: raise("global USD reservation #{projected_usd} exceeds #{state.usd_limit}")

          projected =
            MatchedInstructionOptimizersTREC.CallBudget.reserve!(
              budget.counts,
              budget.ceiling,
              role
            )

          updated =
            state
            |> put_in([:call_budgets, key, :counts], projected)
            |> Map.put(:usd_reserved, projected_usd)

          {:ok, updated}
        rescue
          error ->
            refusal = %{role: role, phase: state.phase, error: Exception.message(error)}
            updated = update_in(state, [:call_budgets, key, :refusals], &(&1 ++ [refusal]))
            {{:error, Exception.message(error)}, updated}
        end
      end)

    case result do
      :ok -> :ok
      {:error, message} -> raise "#{arm} #{message}"
    end
  end

  def message(pid, role, messages) do
    Agent.update(pid, fn state ->
      entry = %{phase: state.phase, role: role, messages: messages}
      %{state | messages: state.messages ++ [entry]}
    end)
  end

  def response(pid, role, result) do
    Agent.update(pid, fn state ->
      entry = %{phase: state.phase, role: role, result: result}
      %{state | responses: state.responses ++ [entry]}
    end)
  end

  def reconcile_cost!(pid, cost) when is_number(cost) and cost >= 0 do
    Agent.get_and_update(pid, fn state ->
      actual = state.actual_cost + cost

      if actual > state.usd_reserved + 1.0e-6 or actual > state.usd_limit + 1.0e-6 do
        {{:error, "actual cumulative cost #{actual} exceeds reserved #{state.usd_reserved}"},
         state}
      else
        {:ok, %{state | actual_cost: actual}}
      end
    end)
    |> case do
      :ok -> :ok
      {:error, message} -> raise message
    end
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

  defp role_usd(manifest) do
    request = manifest["execution"]["request"]
    models = manifest["models"]

    %{
      task:
        request["task"]["reservation_input_tokens"] *
          String.to_float(models["task"]["catalog_prompt_per_token"]) +
          request["task"]["max_tokens"] *
            String.to_float(models["task"]["catalog_completion_per_token"]),
      optimizer:
        request["optimizer"]["reservation_input_tokens"] *
          String.to_float(models["optimizer"]["catalog_cache_write_per_token"]) +
          request["optimizer"]["max_tokens"] *
            String.to_float(models["optimizer"]["catalog_completion_per_token"])
    }
  end

  defp runtime_usd_limit(manifest) do
    role = role_usd(manifest)

    per_seed =
      manifest["execution"]["call_ceilings"]
      |> Map.values()
      |> Enum.reduce(0.0, fn ceiling, total ->
        total + ceiling["task_logical"] * role.task +
          ceiling["optimizer_logical"] * role.optimizer
      end)

    per_seed * length(manifest["seeds"])
  end
end

defmodule MatchedTRECImp.ObservedLM do
  defstruct [:inner, :observer, :role, :seed, :arm, :max_input_tokens, :expected_model]

  def generate(lm, messages, opts) do
    rendered_bytes = (messages |> Jason.encode!() |> byte_size()) + 16 * (length(messages) + 1)

    if rendered_bytes > lm.max_input_tokens do
      raise "#{lm.role} rendered request conservative token bound #{rendered_bytes} exceeds #{lm.max_input_tokens}"
    end

    :ok = MatchedTRECImp.Observer.reserve_call!(lm.observer, lm.seed, lm.arm, lm.role)
    MatchedTRECImp.Observer.message(lm.observer, lm.role, messages)
    result = Imp.LM.generate(lm.inner, messages, opts)
    MatchedTRECImp.Observer.response(lm.observer, lm.role, result)
    validate_response!(lm, result)
    result
  end

  def response_format_capability(%__MODULE__{inner: inner}),
    do: Imp.LM.response_format_capability(inner)

  defp validate_response!(lm, result) do
    evidence = MatchedInstructionOptimizersTREC.ResponseEvidence.from_result!(result)
    expected = lm.expected_model

    unless evidence.model in [expected["logical"], expected["imp"]] and
             String.downcase(to_string(evidence.route)) ==
               String.downcase(expected["endpoint_provider"]) and
             evidence.gateway == "openrouter" and
             evidence.service_tier in [nil, "default", "standard"] and
             is_number(evidence.input_tokens) and
             evidence.input_tokens <= expected["max_input_tokens"] and
             is_number(evidence.gateway_reported_cost) and
             is_number(evidence.computed_cost) and
             abs(evidence.gateway_reported_cost - evidence.computed_cost) <= 1.0e-6 do
      raise "first-response route/model/tier/token/cost drift: #{inspect(evidence)}"
    end

    MatchedTRECImp.Observer.reconcile_cost!(lm.observer, evidence.gateway_reported_cost)
  end
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
    require_launch_sealed!(manifest)
    source_commits = source_commits!(manifest, true)
    catalog_snapshot = verify_models!(manifest)
    # This first pass never decodes held-out lines. Their values cannot be reached by
    # optimizer, metric, selection, or any sealed program before every arm is sealed.
    rows = optimization_rows!(manifest)
    meanings = route_meanings!(manifest)
    {:ok, observer} = Observer.start_link(manifest)
    Process.put(:matched_trec_observer, observer)
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

            wait_for_peer_selection!(manifest)
          end,
          fn -> held_out_rows!(manifest) end
        )

      completed = evaluate_held_out(sealed, held_out, observer, manifest)

      result = %{
        schema_version: 3,
        runtime: "imp",
        status: "complete",
        manifest_sha256: manifest["manifest_sha256"],
        source_commits: source_commits,
        selection_receipt: @selection_output,
        seeds: completed,
        rendered_messages: Observer.snapshot(observer).messages,
        lm_results: Report.encode_term(Observer.snapshot(observer).responses),
        transport_events: Report.encode_term(Observer.snapshot(observer).transports),
        call_budgets: Report.encode_term(Observer.snapshot(observer).call_budgets),
        catalog_snapshot: catalog_snapshot,
        claim_boundary:
          "sealed matched system comparison; task messages are matched exactly, optimizer trajectories are compared through pinned fidelity modes"
      }

      atomic_write!(@output, result)
      IO.puts(Jason.encode!(result, pretty: true))
    after
      :telemetry.detach(telemetry_id)
    end
  rescue
    error ->
      atomic_write!(@output, %{
        schema_version: 3,
        runtime: "imp",
        status: "stopped",
        source_commits: source_commits_for_stopped_output(),
        call_budgets: stopped_call_budgets(),
        error: Exception.format(:error, error, __STACKTRACE__)
      })

      reraise error, __STACKTRACE__
  end

  defp require_launch_sealed!(%{"launch_status" => "sealed"}), do: :ok

  defp require_launch_sealed!(manifest) do
    raise "provider launch refused: #{manifest["launch_status"]}"
  end

  defp compile_and_seal({seed, arm}, manifest, rows, meanings, observer) do
    before_arm = Observer.snapshot(observer)

    :ok =
      Observer.register_budget(observer, seed, arm, manifest["execution"]["call_ceilings"][arm])

    task_lm = observed(task_lm(manifest, seed), observer, :task, seed, arm, manifest)
    optimizer_lm = observed(optimizer_lm(manifest), observer, :optimizer, seed, arm, manifest)
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
        model_contract(manifest, "task")
      )

    after_selection = Observer.snapshot(observer)
    preheld_counts = enforce_call_ceiling!(arm, before_arm, after_selection, manifest, 80)
    validate_response_ledger!(before_arm, after_selection, manifest)

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
      task_model: model_contract(manifest, "task"),
      preheld_call_counts: preheld_counts
    }
  end

  defp selection_receipt(manifest, source_commits, sealed) do
    %{
      schema_version: 3,
      runtime: "imp",
      status: "selection_sealed",
      held_out_loaded: false,
      manifest_sha256: manifest["manifest_sha256"],
      source_commits: source_commits,
      selections: Enum.map(sealed, &Map.drop(&1, [:program]))
    }
  end

  defp wait_for_peer_selection!(manifest) do
    peer =
      System.get_env(
        "IMP_MATCHED_TREC_UPSTREAM_SELECTION",
        Path.expand(
          "../../tmp/matched_instruction_optimizers_trec/upstream-result.json.selection-sealed.json",
          __DIR__
        )
      )

    deadline = System.monotonic_time(:second) + 1_800
    wait_for_peer_selection!(peer, manifest, deadline)
  end

  defp wait_for_peer_selection!(peer, manifest, deadline) do
    if File.regular?(peer) do
      receipt = peer |> File.read!() |> Jason.decode!()

      unless receipt["runtime"] == "upstream" and receipt["status"] == "selection_sealed" and
               receipt["held_out_loaded"] == false and
               receipt["manifest_sha256"] == manifest["manifest_sha256"] and
               length(receipt["selections"] || []) == 9 do
        raise "upstream selection barrier receipt drift"
      end

      :ok
    else
      if System.monotonic_time(:second) >= deadline,
        do: raise("timed out before upstream sealed all selections")

      Process.sleep(1_000)
      wait_for_peer_selection!(peer, manifest, deadline)
    end
  end

  defp evaluate_held_out(sealed, held_out, observer, manifest) do
    sealed
    |> Enum.group_by(& &1.seed)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {seed, entries} ->
      arms =
        Enum.map(entries, fn selected ->
          before_held_out = Observer.snapshot(observer)

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

          after_held_out = Observer.snapshot(observer)

          held_out_counts =
            enforce_call_ceiling!(
              selected.arm,
              before_held_out,
              after_held_out,
              put_in(manifest, ["execution", "call_ceilings"], %{
                selected.arm => %{
                  "task_logical" => 80,
                  "optimizer_logical" => 0,
                  "transports" => 80,
                  "total_logical" => 80
                }
              }),
              0
            )

          validate_response_ledger!(before_held_out, after_held_out, manifest)

          enforce_combined_ceiling!(
            selected.arm,
            selected.preheld_call_counts,
            held_out_counts,
            manifest
          )

          selected
          |> Map.drop([:program, :selection_rows])
          |> Map.put(:rows, %{selection: selected.selection_rows, held_out: rows})
          |> Map.put(:held_out, aggregate(rows))
          |> Map.put(:held_out_call_counts, held_out_counts)
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
      reflection_record_mode: :gepa_v0_1_4,
      max_concurrency: 1,
      timeout: 120_000,
      proposal_timeout: 120_000,
      max_reflection_calls: config["iterations"],
      raise_on_exception: true
    )
    |> GEPA.compile(program, examples(rows.train, true), examples(rows.selection, false))
  end

  defp compile("mipro_v2", program, rows, seed, optimizer_lm, task_lm, manifest, _meanings) do
    config = manifest["optimizer"]["mipro_v2"]

    MIPROv2.new(scalar_metric(),
      auto: nil,
      num_candidates: config["num_candidates"],
      num_trials: config["trials"],
      minibatch: false,
      max_bootstrapped_demos: 0,
      max_labeled_demos: 0,
      startup_trials: config["startup_trials"],
      proposer_fidelity: :dspy_3_2_1,
      program_aware_proposer: false,
      data_aware_proposer: true,
      tip_aware_proposer: true,
      fewshot_aware_proposer: false,
      view_data_batch_size: 10,
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
      responses = Enum.drop(after_call.responses, length(before.responses))
      transports = Enum.drop(after_call.transports, length(before.transports))

      {actual, error, metadata} =
        case result do
          {:ok, prediction} ->
            {Imp.Prediction.get(prediction, :route), nil, prediction.metadata}

          {:error, reason} ->
            {nil, reason, nil}
        end

      unless length(messages) == 1 and length(responses) == 1 and length(transports) == 1,
        do: raise("#{arm}/#{phase}/#{row.id} did not use exactly one logical/transport call")

      response =
        MatchedInstructionOptimizersTREC.ResponseEvidence.from_result!(hd(responses).result)

      transport = hd(transports)
      actual_model = response.model
      actual_route = response.route
      attempts = map_get(transport.measurements, :count)
      retry = map_get(transport.metadata, :retry)
      input_tokens = response.input_tokens
      output_tokens = response.output_tokens
      finish_reason = response.finish_reason
      raw_response = response.content
      gateway_cost = response.gateway_reported_cost
      computed_cost = response.computed_cost

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
          gateway: response.gateway,
          service_tier: response.service_tier,
          gateway_reported_cost: gateway_cost,
          computed_cost: computed_cost
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
        gateway: response.gateway,
        service_tier: response.service_tier,
        request_seed: seed,
        transport_attempts: attempts,
        input_tokens: input_tokens,
        output_tokens: output_tokens,
        finish_reason: finish_reason,
        gateway_reported_cost: gateway_cost,
        adapter_computed_cost: computed_cost,
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
      selection: split_rows!(manifest["dataset"]["selection_path"], splits["selection_ids"])
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
    wanted = MapSet.new(expected_ids)

    rows =
      path
      |> File.stream!()
      |> Enum.map(&Jason.decode!/1)
      |> Enum.filter(&MapSet.member?(wanted, &1["id"]))
      |> Map.new(&{&1["id"], row!(&1)})

    Enum.map(expected_ids, &Map.fetch!(rows, &1))
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

  defp task_lm(manifest, seed),
    do: remote_lm(manifest, "task", seed)

  defp optimizer_lm(manifest),
    do: remote_lm(manifest, "optimizer", nil)

  defp remote_lm(manifest, role, seed) do
    model = manifest["models"][role]
    request = manifest["execution"]["request"][role]
    guard = openrouter_guard(manifest, role)

    opts = [
      api_key: System.fetch_env!("OPENROUTER_API_KEY"),
      cache: false,
      max_tokens: request["max_tokens"],
      max_retries: 0,
      timeout: 120_000,
      provider_options: [openrouter_provider: guard, openrouter_usage: %{include: true}],
      req_http_options: [retry: false, max_retries: 0]
    ]

    opts =
      if is_nil(request["temperature"]),
        do: opts,
        else: Keyword.put(opts, :temperature, request["temperature"])

    opts = if is_nil(seed), do: opts, else: Keyword.put(opts, :seed, seed)

    Imp.req_llm(model["imp"], opts)
  end

  defp openrouter_guard(manifest, role) do
    route = manifest["execution"]["openrouter"]
    providers = route["#{role}_only"]

    %{
      only: providers,
      order: route["#{role}_order"],
      allow_fallbacks: false,
      require_parameters: true,
      data_collection: "deny",
      max_price: route["#{role}_max_price_per_million"]
    }
  end

  defp observed(inner, observer, role, seed, arm, manifest),
    do: %ObservedLM{
      inner: inner,
      observer: observer,
      role: role,
      seed: seed,
      arm: arm,
      max_input_tokens:
        manifest["execution"]["request"][Atom.to_string(role)]["max_input_tokens"],
      expected_model: model_contract(manifest, Atom.to_string(role))
    }

  defp verify_models!(manifest) do
    snapshots =
      Map.new(~w(task optimizer), fn role ->
        expected = manifest["models"][role]
        endpoint_url = "https://openrouter.ai/api/v1/models/#{expected["logical"]}/endpoints"
        body = Req.get!(endpoint_url, retry: false, max_retries: 0).body
        endpoints = get_in(body, ["data", "endpoints"]) || body["data"] || []

        exact =
          Enum.find(endpoints, fn endpoint ->
            endpoint["provider_name"] == expected["endpoint_provider"] and
              endpoint["tag"] in [nil, "default", "standard"] and
              price_lte?(
                get_in(endpoint, ["pricing", "prompt"]),
                expected["catalog_prompt_per_token"]
              ) and
              price_lte?(
                get_in(endpoint, ["pricing", "completion"]),
                expected["catalog_completion_per_token"]
              ) and
              required_parameters?(endpoint, role)
          end) ||
            raise(
              "no exact first-party #{role} endpoint satisfies pricing/parameter/default-tier guard"
            )

        bounded = %{
          endpoint_url: endpoint_url,
          model: expected["logical"],
          endpoint: exact,
          sha256: :crypto.hash(:sha256, Jason.encode!(exact)) |> Base.encode16(case: :lower)
        }

        {role, bounded}
      end)

    snapshots
  end

  defp price_lte?(actual, sealed) when is_binary(actual) and is_binary(sealed),
    do: parse_price(actual) <= parse_price(sealed)

  defp price_lte?(_, _), do: false

  defp parse_price(value) do
    case Float.parse(value) do
      {number, ""} when number >= 0 -> number
      _ -> raise "invalid endpoint price #{inspect(value)}"
    end
  end

  defp required_parameters?(endpoint, "task") do
    params = endpoint["supported_parameters"] || []
    Enum.all?(~w(max_tokens seed response_format), &(&1 in params))
  end

  defp required_parameters?(endpoint, "optimizer") do
    params = endpoint["supported_parameters"] || []
    Enum.all?(~w(max_tokens temperature), &(&1 in params))
  end

  defp report_json(program) do
    case Report.fetch(program) do
      nil -> nil
      report -> Report.json_safe(report)
    end
  end

  defp model_contract(manifest, role) do
    Map.put(
      manifest["models"][role],
      "max_input_tokens",
      manifest["execution"]["request"][role]["max_input_tokens"]
    )
  end

  defp enforce_call_ceiling!(arm, before, after_snapshot, manifest, reserved_held_out_task) do
    ceiling = manifest["execution"]["call_ceilings"][arm]

    effective = %{
      "task_logical" => ceiling["task_logical"] - reserved_held_out_task,
      "optimizer_logical" => ceiling["optimizer_logical"],
      "total_logical" => ceiling["total_logical"] - reserved_held_out_task,
      "transports" => ceiling["transports"] - reserved_held_out_task
    }

    counts = call_counts(before, after_snapshot)

    unless Enum.all?(effective, fn {key, limit} -> counts[key] <= limit end) and
             counts["total_logical"] == counts["transports"] and
             counts["total_logical"] == counts["responses"] do
      raise "#{arm} exceeded or mismatched logical/transport call ceiling: counts=#{inspect(counts)} ceiling=#{inspect(effective)}"
    end

    Map.drop(counts, ["responses"])
  end

  defp enforce_combined_ceiling!(arm, first, second, manifest) do
    combined = Map.merge(first, second, fn _key, left, right -> left + right end)
    ceiling = manifest["execution"]["call_ceilings"][arm]

    unless Enum.all?(ceiling, fn {key, limit} -> combined[key] <= limit end) and
             combined["total_logical"] == combined["transports"] do
      raise "#{arm} exceeded its complete matched call ceiling: counts=#{inspect(combined)} ceiling=#{inspect(ceiling)}"
    end

    combined
  end

  defp call_counts(before, after_snapshot) do
    messages = Enum.drop(after_snapshot.messages, length(before.messages))
    responses = Enum.drop(after_snapshot.responses, length(before.responses))
    transports = Enum.drop(after_snapshot.transports, length(before.transports))

    task = Enum.count(messages, &(&1.role == :task))
    optimizer = Enum.count(messages, &(&1.role == :optimizer))

    %{
      "task_logical" => task,
      "optimizer_logical" => optimizer,
      "total_logical" => task + optimizer,
      "responses" => length(responses),
      "transports" => length(transports)
    }
  end

  defp validate_response_ledger!(before, after_snapshot, manifest) do
    responses = Enum.drop(after_snapshot.responses, length(before.responses))
    transports = Enum.drop(after_snapshot.transports, length(before.transports))

    unless Enum.all?(transports, &(map_get(&1.metadata, :retry) == false)),
      do: raise("matched transport ledger contains a retry-enabled attempt")

    Enum.each(responses, fn entry ->
      response = MatchedInstructionOptimizersTREC.ResponseEvidence.from_result!(entry.result)
      role = Atom.to_string(entry.role)

      validate_transport_evidence!(
        %{
          model: response.model,
          route: response.route,
          attempts: 1,
          retry: false,
          input_tokens: response.input_tokens,
          output_tokens: response.output_tokens,
          finish_reason: response.finish_reason,
          content: response.content,
          gateway: response.gateway,
          service_tier: response.service_tier,
          gateway_reported_cost: response.gateway_reported_cost,
          computed_cost: response.computed_cost
        },
        model_contract(manifest, role),
        "#{role} optimizer/compile response"
      )
    end)
  end

  defp validate_transport_evidence!(evidence, expected, context) do
    configured = expected["logical"]
    expected_provider = String.downcase(expected["endpoint_provider"])

    unless evidence.model in [configured, expected["imp"]] and
             String.downcase(to_string(evidence.route)) == expected_provider and
             evidence.attempts == 1 and evidence.retry == false and
             is_number(evidence.input_tokens) and
             evidence.input_tokens <= expected["max_input_tokens"] and
             is_number(evidence.output_tokens) and is_binary(evidence.finish_reason) and
             is_binary(evidence.content) and evidence.gateway == "openrouter" and
             evidence.service_tier in [nil, "default", "standard"] and
             is_number(evidence.gateway_reported_cost) and evidence.gateway_reported_cost >= 0 and
             is_number(evidence.computed_cost) and evidence.computed_cost >= 0 and
             abs(evidence.gateway_reported_cost - evidence.computed_cost) <= 1.0e-6 do
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

  defp stopped_call_budgets do
    case Process.get(:matched_trec_observer) do
      pid when is_pid(pid) -> Report.encode_term(Observer.snapshot(pid).call_budgets)
      _ -> %{}
    end
  rescue
    _error -> %{}
  end

  defp map_get(value, key) when is_map(value) do
    case Map.fetch(value, key) do
      {:ok, found} -> found
      :error -> Map.get(value, Atom.to_string(key))
    end
  end

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
