defmodule Imp.BenchmarkTruth.OptimizeAnything.UpstreamDifferential do
  @moduledoc false

  alias Imp.Optimize.Anything, as: OptimizeAnything
  alias Imp.Optimize.Anything.{Config, Result}

  @default_manifest "benchmarks/config/optimize-anything-upstream-differential-v1.json"
  @default_python "tmp/optimize-anything-upstream/.venv/bin/python"
  @default_runner "scripts/optimize_anything_upstream_differential.py"
  @authority_registry_reader Path.expand(
                               "../../../../scripts/upstream_authority_registry.py",
                               __DIR__
                             )

  @task_source Path.expand(
                 "../../../mix/tasks/imp.benchmark.optimize_anything_upstream_differential.ex",
                 __DIR__
               )

  @reproduction_registry Path.expand("../../../../benchmarks/reproductions.json", __DIR__)
  @authority_contract "optimize_anything_upstream_differential_protocol"
  @dataset_contract "optimize_anything_swe_bench_flask_5014_dataset"
  @domain_ids ["circle_packing_26", "blackbox_problem_46", "swe_bench_flask_5014"]
  @artifact_schema_version 2
  @report_schema_version 2
  @runtime_timeout 900_000
  @evaluator_timeouts %{
    "circle_packing_26" => 45_000,
    "blackbox_problem_46" => 45_000,
    "swe_bench_flask_5014" => 90_000
  }

  @claim_limitations [
    "local SHA-256 receipts bind bundle content but are not signatures or provider attestations",
    "provider execution and billing are not cryptographically proven; Imp usage comes from correlated ReqLLM telemetry and upstream usage comes from pinned LiteLLM response counters"
  ]

  @upstream_evidence_wrapper ~S"""
  import importlib.util
  import json
  import sys
  from pathlib import Path

  runner_path, manifest_path, domain_id, seed_text, output_path = sys.argv[1:]
  spec = importlib.util.spec_from_file_location("imp_oa_pinned_runner", runner_path)
  module = importlib.util.module_from_spec(spec)
  spec.loader.exec_module(module)

  evaluations = []
  reflection_calls = []
  original_evaluate = module.evaluate_domain
  original_counting_lm = module.CountingLM

  def digest(value):
      payload = json.dumps(
          module.json_value(value), sort_keys=True, separators=(",", ":")
      ).encode("utf-8")
      return module.sha256_bytes(payload)

  def record_evaluate(manifest, authorities, recorded_domain, candidate):
      observed = original_evaluate(manifest, authorities, recorded_domain, candidate)
      evaluations.append({
          "sequence": len(evaluations) + 1,
          "candidate": candidate,
          "observed": observed,
      })
      return observed

  class EvidenceCountingLM(original_counting_lm):
      def __call__(self, prompt):
          before_cost = self.total_cost
          before_input = self.total_tokens_in
          before_output = self.total_tokens_out
          response = super().__call__(prompt)
          model = str(getattr(self.inner, "model", "unknown"))
          provider = model.split("/", 1)[0] if "/" in model else "unknown"
          event = {
              "sequence": 1,
              "source": "litellm_response_usage_delta",
              "event": "litellm.completion",
              "provider": provider,
              "model": model,
              "request_id_sha256": None,
              "input_tokens": self.total_tokens_in - before_input,
              "output_tokens": self.total_tokens_out - before_output,
              "cost_usd": self.total_cost - before_cost,
          }
          reflection_calls.append({
              "sequence": len(reflection_calls) + 1,
              "source": "pinned_litellm_call_wrapper",
              "prompt_sha256": digest(prompt),
              "response_sha256": module.sha256_bytes(response.encode("utf-8")),
              "status": "ok",
              "usage_events": [event],
          })
          return response

  module.evaluate_domain = record_evaluate
  module.CountingLM = EvidenceCountingLM
  manifest = module.load_manifest(Path(manifest_path))
  authorities = module.verify_authorities(manifest)
  report = module.run_upstream(manifest, authorities, domain_id, int(seed_text))

  metric_calls = int(report["metric_calls"])
  if len(evaluations) != metric_calls + 1:
      raise RuntimeError(
          f"expected {metric_calls + 1} evaluator observations, got {len(evaluations)}"
      )
  if len(reflection_calls) != int(report["reflection_calls"]):
      raise RuntimeError("upstream reflection evidence count mismatch")

  for trace, evidence in zip(report["evaluation_trace"], evaluations[:metric_calls]):
      observed = evidence["observed"]
      if (
          trace["candidate_sha256"] != observed["candidate_sha256"]
          or trace["score"] != observed["score"]
          or trace["objective_calls"] != observed["objective_calls"]
      ):
          raise RuntimeError("upstream trace does not match captured evaluator evidence")

  verification = evaluations[-1]
  if verification["candidate"] != report["best_candidate"]:
      raise RuntimeError("upstream verification candidate mismatch")

  report["evaluation_evidence"] = evaluations[:metric_calls]
  report["verification_evidence"] = verification
  report["reflection_evidence"] = reflection_calls
  report["stop_reason"] = "not_exposed_by_pinned_runner"
  module.write_json(Path(output_path), report)
  """

  defmodule AuditedLM do
    @moduledoc false

    @behaviour Imp.LM

    defstruct [:inner, :audit]

    def new(inner, audit), do: %__MODULE__{inner: inner, audit: audit}

    def initial_state, do: %{next_sequence: 1, active: %{}, calls: []}

    @impl true
    def generate(_messages, _opts), do: {:error, :audited_lm_instance_required}

    def generate(%__MODULE__{} = lm, messages, opts) do
      sequence = begin_call!(lm.audit, messages)
      result = Imp.LM.generate(lm.inner, messages, opts)
      finish_call!(lm.audit, sequence, result)
      result
    end

    def record_usage(audit, measurements, metadata) do
      caller = self()

      Agent.update(audit, fn state ->
        case Map.fetch(state.active, caller) do
          {:ok, call} ->
            events = call["usage_events"]
            event = usage_event(measurements, metadata, length(events) + 1)
            put_in(state, [:active, caller], %{call | "usage_events" => events ++ [event]})

          :error ->
            state
        end
      end)
    end

    def calls!(audit) do
      Agent.get(audit, fn state ->
        if map_size(state.active) != 0 do
          raise "Imp reflection usage audit has unfinished calls"
        end

        Enum.sort_by(state.calls, & &1["sequence"])
      end)
    end

    defp begin_call!(audit, messages) do
      caller = self()

      Agent.get_and_update(audit, fn state ->
        if Map.has_key?(state.active, caller) do
          raise "nested Imp reflection call cannot be audited"
        end

        sequence = state.next_sequence

        call = %{
          "sequence" => sequence,
          "source" => "imp_lm_call_audit",
          "prompt_sha256" => term_sha256(messages),
          "usage_events" => []
        }

        {sequence,
         %{
           state
           | next_sequence: sequence + 1,
             active: Map.put(state.active, caller, call)
         }}
      end)
    end

    defp finish_call!(audit, sequence, result) do
      caller = self()

      Agent.update(audit, fn state ->
        {call, active} = Map.pop(state.active, caller)

        unless call && call["sequence"] == sequence do
          raise "Imp reflection usage audit lost call ownership"
        end

        {status, response_sha256} = result_receipt(result)

        call =
          call
          |> Map.put("status", status)
          |> Map.put("response_sha256", response_sha256)

        %{state | active: active, calls: [call | state.calls]}
      end)
    end

    defp result_receipt({:ok, value}), do: {"ok", term_sha256(value)}
    defp result_receipt({:error, value}), do: {"error", term_sha256(value)}
    defp result_receipt(value), do: {"invalid", term_sha256(value)}

    defp usage_event(measurements, metadata, sequence) do
      tokens = fetch(measurements, :tokens, %{})
      model = fetch(metadata, :model, %{})
      provider = fetch(metadata, :provider, fetch(model, :provider, "unknown"))

      model_id =
        fetch(model, :provider_model_id, nil) || fetch(model, :id, nil) ||
          fetch(model, :name, "unknown")

      request_id = fetch(metadata, :request_id, nil)

      %{
        "sequence" => sequence,
        "source" => "req_llm_token_usage_telemetry",
        "event" => "req_llm.token_usage",
        "provider" => to_string(provider),
        "model" => to_string(model_id),
        "request_id_sha256" => if(is_nil(request_id), do: nil, else: term_sha256(request_id)),
        "input_tokens" => trunc(number(tokens, [:input_tokens, :input])),
        "output_tokens" => trunc(number(tokens, [:output_tokens, :output])),
        "cost_usd" => number(measurements, [:total_cost, :cost])
      }
    end

    defp number(map, keys) do
      Enum.find_value(keys, 0, fn key ->
        value = fetch(map, key, nil)
        if is_number(value), do: value
      end)
    end

    defp fetch(map, key, default) when is_map(map),
      do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

    defp fetch(_value, _key, default), do: default

    defp term_sha256(value) do
      value
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
    end
  end

  defmodule RetryLM do
    @moduledoc false

    @behaviour Imp.LM

    @transient_statuses [408, 409, 425, 429, 500, 502, 503, 504, 529]
    @transient_reasons [
      :closed,
      :timeout,
      :econnrefused,
      :enetdown,
      :ehostunreach,
      :pool_not_available
    ]

    defstruct [:inner, :max_retries, :base_delay_ms, :max_delay_ms]

    def new(%__MODULE__{} = lm, _opts), do: lm

    def new(inner, opts) do
      max_retries = Keyword.fetch!(opts, :max_retries)
      base_delay_ms = Keyword.fetch!(opts, :base_delay_ms)
      max_delay_ms = Keyword.fetch!(opts, :max_delay_ms)

      unless is_integer(max_retries) and max_retries >= 0 and is_integer(base_delay_ms) and
               base_delay_ms >= 0 and is_integer(max_delay_ms) and
               max_delay_ms >= base_delay_ms do
        raise ArgumentError, "invalid matched LM retry policy"
      end

      %__MODULE__{
        inner: inner,
        max_retries: max_retries,
        base_delay_ms: base_delay_ms,
        max_delay_ms: max_delay_ms
      }
    end

    @impl true
    def generate(_messages, _opts), do: {:error, :matched_retry_lm_instance_required}

    def generate(%__MODULE__{} = lm, messages, opts) do
      attempt(lm, messages, opts, 0)
    end

    defp attempt(lm, messages, opts, attempt) do
      case Imp.LM.generate(lm.inner, messages, opts) do
        {:error, reason} = error when attempt < lm.max_retries ->
          if retryable?(reason) do
            delay = min(lm.base_delay_ms * Integer.pow(2, attempt), lm.max_delay_ms)

            Imp.Telemetry.execute(
              [:imp, :lm, :retry],
              %{count: 1, delay_ms: delay},
              %{attempt: attempt + 1, max_retries: lm.max_retries}
            )

            if delay > 0, do: Process.sleep(delay)
            attempt(lm, messages, opts, attempt + 1)
          else
            error
          end

        result ->
          result
      end
    end

    defp retryable?(%{status: status}) when status in @transient_statuses, do: true

    defp retryable?(%{cause: cause, reason: reason}),
      do: retryable?(cause) or retryable?(reason)

    defp retryable?(%{cause: cause}), do: retryable?(cause)
    defp retryable?(%{reason: reason}), do: retryable?(reason)
    defp retryable?(reason) when reason in @transient_reasons, do: true

    defp retryable?(tuple) when is_tuple(tuple),
      do: tuple |> Tuple.to_list() |> Enum.any?(&retryable?/1)

    defp retryable?(list) when is_list(list), do: Enum.any?(list, &retryable?/1)
    defp retryable?(_reason), do: false
  end

  @doc "Checks the pinned authority, runner, manifest, and evaluator workspaces."
  def readiness(opts \\ []) when is_list(opts) do
    paths = paths(opts)

    with :ok <- regular_file(paths.manifest, "protocol manifest"),
         :ok <- regular_file(paths.python, "pinned Python executable"),
         :ok <- regular_file(paths.runner, "authority runner"),
         :ok <- verify_canonical_authority_registry(),
         {:ok, description} <- run_python(paths, "describe", [], timeout: 30_000),
         :ok <- verify_description(description, read_json!(paths.manifest)) do
      {:ok, Map.put(paths, :description, description)}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  @doc "Runs the pinned provider-free authority and evaluator verification."
  def verify_evaluators(opts \\ []) when is_list(opts) do
    with {:ok, ready} <- readiness(opts),
         {:ok, artifact} <-
           run_python(ready, "verify-evaluators", [], timeout: 180_000) do
      verify_evaluator_artifact!(artifact, ready.description)
    end
  end

  @doc "Runs the complete matched live differential for every configured domain and seed."
  def run(opts) when is_list(opts) do
    lm = Keyword.fetch!(opts, :lm)
    ready = readiness!(opts)
    manifest = read_json!(ready.manifest)
    description = ready.description
    controls = description["controls"]
    model = controls["model"]

    lm =
      RetryLM.new(lm,
        max_retries: model["imp_retries"],
        base_delay_ms: model["imp_retry_base_delay_ms"],
        max_delay_ms: model["imp_retry_max_delay_ms"]
      )

    domains = selected_domains!(description, Keyword.get(opts, :domains, @domain_ids))
    seeds = selected_seeds!(controls, Keyword.get(opts, :seeds, controls["seeds"]))

    execution_scope = %{
      "domains" => Enum.map(domains, & &1["id"]),
      "seeds" => seeds,
      "full_protocol" =>
        Enum.map(domains, & &1["id"]) == @domain_ids and seeds == controls["seeds"]
    }

    run_root = run_root(opts)
    File.mkdir_p!(run_root)

    rows =
      for domain <- domains,
          seed <- seeds do
        upstream = run_upstream!(ready, domain, seed, run_root, opts)
        imp = run_imp!(ready, manifest, domain, seed, lm, run_root, opts)

        %{
          "domain" => domain["id"],
          "seed" => seed,
          "upstream" => upstream,
          "imp" => imp
        }
      end

    raw_artifact = %{
      "protocol_id" => description["protocol_id"],
      "protocol_class" => description["protocol_class"],
      "generated_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "source_state" => source_state(ready, description),
      "authority" => description["authority"],
      "swe_bench" => description["swe_bench"],
      "isolation" => description["isolation"],
      "controls" => controls,
      "execution_scope" => execution_scope,
      "domains" => Enum.map(domains, &domain_identity/1),
      "rows" => rows
    }

    raw_artifact
    |> build_bundle!(description)
    |> validate_with_ready!(ready)
  end

  def run(opts),
    do: raise(ArgumentError, "differential options must be a keyword list, got: #{inspect(opts)}")

  @doc "Validates and semantically replays a live evidence bundle with the pinned evaluator."
  def validate_artifact!(artifact, description, opts \\ [])

  def validate_artifact!(artifact, description, opts)
      when is_map(artifact) and is_map(description) and is_list(opts) do
    ready = readiness!(opts)

    unless ready.description == description do
      raise ArgumentError, "pinned evaluator description does not match the admission contract"
    end

    validate_with_ready!(artifact, ready)
  rescue
    error ->
      reraise ArgumentError,
              [
                message:
                  "invalid Optimize Anything upstream differential: #{Exception.message(error)}"
              ],
              __STACKTRACE__
  end

  def validate_artifact!(_artifact, _description, _opts),
    do: raise(ArgumentError, "invalid Optimize Anything upstream differential")

  @doc "Validates a captured bundle and admits it only from the current clean source tree."
  def admit_artifact!(artifact, opts \\ [])

  def admit_artifact!(artifact, opts) when is_map(artifact) and is_list(opts) do
    ready = readiness!(opts)
    validate_with_ready!(artifact, ready)
    validate_source_bound_admission!(artifact, ready)
  rescue
    error ->
      reraise ArgumentError,
              [
                message:
                  "Optimize Anything source-bound admission failed: #{Exception.message(error)}"
              ],
              __STACKTRACE__
  end

  def admit_artifact!(_artifact, _opts),
    do: raise(ArgumentError, "invalid Optimize Anything upstream differential admission")

  @doc false
  def build_bundle!(raw_artifact, description)
      when is_map(raw_artifact) and is_map(description) do
    derive_bundle!(raw_artifact, description)
  end

  def build_bundle!(_raw_artifact, _description),
    do: raise(ArgumentError, "Optimize Anything bundle inputs must be maps")

  @doc false
  def evaluator_source_state!(opts \\ []) when is_list(opts) do
    ready = readiness!(opts)
    source_state(ready, ready.description)
  end

  @doc false
  def handle_usage(_event, measurements, metadata, audit),
    do: AuditedLM.record_usage(audit, measurements, metadata)

  defp run_upstream!(ready, domain, seed, run_root, opts) do
    output = Path.join([run_root, "upstream", domain["id"], "seed-#{seed}.json"])
    File.mkdir_p!(Path.dirname(output))

    argv = [
      "-c",
      @upstream_evidence_wrapper,
      ready.runner,
      ready.manifest,
      domain["id"],
      Integer.to_string(seed),
      output
    ]

    try do
      case Imp.ExternalCommand.run(ready.python, argv,
             timeout: Keyword.get(opts, :runtime_timeout, @runtime_timeout),
             max_output_bytes: 32_768,
             cd: File.cwd!()
           ) do
        {:ok, _result} ->
          read_json!(output)

        {:error, reason} ->
          raise "upstream Optimize Anything run failed: #{external_error(reason)}"
      end
    after
      File.rm(output)
    end
  end

  defp run_imp!(ready, manifest, domain, seed, lm, run_root, opts) do
    controls = ready.description["controls"]
    run_dir = Path.join([run_root, "imp", domain["id"], "seed-#{seed}"])
    File.mkdir_p!(run_dir)
    {:ok, evaluations} = Agent.start_link(fn -> [] end)
    {:ok, usage_audit} = Agent.start_link(fn -> AuditedLM.initial_state() end)
    audited_lm = AuditedLM.new(lm, usage_audit)

    evaluator = fn candidate ->
      row = evaluate_candidate!(ready, domain["id"], candidate, run_dir)

      Agent.update(evaluations, fn evidence ->
        evidence ++
          [
            %{
              "sequence" => length(evidence) + 1,
              "candidate" => candidate,
              "observed" => row
            }
          ]
      end)

      {row["score"], row["side_info"]}
    end

    config =
      Config.new(
        engine: [
          run_dir: Path.join(run_dir, "checkpoint"),
          seed: seed,
          raise_on_exception: true,
          track_best_outputs: true,
          max_candidate_proposals: controls["max_candidate_proposals"],
          candidate_selection_strategy:
            candidate_selection_strategy!(controls["candidate_selection_strategy"]),
          frontier_type: frontier_type!(controls["frontier_type"]),
          parallel: controls["parallel"],
          max_workers: controls["max_workers"],
          cache_evaluation: controls["cache_evaluation"]
        ],
        reflection: [
          reflection_lm: audited_lm,
          reflection_minibatch_size: controls["reflection_minibatch_size"],
          reflection_prompt_template: domain["reflection_template"]
        ],
        merge: nil,
        refiner: nil
      )

    try do
      {elapsed_us, result} =
        measure_usage(usage_audit, fn ->
          :timer.tc(fn ->
            OptimizeAnything.run(
              domain["seed_candidate"],
              evaluator,
              config: config,
              timeout: Keyword.get(opts, :evaluator_timeout, @evaluator_timeouts[domain["id"]])
            )
          end)
        end)

      evidence = Agent.get(evaluations, & &1)
      reflection_evidence = AuditedLM.calls!(usage_audit)
      validate_imp_candidate_shape!(result)

      unless result.total_metric_calls == length(evidence) do
        raise "Imp metric-call accounting mismatch: result=#{result.total_metric_calls}, observed=#{length(evidence)}"
      end

      unless result.reflection_calls == length(reflection_evidence) do
        raise "Imp reflection-call accounting mismatch: result=#{result.reflection_calls}, observed=#{length(reflection_evidence)}"
      end

      best_candidate = Result.best_candidate(result)
      verified = evaluate_candidate!(ready, domain["id"], best_candidate, run_dir)
      best_score = Enum.fetch!(result.validation_scores, Result.best_index(result))

      unless close?(best_score, verified["score"]) do
        raise "Imp best score failed independent verification: #{best_score} != #{verified["score"]}"
      end

      %{
        "protocol_id" => manifest["protocol_id"],
        "runtime" => "imp_beam",
        "authority_commit" => manifest["authority"]["commit"],
        "domain" => domain["id"],
        "seed" => seed,
        "model" => controls["model"],
        "controls" => report_controls(controls),
        "wall_time_ms" => max(div(elapsed_us, 1_000), 1),
        "stop_reason" => inspect(result.stop_reason),
        "evaluation_evidence" => evidence,
        "verification_evidence" => %{
          "sequence" => length(evidence) + 1,
          "candidate" => best_candidate,
          "observed" => verified
        },
        "reflection_evidence" => reflection_evidence
      }
    after
      if Process.alive?(evaluations), do: Agent.stop(evaluations)
      if Process.alive?(usage_audit), do: Agent.stop(usage_audit)
    end
  end

  defp evaluate_candidate!(ready, domain_id, candidate, run_dir) when is_binary(candidate) do
    nonce = System.unique_integer([:positive, :monotonic])
    temporary = Path.join(run_dir, "evaluation-#{nonce}")
    File.mkdir_p!(temporary)
    candidate_path = Path.join(temporary, "candidate.txt")
    output_path = Path.join(temporary, "result.json")
    File.write!(candidate_path, candidate)

    try do
      args = ["--domain", domain_id, "--candidate", candidate_path]

      case run_python(ready, "evaluate", args,
             timeout: Map.fetch!(@evaluator_timeouts, domain_id),
             output: output_path
           ) do
        {:ok, row} -> row
        {:error, reason} -> raise "#{domain_id} evaluator failed: #{reason}"
      end
    after
      File.rm_rf!(temporary)
    end
  end

  defp derive_bundle!(raw_artifact, description) do
    controls = description["controls"]
    execution_scope = raw_artifact["execution_scope"]
    rows = raw_artifact["rows"]

    unless valid_execution_scope?(execution_scope, controls) and is_list(rows) and rows != [] do
      raise ArgumentError, "Optimize Anything differential execution scope or rows are invalid"
    end

    descriptions = Map.new(description["domains"], &{&1["id"], &1})

    expected_pairs =
      for domain <- execution_scope["domains"],
          seed <- execution_scope["seeds"],
          do: {domain, seed}

    actual_pairs = Enum.map(rows, &{&1["domain"], &1["seed"]})

    unless actual_pairs == expected_pairs do
      raise ArgumentError,
            "Optimize Anything differential rows do not cover the execution scope exactly"
    end

    selected_domains = Enum.map(execution_scope["domains"], &Map.fetch!(descriptions, &1))
    expected_domains = Enum.map(selected_domains, &domain_identity/1)

    unless raw_artifact["domains"] == expected_domains do
      raise ArgumentError, "Optimize Anything differential domain identities drifted"
    end

    derived_rows =
      Enum.map(rows, fn row ->
        domain = Map.fetch!(descriptions, row["domain"])
        derive_pair!(row, domain, description)
      end)

    generated_at = raw_artifact["generated_at"]
    source_state = raw_artifact["source_state"]

    unless is_binary(generated_at) and is_map(source_state) do
      raise ArgumentError, "Optimize Anything bundle generation evidence is invalid"
    end

    bundle = %{
      "schema_version" => @artifact_schema_version,
      "protocol_id" => description["protocol_id"],
      "protocol_class" => description["protocol_class"],
      "generated_at" => generated_at,
      "source_state" => source_state,
      "authority" => description["authority"],
      "swe_bench" => description["swe_bench"],
      "isolation" => description["isolation"],
      "controls" => controls,
      "claim_scope" => artifact_claim_scope(description["claim_scope"]),
      "execution_scope" => execution_scope,
      "domains" => expected_domains,
      "rows" => derived_rows,
      "summary" => summarize(derived_rows, execution_scope)
    }

    Map.put(bundle, "bundle_receipt", content_receipt("artifact_without_bundle_receipt", bundle))
  end

  defp derive_pair!(raw_pair, domain, description) when is_map(raw_pair) do
    controls = description["controls"]
    authority = description["authority"]
    domain_id = domain["id"]
    seed = raw_pair["seed"]

    unless raw_pair["domain"] == domain_id and is_integer(seed) and seed in controls["seeds"] do
      raise ArgumentError, "invalid differential domain or seed"
    end

    upstream =
      derive_report!(
        raw_pair["upstream"],
        "upstream_python",
        domain,
        seed,
        controls,
        authority,
        description["protocol_id"],
        description["isolation"]
      )

    imp =
      derive_report!(
        raw_pair["imp"],
        "imp_beam",
        domain,
        seed,
        controls,
        authority,
        description["protocol_id"],
        description["isolation"]
      )

    %{
      "domain" => domain_id,
      "seed" => seed,
      "matched_controls" => report_controls(controls),
      "upstream" => upstream,
      "imp" => imp,
      "baseline_scores_match" => close?(upstream["baseline_score"], imp["baseline_score"]),
      "realized_reflection_budget_match" =>
        upstream["reflection_calls"] == imp["reflection_calls"],
      "best_score_delta_imp_minus_upstream" => imp["best_score"] - upstream["best_score"],
      "cost_delta_imp_minus_upstream" => imp["cost_usd"] - upstream["cost_usd"]
    }
  end

  defp derive_pair!(_raw_pair, _domain, _description),
    do: raise(ArgumentError, "Optimize Anything differential pair must be a map")

  defp derive_report!(report, runtime, domain, seed, controls, authority, protocol_id, isolation)
       when is_map(report) do
    expected_controls = report_controls(controls)
    domain_id = domain["id"]

    unless report["runtime"] == runtime and report["domain"] == domain_id and
             report["seed"] == seed and report["protocol_id"] == protocol_id and
             report["authority_commit"] == authority["commit"] and
             report["model"] == controls["model"] and report["controls"] == expected_controls do
      raise ArgumentError, "#{runtime} report identity mismatch for #{domain_id}"
    end

    evidence =
      validate_evaluation_evidence!(report["evaluation_evidence"], domain_id, isolation)

    unless Enum.all?(evidence, &(&1["observed"]["protocol_id"] == protocol_id)) do
      raise ArgumentError, "#{runtime} evaluator protocol drifted for #{domain_id}"
    end

    unless hd(evidence)["candidate"] == domain["seed_candidate"] do
      raise ArgumentError, "#{runtime} baseline candidate drifted for #{domain_id}"
    end

    best =
      Enum.max_by(evidence, fn row ->
        {get_in(row, ["observed", "score"]), -row["sequence"]}
      end)

    verification =
      validate_verification_evidence!(report["verification_evidence"], domain_id, isolation)

    unless verification["sequence"] == length(evidence) + 1 and
             verification["observed"]["protocol_id"] == protocol_id and
             verification["candidate"] == best["candidate"] and
             close?(verification["observed"]["score"], best["observed"]["score"]) do
      raise ArgumentError, "#{runtime} best-candidate verification mismatch for #{domain_id}"
    end

    reflection_evidence =
      validate_reflection_evidence!(report["reflection_evidence"], runtime, controls)

    usage = usage_totals(reflection_evidence)
    baseline_score = get_in(hd(evidence), ["observed", "score"])
    best_score = get_in(best, ["observed", "score"])
    wall_time_ms = report["wall_time_ms"]
    stop_reason = report["stop_reason"]

    unless is_integer(wall_time_ms) and wall_time_ms > 0 and is_binary(stop_reason) do
      raise ArgumentError, "#{runtime} run timing or stop reason is invalid for #{domain_id}"
    end

    derived = %{
      "schema_version" => @report_schema_version,
      "protocol_id" => report["protocol_id"],
      "runtime" => runtime,
      "authority_commit" => authority["commit"],
      "domain" => domain_id,
      "seed" => seed,
      "model" => controls["model"],
      "controls" => expected_controls,
      "baseline_score" => baseline_score,
      "best_score" => best_score,
      "absolute_lift" => best_score - baseline_score,
      "best_candidate" => best["candidate"],
      "best_candidate_sha256" => sha256(best["candidate"]),
      "metric_calls" => length(evidence),
      "objective_calls" =>
        Enum.sum(Enum.map(evidence, &get_in(&1, ["observed", "objective_calls"]))),
      "reflection_calls" => length(reflection_evidence),
      "input_tokens" => usage.input_tokens,
      "output_tokens" => usage.output_tokens,
      "cost_usd" => usage.cost_usd,
      "wall_time_ms" => wall_time_ms,
      "stop_reason" => stop_reason,
      "independent_verification" => verification["observed"],
      "evaluation_trace" => Enum.map(evidence, &trace_row(&1["observed"])),
      "evaluation_evidence" => evidence,
      "verification_evidence" => verification,
      "reflection_evidence" => reflection_evidence,
      "usage_evidence_scope" => usage_evidence_scope(runtime)
    }

    Map.put(derived, "run_receipt", content_receipt("report_without_run_receipt", derived))
  end

  defp derive_report!(
         _report,
         runtime,
         domain,
         _seed,
         _controls,
         _authority,
         _protocol_id,
         _isolation
       ),
       do: raise(ArgumentError, "#{runtime} report must be a map for #{domain["id"]}")

  defp validate_evaluation_evidence!(evidence, domain, isolation)
       when is_list(evidence) and evidence != [] do
    Enum.with_index(evidence, 1)
    |> Enum.map(fn {row, sequence} ->
      validate_evaluation_evidence_row!(row, domain, isolation, sequence)
    end)
  end

  defp validate_evaluation_evidence!(_evidence, domain, _isolation),
    do: raise(ArgumentError, "evaluation evidence is missing for #{domain}")

  defp validate_evaluation_evidence_row!(row, domain, isolation, sequence) when is_map(row) do
    unless MapSet.new(Map.keys(row)) == MapSet.new(~w(sequence candidate observed)) and
             row["sequence"] == sequence and is_binary(row["candidate"]) and
             row["candidate"] != "" do
      raise ArgumentError, "invalid evaluator evidence row #{sequence} for #{domain}"
    end

    validate_observation!(row["observed"], domain, row["candidate"], isolation)
    row
  end

  defp validate_evaluation_evidence_row!(_row, domain, _isolation, sequence),
    do: raise(ArgumentError, "invalid evaluator evidence row #{sequence} for #{domain}")

  defp validate_verification_evidence!(row, domain, isolation) when is_map(row) do
    unless MapSet.new(Map.keys(row)) == MapSet.new(~w(sequence candidate observed)) and
             is_integer(row["sequence"]) and row["sequence"] > 0 and
             is_binary(row["candidate"]) and row["candidate"] != "" do
      raise ArgumentError, "invalid independent verification evidence for #{domain}"
    end

    validate_observation!(row["observed"], domain, row["candidate"], isolation)
    row
  end

  defp validate_verification_evidence!(_row, domain, _isolation),
    do: raise(ArgumentError, "invalid independent verification evidence for #{domain}")

  defp validate_observation!(observation, domain, candidate, isolation)
       when is_map(observation) do
    required =
      ~w(protocol_id domain candidate_sha256 isolation score side_info objective_calls wall_time_ms)

    unless MapSet.new(Map.keys(observation)) == MapSet.new(required) and
             observation["domain"] == domain and
             observation["candidate_sha256"] == sha256(candidate) and
             observation["isolation"] == isolation and
             finite_number?(observation["score"]) and is_map(observation["side_info"]) and
             is_integer(observation["objective_calls"]) and
             observation["objective_calls"] >= 0 and is_integer(observation["wall_time_ms"]) and
             observation["wall_time_ms"] > 0 and
             close?(observation["side_info"]["score"], observation["score"]) do
      raise ArgumentError, "invalid shared-evaluator observation for #{domain}"
    end

    observation
  end

  defp validate_observation!(_observation, domain, _candidate, _isolation),
    do: raise(ArgumentError, "invalid shared-evaluator observation for #{domain}")

  defp validate_reflection_evidence!(calls, runtime, controls)
       when is_list(calls) and calls != [] do
    if length(calls) > controls["max_candidate_proposals"] do
      raise ArgumentError, "#{runtime} reflection evidence exceeds the matched proposal budget"
    end

    Enum.with_index(calls, 1)
    |> Enum.map(fn {call, sequence} ->
      validate_reflection_call!(call, runtime, controls["model"], sequence)
    end)
  end

  defp validate_reflection_evidence!(_calls, runtime, _controls),
    do: raise(ArgumentError, "#{runtime} report has no durable reflection usage evidence")

  defp validate_reflection_call!(call, runtime, model, sequence) when is_map(call) do
    keys = ~w(sequence source prompt_sha256 response_sha256 status usage_events)

    expected_source =
      if(runtime == "imp_beam", do: "imp_lm_call_audit", else: "pinned_litellm_call_wrapper")

    unless MapSet.new(Map.keys(call)) == MapSet.new(keys) and call["sequence"] == sequence and
             call["source"] == expected_source and call["status"] == "ok" and
             digest?(call["prompt_sha256"]) and digest?(call["response_sha256"]) and
             is_list(call["usage_events"]) and call["usage_events"] != [] do
      raise ArgumentError, "invalid #{runtime} reflection evidence call #{sequence}"
    end

    events =
      Enum.with_index(call["usage_events"], 1)
      |> Enum.map(fn {event, event_sequence} ->
        validate_usage_event!(event, runtime, model, event_sequence)
      end)

    %{call | "usage_events" => events}
  end

  defp validate_reflection_call!(_call, runtime, _model, sequence),
    do: raise(ArgumentError, "invalid #{runtime} reflection evidence call #{sequence}")

  defp validate_usage_event!(event, runtime, model, sequence) when is_map(event) do
    keys =
      ~w(sequence source event provider model request_id_sha256 input_tokens output_tokens cost_usd)

    {expected_source, expected_event, expected_model} =
      case runtime do
        "imp_beam" ->
          {"req_llm_token_usage_telemetry", "req_llm.token_usage", model["imp_name"]}

        "upstream_python" ->
          {"litellm_response_usage_delta", "litellm.completion", model["upstream_name"]}
      end

    request_id = event["request_id_sha256"]

    unless MapSet.new(Map.keys(event)) == MapSet.new(keys) and event["sequence"] == sequence and
             event["source"] == expected_source and event["event"] == expected_event and
             event["provider"] == model["provider"] and is_binary(event["model"]) and
             model_matches?(event["model"], expected_model) and
             (is_nil(request_id) or digest?(request_id)) and
             is_integer(event["input_tokens"]) and event["input_tokens"] > 0 and
             is_integer(event["output_tokens"]) and event["output_tokens"] > 0 and
             finite_number?(event["cost_usd"]) and event["cost_usd"] >= 0 do
      raise ArgumentError, "invalid #{runtime} usage event #{sequence}"
    end

    event
  end

  defp validate_usage_event!(_event, runtime, _model, sequence),
    do: raise(ArgumentError, "invalid #{runtime} usage event #{sequence}")

  defp usage_totals(reflection_evidence) do
    reflection_evidence
    |> Enum.flat_map(& &1["usage_events"])
    |> Enum.reduce(%{input_tokens: 0, output_tokens: 0, cost_usd: 0.0}, fn event, total ->
      %{
        input_tokens: total.input_tokens + event["input_tokens"],
        output_tokens: total.output_tokens + event["output_tokens"],
        cost_usd: total.cost_usd + event["cost_usd"]
      }
    end)
  end

  defp validate_with_ready!(artifact, ready) do
    description = ready.description
    expected = derive_bundle!(artifact, description)

    unless artifact == expected do
      raise ArgumentError,
            "Optimize Anything report, comparison, summary, or content receipt is not mechanically derived"
    end

    validate_source_state!(artifact["source_state"], ready, description)
    replay_bundle!(artifact, ready)
    artifact
  end

  defp validate_source_state!(source_state, ready, description) do
    expected = source_state(ready, description)
    source_keys = Map.keys(expected) |> Enum.sort()
    captured_clean = if is_map(source_state), do: source_state["working_tree_clean"], else: nil
    expected = Map.put(expected, "working_tree_clean", captured_clean)

    unless is_map(source_state) and Map.keys(source_state) |> Enum.sort() == source_keys and
             source_state == expected do
      raise ArgumentError, "Optimize Anything pinned evaluator source receipt mismatch"
    end
  end

  defp validate_source_bound_admission!(artifact, ready) do
    current = source_state(ready, ready.description)
    captured = artifact["source_state"]

    unless current["working_tree_clean"] do
      raise ArgumentError,
            "current repository is dirty; captured evidence remains capture-only until committed and clean"
    end

    validate_committed_sources!(current)

    unless captured["working_tree_clean"] == current["working_tree_clean"] do
      raise ArgumentError,
            "captured working-tree state does not match independently observed current state"
    end

    unless captured["git_sha"] == current["git_sha"] and
             captured["source_files"] == current["source_files"] do
      raise ArgumentError,
            "captured source identity does not match the current committed source tree"
    end

    artifact
  end

  defp validate_committed_sources!(source_state) do
    repository = repository_root()

    Enum.each(source_state["source_files"], fn {label, %{"path" => path, "sha256" => digest}} ->
      relative = Path.relative_to(Path.expand(path), Path.expand(repository))

      if Path.type(relative) != :relative or String.starts_with?(relative, "..") do
        raise ArgumentError, "#{label} source is outside the current repository: #{path}"
      end

      case System.cmd("git", ["-C", repository, "ls-files", "--error-unmatch", "--", relative],
             stderr_to_stdout: true
           ) do
        {_output, 0} -> :ok
        {_output, _status} -> raise ArgumentError, "#{label} source is not committed: #{relative}"
      end

      case System.cmd("git", ["-C", repository, "show", "HEAD:#{relative}"],
             stderr_to_stdout: true
           ) do
        {bytes, 0} ->
          unless sha256(bytes) == digest do
            raise ArgumentError, "#{label} source does not match the current commit: #{relative}"
          end

        {_output, _status} ->
          raise ArgumentError, "#{label} source is absent from the current commit: #{relative}"
      end
    end)
  end

  defp replay_bundle!(artifact, ready) do
    replay_root =
      Path.join(
        System.tmp_dir!(),
        "imp-oa-replay-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(replay_root)

    try do
      Enum.each(artifact["rows"], fn pair ->
        Enum.each([pair["upstream"], pair["imp"]], fn report ->
          evidence = report["evaluation_evidence"] ++ [report["verification_evidence"]]

          Enum.each(evidence, fn row ->
            replayed =
              evaluate_candidate!(ready, pair["domain"], row["candidate"], replay_root)

            unless same_semantic_evaluation?(row["observed"], replayed) do
              raise ArgumentError,
                    "#{report["runtime"]} evaluator replay mismatch for #{pair["domain"]} seed #{pair["seed"]} candidate #{row["sequence"]}"
            end
          end)
        end)
      end)
    after
      File.rm_rf!(replay_root)
    end
  end

  defp same_semantic_evaluation?(recorded, replayed) do
    recorded["protocol_id"] == replayed["protocol_id"] and
      recorded["domain"] == replayed["domain"] and
      recorded["candidate_sha256"] == replayed["candidate_sha256"] and
      recorded["isolation"] == replayed["isolation"] and
      recorded["objective_calls"] == replayed["objective_calls"] and
      close?(recorded["score"], replayed["score"]) and
      stable_evaluator_value(recorded["side_info"]) ==
        stable_evaluator_value(replayed["side_info"])
  end

  defp stable_evaluator_value(value) when is_map(value) do
    value
    |> Map.drop(["wall_time_ms", "execution_time_seconds"])
    |> Map.new(fn {key, item} -> {key, stable_evaluator_value(item)} end)
  end

  defp stable_evaluator_value(value) when is_list(value),
    do: Enum.map(value, &stable_evaluator_value/1)

  defp stable_evaluator_value(value), do: value

  defp summarize(rows, execution_scope) do
    grouped = Enum.group_by(rows, & &1["domain"])

    domains =
      Map.new(grouped, fn {domain, domain_rows} ->
        upstream_lifts = Enum.map(domain_rows, &get_in(&1, ["upstream", "absolute_lift"]))
        imp_lifts = Enum.map(domain_rows, &get_in(&1, ["imp", "absolute_lift"]))
        deltas = Enum.map(domain_rows, & &1["best_score_delta_imp_minus_upstream"])

        {domain,
         %{
           "runs" => length(domain_rows),
           "upstream_mean_lift" => mean(upstream_lifts),
           "imp_mean_lift" => mean(imp_lifts),
           "imp_positive_lift_runs" => Enum.count(imp_lifts, &(&1 > 0)),
           "upstream_positive_lift_runs" => Enum.count(upstream_lifts, &(&1 > 0)),
           "imp_wins" => Enum.count(deltas, &(&1 > 0)),
           "ties" => Enum.count(deltas, &close?(&1, 0)),
           "upstream_wins" => Enum.count(deltas, &(&1 < 0)),
           "mean_best_score_delta_imp_minus_upstream" => mean(deltas),
           "imp_total_cost_usd" =>
             Enum.sum(Enum.map(domain_rows, &get_in(&1, ["imp", "cost_usd"]))),
           "upstream_total_cost_usd" =>
             Enum.sum(Enum.map(domain_rows, &get_in(&1, ["upstream", "cost_usd"])))
         }}
      end)

    %{
      "execution_complete" =>
        rows != [] and Enum.all?(rows, &valid_completed_pair?/1) and
          length(rows) ==
            length(execution_scope["domains"]) * length(execution_scope["seeds"]),
      "protocol_complete" =>
        execution_scope["full_protocol"] and rows != [] and
          Enum.all?(rows, &valid_completed_pair?/1) and
          length(rows) == length(@domain_ids) * 3,
      "matched_control_integrity" => Enum.all?(rows, & &1["baseline_scores_match"]),
      "realized_reflection_budgets_match" =>
        Enum.all?(rows, & &1["realized_reflection_budget_match"]),
      "pair_count" => length(rows),
      "domain_count" => map_size(grouped),
      "imp_total_cost_usd" => Enum.sum(Enum.map(rows, &get_in(&1, ["imp", "cost_usd"]))),
      "upstream_total_cost_usd" =>
        Enum.sum(Enum.map(rows, &get_in(&1, ["upstream", "cost_usd"]))),
      "imp_total_input_tokens" => Enum.sum(Enum.map(rows, &get_in(&1, ["imp", "input_tokens"]))),
      "imp_total_output_tokens" =>
        Enum.sum(Enum.map(rows, &get_in(&1, ["imp", "output_tokens"]))),
      "upstream_total_input_tokens" =>
        Enum.sum(Enum.map(rows, &get_in(&1, ["upstream", "input_tokens"]))),
      "upstream_total_output_tokens" =>
        Enum.sum(Enum.map(rows, &get_in(&1, ["upstream", "output_tokens"]))),
      "imp_total_objective_calls" =>
        Enum.sum(Enum.map(rows, &get_in(&1, ["imp", "objective_calls"]))),
      "upstream_total_objective_calls" =>
        Enum.sum(Enum.map(rows, &get_in(&1, ["upstream", "objective_calls"]))),
      "imp_total_reflection_calls" =>
        Enum.sum(Enum.map(rows, &get_in(&1, ["imp", "reflection_calls"]))),
      "upstream_total_reflection_calls" =>
        Enum.sum(Enum.map(rows, &get_in(&1, ["upstream", "reflection_calls"]))),
      "domains" => domains,
      "exact_paper_reproduction" => false,
      "general_superiority_claimed" => false,
      "provider_execution_cryptographically_proven" => false
    }
  end

  defp valid_completed_pair?(row) do
    Enum.all?([row["upstream"], row["imp"]], fn report ->
      is_map(report) and is_number(report["best_score"]) and
        is_number(report["cost_usd"]) and report["metric_calls"] > 0
    end)
  end

  defp valid_execution_scope?(scope, controls) do
    is_map(scope) and is_list(scope["domains"]) and scope["domains"] != [] and
      Enum.all?(scope["domains"], &(&1 in @domain_ids)) and
      Enum.uniq(scope["domains"]) == scope["domains"] and is_list(scope["seeds"]) and
      scope["seeds"] != [] and Enum.all?(scope["seeds"], &(&1 in controls["seeds"])) and
      Enum.uniq(scope["seeds"]) == scope["seeds"] and
      scope["full_protocol"] ==
        (scope["domains"] == @domain_ids and scope["seeds"] == controls["seeds"])
  end

  defp verify_evaluator_artifact!(artifact, description) do
    unless artifact["schema_version"] == 1 and
             artifact["protocol_id"] == description["protocol_id"] and
             artifact["authority_verified"] == true and
             artifact["test_runtime"] == get_in(description, ["swe_bench", "test_runtime"]) do
      raise ArgumentError, "provider-free evaluator verification identity mismatch"
    end

    rows = artifact["rows"]

    unless is_list(rows) and Enum.map(rows, & &1["domain"]) == @domain_ids do
      raise ArgumentError, "provider-free evaluator verification domain mismatch"
    end

    Enum.each(rows, fn row ->
      baseline = row["baseline"]

      unless is_number(baseline["score"]) and baseline["candidate_sha256"] =~ ~r/^[0-9a-f]{64}$/ do
        raise ArgumentError, "invalid provider-free baseline for #{row["domain"]}"
      end
    end)

    flask = List.last(rows)

    unless get_in(flask, ["reference", "score"]) == 1.0 and
             get_in(flask, ["baseline", "score"]) < 1.0 do
      raise ArgumentError, "Flask evaluator does not separate baseline and reference patch"
    end

    artifact
  end

  defp readiness!(opts) do
    case readiness(opts) do
      {:ok, ready} ->
        ready

      {:error, reason} ->
        raise ArgumentError, "Optimize Anything differential is not ready: #{reason}"
    end
  end

  defp paths(opts) do
    %{
      manifest: opts |> Keyword.get(:manifest, @default_manifest) |> Path.expand(),
      python: opts |> Keyword.get(:python, @default_python) |> Path.expand(),
      runner: opts |> Keyword.get(:runner, @default_runner) |> Path.expand()
    }
  end

  defp regular_file(path, label) do
    if File.regular?(path), do: :ok, else: {:error, "#{label} is missing: #{path}"}
  end

  defp run_python(paths, command, args, opts) do
    output = Keyword.get(opts, :output, temporary_output(command))
    owned_output? = not Keyword.has_key?(opts, :output)
    File.mkdir_p!(Path.dirname(output))

    argv =
      [paths.runner, "--manifest", paths.manifest, command] ++ args ++ ["--out", output]

    try do
      case Imp.ExternalCommand.run(paths.python, argv,
             timeout: Keyword.fetch!(opts, :timeout),
             max_output_bytes: 32_768,
             cd: File.cwd!()
           ) do
        {:ok, _result} -> {:ok, read_json!(output)}
        {:error, reason} -> {:error, external_error(reason)}
      end
    after
      if owned_output?, do: File.rm(output)
    end
  end

  defp temporary_output(command) do
    Path.join(
      System.tmp_dir!(),
      "imp-oa-#{command}-#{System.unique_integer([:positive, :monotonic])}.json"
    )
  end

  defp external_error({kind, status, result}),
    do: "#{kind} #{status}: #{String.trim(result.output)}"

  defp external_error({:timeout, result}), do: "timeout: #{String.trim(result.output)}"
  defp external_error(reason), do: inspect(reason)

  defp verify_canonical_authority_registry do
    registry = Imp.UpstreamAuthorityRegistry.load!()
    Imp.UpstreamAuthorityRegistry.authority!(registry, @authority_contract)
    Imp.UpstreamAuthorityRegistry.authority!(registry, @dataset_contract)
    :ok
  rescue
    error -> {:error, "canonical authority registry is invalid: #{Exception.message(error)}"}
  end

  defp verify_description(description, manifest) do
    domains = description["domains"]

    cond do
      description["schema_version"] != 1 ->
        {:error, "authority description schema mismatch"}

      description["protocol_id"] != manifest["protocol_id"] ->
        {:error, "authority description protocol mismatch"}

      Enum.map(domains || [], & &1["id"]) != @domain_ids ->
        {:error, "authority description domain mismatch"}

      not is_map(description["isolation"]) ->
        {:error, "authority description has no verified isolation receipt"}

      not Enum.all?(domains, &valid_domain_description?/1) ->
        {:error, "authority description has an invalid seed or reflection template"}

      true ->
        :ok
    end
  end

  defp valid_domain_description?(domain) do
    is_binary(domain["seed_candidate"]) and domain["seed_candidate"] != "" and
      domain["seed_candidate_sha256"] == sha256(domain["seed_candidate"]) and
      is_binary(domain["reflection_template"]) and
      domain["reflection_template_sha256"] == sha256(domain["reflection_template"]) and
      String.contains?(domain["reflection_template"], "<curr_param>") and
      String.contains?(domain["reflection_template"], "<side_info>")
  end

  defp selected_domains!(description, requested) when is_list(requested) and requested != [] do
    available = Map.new(description["domains"], &{&1["id"], &1})

    Enum.map(requested, fn id ->
      case Map.fetch(available, id) do
        {:ok, domain} ->
          domain

        :error ->
          raise ArgumentError, "unknown Optimize Anything differential domain: #{inspect(id)}"
      end
    end)
  end

  defp selected_domains!(_description, requested),
    do: raise(ArgumentError, ":domains must be a non-empty list, got: #{inspect(requested)}")

  defp selected_seeds!(controls, requested) when is_list(requested) and requested != [] do
    allowed = controls["seeds"]

    unless Enum.all?(requested, &(&1 in allowed)) and Enum.uniq(requested) == requested do
      raise ArgumentError, ":seeds must be a distinct subset of #{inspect(allowed)}"
    end

    requested
  end

  defp selected_seeds!(_controls, requested),
    do: raise(ArgumentError, ":seeds must be a non-empty list, got: #{inspect(requested)}")

  defp run_root(opts) do
    Keyword.get_lazy(opts, :run_dir, fn ->
      Path.join(
        Imp.BenchmarkTruth.Paths.runs("optimize-anything-upstream-differential"),
        Calendar.strftime(DateTime.utc_now(), "%Y%m%dT%H%M%SZ") <>
          "-#{System.unique_integer([:positive])}"
      )
    end)
    |> Path.expand()
  end

  defp report_controls(controls) do
    Map.take(controls, [
      "max_candidate_proposals",
      "parallel",
      "max_workers",
      "cache_evaluation",
      "reflection_minibatch_size",
      "candidate_selection_strategy",
      "frontier_type"
    ])
  end

  defp candidate_selection_strategy!("pareto"), do: :pareto

  defp candidate_selection_strategy!(value),
    do: raise(ArgumentError, "unsupported selector: #{inspect(value)}")

  defp frontier_type!("hybrid"), do: :hybrid

  defp frontier_type!(value),
    do: raise(ArgumentError, "unsupported frontier type: #{inspect(value)}")

  defp validate_imp_candidate_shape!(result) do
    valid? =
      Enum.all?(result.candidates, fn candidate ->
        is_map(candidate) and map_size(candidate) == 1 and
          Enum.map(Map.keys(candidate), &to_string/1) == ["current_candidate"]
      end)

    unless valid? do
      raise "Imp string-candidate run escaped the strict current_candidate wrapper"
    end
  end

  defp measure_usage(audit, fun) do
    handler_id = {__MODULE__, :usage, make_ref()}

    :ok =
      :telemetry.attach(handler_id, [:req_llm, :token_usage], &__MODULE__.handle_usage/4, audit)

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end
  end

  defp trace_row(row) do
    Map.take(row, ["candidate_sha256", "score", "objective_calls", "wall_time_ms"])
  end

  defp domain_identity(domain) do
    Map.take(domain, [
      "id",
      "kind",
      "objective",
      "seed_candidate_sha256",
      "reflection_template_sha256",
      "evaluator"
    ])
  end

  defp source_state(ready, description) do
    source_files = source_files(ready)

    %{
      "git_sha" => git_sha(),
      "working_tree_clean" => working_tree_clean?(),
      "source_files" => source_files,
      "manifest_sha256" => source_files["manifest"]["sha256"],
      "runner_sha256" => source_files["python_runner"]["sha256"],
      "imp_harness_sha256" => source_files["elixir_harness"]["sha256"],
      "imp_task_sha256" => source_files["elixir_task"]["sha256"],
      "authority_registry_sha256" => source_files["authority_registry"]["sha256"],
      "authority_registry_reader_sha256" => source_files["python_authority_registry"]["sha256"],
      "reproduction_registry_sha256" => source_files["reproduction_registry"]["sha256"],
      "evaluator_description_sha256" => canonical_sha256(description)
    }
  end

  defp source_files(ready) do
    %{
      "manifest" => source_identity(ready.manifest),
      "python_runner" => source_identity(ready.runner),
      "python_authority_registry" => source_identity(@authority_registry_reader),
      "elixir_harness" => source_identity(__ENV__.file),
      "elixir_task" => source_identity(@task_source),
      "authority_registry" => source_identity(Imp.UpstreamAuthorityRegistry.path()),
      "reproduction_registry" => source_identity(@reproduction_registry)
    }
  end

  defp source_identity(path) do
    path = Path.expand(path)

    unless File.regular?(path),
      do: raise(ArgumentError, "source identity file is missing: #{path}")

    %{"path" => path, "sha256" => sha256(File.read!(path))}
  end

  defp artifact_claim_scope(claim_scope) when is_map(claim_scope) do
    excluded = Enum.uniq((claim_scope["excluded"] || []) ++ @claim_limitations)

    claim_scope
    |> Map.put("excluded", excluded)
    |> Map.put("limitations", @claim_limitations)
    |> Map.put("provider_execution_cryptographically_proven", false)
  end

  defp artifact_claim_scope(_claim_scope),
    do: raise(ArgumentError, "Optimize Anything claim scope must be a map")

  defp usage_evidence_scope("imp_beam") do
    %{
      "source" => "correlated ReqLLM token-usage telemetry",
      "provider_attestation" => false
    }
  end

  defp usage_evidence_scope("upstream_python") do
    %{
      "source" => "per-call deltas from the pinned LiteLLM response counters",
      "provider_attestation" => false
    }
  end

  defp content_receipt(scope, value) do
    %{
      "algorithm" => "sha256_canonical_json_v1",
      "scope" => scope,
      "sha256" => canonical_sha256(value),
      "provider_execution_attested" => false
    }
  end

  defp canonical_sha256(value) do
    value
    |> canonical_json()
    |> IO.iodata_to_binary()
    |> sha256()
  end

  defp canonical_json(value) when is_map(value) do
    entries =
      value
      |> Enum.map(fn
        {key, item} when is_binary(key) ->
          [Jason.encode!(key), ?:, canonical_json(item)]

        {key, _item} ->
          raise ArgumentError, "canonical JSON key must be text, got: #{inspect(key)}"
      end)
      |> Enum.sort_by(&IO.iodata_to_binary(hd(&1)))

    [?{, Enum.intersperse(entries, ?,), ?}]
  end

  defp canonical_json(value) when is_list(value),
    do: [?[, value |> Enum.map(&canonical_json/1) |> Enum.intersperse(?,), ?]]

  defp canonical_json(value), do: Jason.encode!(value)

  defp model_matches?(observed, expected) when is_binary(observed) and is_binary(expected) do
    observed == expected or model_suffix(observed) == model_suffix(expected)
  end

  defp model_matches?(_observed, _expected), do: false

  defp model_suffix(model) do
    model
    |> String.split([":", "/"], trim: true)
    |> List.last()
  end

  defp digest?(value), do: is_binary(value) and value =~ ~r/\A[0-9a-f]{64}\z/

  defp finite_number?(value) when is_number(value), do: match?({:ok, _}, Jason.encode(value))
  defp finite_number?(_value), do: false

  defp git_sha do
    case System.cmd("git", ["-C", repository_root(), "rev-parse", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> "unknown"
    end
  end

  defp working_tree_clean? do
    case System.cmd(
           "git",
           ["-C", repository_root(), "status", "--porcelain=v1", "--untracked-files=all"],
           stderr_to_stdout: true
         ) do
      {status, 0} -> String.trim(status) == ""
      _ -> false
    end
  end

  defp repository_root do
    case System.cmd("git", ["-C", File.cwd!(), "rev-parse", "--show-toplevel"],
           stderr_to_stdout: true
         ) do
      {root, 0} -> String.trim(root)
      _ -> File.cwd!()
    end
  end

  defp read_json!(path), do: path |> File.read!() |> Jason.decode!()

  defp sha256(value) when is_binary(value),
    do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp mean(values), do: Enum.sum(values) / length(values)

  defp close?(left, right) when is_number(left) and is_number(right) do
    abs(left - right) <= max(1.0e-12, max(abs(left), abs(right)) * 1.0e-12)
  end

  defp close?(_left, _right), do: false
end
