Code.require_file("contract.exs", __DIR__)
Code.require_file("two_phase.exs", __DIR__)
Code.require_file("source_identity.exs", __DIR__)
Code.require_file("response_evidence.exs", __DIR__)
Code.require_file("call_budget.exs", __DIR__)
Code.require_file("stop_accounting.exs", __DIR__)
Code.require_file(Path.expand("../../bench/imp/benchmark_truth/ifbench_two_stage.ex", __DIR__))
Code.require_file(Path.expand("../../bench/imp/benchmark_truth/gepa_metrics.ex", __DIR__))
Code.require_file(Path.expand("../../bench/imp/benchmark_truth/ifbench_feedback.ex", __DIR__))

defmodule MatchedIFBenchR16kImp.Observer do
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
          # Hard actual-spend cap: this runtime's half of the campaign's
          # new_spend_max ($60 across both runtimes). Checked against ACTUAL
          # gateway-reported cost in reconcile_cost!/2, independently of the
          # (p99-priced) reservation ledger.
          actual_usd_cap: manifest["budget"]["new_spend_max"] / 2,
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
        counts: MatchedIFBenchR16k.CallBudget.zero(),
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
            MatchedIFBenchR16k.CallBudget.reserve!(
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
      :ok ->
        :ok

      {:error, message} ->
        operational_error(:budget, :call_reservation_refused, "#{arm} #{message}")
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

      cond do
        actual > state.usd_reserved + 1.0e-6 or actual > state.usd_limit + 1.0e-6 ->
          {{:error, "actual cumulative cost #{actual} exceeds reserved #{state.usd_reserved}"},
           state}

        actual > state.actual_usd_cap + 1.0e-6 ->
          {{:error,
            "actual cumulative cost #{actual} exceeds this runtime's hard spend cap #{state.actual_usd_cap} (new_spend_max/2)"},
           state}

        true ->
          {:ok, %{state | actual_cost: actual}}
      end
    end)
    |> case do
      :ok ->
        :ok

      {:error, message} ->
        operational_error(:cost, :cumulative_cost_drift, message)
    end
  end

  # One transport entry per LOGICAL dispatch, mirroring upstream's ledger
  # (run_upstream.py records adapter_transport_dispatch per forward; its
  # litellm-internal num_retries=3 attempts are invisible to that ledger).
  # Imp's transient retry attempts (ObservedLM.dispatch_with_retries/3) share
  # a dispatch_tag; they merge into the logical call's entry with the attempt
  # total disclosed in measurements.count. Ledger arithmetic (logical ==
  # transports) is therefore preserved, with strictly more disclosure.
  def transport(pid, measurements, metadata) do
    Agent.update(pid, fn state ->
      tag = Map.get(metadata, :dispatch_tag)

      merge_index =
        if is_nil(tag) do
          nil
        else
          state.transports
          |> Enum.with_index()
          |> Enum.reverse()
          |> Enum.find_value(fn {entry, index} ->
            if Map.get(entry.metadata, :dispatch_tag) == tag, do: index
          end)
        end

      case merge_index do
        nil ->
          entry = %{
            phase: state.phase,
            measurements: measurements,
            metadata: metadata
          }

          %{state | transports: state.transports ++ [entry]}

        index ->
          merged =
            List.update_at(state.transports, index, fn entry ->
              %{
                entry
                | measurements:
                    Map.update(
                      entry.measurements,
                      :count,
                      1,
                      &(&1 + Map.get(measurements, :count, 1))
                    )
              }
            end)

          %{state | transports: merged}
      end
    end)
  end

  def snapshot(pid), do: Agent.get(pid, & &1)

  defp operational_error(kind, reason, message) do
    {:error, Imp.OperationalSafetyError.exception(kind: kind, reason: reason, message: message)}
  end

  # COST GUARD REDESIGN (HEAVY_DESIGN_DRAFT option a): each task call reserves
  # at reservation_output_tokens = 4096 completion tokens, a generous p99, NOT
  # the 16384 max_tokens request cap. Basis (measured pilot, gepa014 final
  # verdict): held-out completion tokens median 505 / mean 648 / max
  # ~1024-capped; 4096 is ~6x the mean while 16384-priced reservations would
  # make the reservation ceiling, not spend, the binding constraint. The
  # companion guard: any single call whose ACTUAL completion tokens exceed
  # hard_stop_completion_tokens = 8192 (2x the reservation, ~12x the pilot
  # mean) is a loud anomaly and a fatal operational stop (see
  # ObservedLM.validate_response/2). Pre-dispatch reservation and
  # reconcile_cost mechanics are otherwise unchanged.
  defp role_usd(manifest) do
    request = manifest["execution"]["request"]
    models = manifest["models"]

    %{
      task:
        request["task"]["reservation_input_tokens"] *
          catalog_price!(models["task"]["catalog_prompt_per_token"]) +
          request["task"]["reservation_output_tokens"] *
            catalog_price!(models["task"]["catalog_completion_per_token"]),
      optimizer:
        request["optimizer"]["reservation_input_tokens"] *
          catalog_price!(models["optimizer"]["catalog_cache_write_per_token"]) +
          request["optimizer"]["max_tokens"] *
            catalog_price!(models["optimizer"]["catalog_completion_per_token"])
    }
  end

  # String.to_float/1 crashes on integer-formatted prices like "0"; catalog
  # values must parse completely either way or preflight fails loudly.
  defp catalog_price!(value) when is_binary(value) do
    case Float.parse(value) do
      {price, ""} -> price
      _other -> raise ArgumentError, "invalid catalog price: #{inspect(value)}"
    end
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

defmodule MatchedIFBenchR16kImp.ObservedLM do
  defstruct [
    :inner,
    :observer,
    :role,
    :seed,
    :arm,
    :max_input_tokens,
    :expected_model,
    :hard_stop_completion_tokens
  ]

  def generate(lm, messages, opts) do
    configured_seed =
      case lm.inner do
        %{opts: inner_opts} when is_list(inner_opts) -> Keyword.get(inner_opts, :seed)
        _other -> nil
      end

    expected_seed = if lm.role == :task, do: lm.seed

    with :ok <-
           ensure(
             configured_seed == expected_seed,
             :route,
             :request_seed_drift,
             "#{lm.role} request seed drift: configured=#{inspect(configured_seed)} expected=#{inspect(expected_seed)}"
           ),
         :ok <-
           MatchedIFBenchR16kImp.Observer.reserve_call!(lm.observer, lm.seed, lm.arm, lm.role) do
      MatchedIFBenchR16kImp.Observer.message(lm.observer, lm.role, messages)
      result = dispatch_with_retries(lm, messages, opts)
      MatchedIFBenchR16kImp.Observer.response(lm.observer, lm.role, result)

      case result do
        {:ok, _value} ->
          with :ok <- validate_response(lm, result), do: result

        {:error, %Imp.OperationalSafetyError{}} = safety ->
          safety

        {:error, reason} ->
          operational_error(
            :transport,
            :provider_transport_failed,
            "#{lm.role} transport failed: #{inspect(reason)}"
          )

        other ->
          operational_error(
            :transport,
            :invalid_transport_envelope,
            "#{lm.role} returned an invalid transport envelope: #{inspect(other)}"
          )
      end
    end
  end

  def response_format_capability(%__MODULE__{inner: inner}),
    do: Imp.LM.response_format_capability(inner)

  # dspy 3.2.1 parity: LM(num_retries=3) retries transient transport failures
  # beneath its call ledger (litellm-internal; lm.py:41). Imp mirrors the same
  # 3-retry budget HERE, where the accounting can see it: each attempt is an
  # explicit no-retry dispatch (so the client's transport telemetry fires per
  # attempt), all attempts share a dispatch_tag and merge into one ledger
  # entry (Observer.transport/3). Retries apply only to transport-class
  # failures — never to cost/route/contract safety stops.
  @transient_retry_limit 3

  defp dispatch_with_retries(lm, messages, opts) do
    Process.put(:r16k_dispatch_tag, make_ref())
    attempt_dispatch(lm, messages, opts, 0)
  end

  defp attempt_dispatch(lm, messages, opts, tried) do
    result = dispatch(lm, messages, opts)

    retriable? =
      case result do
        {:error, %Imp.OperationalSafetyError{kind: :transport}} -> true
        {:error, %Imp.OperationalSafetyError{}} -> false
        {:error, _transient_transport} -> true
        _success -> false
      end

    if retriable? and tried < @transient_retry_limit do
      Process.sleep(1000 * Integer.pow(2, tried))
      attempt_dispatch(lm, messages, opts, tried + 1)
    else
      result
    end
  end

  defp dispatch(lm, messages, opts) do
    Imp.LM.generate(lm.inner, messages, opts)
  rescue
    error ->
      operational_error(
        :transport,
        :provider_transport_raised,
        "#{lm.role} transport raised: #{Exception.message(error)}"
      )
  catch
    kind, reason ->
      operational_error(
        :transport,
        :provider_transport_threw,
        "#{lm.role} transport #{kind}: #{inspect(reason)}"
      )
  end

  defp validate_response(lm, result) do
    evidence = MatchedIFBenchR16k.ResponseEvidence.from_result!(result)
    expected = lm.expected_model

    # Hard anomaly stop (cost-guard companion): a single completion beyond
    # 8192 tokens is ~12x the measured pilot mean (648) and 2x the 4096 p99
    # reservation; it is a fatal operational anomaly, never ordinary spend.
    anomaly? =
      lm.role == :task and is_number(lm.hard_stop_completion_tokens) and
        is_number(evidence.output_tokens) and
        evidence.output_tokens > lm.hard_stop_completion_tokens

    if is_number(evidence.gateway_reported_cost) and evidence.gateway_reported_cost >= 0 do
      MatchedIFBenchR16kImp.Observer.reconcile_cost!(
        lm.observer,
        evidence.gateway_reported_cost
      )
    end

    cond do
      anomaly? ->
        operational_error(
          :cost,
          :completion_token_anomaly,
          "task call completion tokens #{evidence.output_tokens} exceed the hard stop #{lm.hard_stop_completion_tokens}"
        )

      true ->
        case MatchedIFBenchR16k.ResponseEvidence.validate_contract(evidence, expected) do
          :ok ->
            :ok

          {:error, {:response_identity_or_usage_drift, _evidence}} ->
            operational_error(
              :route,
              :response_identity_or_usage_drift,
              "first-response route/model/tier/token/cost drift: #{inspect(evidence)}"
            )
        end
    end
  rescue
    error ->
      operational_error(
        :transport,
        :response_evidence_missing,
        "response evidence validation failed: #{Exception.message(error)}"
      )
  end

  defp ensure(true, _kind, _reason, _message), do: :ok

  defp ensure(false, kind, reason, message), do: operational_error(kind, reason, message)

  defp operational_error(kind, reason, message) do
    {:error, Imp.OperationalSafetyError.exception(kind: kind, reason: reason, message: message)}
  end
end

defmodule MatchedIFBenchR16kImp.Runner do
  alias Imp.Optimizer.{Artifact, GEPA, MIPROv2, Report}
  alias MatchedIFBenchR16kImp.{ObservedLM, Observer}

  @manifest Path.expand("contract.json", __DIR__)
  @output Path.expand(
            System.get_env(
              "IMP_MATCHED_IFBENCH_R16K_OUTPUT",
              "../../tmp/matched_ifbench_rehearsal16k/imp-result.json"
            ),
            __DIR__
          )
  @selection_output @output <> ".selection-sealed.json"

  def run do
    bootstrap_digest = authenticate_bootstrap_environment!()
    ensure_transport_runtime_started!()
    manifest = MatchedIFBenchR16k.Contract.load_optimization!(@manifest)
    launch_commit = require_expected_launch_commit!()
    source_commits = source_commits!(manifest, true, launch_commit)
    verify_runtime_dependencies!(manifest)
    catalog_snapshot = verify_models!(manifest)
    # This first pass never decodes held-out lines. Their values cannot be reached by
    # optimizer, metric, selection, or any sealed program before every arm is sealed.
    rows = optimization_rows!(manifest)
    {:ok, observer} = Observer.start_link(manifest)
    Process.put(:matched_ifbench_observer, observer)
    telemetry_id = {__MODULE__, self()}

    :ok =
      :telemetry.attach(
        telemetry_id,
        [:imp, :lm, :transport, :attempt],
        fn _event, measurements, metadata, target ->
          # :telemetry.execute is synchronous in the emitting process, so the
          # dispatching call's tag is readable here and travels with the entry.
          Observer.transport(
            target,
            measurements,
            Map.put(metadata, :dispatch_tag, Process.get(:r16k_dispatch_tag))
          )
        end,
        observer
      )

    signal_id = {__MODULE__, :coordinator_stop, make_ref()}

    {:ok, ^signal_id} =
      System.trap_signal(:sigterm, signal_id, fn ->
        atomic_write!(
          @output,
          stopped_payload(
            observer,
            source_commits,
            launch_commit,
            "coordinator requested graceful stop"
          )
        )

        # The signal callback runs outside the blocked request process. Stop the
        # VM after the durable snapshot so the interrupted run cannot continue
        # and later overwrite the stopped artifact.
        System.stop(1)
      end)

    try do
      work_items = for seed <- manifest["seeds"], arm <- manifest["arms"], do: {seed, arm}

      {sealed, held_out} =
        MatchedIFBenchR16k.TwoPhase.seal_then_load_held_out!(
          work_items,
          &compile_and_seal(&1, manifest, rows, observer),
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
        bootstrap_digest: bootstrap_digest,
        claim_boundary:
          "stock-DSPy-adapted IFBench task graph comparison; not the unmodified artifact or paper reproduction"
      }

      atomic_write!(@output, result)
      IO.puts(Jason.encode!(result, pretty: true))
    after
      :telemetry.detach(telemetry_id)
      System.untrap_signal(:sigterm, signal_id)
    end
  rescue
    error ->
      stopped =
        %{
          schema_version: 3,
          runtime: "imp",
          status: "stopped",
          source_commits: source_commits_for_stopped_output(),
          call_budgets: stopped_observer_field(:call_budgets),
          actual_cost: stopped_observer_field(:actual_cost),
          usd_reserved: stopped_observer_field(:usd_reserved),
          lm_results: stopped_observer_field(:responses),
          transport_events: stopped_observer_field(:transports),
          rescue_accounting: stopped_rescue_accounting(),
          error: Exception.format(:error, error, __STACKTRACE__)
        }
        |> Map.merge(stopped_binding_fields())

      atomic_write!(@output, stopped)

      reraise error, __STACKTRACE__
  end

  def shadow_preflight do
    bootstrap_digest = authenticate_bootstrap_environment!()
    ensure_transport_runtime_started!()

    if String.trim(System.get_env("OPENROUTER_API_KEY", "")) != "",
      do: raise("Imp shadow preflight received provider authority")

    manifest = MatchedIFBenchR16k.Contract.load_optimization!(@manifest)
    launch_commit = require_expected_launch_commit!()
    # Shadow mode makes zero provider calls and runs the uncommitted rehearsal
    # surface on purpose; the clean-tree capture applies only to the live run.
    source_commits = source_commits!(manifest, false, launch_commit)
    verify_runtime_dependencies!(manifest)

    api_base_url = System.fetch_env!("MATCHED_IFBENCH_R16K_API_BASE_URL")
    catalog_base_url = System.fetch_env!("MATCHED_IFBENCH_R16K_CATALOG_BASE_URL")
    health_url = System.fetch_env!("MATCHED_IFBENCH_R16K_HEALTH_URL")
    ca_cert = System.fetch_env!("MATCHED_IFBENCH_R16K_TLS_CA_CERT")
    connect_options = [transport_opts: [cacertfile: String.to_charlist(ca_cert)]]

    %{status: 200, body: %{"status" => "ready"}} =
      Req.get!(health_url,
        retry: :transient,
        max_retries: 3,
        connect_options: connect_options
      )

    catalog =
      verify_models!(manifest,
        catalog_base_url: catalog_base_url,
        connect_options: connect_options
      )

    {:ok, shadow_finch} =
      Finch.start_link(
        name: MatchedIFBenchR16kImp.ShadowFinch,
        pools: %{
          default: [conn_opts: [transport_opts: [cacertfile: String.to_charlist(ca_cert)]]]
        }
      )

    results =
      try do
        Enum.map([task: 17, optimizer: nil], fn {role, seed} ->
          lm = remote_lm(manifest, Atom.to_string(role), seed)

          case Imp.Clients.ReqLLM.generate(
                 lm,
                 [%{role: :user, content: "shadow #{role}"}],
                 cache: false
               ) do
            {:ok, result} -> %{role: role, result: Report.encode_term(result)}
            {:error, reason} -> raise "Imp shadow #{role} transport failed: #{inspect(reason)}"
          end
        end)
      after
        Supervisor.stop(shadow_finch)
      end

    report = %{
      status: "pass",
      runtime: "imp",
      source_commits: source_commits,
      provider_authority_present: false,
      held_out_loaded: false,
      applications_started: %{
        ssl: application_started?(:ssl),
        req: application_started?(:req),
        imp: application_started?(:imp)
      },
      transport_roles: Enum.map(results, & &1.role),
      transport_count: length(results),
      catalog_roles: catalog |> Map.keys() |> Enum.sort(),
      tls_ca_sha256: sha256_file(ca_cert),
      bootstrap_digest: bootstrap_digest
    }

    IO.puts("PAIRED_SHADOW_JSON=" <> Jason.encode!(report))
    :ok
  end

  defp ensure_transport_runtime_started! do
    Enum.each([:ssl, :req, :imp], fn application ->
      case Application.ensure_all_started(application) do
        {:ok, _started} ->
          :ok

        {:error, reason} ->
          raise "cannot start required transport application #{application}: #{inspect(reason)}"
      end
    end)

    unless Enum.all?([:ssl, :req, :imp], &application_started?/1),
      do: raise("required transport applications are not running")
  end

  defp application_started?(application) do
    Enum.any?(Application.started_applications(), fn {name, _description, _version} ->
      name == application
    end)
  end

  defp compile_and_seal({seed, arm}, manifest, rows, observer) do
    before_arm = Observer.snapshot(observer)

    :ok =
      Observer.register_budget(observer, seed, arm, manifest["execution"]["call_ceilings"][arm])

    task_lm = observed(task_lm(manifest, seed), observer, :task, seed, arm, manifest)
    optimizer_lm = observed(optimizer_lm(manifest), observer, :optimizer, seed, arm, manifest)
    baseline = program(task_lm)
    Observer.phase(observer, %{seed: seed, arm: arm, phase: "compile"})

    selected = compile(arm, baseline, rows, seed, optimizer_lm, task_lm, manifest)

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
    preheld_counts = enforce_call_ceiling!(arm, before_arm, after_selection, manifest, 128)
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
            score: score.mean_constraint_score,
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
        "IMP_MATCHED_IFBENCH_R16K_UPSTREAM_SELECTION",
        Path.expand(
          "../../tmp/matched_ifbench_rehearsal16k/upstream-result.json.selection-sealed.json",
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
               length(receipt["selections"] || []) == 3 do
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
                  "task_logical" => 128,
                  "optimizer_logical" => 0,
                  "transports" => 128,
                  "total_logical" => 128
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

  defp compile("baseline", program, _rows, _seed, _optimizer_lm, _task_lm, _manifest),
    do: program

  defp compile("gepa", program, rows, seed, optimizer_lm, _task_lm, manifest) do
    config = manifest["optimizer"]["gepa"]

    metric = feedback_metric()

    GEPA.new(metric,
      execution_profile: :gepa_v0_1_4,
      reflection_lm: optimizer_lm,
      # Semantic budget is the pinned profile's authority and supersedes the
      # BEAM-native generations knob: 1200 metric calls (~1/3 of the paper's
      # 3,593 IFBench budget), legal iteration cap 1400, reflection cap 24.
      max_metric_calls: config["semantic_max_metric_calls"],
      minibatch_size: config["minibatch_size"],
      seed: seed,
      candidate_selection_strategy: :pareto,
      module_selector: :round_robin,
      acceptance_policy: :strict_improvement,
      selection_strategy: :all_improvements,
      use_merge: false,
      reflection_record_mode: :gepa_v0_1_4,
      component_feedback: Imp.BenchmarkTruth.IFBenchFeedback.callbacks(metric),
      max_concurrency: 1,
      # Matched to upstream's effective per-call ceiling: litellm's default
      # request timeout is 6000s and pinned DSPy sets none stricter. The
      # prior 120s here was 50x tighter than the matched arm and killed two
      # slow-tail calls upstream would have waited out (pilot stop,
      # 2026-08-09) - severed dispatches then tripped the call-accounting
      # consistency check, which treats spend without recorded outcome as a
      # stop condition (correctly).
      timeout: 6_000_000,
      proposal_timeout: 6_000_000,
      raise_on_exception: true,
      # Score-integrity bindings (2026-08-09): the evaluation cache identity
      # is fingerprinted so a resumed run can never replay entries from a
      # different configuration, and resume_cache: :drop mirrors pinned gepa
      # v0.1.4 exactly (upstream does not persist its evaluation cache across
      # runs), keeping resumed-arm budget accounting matched.
      cache_identity: %{
        campaign: "matched-ifbench-rehearsal16k-v1",
        arm: "gepa",
        seed: seed,
        train_sha256: manifest["dataset"]["train_sha256"],
        selection_sha256: manifest["dataset"]["selection_sha256"]
      },
      resume_cache: :drop
    )
    |> GEPA.compile(program, examples(rows.train, true), examples(rows.selection, false))
  end

  defp compile("mipro_v2", program, rows, seed, optimizer_lm, task_lm, manifest) do
    config = manifest["optimizer"]["mipro_v2"]

    MIPROv2.new(scalar_metric(),
      auto: nil,
      # 6 candidates / 18 trials: ~1/3 of the paper's IFBench MIPROv2-Heavy shape.
      num_candidates: config["num_candidates"],
      num_trials: config["trials"],
      minibatch: false,
      max_bootstrapped_demos: 0,
      max_labeled_demos: 0,
      startup_trials: config["startup_trials"],
      search_fidelity: :dspy_3_2_1_optuna_4_9_0_startup,
      proposer_fidelity: :dspy_3_2_1,
      program_aware_proposer: false,
      data_aware_proposer: true,
      tip_aware_proposer: true,
      fewshot_aware_proposer: false,
      view_data_batch_size: 10,
      prompt_lm: optimizer_lm,
      task_lm: task_lm,
      max_concurrency: 1,
      timeout: 6_000_000,
      # Refusal tolerance (2026-08-09, owner-approved): symmetric with the
      # upstream arm's max_errors=48 - refused/unparseable rows score 0
      # instead of killing the campaign; operational errors stay fatal.
      max_errors: 48,
      seed: seed
    )
    |> MIPROv2.compile(program, examples(rows.train, true), examples(rows.selection, false))
  end

  defp program(lm) do
    Imp.BenchmarkTruth.IFBenchTwoStage.new(lm,
      adapter: Imp.Adapter.Chat,
      config: [cache: false, json_fallback: false]
    )
  end

  defp feedback_metric do
    Imp.BenchmarkTruth.GepaMetrics.metric_with_feedback(
      %{"upstream_metric" => "IFBench.ifbench_metric.metric"},
      upstream_descriptions: true,
      gepa_root: System.fetch_env!("IMP_GEPA_ARTIFACT_ROOT"),
      python: System.fetch_env!("IMP_GEPA_PYTHON")
    )
  end

  defp scalar_metric do
    Imp.BenchmarkTruth.GepaMetrics.metric(%{"upstream_metric" => "IFBench.ifbench_metric.metric"})
  end

  defp examples(rows, feedback_allowed) do
    Enum.map(rows, fn row ->
      example(row, feedback_allowed)
    end)
  end

  defp evaluate(program, rows, observer, seed, arm, phase, expected_model) do
    Observer.phase(observer, %{seed: seed, arm: arm, phase: phase})

    Enum.map(rows, fn row ->
      before = Observer.snapshot(observer)
      started = System.monotonic_time()
      result = Imp.call(program, %{prompt: row.prompt})
      after_call = Observer.snapshot(observer)
      messages = Enum.drop(after_call.messages, length(before.messages))
      responses = Enum.drop(after_call.responses, length(before.responses))
      transports = Enum.drop(after_call.transports, length(before.transports))

      case result do
        {:error, %Imp.OperationalSafetyError{} = safety} -> raise safety
        _other -> :ok
      end

      {actual, error, metadata} =
        case result do
          {:ok, prediction} ->
            {Imp.Prediction.get(prediction, :response), nil, prediction.metadata}

          {:error, reason} ->
            {nil, reason, nil}
        end

      unless length(messages) in 1..2 and length(messages) == length(responses) and
               length(responses) == length(transports),
             do: raise("#{arm}/#{phase}/#{row.id} used an invalid two-stage call envelope")

      evidences =
        Enum.map(
          responses,
          &MatchedIFBenchR16k.ResponseEvidence.from_result!(&1.result)
        )

      Enum.zip(evidences, transports)
      |> Enum.each(fn {response, transport} ->
        validate_transport_evidence!(
          %{
            model: response.model,
            route: response.route,
            attempts: map_get(transport.measurements, :count),
            retry: map_get(transport.metadata, :retry),
            input_tokens: response.input_tokens,
            output_tokens: response.output_tokens,
            finish_reason: response.finish_reason,
            content: response.content,
            gateway: response.gateway,
            service_tier: response.service_tier,
            gateway_reported_cost: response.gateway_reported_cost,
            computed_cost: response.computed_cost
          },
          expected_model,
          "#{arm}/#{phase}/#{row.id}"
        )
      end)

      score =
        case result do
          {:ok, prediction} -> scalar_metric().(example(row, false), prediction)
          _ -> 0.0
        end

      %{
        source_id: row.id,
        instruction_id_list: row.instruction_id_list,
        parsed_response: actual,
        score: score,
        error: if(is_nil(error), do: nil, else: Report.encode_term(error)),
        raw_response: Enum.map(evidences, & &1.content),
        prediction_metadata: Report.encode_term(metadata),
        rendered_messages: Enum.map(messages, & &1.messages),
        transports: Report.encode_term(transports),
        actual_model: Enum.map(evidences, & &1.model),
        actual_route: Enum.map(evidences, & &1.route),
        gateway: Enum.map(evidences, & &1.gateway),
        service_tier: Enum.map(evidences, & &1.service_tier),
        request_seed: seed,
        transport_attempts: Enum.map(transports, &map_get(&1.measurements, :count)),
        input_tokens: Enum.sum(Enum.map(evidences, & &1.input_tokens)),
        output_tokens: Enum.sum(Enum.map(evidences, & &1.output_tokens)),
        finish_reason: Enum.map(evidences, & &1.finish_reason),
        gateway_reported_cost: Enum.sum(Enum.map(evidences, & &1.gateway_reported_cost)),
        adapter_computed_cost: Enum.sum(Enum.map(evidences, & &1.computed_cost)),
        wall_seconds: elapsed(started)
      }
    end)
  end

  defp aggregate(rows) do
    %{
      mean_constraint_score: Enum.sum(Enum.map(rows, & &1.score)) / length(rows),
      parse_errors: Enum.count(rows, &(not is_nil(&1.error))),
      count: length(rows)
    }
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
    %{
      train:
        split_rows!(
          manifest["dataset"]["train_path"],
          manifest["dataset"]["split_ids"]["train"]
        ),
      selection:
        split_rows!(
          manifest["dataset"]["selection_path"],
          manifest["dataset"]["split_ids"]["selection"]
        )
    }
  end

  defp held_out_rows!(manifest) do
    unless sha256_file(manifest["dataset"]["held_out_path"]) ==
             manifest["dataset"]["held_out_sha256"],
           do: raise("held-out split digest drift")

    ids = manifest["dataset"]["split_ids"]["held_out"]
    split_rows!(manifest["dataset"]["held_out_path"], ids)
  end

  defp split_rows!(path, expected_ids) do
    wanted = MapSet.new(expected_ids)

    rows =
      path
      |> File.stream!()
      |> Enum.map(&Jason.decode!/1)
      |> Enum.filter(&MapSet.member?(wanted, &1["source_id"]))
      |> Map.new(&{&1["source_id"], row!(&1)})

    Enum.map(expected_ids, &Map.fetch!(rows, &1))
  end

  defp row!(row) do
    %{
      id: row["source_id"],
      prompt: row["prompt"],
      instruction_id_list: row["instruction_id_list"],
      kwargs: row["kwargs"]
    }
  end

  defp example(row, feedback_allowed) do
    row
    |> Map.put(:feedback_allowed, feedback_allowed)
    |> Imp.Example.new()
    |> Imp.Example.with_inputs([:prompt])
  end

  defp task_lm(manifest, seed),
    do: remote_lm(manifest, "task", seed)

  defp optimizer_lm(manifest),
    do: remote_lm(manifest, "optimizer", nil)

  defp remote_lm(manifest, role, seed) do
    model = manifest["models"][role]
    request = manifest["execution"]["request"][role]
    guard = openrouter_guard(manifest, role)
    api_base_url = System.fetch_env!("MATCHED_IFBENCH_R16K_API_BASE_URL")
    shadow? = String.trim(System.get_env("OPENROUTER_API_KEY", "")) == ""

    api_key =
      if shadow?, do: "local-shadow-only", else: System.fetch_env!("OPENROUTER_API_KEY")

    # Explicit no-retry at the Req layer is what installs the client's
    # transport-attempt telemetry guard (req_llm.ex enforce_explicit_no_retry):
    # observability and no-hidden-retries are one mechanism. Transient retries
    # live in ObservedLM.dispatch_with_retries/3 where the ledger can see them.
    req_http_options = [retry: false, max_retries: 0]

    req_http_options =
      if shadow?,
        do:
          Keyword.put(
            req_http_options,
            :finch,
            MatchedIFBenchR16kImp.ShadowFinch
          ),
        else: req_http_options

    opts = [
      api_key: api_key,
      cache: false,
      max_tokens: request["max_tokens"],
      max_retries: 0,
      timeout: 6_000_000,
      provider_options: [openrouter_provider: guard, openrouter_usage: %{include: true}],
      req_http_options: req_http_options
    ]

    opts =
      Keyword.put(opts, :base_url, api_base_url)

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
      expected_model: model_contract(manifest, Atom.to_string(role)),
      hard_stop_completion_tokens:
        manifest["execution"]["request"][Atom.to_string(role)]["hard_stop_completion_tokens"]
    }

  defp verify_models!(manifest, opts \\ []) do
    catalog_base_url = Keyword.get(opts, :catalog_base_url, "https://openrouter.ai/api/v1")
    connect_options = Keyword.get(opts, :connect_options)

    snapshots =
      Map.new(~w(task optimizer), fn role ->
        expected = manifest["models"][role]
        endpoint_url = "#{catalog_base_url}/models/#{expected["logical"]}/endpoints"
        request_options = [retry: :transient, max_retries: 3]

        request_options =
          if connect_options,
            do: Keyword.put(request_options, :connect_options, connect_options),
            else: request_options

        body = Req.get!(endpoint_url, request_options).body
        endpoints = get_in(body, ["data", "endpoints"]) || body["data"] || []
        tags = manifest["execution"]["openrouter"]["#{role}_order"]

        eligible =
          endpoints
          |> Enum.filter(fn endpoint ->
            endpoint["provider_name"] == expected["endpoint_provider"] and
              endpoint["tag"] in tags and
              price_lte?(
                get_in(endpoint, ["pricing", "prompt"]),
                expected["catalog_prompt_per_token"]
              ) and
              price_lte?(
                get_in(endpoint, ["pricing", "completion"]),
                expected["catalog_completion_per_token"]
              ) and
              required_parameters?(endpoint, role)
          end)
          |> Enum.sort_by(&to_string(&1["tag"]))

        if eligible == [],
          do: raise("no exact first-party #{role} endpoint satisfies pricing/parameter guard")

        bounded = %{
          endpoint_url: endpoint_url,
          model: expected["logical"],
          eligible_endpoints: eligible,
          sha256: :crypto.hash(:sha256, Jason.encode!(eligible)) |> Base.encode16(case: :lower)
        }

        {role, bounded}
      end)

    snapshots
  end

  defp verify_runtime_dependencies!(manifest) do
    expected = manifest["runtime_dependencies"]["imp"]

    actual_otp = :erlang.system_info(:otp_release) |> List.to_string()

    unless System.version() == expected["elixir"] and actual_otp == expected["otp"],
      do: raise("Imp Elixir/OTP runtime dependency drift")

    root_lock = Path.expand(expected["mix_lock_path"], __DIR__)
    consumer_lock = Path.expand(expected["consumer_mix_lock_path"], __DIR__)

    unless sha256_file(root_lock) == expected["mix_lock_sha256"] and
             sha256_file(consumer_lock) == expected["consumer_mix_lock_sha256"],
           do: raise("Imp Mix lock dependency drift")

    actual =
      Map.new(expected["packages"], fn {name, _version} ->
        app = String.to_existing_atom(name)
        version = Application.spec(app, :vsn) || raise("Imp dependency #{name} is not loaded")
        {name, to_string(version)}
      end)

    unless actual == expected["packages"],
      do: raise("Imp dependency version drift: #{inspect(actual)}")
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
    manifest["models"][role]
    |> Map.put(
      "max_input_tokens",
      manifest["execution"]["request"][role]["max_input_tokens"]
    )
    |> Map.put("max_output_tokens", manifest["execution"]["request"][role]["max_tokens"])
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
      response = MatchedIFBenchR16k.ResponseEvidence.from_result!(entry.result)
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
             is_integer(evidence.attempts) and evidence.attempts in 1..4 and
             evidence.retry == false and
             is_number(evidence.input_tokens) and
             evidence.input_tokens <= expected["max_input_tokens"] and
             is_number(evidence.output_tokens) and
             evidence.output_tokens <= expected["max_output_tokens"] and
             is_binary(evidence.finish_reason) and
             is_binary(evidence.content) and evidence.gateway == "openrouter" and
             evidence.service_tier in [nil, "default", "standard"] and
             is_number(evidence.gateway_reported_cost) and evidence.gateway_reported_cost >= 0 and
             is_number(evidence.computed_cost) and evidence.computed_cost >= 0 and
             MatchedIFBenchR16k.ResponseEvidence.costs_reconcile?(
               evidence.gateway_reported_cost,
               evidence.computed_cost
             ) do
      raise "#{context} lacks exact route/model/attempt/token/finish/content transport evidence: #{inspect(evidence)}"
    end
  end

  defp artifact_path(seed, arm),
    do: Path.join(Path.dirname(@output), "sealed/imp-#{seed}-#{arm}.json")

  defp source_commits!(manifest, clean?, expected \\ require_expected_launch_commit!()) do
    pinned = %{
      "dspy" => manifest["authorities"]["dspy"]["commit"],
      "gepa" => manifest["authorities"]["gepa"]["commit"]
    }

    root = Path.expand("../..", __DIR__)

    commits =
      if clean?,
        do: MatchedIFBenchR16k.SourceIdentity.capture_clean!(root, pinned),
        else: MatchedIFBenchR16k.SourceIdentity.current(root, pinned)

    if expected == commits["imp"],
      do: commits,
      else: raise("GEPA 0.1.4 successor launch commit drift: #{commits["imp"]} != #{expected}")
  end

  defp source_commits_for_stopped_output do
    manifest = @manifest |> File.read!() |> Jason.decode!()
    source_commits!(manifest, false)
  rescue
    _error -> %{"imp" => "unavailable", "dspy" => "unavailable", "gepa" => "unavailable"}
  end

  defp stopped_observer_field(field) do
    case Process.get(:matched_ifbench_observer) do
      pid when is_pid(pid) ->
        pid
        |> Observer.snapshot()
        |> Map.fetch!(field)
        |> Report.encode_term()

      _ ->
        stopped_observer_default(field)
    end
  rescue
    _error -> stopped_observer_default(field)
  end

  defp stopped_observer_default(field) when field in [:actual_cost, :usd_reserved], do: 0.0
  defp stopped_observer_default(:call_budgets), do: %{}
  defp stopped_observer_default(field) when field in [:responses, :transports], do: []

  defp stopped_payload(observer, source_commits, launch_commit, error) do
    snapshot = Observer.snapshot(observer)

    %{
      schema_version: 3,
      runtime: "imp",
      status: "stopped",
      source_commits: source_commits,
      call_budgets: Report.encode_term(snapshot.call_budgets),
      actual_cost: snapshot.actual_cost,
      usd_reserved: snapshot.usd_reserved,
      lm_results: Report.encode_term(snapshot.responses),
      transport_events: Report.encode_term(snapshot.transports),
      rescue_accounting: rescue_accounting(snapshot),
      error: error
    }
    |> Map.merge(stopped_binding_fields(launch_commit))
  end

  defp require_expected_launch_commit! do
    case System.get_env("MATCHED_IFBENCH_R16K_EXPECTED_COMMIT") do
      value when is_binary(value) and byte_size(value) == 40 -> value
      _ -> raise "MATCHED_IFBENCH_R16K_EXPECTED_COMMIT is required as a full commit"
    end
  end

  defp authenticate_bootstrap_environment! do
    materialized = System.fetch_env!("MATCHED_IFBENCH_R16K_BOOTSTRAP_SPEC")
    expected_digest = System.fetch_env!("MATCHED_IFBENCH_R16K_BOOTSTRAP_DIGEST")
    actual_digest = :crypto.hash(:sha256, materialized) |> Base.encode16(case: :lower)
    manifest = @manifest |> File.read!() |> Jason.decode!()
    bound_digest = manifest["bootstrap_contract"]["digest"]

    if actual_digest != expected_digest or expected_digest != bound_digest,
      do: raise("peer bootstrap digest mismatch")

    spec = Jason.decode!(materialized)

    if spec != expected_bootstrap_spec!(),
      do: raise("peer canonical bootstrap specification mismatch")

    Enum.each(spec["common_environment"], fn {key, expected} ->
      if key == "MATCHED_IFBENCH_R16K_EXPECTED_COMMIT" do
        if byte_size(System.get_env(key, "")) != 40,
          do: raise("peer launch commit binding is absent")
      else
        if System.get_env(key) != expected,
          do: raise("peer fixed bootstrap environment drift: #{key}")
      end
    end)

    if System.get_env("LITELLM_LOCAL_MODEL_COST_MAP") != "True",
      do: raise("peer bootstrap may reach the remote LiteLLM cost map")

    if System.get_env("OPENAI_API_KEY") != "" or System.get_env("ANTHROPIC_API_KEY") != "",
      do: raise("ambient provider credentials escaped canonical bootstrap")

    expected_digest
  end

  defp expected_bootstrap_spec! do
    root = Path.expand("../..", __DIR__)
    tmp = Path.join(root, "tmp")
    ifbench = Path.join(tmp, "ifbench-parity-venv")
    treatment_tmp = Path.join(tmp, "matched_ifbench_rehearsal16k")
    upstream_python = Path.join([tmp, "dspy-parity-venv", "bin", "python"])

    %{
      "schema_version" => 1,
      "commands" => %{
        "imp" => %{
          "argv" => ["mix", "run", "run_imp.exs"],
          "cwd" => __DIR__
        },
        "upstream" => %{
          "argv" => [
            upstream_python,
            Path.join(__DIR__, "run_upstream.py"),
            "--dspy-root",
            Path.join(tmp, "dspy-3.2.1"),
            "--gepa-root",
            Path.join(tmp, "gepa-v0.1.4"),
            "--gepa-artifact-root",
            Path.join(tmp, "gepa-artifact"),
            "--ifbench-site-packages",
            Path.join([ifbench, "lib", "python3.13", "site-packages"])
          ],
          "cwd" => root
        }
      },
      "common_environment" => %{
        "ANTHROPIC_API_KEY" => "",
        "IMP_GEPA_ARTIFACT_ROOT" => Path.join(tmp, "gepa-artifact"),
        "IMP_GEPA_PYTHON" => Path.join([ifbench, "bin", "python"]),
        "IMP_IFBENCH_NLP_BRIDGE" => Path.join([root, "scripts", "ifbench_nlp_check.py"]),
        "IMP_IFBENCH_NLP_PYTHON" => Path.join([ifbench, "bin", "python"]),
        "IMP_MATCHED_IFBENCH_R16K_OUTPUT" => Path.join(treatment_tmp, "imp-result.json"),
        "IMP_MATCHED_IFBENCH_R16K_UPSTREAM_SELECTION" =>
          Path.join(treatment_tmp, "upstream-result.json.selection-sealed.json"),
        "LITELLM_LOCAL_MODEL_COST_MAP" => "True",
        "MATCHED_IFBENCH_R16K_EXPECTED_COMMIT" => "$LAUNCH_COMMIT",
        "NLTK_DATA" => Path.join(ifbench, "nltk_data"),
        "OPENAI_API_KEY" => "",
        "UPSTREAM_MATCHED_IFBENCH_R16K_IMP_SELECTION" =>
          Path.join(treatment_tmp, "imp-result.json.selection-sealed.json"),
        "UPSTREAM_MATCHED_IFBENCH_R16K_OUTPUT" =>
          Path.join(treatment_tmp, "upstream-result.json")
      },
      "mode_substitutions" => %{
        "MATCHED_IFBENCH_R16K_API_BASE_URL" => "endpoint_url",
        "MATCHED_IFBENCH_R16K_CATALOG_BASE_URL" => "endpoint_url",
        "MATCHED_IFBENCH_R16K_HEALTH_URL" => "endpoint_url",
        "MATCHED_IFBENCH_R16K_TLS_CA_CERT" => "endpoint_trust",
        "OPENROUTER_API_KEY" => "provider_credential",
        "SSL_CERT_FILE" => "endpoint_trust"
      },
      "bootstrap_invariants" => %{
        "dotenv_provider_keys_blocked" => ["OPENAI_API_KEY", "ANTHROPIC_API_KEY"],
        "local_cost_map" => true,
        "provider_authority_owned_only_by_openrouter_substitution" => true
      }
    }
  end

  defp stopped_binding_fields(
         launch_commit \\ System.get_env("MATCHED_IFBENCH_R16K_EXPECTED_COMMIT") ||
           "unavailable"
       ) do
    %{
      manifest_sha256: sha256_file(@manifest),
      launch_commit: launch_commit,
      bootstrap_digest: System.get_env("MATCHED_IFBENCH_R16K_BOOTSTRAP_DIGEST", "unavailable")
    }
  rescue
    _error ->
      %{
        manifest_sha256: "unavailable",
        launch_commit: launch_commit,
        bootstrap_digest:
          System.get_env("MATCHED_IFBENCH_R16K_BOOTSTRAP_DIGEST", "unavailable")
      }
  end

  defp stopped_rescue_accounting do
    case Process.get(:matched_ifbench_observer) do
      pid when is_pid(pid) -> pid |> Observer.snapshot() |> rescue_accounting()
      _ -> empty_rescue_accounting()
    end
  rescue
    _error -> empty_rescue_accounting()
  end

  defp rescue_accounting(snapshot) do
    MatchedIFBenchR16kImp.StopAccounting.normalize(
      snapshot.call_budgets,
      snapshot.responses,
      snapshot.transports
    )
  end

  defp empty_rescue_accounting, do: MatchedIFBenchR16kImp.StopAccounting.empty()

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

unless System.get_env("IMP_MATCHED_IFBENCH_R16K_LOAD_ONLY") == "1" do
  if String.trim(System.get_env("OPENROUTER_API_KEY", "")) == "",
    do: MatchedIFBenchR16kImp.Runner.shadow_preflight(),
    else: MatchedIFBenchR16kImp.Runner.run()
end
