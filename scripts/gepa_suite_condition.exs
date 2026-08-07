defmodule Imp.GepaSuiteSpendGuard do
  @moduledoc false

  @behaviour Imp.LM

  defstruct [:inner, :guard, :role, :reservation_usd, :input_price, :output_price]

  def start_link!(initial_cost_usd, max_cost_usd)
      when is_number(initial_cost_usd) and initial_cost_usd >= 0 and
             is_number(max_cost_usd) and max_cost_usd > 0 do
    if initial_cost_usd > max_cost_usd + 1.0e-9 do
      raise Imp.OperationalSafetyError,
        kind: :budget,
        message:
          "GEPA suite initial actual spend already exceeds the owner cap: " <>
            "$#{initial_cost_usd} > $#{max_cost_usd}"
    end

    {:ok, guard} =
      Agent.start_link(fn ->
        %{
          initial_actual_cost_usd: initial_cost_usd * 1.0,
          reconciled_accounted_cost_usd: 0.0,
          retained_reservation_usd: 0.0,
          active: %{},
          owner_cap_usd: max_cost_usd * 1.0,
          next_id: 1
        }
      end)

    guard
  end

  def start_link!(initial_cost_usd, max_cost_usd) do
    raise ArgumentError,
          "GEPA suite spend guard requires nonnegative initial actual spend and a positive owner cap, " <>
            "got: #{inspect(initial_cost_usd)}, #{inspect(max_cost_usd)}"
  end

  def wrap(inner, guard, role, reservation_usd, input_price, output_price)
      when is_pid(guard) and is_atom(role) and is_number(reservation_usd) and
             reservation_usd >= 0 and is_number(input_price) and input_price >= 0 and
             is_number(output_price) and output_price >= 0 do
    %__MODULE__{
      inner: inner,
      guard: guard,
      role: role,
      reservation_usd: reservation_usd * 1.0,
      input_price: input_price * 1.0,
      output_price: output_price * 1.0
    }
  end

  def snapshot(guard) do
    Agent.get(guard, fn state ->
      active_reservation = state.active |> Map.values() |> Enum.sum()

      state
      |> Map.drop([:active, :next_id])
      |> Map.put(:active_reservation_usd, active_reservation)
      |> Map.put(:active_requests, map_size(state.active))
      |> Map.put(
        :accounted_total_usd,
        state.initial_actual_cost_usd + state.reconciled_accounted_cost_usd +
          state.retained_reservation_usd + active_reservation
      )
    end)
  end

  @impl true
  def generate(_messages, _opts), do: {:error, :gepa_suite_spend_guard_instance_required}

  def generate(%__MODULE__{} = lm, messages, opts) do
    with {:ok, reservation_id} <- reserve(lm) do
      started = System.monotonic_time()

      case generate_inner(lm.inner, messages, opts) do
        {:ok, value} = success ->
          case response_cost(value, lm) do
            {:ok, usage} ->
              settle(lm.guard, reservation_id, usage.cost_usd)
              emit_role_event(:stop, lm.role, started, usage)
              success

            {:error, reason} ->
              retain(lm.guard, reservation_id)
              emit_role_event(:exception, lm.role, started, %{error: reason})

              {:error,
               %Imp.OperationalSafetyError{
                 kind: :budget,
                 message: "provider response did not retain an authenticated nonnegative cost",
                 reason: reason
               }}
          end

        {:error, _reason} = error ->
          retain(lm.guard, reservation_id)
          emit_role_event(:exception, lm.role, started, %{error: elem(error, 1)})
          error
      end
    end
  end

  def response_format_capability(%__MODULE__{inner: inner}),
    do: Imp.LM.response_format_capability(inner)

  defp generate_inner(%module{} = inner, messages, opts) do
    apply(module, :generate, [inner, messages, opts])
  end

  defp emit_role_event(status, role, started, metadata) do
    :telemetry.execute(
      [:imp, :gepa_suite, :role, status],
      %{duration: System.monotonic_time() - started},
      Map.put(metadata, :role, role)
    )
  end

  defp reserve(lm) do
    Agent.get_and_update(lm.guard, fn state ->
      active = state.active |> Map.values() |> Enum.sum()

      projected =
        state.initial_actual_cost_usd + state.reconciled_accounted_cost_usd +
          state.retained_reservation_usd + active + lm.reservation_usd

      if projected <= state.owner_cap_usd + 1.0e-9 do
        id = state.next_id

        {{:ok, id},
         %{state | active: Map.put(state.active, id, lm.reservation_usd), next_id: id + 1}}
      else
        error =
          %Imp.OperationalSafetyError{
            kind: :budget,
            message:
              "next #{lm.role} transport would exceed the owner cap: " <>
                "$#{projected} > $#{state.owner_cap_usd}",
            reason: %{
              role: lm.role,
              next_reservation_usd: lm.reservation_usd,
              projected_usd: projected,
              owner_cap_usd: state.owner_cap_usd
            }
          }

        {{:error, error}, state}
      end
    end)
  end

  defp settle(guard, id, actual_cost) do
    Agent.update(guard, fn state ->
      case Map.pop(state.active, id) do
        {nil, _active} ->
          state

        {_reservation, active} ->
          %{
            state
            | active: active,
              reconciled_accounted_cost_usd: state.reconciled_accounted_cost_usd + actual_cost
          }
      end
    end)
  end

  defp retain(guard, id) do
    Agent.update(guard, fn state ->
      case Map.pop(state.active, id) do
        {nil, _active} ->
          state

        {reservation, active} ->
          %{
            state
            | active: active,
              retained_reservation_usd: state.retained_reservation_usd + reservation
          }
      end
    end)
  end

  defp response_cost(value, lm) do
    with {:ok, metadata} <- Imp.LM.Result.metadata(value),
         provider when is_map(provider) <- metadata[:req_llm] || metadata["req_llm"],
         usage when is_map(usage) <- provider[:usage] || provider["usage"],
         input when is_integer(input) and input >= 0 <-
           usage[:input_tokens] || usage["input_tokens"] || usage[:prompt_tokens] ||
             usage["prompt_tokens"],
         output when is_integer(output) and output >= 0 <-
           usage[:output_tokens] || usage["output_tokens"] || usage[:completion_tokens] ||
             usage["completion_tokens"] do
      reported = usage[:total_cost] || usage["total_cost"] || usage[:cost] || usage["cost"]

      if is_nil(reported) or (is_number(reported) and reported >= 0) do
        calculated = (input * lm.input_price + output * lm.output_price) / 1_000_000

        {:ok,
         %{
           input_tokens: input,
           output_tokens: output,
           cost_usd: max((reported || 0) * 1.0, calculated)
         }}
      else
        {:error, {:invalid_provider_cost, reported}}
      end
    else
      value -> {:error, {:missing_provider_cost, value}}
    end
  end
end

defmodule Imp.GepaSuiteConditionCLI do
  @moduledoc false

  alias Imp.BenchmarkTruth.{GepaStudyCondition, GepaSuite}
  alias Imp.Optimizer.Artifact

  @arms ~w(baseline mipro_v2_heavy gepa_v0_1_4_merge)
  @request_timeout_ms 120_000
  @study_seeds [2_026_080_101, 2_026_080_102, 2_026_080_103]
  @gepa_artifact_commit "cbefbc1aa0f43dd39874ec4bf42211365dbda42e"

  def main(argv) do
    {opts, positional, invalid} =
      OptionParser.parse(argv,
        strict: [
          dataset_root: :string,
          retrieval_root: :string,
          retrieval_receipt: :string,
          retrieval_python: :string,
          livebench_math_python: :string,
          livebench_math_source_root: :string,
          family: :string,
          arm: :string,
          seed: :integer,
          output: :string,
          baseline_result: :string,
          baseline_source_commit: :string,
          artifact: :string,
          fresh_output: :string,
          task_model: :string,
          reflection_model: :string,
          judge_model: :string,
          task_provider: :string,
          reflection_provider: :string,
          judge_provider: :string,
          task_max_input_bytes: :integer,
          reflection_max_input_bytes: :integer,
          judge_max_input_bytes: :integer,
          task_max_output_tokens: :integer,
          reflection_max_output_tokens: :integer,
          judge_max_output_tokens: :integer,
          input_price_per_million: :float,
          output_price_per_million: :float,
          task_input_price_per_million: :float,
          task_output_price_per_million: :float,
          reflection_input_price_per_million: :float,
          reflection_output_price_per_million: :float,
          judge_input_price_per_million: :float,
          judge_output_price_per_million: :float,
          max_concurrency: :integer,
          initial_cost_usd: :float,
          max_cost_usd: :float,
          api_key_env: :string,
          provider_disabled_fixture: :boolean,
          run: :boolean,
          fresh: :boolean
        ]
      )

    if positional != [] or invalid != [],
      do: raise(ArgumentError, "invalid GEPA suite arguments: #{inspect(positional ++ invalid)}")

    config = opts |> config!() |> configure_livebench_metric!() |> start_spend_guard!()

    try do
      if config.run? or config.fresh?, do: configure_req_llm_pool!(config)
      prepared = prepare!(config)

      cond do
        config.fresh? -> fresh!(config, prepared)
        config.run? -> run!(config, prepared)
        true -> preflight!(config, prepared)
      end
    after
      if is_pid(config.spend_guard) and Process.alive?(config.spend_guard),
        do: Agent.stop(config.spend_guard)
    end
  end

  defp config!(opts) do
    family = required!(opts, :family)
    arm = Keyword.get(opts, :arm, "baseline")

    unless family in GepaSuite.families(),
      do: raise(ArgumentError, "unknown official GEPA family: #{inspect(family)}")

    unless arm in @arms,
      do: raise(ArgumentError, "unknown matched study arm: #{inspect(arm)}")

    run? = Keyword.get(opts, :run, false)
    fresh? = Keyword.get(opts, :fresh, false)

    if run? and fresh?, do: raise(ArgumentError, "choose --run or --fresh, not both")

    %{
      dataset_root: opts |> required!(:dataset_root) |> Path.expand(),
      retrieval_root: expand(opts[:retrieval_root]),
      retrieval_receipt: expand(opts[:retrieval_receipt]),
      retrieval_python: Keyword.get(opts, :retrieval_python, "python3"),
      livebench_math_python: expand(opts[:livebench_math_python]),
      livebench_math_source_root: expand(opts[:livebench_math_source_root]),
      family: family,
      arm:
        Map.fetch!(
          %{
            "baseline" => :baseline,
            "mipro_v2_heavy" => :mipro_v2_heavy,
            "gepa_v0_1_4_merge" => :gepa_v0_1_4_merge
          },
          arm
        ),
      seed: Keyword.get(opts, :seed, 2_026_080_101),
      output: expand(opts[:output]),
      baseline_result: expand(opts[:baseline_result]),
      baseline_source_commit: opts[:baseline_source_commit],
      artifact: expand(opts[:artifact]),
      fresh_output: expand(opts[:fresh_output]),
      task_model: opts[:task_model],
      reflection_model: opts[:reflection_model],
      judge_model: opts[:judge_model],
      task_provider: opts[:task_provider],
      reflection_provider: opts[:reflection_provider],
      judge_provider: opts[:judge_provider],
      task_max_input_bytes: opts[:task_max_input_bytes],
      reflection_max_input_bytes: opts[:reflection_max_input_bytes],
      judge_max_input_bytes: opts[:judge_max_input_bytes],
      task_max_output_tokens: opts[:task_max_output_tokens],
      reflection_max_output_tokens: opts[:reflection_max_output_tokens],
      judge_max_output_tokens: opts[:judge_max_output_tokens],
      input_price_per_million: opts[:input_price_per_million],
      output_price_per_million: opts[:output_price_per_million],
      task_input_price_per_million: opts[:task_input_price_per_million],
      task_output_price_per_million: opts[:task_output_price_per_million],
      reflection_input_price_per_million: opts[:reflection_input_price_per_million],
      reflection_output_price_per_million: opts[:reflection_output_price_per_million],
      judge_input_price_per_million: opts[:judge_input_price_per_million],
      judge_output_price_per_million: opts[:judge_output_price_per_million],
      max_concurrency: Keyword.get(opts, :max_concurrency, 1),
      initial_cost_usd: opts[:initial_cost_usd],
      max_cost_usd: opts[:max_cost_usd],
      api_key_env: Keyword.get(opts, :api_key_env, "OPENROUTER_API_KEY"),
      provider_disabled_fixture?: Keyword.get(opts, :provider_disabled_fixture, false),
      run?: run?,
      fresh?: fresh?
    }
    |> validate_live!()
  end

  defp start_spend_guard!(%{provider_disabled_fixture?: true} = config),
    do: Map.put(config, :spend_guard, nil)

  defp start_spend_guard!(%{run?: active, fresh?: fresh} = config) when active or fresh do
    Map.put(
      config,
      :spend_guard,
      Imp.GepaSuiteSpendGuard.start_link!(config.initial_cost_usd, config.max_cost_usd)
    )
  end

  defp start_spend_guard!(config), do: Map.put(config, :spend_guard, nil)

  defp configure_livebench_metric!(%{family: "LiveBenchMathBench", run?: true} = config) do
    python =
      config.livebench_math_python ||
        raise(ArgumentError, "LiveBenchMathBench live execution requires --livebench-math-python")

    source_root =
      config.livebench_math_source_root ||
        raise(
          ArgumentError,
          "LiveBenchMathBench live execution requires --livebench-math-source-root"
        )

    unless git_output(["-C", source_root, "rev-parse", "HEAD"]) == @gepa_artifact_commit and
             git_status(["-C", source_root, "diff", "--quiet"]) == 0 and
             git_status(["-C", source_root, "diff", "--cached", "--quiet"]) == 0 do
      raise ArgumentError,
            "LiveBenchMath feedback source root is not the clean pinned GEPA artifact"
    end

    bridge = Path.expand("scripts/livebench_math_score.py", File.cwd!())

    payload =
      Path.join(
        System.tmp_dir!(),
        "imp-livebench-preflight-#{System.unique_integer([:positive])}.json"
      )

    File.write!(
      payload,
      Jason.encode!(%{
        "task" => "livebench_math_feedback",
        "question_d" => %{
          "task" => "AMPS_Hard",
          "subtask" => "amps_hard_algebra",
          "turns" => ["Solve."],
          "ground_truth" => "x^2"
        },
        "answer" => "\\boxed{x^2}"
      })
    )

    try do
      case System.cmd(python, [bridge, payload],
             stderr_to_stdout: true,
             env: [{"IMP_LIVEBENCH_MATH_SOURCE_ROOT", source_root}]
           ) do
        {output, 0} ->
          unless match?(
                   {:ok, %{"score" => score, "feedback" => feedback}}
                   when is_number(score) and is_binary(feedback),
                   Jason.decode(output)
                 ) do
            raise ArgumentError,
                  "LiveBenchMath symbolic scorer preflight returned an invalid result"
          end

        {output, status} ->
          raise ArgumentError,
                "LiveBenchMath symbolic scorer preflight failed with status #{status}: " <>
                  String.trim(output)
      end
    after
      File.rm(payload)
    end

    System.put_env("IMP_LIVEBENCH_MATH_PYTHON", python)
    System.put_env("IMP_LIVEBENCH_MATH_BRIDGE", bridge)
    System.put_env("IMP_LIVEBENCH_MATH_SOURCE_ROOT", source_root)
    %{config | livebench_math_python: python}
  end

  defp configure_livebench_metric!(config), do: config

  defp prepare!(config) do
    lms =
      if config.provider_disabled_fixture? do
        fixture = Imp.LM.Static.new()
        %{task: fixture, reflection: fixture, judge: fixture}
      else
        if config.run? or config.fresh? do
          %{
            task: live_lm!(config, :task),
            reflection: live_lm!(config, :reflection),
            judge: live_lm!(config, :judge)
          }
        else
          never =
            Imp.LM.Static.new(
              handler: fn _, _ -> raise "provider-disabled preflight called an LM" end
            )

          %{task: never, reflection: never, judge: never}
        end
      end

    GepaStudyCondition.prepare!(config.dataset_root, config.family, lms,
      execution: execution!(config),
      max_concurrency: config.max_concurrency
    )
  end

  defp preflight!(config, prepared) do
    matched_baseline =
      if is_binary(config.baseline_result), do: matched_baseline!(config, prepared), else: nil

    treatments =
      for arm <- [:mipro_v2_heavy, :gepa_v0_1_4_merge], into: %{} do
        optimizer = GepaStudyCondition.optimizer!(arm, prepared, config.seed)
        {arm, optimizer_receipt(arm, optimizer)}
      end

    emit(%{
      status: :provider_disabled_ready,
      family: config.family,
      arm: config.arm,
      seed: config.seed,
      outer_max_concurrency: config.max_concurrency,
      request_timeout_ms: @request_timeout_ms,
      req_llm_pool: req_llm_pool(config),
      heldout_decoded: false,
      split_counts: prepared.loaded.spec["split_counts"],
      data: data_receipt(prepared.loaded.spec),
      treatments: treatments,
      retrieval: retrieval_disclosure(config, prepared.loaded.spec),
      metric_runtime: metric_runtime(config),
      condition: condition_receipt(config),
      matched_baseline: matched_baseline,
      matched_baseline_required_for_live_optimizer: config.arm != :baseline,
      provider_calls_authorized: false
    })
  end

  defp run!(config, prepared) do
    for key <- [:output], do: required_config!(config, key)

    if config.arm != :baseline do
      for key <- [:artifact, :fresh_output], do: required_config!(config, key)
    end

    ensure_new_targets!(
      [config.output, progress_path(config)] ++
        if(config.arm == :baseline,
          do: [],
          else: [config.artifact, config.fresh_output, config.fresh_output <> ".progress.jsonl"]
        )
    )

    matched_baseline = matched_baseline!(config, prepared)
    admission = spend_admission(config)
    progress = init_progress!(config)

    {wall_time_us, outcome, usage} =
      capture_runtime(
        fn ->
          optimized =
            GepaStudyCondition.optimize!(config.arm, prepared, config.seed,
              matched_baseline: matched_baseline
            )

          {optimized, GepaStudyCondition.heldout!(config.arm, prepared, optimized)}
        end,
        progress
      )

    {optimized, heldout} =
      unwrap_run!(
        outcome,
        config,
        prepared,
        admission,
        wall_time_us,
        usage,
        matched_baseline
      )

    accounted_total =
      config.spend_guard
      |> Imp.GepaSuiteSpendGuard.snapshot()
      |> Map.fetch!(:accounted_total_usd)

    try do
      {artifact_sha, fresh_sha, fresh_usage, fresh_spend} =
        case optimized.artifact do
          nil ->
            {nil, nil, empty_runtime(), nil}

          artifact ->
            for key <- [:artifact, :fresh_output], do: required_config!(config, key)
            write_artifact_exclusive!(artifact, config.artifact)
            artifact_sha = sha256(config.artifact)
            fresh_child!(config, accounted_total)
            fresh = config.fresh_output |> File.read!() |> Jason.decode!()
            expected_condition = condition_receipt(config) |> json_safe()
            expected_data = data_receipt(prepared.loaded.spec) |> json_safe()

            unless fresh["status"] == "fresh_ok" and
                     fresh["loaded_artifact_sha256"] == artifact_sha and
                     fresh["condition"] == expected_condition and fresh["data"] == expected_data do
              raise "fresh GEPA suite receipt does not bind the selected Artifact and condition"
            end

            unless fresh["matched_baseline"] == json_safe(matched_baseline) do
              raise "fresh GEPA suite receipt does not bind the matched baseline"
            end

            {artifact_sha, sha256(config.fresh_output), fresh["usage"], fresh["spend_admission"]}
        end

      write_private!(config.output, %{
        status: :complete,
        family: config.family,
        arm: config.arm,
        seed: config.seed,
        heldout: evaluation(heldout.result),
        artifact_sha256: artifact_sha,
        fresh_sha256: fresh_sha,
        usage: merge_runtime(usage, fresh_usage),
        usage_cost_basis: :frozen_catalog_calculated,
        progress_sha256: sha256(progress),
        wall_time_us: wall_time_us,
        request_timeout_ms: @request_timeout_ms,
        req_llm_pool: req_llm_pool(config),
        spend_admission: Map.put(admission, "final", spend_snapshot(config)),
        fresh_spend_admission: fresh_spend,
        heldout_decoded: true,
        metric_runtime: metric_runtime(config),
        retrieval: retrieval_disclosure(config, prepared.loaded.spec),
        condition: condition_receipt(config),
        data: data_receipt(prepared.loaded.spec),
        matched_baseline: matched_baseline
      })
    rescue
      error ->
        child = retained_fresh_failure(config, prepared)

        write_failure_unless_exists!(config, prepared, :persist_or_fresh_service, error, %{
          usage: merge_runtime(usage, child.usage),
          wall_time_us: wall_time_us,
          progress_sha256: existing_sha256(progress),
          spend_admission: Map.put(admission, "final", spend_snapshot(config)),
          matched_baseline: matched_baseline,
          fresh_failure_evidence: child.evidence,
          fresh_spend_admission: child.spend
        })

        reraise error, __STACKTRACE__
    end
  end

  defp fresh!(config, prepared) do
    for key <- [:artifact, :fresh_output], do: required_config!(config, key)
    ensure_new_targets!([config.fresh_output, progress_path(config)])
    progress = init_progress!(config)

    for file <- ~w(support_pipeline.ex callbacks.ex workflow.ex program_server.ex) do
      Code.require_file(
        Path.expand("examples/deployment/lib/imp_deployment/#{file}", File.cwd!())
      )
    end

    matched_baseline = matched_baseline!(config, prepared)
    loaded_artifact_sha256 = sha256(config.artifact)
    artifact = Artifact.read!(config.artifact)

    unless get_in(Artifact.inspect(artifact), [:provenance, "matched_baseline"]) ==
             json_safe(matched_baseline) do
      raise "selected Artifact does not bind the matched baseline"
    end

    program = Artifact.apply(artifact, prepared.program)
    test = GepaSuite.load_test!(prepared.loaded) |> Enum.take(4)
    supervisor = Module.concat([ImpGepaSuiteFresh, TaskSupervisor])
    {:ok, _supervisor} = Task.Supervisor.start_link(name: supervisor)

    server_options = [
      program: program,
      lm: prepared.lms.task,
      task_supervisor: supervisor,
      name: nil
    ]

    {:ok, server} = apply(ImpDeployment.ProgramServer, :start_link, [server_options])

    {wall_time_us, outcome, usage} =
      capture_runtime(
        fn ->
          test
          |> Task.async_stream(
            fn example ->
              inputs = example |> Imp.Example.inputs() |> Imp.Example.to_map()
              apply(ImpDeployment.ProgramServer, :call, [server, inputs, :infinity])
            end,
            ordered: true,
            max_concurrency: 4,
            timeout: :infinity
          )
          |> Enum.map(fn
            {:ok, {:ok, prediction}} -> %{status: :ok, prediction: json_safe(prediction)}
            {:ok, {:error, reason}} -> %{status: :error, reason: json_safe(reason)}
            {:exit, reason} -> %{status: :exit, reason: json_safe(reason)}
          end)
        end,
        progress
      )

    outcomes =
      unwrap_fresh!(outcome, config, prepared, loaded_artifact_sha256, wall_time_us, usage)

    unless length(outcomes) == 4 and Enum.all?(outcomes, &(&1.status == :ok)) do
      write_private!(config.fresh_output, %{
        status: :failed,
        family: config.family,
        arm: config.arm,
        seed: config.seed,
        stage: :fresh_service_acceptance,
        calls: outcomes,
        usage: usage,
        progress_sha256: existing_sha256(progress),
        wall_time_us: wall_time_us,
        spend_admission:
          spend_admission(config)
          |> Map.put("final", spend_snapshot(config)),
        loaded_artifact_sha256: loaded_artifact_sha256,
        condition: condition_receipt(config),
        data: data_receipt(prepared.loaded.spec),
        matched_baseline: matched_baseline
      })

      raise "fresh GEPA suite service did not complete all four calls: #{inspect(outcomes)}"
    end

    write_private!(config.fresh_output, %{
      status: :fresh_ok,
      family: config.family,
      arm: config.arm,
      seed: config.seed,
      calls: outcomes,
      usage: usage,
      usage_cost_basis: :frozen_catalog_calculated,
      spend_admission:
        spend_admission(config)
        |> Map.put("final", spend_snapshot(config)),
      progress_sha256: sha256(progress),
      wall_time_us: wall_time_us,
      condition: condition_receipt(config),
      data: data_receipt(prepared.loaded.spec),
      matched_baseline: matched_baseline,
      loaded_artifact_sha256: loaded_artifact_sha256
    })
  end

  defp fresh_child!(config, initial_cost_usd) do
    args =
      [
        "run",
        "--no-start",
        "--no-deps-check",
        Path.expand(__ENV__.file),
        "--fresh",
        "--dataset-root",
        config.dataset_root,
        "--family",
        config.family,
        "--arm",
        Atom.to_string(config.arm),
        "--seed",
        Integer.to_string(config.seed),
        "--baseline-result",
        config.baseline_result,
        "--baseline-source-commit",
        config.baseline_source_commit,
        "--artifact",
        config.artifact,
        "--fresh-output",
        config.fresh_output
      ] ++ live_args(config, initial_cost_usd) ++ retrieval_args(config)

    case System.cmd("mix", args,
           env: [{"MIX_ENV", "test"}],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      {output, status} -> raise "fresh GEPA suite process failed (#{status}): #{output}"
    end
  end

  defp live_args(config, initial_cost_usd) do
    args =
      Enum.flat_map([:task, :reflection, :judge], fn role ->
        [
          "--#{role}-model",
          Map.fetch!(config, String.to_existing_atom("#{role}_model")),
          "--#{role}-provider",
          Map.fetch!(config, String.to_existing_atom("#{role}_provider")),
          "--#{role}-max-input-bytes",
          config |> Map.fetch!(String.to_existing_atom("#{role}_max_input_bytes")) |> to_string(),
          "--#{role}-max-output-tokens",
          config
          |> Map.fetch!(String.to_existing_atom("#{role}_max_output_tokens"))
          |> to_string()
        ]
      end) ++
        price_args(config) ++
        [
          "--api-key-env",
          config.api_key_env,
          "--max-concurrency",
          to_string(config.max_concurrency),
          "--initial-cost-usd",
          to_string(initial_cost_usd),
          "--max-cost-usd",
          to_string(config.max_cost_usd)
        ]

    if config.family == "LiveBenchMathBench" do
      args ++
        [
          "--livebench-math-python",
          config.livebench_math_python,
          "--livebench-math-source-root",
          config.livebench_math_source_root
        ]
    else
      args
    end
  end

  defp price_args(config) do
    shared =
      if is_number(config.input_price_per_million) and
           is_number(config.output_price_per_million) do
        [
          "--input-price-per-million",
          to_string(config.input_price_per_million),
          "--output-price-per-million",
          to_string(config.output_price_per_million)
        ]
      else
        []
      end

    role_specific =
      Enum.flat_map([:task, :reflection, :judge], fn role ->
        Enum.flat_map([:input, :output], fn direction ->
          key = String.to_existing_atom("#{role}_#{direction}_price_per_million")

          case Map.get(config, key) do
            value when is_number(value) ->
              ["--#{role}-#{direction}-price-per-million", to_string(value)]

            _ ->
              []
          end
        end)
      end)

    shared ++ role_specific
  end

  defp retrieval_args(%{retrieval_root: nil}), do: []

  defp retrieval_args(config) do
    [
      "--retrieval-root",
      config.retrieval_root,
      "--retrieval-receipt",
      config.retrieval_receipt,
      "--retrieval-python",
      config.retrieval_python
    ]
  end

  defp execution!(%{family: family} = config)
       when family in ["HotpotQABench", "hoverBench"] do
    if is_nil(config.retrieval_root) or is_nil(config.retrieval_receipt) do
      raise ArgumentError,
            "#{family} requires --retrieval-root and --retrieval-receipt"
    end

    %{
      "retrieval" => %{
        "root" => config.retrieval_root,
        "authenticated_receipt" => config.retrieval_receipt |> File.read!() |> Jason.decode!(),
        "hover_upstream_bm25" => true,
        "python" => config.retrieval_python
      }
    }
  end

  defp execution!(_config), do: %{}

  defp live_lm!(config, role) do
    model = required_config!(config, String.to_existing_atom("#{role}_model"))
    provider = required_config!(config, String.to_existing_atom("#{role}_provider"))
    input_bytes = required_positive!(config, String.to_existing_atom("#{role}_max_input_bytes"))

    output_tokens =
      required_positive!(config, String.to_existing_atom("#{role}_max_output_tokens"))

    input_price = role_price!(config, role, :input)
    output_price = role_price!(config, role, :output)

    api_key = System.fetch_env!(config.api_key_env)

    inner =
      Imp.req_llm(
        priced_model_spec(
          model,
          input_price,
          output_price
        ),
        api_key: api_key,
        cache: false,
        temperature: 1.0,
        max_tokens: output_tokens,
        timeout: @request_timeout_ms,
        max_retries: 0,
        input_envelope: [max_bytes: input_bytes, reservation_tokens: input_bytes],
        provider_options: [
          openrouter_provider: %{
            only: [provider],
            order: [provider],
            allow_fallbacks: false,
            require_parameters: true,
            data_collection: "deny",
            zdr: true,
            max_price: %{
              prompt: input_price,
              completion: output_price
            }
          },
          openrouter_usage: %{include: true}
        ],
        req_http_options: [
          headers: [
            {"X-OpenRouter-Metadata", "enabled"},
            {"X-OpenRouter-Cache", "false"}
          ],
          retry: false,
          max_retries: 0
        ]
      )

    Imp.GepaSuiteSpendGuard.wrap(
      inner,
      config.spend_guard,
      role,
      role_reservation(config, role),
      input_price,
      output_price
    )
  end

  @doc false
  def priced_model_spec(model, input_price_per_million, output_price_per_million) do
    %{
      provider: :openrouter,
      id: model,
      model: model,
      base_url: "https://openrouter.ai/api/v1",
      cost: %{
        input: input_price_per_million,
        output: output_price_per_million
      },
      pricing: %{
        currency: "USD",
        merge: "replace",
        components: [
          %{
            id: "token.input",
            kind: "token",
            unit: "token",
            per: 1_000_000,
            rate: input_price_per_million
          },
          %{
            id: "token.output",
            kind: "token",
            unit: "token",
            per: 1_000_000,
            rate: output_price_per_million
          }
        ]
      }
    }
  end

  defp configure_req_llm_pool!(config) do
    if Process.whereis(ReqLLM.Supervisor) do
      raise ArgumentError,
            "GEPA suite live entrance must configure the ReqLLM pool before ReqLLM starts"
    end

    pool = req_llm_pool(config)
    Application.put_env(:req_llm, :stream_pool_protocols, pool.protocols)
    Application.put_env(:req_llm, :stream_pool_size, pool.size)
    Application.put_env(:req_llm, :stream_pool_count, pool.count)

    case Application.ensure_all_started(:req_llm) do
      {:ok, _started} ->
        :ok

      {:error, reason} ->
        raise "failed to start ReqLLM after pool configuration: #{inspect(reason)}"
    end

    unless is_pid(Process.whereis(ReqLLM.Supervisor)) and
             is_pid(Process.whereis(ReqLLM.Finch)) do
      raise "ReqLLM did not start its configured supervisor and Finch pool"
    end

    :ok
  end

  defp req_llm_pool(config), do: %{protocols: [:http1], size: config.max_concurrency, count: 1}

  defp optimizer_receipt(:mipro_v2_heavy, optimizer) do
    %{
      auto: optimizer.config.auto,
      max_concurrency: optimizer.max_concurrency,
      proposer_fidelity: optimizer.config.proposer_fidelity,
      search_fidelity: optimizer.config.search_fidelity,
      max_errors: optimizer.max_errors
    }
  end

  defp optimizer_receipt(:gepa_v0_1_4_merge, optimizer) do
    %{
      execution_profile: optimizer.execution_profile,
      max_concurrency: optimizer.max_concurrency,
      max_metric_calls: optimizer.max_metric_calls,
      max_reflection_calls: optimizer.max_reflection_calls,
      minibatch_size: optimizer.minibatch_size,
      module_selector: optimizer.module_selector,
      use_merge: optimizer.use_merge
    }
  end

  defp spend_admission(config) do
    %{
      "initial_cost_usd" => config.initial_cost_usd,
      "owner_cap_usd" => config.max_cost_usd,
      "accounting" =>
        "before each transport: initial actual spend plus the greater of provider-reported or conservative full-price token cost for completed calls, active/unreconciled reservations, and this request's full envelope reservation must remain within the owner cap; no cache discount"
    }
  end

  defp condition_receipt(config) do
    %{
      study: "matched-current-model-gepa-suite-v1",
      protocol: :adapted_current_model_reference_differential,
      source_commit: git_output(["rev-parse", "HEAD"]),
      source_tracked_clean:
        git_status(["diff", "--quiet"]) == 0 and git_status(["diff", "--cached", "--quiet"]) == 0,
      family: config.family,
      arm: config.arm,
      seed: config.seed,
      temperature: 1.0,
      max_concurrency: config.max_concurrency,
      request_timeout_ms: @request_timeout_ms,
      request_timeout_semantics: :client_receive_timeout_not_hard_total_wall_clock,
      cache: false,
      retries: 0,
      fallback: false,
      route: %{
        api_base: "https://openrouter.ai/api/v1",
        require_parameters: true,
        data_collection: :deny,
        zdr: true,
        response_cache: false,
        usage_required: true
      },
      papillon_judge_treatment:
        if(config.family == "Papillon",
          do:
            :source_scoring_procedure_with_matched_current_model_judge_not_historical_judge_reproduction,
          else: :not_applicable
        ),
      roles:
        Map.new([:task, :reflection, :judge], fn role ->
          {role,
           %{
             model: Map.get(config, String.to_existing_atom("#{role}_model")),
             provider: Map.get(config, String.to_existing_atom("#{role}_provider")),
             max_input_content_bytes:
               Map.get(config, String.to_existing_atom("#{role}_max_input_bytes")),
             max_output_tokens:
               Map.get(config, String.to_existing_atom("#{role}_max_output_tokens")),
             prices_per_million: %{
               input: role_price(config, role, :input),
               output: role_price(config, role, :output)
             }
           }}
        end),
      legacy_shared_prices_per_million:
        if(
          is_number(config.input_price_per_million) and
            is_number(config.output_price_per_million),
          do: %{
            input: config.input_price_per_million,
            output: config.output_price_per_million
          },
          else: nil
        )
    }
  end

  def matched_baseline!(%{arm: :baseline}, _prepared), do: nil

  def matched_baseline!(config, prepared) do
    path = required_config!(config, :baseline_result)
    expected_source_commit = required_config!(config, :baseline_source_commit)

    unless Regex.match?(~r/\A[0-9a-f]{40}\z/, expected_source_commit) do
      raise ArgumentError, "matched baseline source commit must be a full lowercase Git SHA"
    end

    stat = File.stat!(path)

    unless Bitwise.band(stat.mode, 0o777) == 0o600 do
      raise ArgumentError, "matched baseline Result must be owner-readable only"
    end

    receipt = path |> File.read!() |> Jason.decode!()
    expected_condition = config |> Map.put(:arm, :baseline) |> condition_receipt() |> json_safe()
    actual_condition = receipt["condition"] || %{}

    comparable = fn condition -> Map.drop(condition, ["source_commit"]) end

    checks = %{
      status: receipt["status"] == "complete",
      family: receipt["family"] == config.family,
      arm: receipt["arm"] == "baseline",
      seed: receipt["seed"] == config.seed,
      heldout_decoded: receipt["heldout_decoded"] == true,
      heldout_score: is_number(get_in(receipt, ["heldout", "score"])),
      heldout_rows:
        get_in(receipt, ["heldout", "row_count"]) ==
          prepared.loaded.spec["split_counts"]["test"],
      tracked_clean_identity:
        actual_condition["source_tracked_clean"] == expected_condition["source_tracked_clean"],
      live_source_clean:
        config.provider_disabled_fixture? or actual_condition["source_tracked_clean"] == true,
      source_commit: actual_condition["source_commit"] == expected_source_commit,
      condition: comparable.(actual_condition) == comparable.(expected_condition),
      data: receipt["data"] == data_receipt(prepared.loaded.spec) |> json_safe()
    }

    unless Enum.all?(checks, fn {_name, passed?} -> passed? end) do
      failed = for {name, false} <- checks, do: name

      raise ArgumentError,
            "matched baseline Result does not match the completed source-sized condition: " <>
              inspect(Enum.sort(failed))
    end

    %{
      result_sha256: sha256(path),
      source_commit: expected_source_commit,
      heldout_score: get_in(receipt, ["heldout", "score"]),
      heldout_error_count: get_in(receipt, ["heldout", "error_count"]),
      progress_sha256: receipt["progress_sha256"]
    }
  end

  defp data_receipt(spec) do
    %{
      source: spec["source"] || spec["dataset_source"] || spec["source_commit"],
      split_counts: spec["split_counts"],
      split_checksums: spec["split_checksums"] || spec["checksums"]
    }
  end

  defp git_output(args) do
    case System.cmd("git", args, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {_output, _status} -> nil
    end
  end

  defp git_status(args) do
    {_output, status} = System.cmd("git", args, stderr_to_stdout: true)
    status
  end

  defp spend_snapshot(%{spend_guard: nil}), do: nil

  defp spend_snapshot(config) do
    config.spend_guard |> Imp.GepaSuiteSpendGuard.snapshot() |> json_safe()
  end

  defp role_reservation(config, role) do
    input = Map.fetch!(config, String.to_existing_atom("#{role}_max_input_bytes"))
    output = Map.fetch!(config, String.to_existing_atom("#{role}_max_output_tokens"))

    (input * role_price!(config, role, :input) +
       output * role_price!(config, role, :output)) /
      1_000_000
  end

  @doc false
  def role_price!(config, role, direction) do
    role_price(config, role, direction) ||
      raise ArgumentError,
            "#{role}_#{direction}_price_per_million or #{direction}_price_per_million " <>
              "must be a nonnegative number"
  end

  defp role_price(config, role, direction) do
    role_key = String.to_existing_atom("#{role}_#{direction}_price_per_million")
    shared_key = String.to_existing_atom("#{direction}_price_per_million")

    case Map.get(config, role_key) do
      value when is_number(value) and value >= 0 ->
        value

      nil ->
        case Map.get(config, shared_key) do
          value when is_number(value) and value >= 0 -> value
          nil -> nil
          _ -> raise ArgumentError, "#{shared_key} must be a nonnegative number"
        end

      _ ->
        raise ArgumentError, "#{role_key} must be a nonnegative number"
    end
  end

  defp evaluation(result) do
    rows =
      result.rows
      |> Enum.with_index()
      |> Enum.map(fn {row, index} ->
        inputs = row.example |> Imp.Example.inputs() |> Imp.Example.to_map()

        %{
          index: index,
          input_sha256: canonical_sha256(inputs),
          score: row.score,
          error: redacted_error(row.error)
        }
      end)

    %{
      score: result.score,
      row_count: length(rows),
      error_count: length(result.errors),
      rows: rows
    }
  end

  defp capture_runtime(fun, progress_path) do
    {:ok, _started} = Application.ensure_all_started(:telemetry)
    id = {__MODULE__, :runtime_usage, make_ref()}

    {:ok, usage} =
      Agent.start_link(fn ->
        empty_runtime()
        |> Map.put("progress_path", progress_path)
        |> Map.put("next_sequence", 1)
      end)

    :ok =
      :telemetry.attach_many(
        id,
        [
          [:req_llm, :request, :start],
          [:req_llm, :request, :stop],
          [:req_llm, :request, :exception],
          [:imp, :adapter, :parse, :json_fallback],
          [:imp, :gepa_suite, :role, :stop],
          [:imp, :gepa_suite, :role, :exception]
        ],
        &__MODULE__.handle_runtime_event/4,
        usage
      )

    started = System.monotonic_time(:microsecond)

    try do
      result =
        try do
          {:ok, fun.()}
        rescue
          error -> {:error, error, __STACKTRACE__}
        end

      runtime = Agent.get(usage, &finalize_runtime/1)
      {System.monotonic_time(:microsecond) - started, result, runtime}
    after
      :telemetry.detach(id)
      Agent.stop(usage)
    end
  end

  defp unwrap_run!(
         {:ok, result},
         _config,
         _prepared,
         _reservation,
         _wall_time_us,
         _usage,
         _matched_baseline
       ),
       do: result

  defp unwrap_run!(
         {:error, error, stacktrace},
         config,
         prepared,
         reservation,
         wall_time_us,
         usage,
         matched_baseline
       ) do
    write_private!(config.output, %{
      status: :failed,
      family: config.family,
      arm: config.arm,
      seed: config.seed,
      stage: :optimize_or_heldout,
      error: redacted_error(error),
      usage: usage,
      progress_sha256: existing_sha256(progress_path(config)),
      wall_time_us: wall_time_us,
      spend_admission: Map.put(reservation, "final", spend_snapshot(config)),
      condition: condition_receipt(config),
      data: data_receipt(prepared.loaded.spec),
      matched_baseline: matched_baseline
    })

    reraise error, stacktrace
  end

  defp write_failure_unless_exists!(config, prepared, stage, error, details) do
    unless File.exists?(config.output) do
      write_private!(
        config.output,
        Map.merge(
          %{
            status: :failed,
            family: config.family,
            arm: config.arm,
            seed: config.seed,
            stage: stage,
            error: redacted_error(error),
            condition: condition_receipt(config),
            data: data_receipt(prepared.loaded.spec)
          },
          details
        )
      )
    end
  end

  defp retained_fresh_failure(config, prepared) do
    expected_condition = condition_receipt(config) |> json_safe()
    expected_data = data_receipt(prepared.loaded.spec) |> json_safe()

    expected_artifact_sha256 =
      if is_binary(config.artifact) and File.regular?(config.artifact),
        do: sha256(config.artifact),
        else: nil

    with path when is_binary(path) <- config.fresh_output,
         true <- File.regular?(path),
         {:ok, receipt} <- path |> File.read!() |> Jason.decode(),
         "failed" <- receipt["status"],
         ^expected_condition <- receipt["condition"],
         ^expected_data <- receipt["data"],
         ^expected_artifact_sha256 <- receipt["loaded_artifact_sha256"] do
      %{
        usage: receipt["usage"] || empty_runtime(),
        spend: receipt["spend_admission"],
        evidence: %{status: :retained, sha256: sha256(path), path: path}
      }
    else
      _ ->
        %{
          usage: empty_runtime(),
          spend: nil,
          evidence: %{
            status: :unresolved,
            reason: :no_valid_atomic_child_failure_receipt,
            passed_initial_cost_usd: get_in(spend_snapshot(config), ["accounted_total_usd"])
          }
        }
    end
  end

  defp unwrap_fresh!(
         {:ok, result},
         _config,
         _prepared,
         _loaded_artifact_sha256,
         _wall_time_us,
         _usage
       ),
       do: result

  defp unwrap_fresh!(
         {:error, error, stacktrace},
         config,
         prepared,
         loaded_artifact_sha256,
         wall_time_us,
         usage
       ) do
    write_private!(config.fresh_output, %{
      status: :failed,
      family: config.family,
      arm: config.arm,
      seed: config.seed,
      stage: :fresh_service,
      error: redacted_error(error),
      usage: usage,
      progress_sha256: existing_sha256(progress_path(config)),
      wall_time_us: wall_time_us,
      spend_admission:
        spend_admission(config)
        |> Map.put("final", spend_snapshot(config)),
      loaded_artifact_sha256: loaded_artifact_sha256,
      condition: condition_receipt(config),
      data: data_receipt(prepared.loaded.spec)
    })

    reraise error, stacktrace
  end

  @doc false
  def handle_runtime_event([:req_llm, :request, :start], _measurements, metadata, usage) do
    event_record = %{
      "sequence" => nil,
      "status" => "started",
      "request_id" => Map.get(metadata, :request_id),
      "provider" => json_safe(Map.get(metadata, :provider)),
      "model" => model_id(Map.get(metadata, :model)),
      "request_summary" => json_safe(Map.get(metadata, :request_summary))
    }

    record_runtime_event(usage, event_record, %{"request_starts" => 1})
  end

  def handle_runtime_event(event, measurements, metadata, usage)
      when event in [[:req_llm, :request, :stop], [:req_llm, :request, :exception]] do
    duration = Map.get(measurements, :duration, 0)
    provider_usage = Map.get(metadata, :usage, %{}) || %{}
    token_usage = field(provider_usage, :tokens) || provider_usage
    successful? = event == [:req_llm, :request, :stop]

    delta = %{
      "usage_events" => if(successful?, do: 1, else: 0),
      "request_attempts" => 1,
      "request_duration_us" => System.convert_time_unit(duration, :native, :microsecond),
      "input_tokens" => number(token_usage, [:input_tokens, :input]) |> trunc(),
      "output_tokens" => number(token_usage, [:output_tokens, :output]) |> trunc(),
      "cost_usd" => number(provider_usage, [:total_cost, :cost])
    }

    event_record = %{
      "sequence" => nil,
      "status" => if(successful?, do: "ok", else: "error"),
      "request_id" => Map.get(metadata, :request_id),
      "provider" => json_safe(Map.get(metadata, :provider)),
      "model" => model_id(Map.get(metadata, :model)),
      "http_status" => Map.get(metadata, :http_status),
      "finish_reason" => json_safe(Map.get(metadata, :finish_reason)),
      "request_summary" => json_safe(Map.get(metadata, :request_summary)),
      "response_summary" => json_safe(Map.get(metadata, :response_summary)),
      "duration_us" => delta["request_duration_us"],
      "input_tokens" => delta["input_tokens"],
      "output_tokens" => delta["output_tokens"],
      "cost_usd" => delta["cost_usd"],
      "error" => if(successful?, do: nil, else: redacted_error(Map.get(metadata, :error)))
    }

    record_runtime_event(usage, event_record, delta)
  end

  def handle_runtime_event(
        [:imp, :adapter, :parse, :json_fallback],
        measurements,
        metadata,
        usage
      ) do
    count = Map.get(measurements, :count, 1)

    event_record = %{
      "sequence" => nil,
      "status" => "adapter_json_fallback",
      "adapter" => metadata |> Map.get(:adapter) |> json_safe(),
      "error_fingerprint_sha256" =>
        metadata |> Map.get(:error) |> redacted_error() |> field("fingerprint_sha256")
    }

    record_runtime_event(usage, event_record, %{"json_fallbacks" => count})
  end

  def handle_runtime_event(
        [:imp, :gepa_suite, :role, status],
        measurements,
        metadata,
        usage
      )
      when status in [:stop, :exception] do
    role = Map.fetch!(metadata, :role)
    successful? = status == :stop

    delta = %{
      "request_attempts" => 1,
      "usage_events" => if(successful?, do: 1, else: 0),
      "error_count" => if(successful?, do: 0, else: 1),
      "request_duration_us" =>
        measurements
        |> Map.get(:duration, 0)
        |> System.convert_time_unit(:native, :microsecond),
      "input_tokens" => if(successful?, do: Map.get(metadata, :input_tokens, 0), else: 0),
      "output_tokens" => if(successful?, do: Map.get(metadata, :output_tokens, 0), else: 0),
      "cost_usd" => if(successful?, do: Map.get(metadata, :cost_usd, 0.0), else: 0.0)
    }

    event_record = %{
      "sequence" => nil,
      "event" => "role_transport",
      "role" => Atom.to_string(role),
      "status" => if(successful?, do: "ok", else: "error"),
      "duration_us" => delta["request_duration_us"],
      "input_tokens" => delta["input_tokens"],
      "output_tokens" => delta["output_tokens"],
      "cost_usd" => delta["cost_usd"],
      "error" => if(successful?, do: nil, else: redacted_error(Map.get(metadata, :error)))
    }

    Agent.update(usage, fn state ->
      sequence = state["next_sequence"]
      event_record = Map.put(event_record, "sequence", sequence)
      append_progress!(state["progress_path"], event_record)

      state
      |> put_in(
        ["by_role", Atom.to_string(role)],
        add_usage(get_in(state, ["by_role", Atom.to_string(role)]), delta)
      )
      |> Map.put("events", [event_record | state["events"]])
      |> Map.put("next_sequence", sequence + 1)
    end)
  end

  defp empty_runtime do
    %{
      "summary" => empty_usage(),
      "by_role" => Map.new(~w(task reflection judge), &{&1, empty_role_usage()}),
      "events" => []
    }
  end

  defp finalize_runtime(runtime) do
    events =
      runtime["events"]
      |> Enum.reverse()
      |> Enum.with_index(1)
      |> Enum.map(fn {event, index} -> %{event | "sequence" => index} end)

    runtime
    |> Map.put("events", events)
    |> Map.drop(["progress_path", "next_sequence"])
  end

  defp empty_usage do
    %{
      "usage_events" => 0,
      "request_attempts" => 0,
      "request_starts" => 0,
      "json_fallbacks" => 0,
      "request_duration_us" => 0,
      "input_tokens" => 0,
      "output_tokens" => 0,
      "cost_usd" => 0.0
    }
  end

  defp empty_role_usage do
    %{
      "usage_events" => 0,
      "request_attempts" => 0,
      "error_count" => 0,
      "request_duration_us" => 0,
      "input_tokens" => 0,
      "output_tokens" => 0,
      "cost_usd" => 0.0
    }
  end

  defp add_usage(left, right) do
    Map.new(left, fn {key, value} -> {key, value + Map.get(right || %{}, key, 0)} end)
  end

  defp record_runtime_event(usage, event_record, delta) do
    Agent.update(usage, fn state ->
      sequence = state["next_sequence"]
      event_record = Map.put(event_record, "sequence", sequence)
      append_progress!(state["progress_path"], event_record)

      state
      |> Map.put("summary", add_usage(state["summary"], delta))
      |> Map.put("events", [event_record | state["events"]])
      |> Map.put("next_sequence", sequence + 1)
    end)
  end

  defp merge_runtime(left, right) do
    left = left || empty_runtime()
    right = right || empty_runtime()

    events =
      (Map.get(left, "events", []) ++ Map.get(right, "events", []))
      |> Enum.with_index(1)
      |> Enum.map(fn {event, index} -> Map.put(event, "sequence", index) end)

    %{
      "summary" => add_usage(Map.get(left, "summary", %{}), Map.get(right, "summary", %{})),
      "by_role" =>
        Map.new(~w(task reflection judge), fn role ->
          {role,
           add_usage(
             get_in(left, ["by_role", role]) || empty_role_usage(),
             get_in(right, ["by_role", role]) || empty_role_usage()
           )}
        end),
      "events" => events
    }
  end

  defp model_id(%{id: id}) when is_binary(id), do: id
  defp model_id(%{"id" => id}) when is_binary(id), do: id
  defp model_id(value), do: json_safe(value)

  defp number(map, keys) do
    Enum.find_value(keys, 0, fn key ->
      value = Map.get(map, key, Map.get(map, Atom.to_string(key)))
      if is_number(value), do: value
    end)
  end

  defp field(nil, _key), do: nil

  defp field(map, key) when is_map(map) do
    Map.get(map, key, Map.get(map, to_string(key)))
  end

  defp field(_value, _key), do: nil

  defp redacted_error(nil), do: nil

  defp redacted_error(error) do
    redacted = Imp.Redaction.redact(error)

    %{
      "type" => error |> elem_type() |> inspect(),
      "cause_types" => error |> cause_types() |> Enum.uniq(),
      "fingerprint_sha256" =>
        :crypto.hash(:sha256, :erlang.term_to_binary(redacted)) |> Base.encode16(case: :lower)
    }
  end

  defp cause_types(%{__struct__: module}), do: [inspect(module)]

  defp cause_types(tuple) when is_tuple(tuple) do
    [inspect(:tuple) | tuple |> Tuple.to_list() |> Enum.flat_map(&cause_types/1)]
  end

  # Provider diagnostics may be improper lists. Do not enumerate them while
  # producing evidence; the outer type is sufficient and cannot expose values.
  defp cause_types(list) when is_list(list), do: [inspect(:list)]

  defp cause_types(value), do: [value |> elem_type() |> inspect()]

  defp elem_type(%{__struct__: module}), do: module
  defp elem_type(value) when is_atom(value), do: :atom
  defp elem_type(value) when is_binary(value), do: :binary
  defp elem_type(value) when is_list(value), do: :list
  defp elem_type(value) when is_tuple(value), do: :tuple
  defp elem_type(value) when is_map(value), do: :map
  defp elem_type(_value), do: :term

  defp retrieval_disclosure(config, %{"retrieval" => historical}) do
    receipt = config.retrieval_receipt |> File.read!() |> Jason.decode!()

    %{
      classification:
        :authenticated_current_build_of_official_retrieval_not_historical_byte_reproduction,
      corpus_sha256: get_in(receipt, ["retrieval", "extraction", "corpus_sha256"]),
      index_tree_sha256: get_in(receipt, ["retrieval", "build", "actual_tree_sha256"]),
      historical_unretained_index_sha256: historical["index_checksum"]
    }
  end

  defp retrieval_disclosure(_config, _spec), do: nil

  defp metric_runtime(%{family: "LiveBenchMathBench", livebench_math_python: python})
       when is_binary(python) do
    bridge = Path.expand("scripts/livebench_math_score.py", File.cwd!())

    %{
      symbolic_bridge_python: python,
      symbolic_bridge_python_sha256: sha256(python),
      symbolic_bridge_path: bridge,
      symbolic_bridge_sha256: sha256(bridge),
      feedback_source_root: System.fetch_env!("IMP_LIVEBENCH_MATH_SOURCE_ROOT"),
      feedback_source_commit: @gepa_artifact_commit,
      preflight: :exact_symbolic_identity_score_passed_before_transport
    }
  end

  defp metric_runtime(_config), do: nil

  defp validate_live!(config) do
    required_positive!(config, :max_concurrency)

    unless config.seed in @study_seeds do
      raise ArgumentError,
            "seed must be one of the frozen study seeds: #{inspect(@study_seeds)}"
    end

    if config.provider_disabled_fixture? and not config.fresh? do
      raise ArgumentError, "--provider-disabled-fixture is restricted to fresh lifecycle tests"
    end

    if (config.run? or config.fresh?) and not config.provider_disabled_fixture? do
      for role <- [:task, :reflection, :judge], suffix <- [:model, :provider] do
        required_config!(config, String.to_existing_atom("#{role}_#{suffix}"))
      end

      for role <- [:task, :reflection, :judge],
          suffix <- [:max_input_bytes, :max_output_tokens] do
        required_positive!(config, String.to_existing_atom("#{role}_#{suffix}"))
      end

      for role <- [:task, :reflection, :judge], direction <- [:input, :output] do
        role_price!(config, role, direction)
      end

      if config.run? do
        required_nonnegative_number!(config, :initial_cost_usd)
        required_positive_number!(config, :max_cost_usd)
      end
    end

    config
  end

  defp required!(opts, key) do
    Keyword.get(opts, key) ||
      raise ArgumentError, "missing --#{String.replace(to_string(key), "_", "-")}"
  end

  defp required_config!(config, key) do
    Map.get(config, key) || raise ArgumentError, "missing live option #{inspect(key)}"
  end

  defp required_positive!(config, key) do
    case Map.get(config, key) do
      value when is_integer(value) and value > 0 -> value
      _ -> raise ArgumentError, "#{key} must be a positive integer"
    end
  end

  defp required_nonnegative_number!(config, key) do
    case Map.get(config, key) do
      value when is_number(value) and value >= 0 -> value
      _ -> raise ArgumentError, "#{key} must be a nonnegative number"
    end
  end

  defp required_positive_number!(config, key) do
    case Map.get(config, key) do
      value when is_number(value) and value > 0 -> value
      _ -> raise ArgumentError, "#{key} must be a positive number"
    end
  end

  defp expand(nil), do: nil
  defp expand(path), do: Path.expand(path)

  defp write_private!(path, payload) do
    File.mkdir_p!(Path.dirname(path))
    File.chmod!(Path.dirname(path), 0o700)
    temporary = path <> ".tmp-#{System.pid()}-#{System.monotonic_time()}"

    try do
      File.open!(temporary, [:write, :exclusive], fn file ->
        File.chmod!(temporary, 0o600)
        IO.binwrite(file, Jason.encode!(json_safe(payload), pretty: true) <> "\n")
        :ok = :file.sync(file)
      end)

      case File.ln(temporary, path) do
        :ok ->
          :ok

        {:error, :eexist} ->
          raise ArgumentError, "refusing to overwrite existing evidence: #{path}"

        {:error, reason} ->
          raise File.Error, reason: reason, action: "link", path: path
      end
    after
      File.rm(temporary)
    end
  end

  @doc false
  def write_artifact_exclusive!(artifact, path) do
    temporary = path <> ".tmp-#{System.pid()}-#{System.monotonic_time()}"

    try do
      Artifact.write!(artifact, temporary)

      case File.ln(temporary, path) do
        :ok ->
          :ok

        {:error, :eexist} ->
          raise ArgumentError, "refusing to overwrite existing evidence: #{path}"

        {:error, reason} ->
          raise File.Error, reason: reason, action: "link", path: path
      end
    after
      File.rm(temporary)
    end
  end

  defp ensure_new_targets!(paths) do
    paths
    |> Enum.reject(&is_nil/1)
    |> Enum.each(fn path ->
      if File.exists?(path),
        do: raise(ArgumentError, "refusing to overwrite existing evidence: #{path}")
    end)
  end

  defp init_progress!(config) do
    progress_path = progress_path(config)
    File.mkdir_p!(Path.dirname(progress_path))
    File.chmod!(Path.dirname(progress_path), 0o700)

    header = %{
      "event" => "start",
      "family" => config.family,
      "arm" => config.arm,
      "seed" => config.seed,
      "max_concurrency" => config.max_concurrency
    }

    File.open!(progress_path, [:write, :exclusive], fn file ->
      IO.binwrite(file, Jason.encode!(json_safe(header)) <> "\n")
    end)

    File.chmod!(progress_path, 0o600)
    progress_path
  end

  defp progress_path(config) do
    output = if config.fresh?, do: config.fresh_output, else: config.output
    output <> ".progress.jsonl"
  end

  defp append_progress!(path, event) do
    File.write!(path, Jason.encode!(json_safe(event)) <> "\n", [:append])
  end

  defp emit(payload), do: IO.puts(Jason.encode!(json_safe(payload)))
  defp sha256(path), do: :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)
  defp existing_sha256(path), do: if(File.exists?(path), do: sha256(path), else: nil)

  # Python's canonical study entrance uses json.dumps(..., ensure_ascii=False),
  # which spells hexadecimal digits in required control-character escapes in
  # lowercase. Jason emits the same JSON value with uppercase hex digits. Make
  # that representational choice explicit so identical cross-runtime inputs
  # have one evidence identity without changing the decoded value.
  def canonical_sha256(value) do
    value
    |> json_safe()
    |> canonical_json_value()
    |> Jason.encode!()
    |> normalize_json_unicode_escapes()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp normalize_json_unicode_escapes(json) do
    normalize_json_unicode_escapes(json, 0, [])
  end

  defp normalize_json_unicode_escapes(<<>>, _preceding_backslashes, acc),
    do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp normalize_json_unicode_escapes(
         <<?\\, ?u, a, b, c, d, rest::binary>> = json,
         preceding_backslashes,
         acc
       ) do
    digits = <<a, b, c, d>>

    if rem(preceding_backslashes, 2) == 0 and digits =~ ~r/^[0-9A-Fa-f]{4}$/ do
      normalize_json_unicode_escapes(rest, 0, ["\\u" <> String.downcase(digits) | acc])
    else
      <<byte, rest::binary>> = json
      normalize_json_unicode_escapes(rest, preceding_backslashes + 1, [byte | acc])
    end
  end

  defp normalize_json_unicode_escapes(<<byte, rest::binary>>, preceding_backslashes, acc) do
    next = if byte == ?\\, do: preceding_backslashes + 1, else: 0
    normalize_json_unicode_escapes(rest, next, [byte | acc])
  end

  defp canonical_json_value(map) when is_map(map) and not is_struct(map) do
    values =
      map
      |> Enum.map(fn {key, value} -> {to_string(key), canonical_json_value(value)} end)
      |> Enum.sort_by(&elem(&1, 0))

    %Jason.OrderedObject{values: values}
  end

  defp canonical_json_value(list) when is_list(list), do: Enum.map(list, &canonical_json_value/1)
  defp canonical_json_value(value), do: value
  defp json_safe(%Imp.Example{} = value), do: value |> Imp.Example.to_map() |> json_safe()
  defp json_safe(%Imp.Prediction{} = value), do: value |> Imp.Prediction.to_map() |> json_safe()
  defp json_safe(%_{} = value), do: value |> Map.from_struct() |> json_safe()

  defp json_safe(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {to_string(key), json_safe(item)} end)

  defp json_safe(value) when is_list(value) do
    try do
      Enum.map(value, &json_safe/1)
    rescue
      FunctionClauseError -> inspect(Imp.Redaction.redact(value), limit: 50, printable_limit: 500)
    end
  end

  defp json_safe(value) when is_tuple(value), do: value |> Tuple.to_list() |> json_safe()
  defp json_safe(nil), do: nil
  defp json_safe(value) when is_boolean(value), do: value
  defp json_safe(value) when is_atom(value), do: Atom.to_string(value)
  defp json_safe(value) when is_binary(value) or is_number(value), do: value
  defp json_safe(value), do: inspect(value)
end

Imp.GepaSuiteConditionCLI.main(System.argv())
