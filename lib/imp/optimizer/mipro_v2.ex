defmodule Imp.Optimizer.MIPROv2 do
  @behaviour Imp.Optimizer
  import Bitwise

  @moduledoc """
  Joint instruction and few-shot optimization using grounded proposals and categorical TPE.

  The implementation follows DSPy MIPROv2's three stages: metric-filtered
  demonstration bootstrapping, predictor-specific grounded instruction
  proposal, and seeded multivariate Bayesian search. Minibatch trials inform
  the surrogate, but only full validation evaluations can select the returned
  program.

  `:init_temperature` is the pinned DSPy proposal-temperature control.
  `:proposal_response_format` optionally binds each proposal to Imp's strict
  one-instruction JSON schema (`:off`, `:auto`, or `:required`).

  Program-aware proposals use structural program metadata by default. Source
  text is included only through the explicit `program_grounding: :module_source`
  or `program_grounding: {:text, context}` opt-in.

  `:proposer_fidelity` defaults to Imp's documented `:beam_native` grounded
  proposer. Set it to `:dspy_3_2_1` for the matched-comparison path with data/tip
  awareness enabled. Program awareness requires explicit text grounding and
  performs DSPy's program-description and module-description calls before each
  candidate; few-shot awareness uses the same ordered demo arms searched by the
  optimizer. Both zero-shot and joint instruction/demonstration search are
  supported; unsupported proposer combinations fail before any LM call.
  Pinned dataset grounding renders the JSON-safe values in `Imp.Example` with
  DSPy/Python spelling. Use `Jason.OrderedObject` when nested JSON object order
  is semantically significant; unsupported values fail before proposer
  transport with their exact example path.

  `:search_fidelity` separately controls parameter search. The legacy narrow
  `:dspy_3_2_1_optuna_4_9_0_startup` mode reproduces Optuna 4.9.0's NumPy
  RandomState startup sequence exactly and rejects configurations that would
  enter modeled TPE. `:dspy_3_2_1_optuna_4_9_0` continues through Optuna's
  multivariate categorical TPE phase with the pinned split, Parzen kernels,
  candidate sampling, and independent NumPy RNG streams. Imp's default
  categorical Parzen search remains a
  BEAM-native algorithm and does not claim Optuna trial-sequence parity.

  An explicit compile-time `seed: 0` is a real seed in the default BEAM-native
  mode. The pinned `:dspy_3_2_1` proposer mode deliberately mirrors DSPy's
  Python-truthiness behavior and retains the constructor seed when the compile
  override is zero.
  """

  alias Imp.Optimizer.{
    DemoCandidates,
    DurableCallbackIdentity,
    InstructionProposer,
    Report,
    Sampling,
    SearchPolicy
  }

  alias Imp.Optimizer.MIPROv2.{Checkpoint, Config}
  alias Imp.OperationalSafetyError
  alias Imp.Optimizer.MIPROv2.{OptunaStartupPolicy, OptunaTPEPolicy}
  alias Imp.Optimizer.MIPROv2.PythonRandom
  alias Imp.Optimizer.MIPROv2.UpstreamBootstrap
  alias Imp.Optimizer.MIPROv2.UpstreamProposer
  alias Imp.Optimizer.SearchPolicy.CategoricalTPE, as: CategoricalPolicy

  defstruct [
    :metric,
    :config,
    :prompt_lm,
    :task_lm,
    :teacher,
    :metric_threshold,
    :metric_identity,
    init_temperature: 1.0,
    proposal_response_format: :off,
    max_errors: :infinity,
    max_concurrency: 1,
    timeout: :infinity,
    startup_trials: 10
  ]

  @runtime_keys [
    :prompt_lm,
    :task_lm,
    :teacher,
    :metric_threshold,
    :metric_identity,
    :init_temperature,
    :proposal_response_format,
    :max_errors,
    :max_concurrency,
    :timeout,
    :startup_trials
  ]
  @compile_runtime_keys [:resume_state, :checkpoint_fn, :max_trials]

  def new(metric, opts \\ []) do
    Imp.FunctionContract.validate!(metric, [2, 3], "Imp.Optimizer.MIPROv2.new/2", "metric")

    unless Keyword.keyword?(opts),
      do: raise(ArgumentError, "Imp.Optimizer.MIPROv2.new/2: expected keyword options")

    {config_opts, runtime_opts} = normalize_options(opts)

    optimizer =
      %__MODULE__{
        metric: metric,
        config: Config.new(config_opts),
        prompt_lm: runtime_opts[:prompt_lm],
        task_lm: runtime_opts[:task_lm],
        teacher: runtime_opts[:teacher],
        metric_threshold: runtime_opts[:metric_threshold],
        metric_identity:
          DurableCallbackIdentity.normalize!(runtime_opts[:metric_identity], :metric_identity),
        init_temperature: Keyword.get(runtime_opts, :init_temperature, 1.0),
        proposal_response_format: Keyword.get(runtime_opts, :proposal_response_format, :off),
        max_errors: Keyword.get(runtime_opts, :max_errors, :infinity),
        max_concurrency: Keyword.get(runtime_opts, :max_concurrency, 1),
        timeout: Keyword.get(runtime_opts, :timeout, :infinity),
        startup_trials: Keyword.get(runtime_opts, :startup_trials, 10)
      }

    :ok = validate_optimizer!(optimizer, optimizer.config)
    optimizer
  end

  @doc """
  Returns a typed fail-closed error for an operational guard inside an LM or
  program callback.

  Generic Imp call boundaries intentionally normalize raised exceptions. A
  route, cost, transport, budget, or cancellation guard that runs inside those
  boundaries must therefore return this tuple so pinned MIPRO search can
  distinguish it from an ordinary task/adapter failure:

      MIPROv2.operational_error(:cost, :nonzero_provider_cost,
        message: "provider cost guard drift"
      )

  Use `operational_error!/3` only outside a normalized LM/program callback.
  """
  def operational_error(kind, reason, opts \\ []) when is_list(opts) do
    {:error,
     OperationalSafetyError.exception(
       [kind: kind, reason: reason] ++ Keyword.take(opts, [:message])
     )}
  end

  @doc "Raises the typed operational guard error outside normalized call boundaries."
  def operational_error!(kind, reason, opts \\ []) when is_list(opts) do
    {_tag, error} = operational_error(kind, reason, opts)
    raise error
  end

  @impl true
  def __optimizer__,
    do: %{
      kind: :program,
      datasets: %{trainset: :required, validation: :required},
      result: :program
    }

  @impl true
  def run(%__MODULE__{} = optimizer, program, opts) do
    {:ok,
     compile(
       optimizer,
       program,
       Imp.Optimizer.fetch_dataset!(opts, :trainset),
       Imp.Optimizer.fetch_dataset!(opts, :validation),
       Imp.Optimizer.invocation_options(opts)
     )}
  end

  @impl true
  def validate_invocation_options(opts) do
    unless Keyword.keyword?(opts),
      do: raise(ArgumentError, "MIPROv2 invocation options must be a keyword list")

    unknown = Keyword.keys(opts) -- (Config.option_keys() ++ @compile_runtime_keys)

    if unknown != [],
      do: raise(ArgumentError, "unknown MIPROv2 invocation options: #{inspect(unknown)}")

    _validated_config = opts |> Keyword.take(Config.option_keys()) |> Config.new()

    _validated_runtime =
      opts |> Keyword.take(@compile_runtime_keys) |> validate_compile_options!()

    :ok
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  @impl true
  def validate_invocation_options(%__MODULE__{} = optimizer, opts) do
    unless Keyword.keyword?(opts),
      do: raise(ArgumentError, "MIPROv2 invocation options must be a keyword list")

    unknown = Keyword.keys(opts) -- (Config.option_keys() ++ @compile_runtime_keys)

    if unknown != [],
      do: raise(ArgumentError, "unknown MIPROv2 invocation options: #{inspect(unknown)}")

    config_options =
      optimizer.config
      |> Map.from_struct()
      |> Map.take(Config.option_keys())
      |> Enum.to_list()
      |> Keyword.merge(Keyword.take(opts, Config.option_keys()))

    config = Config.new(config_options)

    _validated_runtime =
      opts |> Keyword.take(@compile_runtime_keys) |> validate_compile_options!()

    :ok = validate_optimizer!(optimizer, config)
    :ok
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  def compile(%__MODULE__{} = optimizer, program, trainset, valset) do
    compile(optimizer, program, trainset, valset, [])
  end

  @doc """
  Compiles with optional invocation-level checkpoint and resume controls.

  `:max_trials` limits the number of new objective trials executed by this
  invocation. `:checkpoint_fn` receives a JSON-safe checkpoint after setup and
  after each completed trial. Pass any emitted checkpoint back as
  `:resume_state` to continue without replaying setup or completed trials.
  Checkpoints are trial-atomic, so an interrupted in-flight trial is retried.
  """
  def compile(%__MODULE__{} = optimizer, program, trainset, valset, opts) do
    unless Keyword.keyword?(opts),
      do: raise(ArgumentError, "Imp.Optimizer.MIPROv2.compile/5 expects keyword options")

    compile(optimizer, program, Keyword.merge(opts, trainset: trainset, valset: valset))
  end

  def compile(%__MODULE__{} = optimizer, program, opts) when is_list(opts) do
    unless Keyword.keyword?(opts),
      do: raise(ArgumentError, "Imp.Optimizer.MIPROv2.compile/3 expects keyword options")

    trainset = Keyword.fetch!(opts, :trainset)
    valset = Keyword.get(opts, :valset)
    compile_overrides = Keyword.drop(opts, [:trainset, :valset] ++ @compile_runtime_keys)
    run_opts = opts |> Keyword.take(@compile_runtime_keys) |> validate_compile_options!()
    predictors = Imp.ProgramParameters.predictors(program)

    if predictors == [] do
      raise ArgumentError, "MIPROv2 requires a program with at least one optimizer predictor"
    end

    config =
      Config.resolve(optimizer.config, length(predictors), trainset, valset, compile_overrides)

    run(optimizer, config, program, predictors, run_opts)
  end

  @doc false
  def upstream_trial_schedule(num_trials, full_eval_steps)
      when is_integer(num_trials) and num_trials >= 0 and is_integer(full_eval_steps) and
             full_eval_steps > 0 do
    adjusted = adjusted_trial_count(num_trials, full_eval_steps)

    {objectives, promotions, _next_study_number} =
      Enum.reduce(trial_indices(num_trials), {[], [], 1}, fn objective,
                                                             {objectives, promotions, next} ->
        upstream_trial_num = next + 1
        objectives = objectives ++ [upstream_trial_num]
        next = next + 1

        if upstream_full_evaluation_trial?(upstream_trial_num, adjusted, full_eval_steps) do
          promotion = %{
            after_objective: objective,
            trigger_trial_num: upstream_trial_num,
            log_trial_num: upstream_trial_num + 1
          }

          {objectives, promotions ++ [promotion], next + 1}
        else
          {objectives, promotions, next}
        end
      end)

    %{
      num_trials: num_trials,
      minibatch_full_eval_steps: full_eval_steps,
      adjusted_num_trials: adjusted,
      baseline_full_evaluation_log_trial: 1,
      objective_trial_numbers: objectives,
      periodic_full_evaluations: promotions
    }
  end

  @doc false
  def categorical_space(predictors, instructions, demos)
      when is_list(predictors) and is_map(instructions) and (is_map(demos) or is_nil(demos)) do
    search_space(predictors, instructions, demos)
  end

  defp run(optimizer, config, program, predictors, run_opts) do
    :ok = validate_optimizer!(optimizer, config)

    prompt_lm =
      optimizer.prompt_lm || predictors |> hd() |> Map.fetch!(:predictor) |> Map.get(:lm)

    program = maybe_rebind_task_lm(program, predictors, optimizer.task_lm)
    predictors = Imp.ProgramParameters.predictors(program)

    if is_nil(prompt_lm) and is_nil(run_opts[:resume_state]) do
      raise ArgumentError,
            "MIPROv2 requires :prompt_lm or a concrete LM on the program's first predictor"
    end

    durable? =
      DurableCallbackIdentity.durable?(
        optimizer.metric,
        optimizer.metric_identity,
        durable_controls?(run_opts)
      )

    metric_identity =
      DurableCallbackIdentity.resolve!(
        optimizer.metric,
        optimizer.metric_identity,
        durable?,
        "MIPROv2",
        :metric_identity
      )

    compatibility = resume_compatibility(program, predictors, config, optimizer, metric_identity)

    {artifacts, state, resumed?} =
      case run_opts[:resume_state] do
        nil ->
          {artifacts, state} = setup_run(optimizer, config, program, predictors, prompt_lm)
          emit_checkpoint(run_opts[:checkpoint_fn], compatibility, artifacts, state)
          {artifacts, state, false}

        checkpoint ->
          %{artifacts: artifacts, state: state} =
            Checkpoint.load!(checkpoint, compatibility)

          {artifacts, restore_programs(state, program, predictors, artifacts), true}
      end

    %{instruction_candidates: instruction_candidates, search_demos: search_demos} = artifacts
    completed_trials = length(state.trials)
    run_limit = invocation_trial_limit(config.num_trials, completed_trials, run_opts[:max_trials])

    state =
      Enum.reduce(trial_range(completed_trials + 1, run_limit), state, fn trial, state ->
        state =
          run_trial(
            trial,
            state,
            optimizer,
            config,
            program,
            predictors,
            instruction_candidates,
            search_demos
          )

        emit_checkpoint(run_opts[:checkpoint_fn], compatibility, artifacts, state)
        state
      end)

    checkpoint = if durable?, do: Checkpoint.dump(compatibility, artifacts, state)
    run_status = if length(state.trials) == config.num_trials, do: :complete, else: :paused
    best = Enum.max_by(state.full_evaluations, & &1.score)

    Imp.Optimizer.Report.attach(
      best.program,
      Imp.Optimizer.Report.new(%{
        optimizer: :mipro_v2,
        best_score: best.score,
        candidate_count: length(state.trials),
        candidates: Enum.map(state.trials, &Map.drop(&1, [:program])),
        errors: state.errors,
        metadata: %{
          algorithm: :mipro_v2,
          sampler: sampler_metadata(config),
          upstream_sampler: :optuna_multivariate_tpe,
          exact_sampler_sequence_parity: exact_sampler_sequence_parity?(config),
          exact_sampler_sequence_scope: sampler_sequence_scope(config),
          optuna_release: optuna_release(config),
          upstream_release: upstream_release(config),
          upstream_commit: upstream_commit(config),
          seed: config.seed,
          effective_config: config_metadata(config),
          bootstrap: artifacts.bootstrap_metadata,
          proposals: artifacts.proposal_metadata,
          predictor_names: Enum.map(predictors, & &1.name),
          search_space: Map.new(artifacts.space, fn {key, choices} -> {key, length(choices)} end),
          search_policy: SearchPolicy.dump(state.policy),
          full_evaluations: Enum.map(state.full_evaluations, &Map.drop(&1, [:program])),
          evaluation_calls: state.evaluation_calls,
          evaluation_call_accounting: evaluation_call_accounting(state, config),
          resumed: resumed?,
          durable: durable?,
          metric_identity: metric_identity,
          run_status: run_status,
          completed_trials: length(state.trials),
          resume_state: checkpoint,
          status: if(state.errors == [], do: :ok, else: :with_errors)
        }
      })
    )
  end

  defp setup_run(optimizer, config, program, predictors, prompt_lm) do
    teacher = optimizer.teacher || program
    proposal_rng = PythonRandom.new(config.seed)

    {demo_candidates, bootstrap_metadata, proposal_rng} =
      if config.proposer_fidelity == :dspy_3_2_1 do
        UpstreamBootstrap.build!(
          program,
          teacher,
          config.trainset,
          optimizer.metric,
          proposal_rng,
          candidate_count: config.num_fewshot_candidates,
          max_bootstrapped_demos: config.max_bootstrapped_demos,
          max_labeled_demos: config.max_labeled_demos,
          metric_threshold: optimizer.metric_threshold,
          timeout: optimizer.timeout,
          max_errors: optimizer.max_errors
        )
      else
        {candidates, metadata} =
          DemoCandidates.build(program, config.trainset, optimizer.metric,
            runtime: :mipro_v2,
            candidate_count: config.num_fewshot_candidates,
            max_bootstrapped_demos: bootstrap_demo_limit(config),
            max_labeled_demos: config.max_labeled_demos,
            metric_threshold: optimizer.metric_threshold,
            teacher: teacher,
            seed: config.seed,
            max_concurrency: optimizer.max_concurrency,
            timeout: optimizer.timeout,
            max_errors: optimizer.max_errors
          )

        {candidates, metadata, proposal_rng}
      end

    dataset_summary =
      if config.proposer_fidelity == :dspy_3_2_1 do
        UpstreamProposer.summarize!(
          prompt_lm,
          config.trainset,
          config.view_data_batch_size
        )
      end

    {instruction_pairs, {proposal_metadata, proposal_rng}} =
      predictors
      |> Enum.with_index()
      |> Enum.map_reduce({%{}, proposal_rng}, fn {%{name: name, predictor: predictor},
                                                  predictor_index},
                                                 {metadata, proposal_rng} ->
        demo_sets = Map.fetch!(demo_candidates, name)

        {proposed, report, proposal_rng} =
          if config.proposer_fidelity == :dspy_3_2_1 do
            {proposed, report, proposal_rng} =
              UpstreamProposer.propose_with_report_and_rng!(
                prompt_lm,
                predictor,
                dataset_summary,
                proposal_rng,
                count: config.num_instruct_candidates,
                temperature: optimizer.init_temperature,
                seed: config.seed,
                demo_sets: demo_sets,
                fewshot_aware: config.fewshot_aware_proposer,
                program_aware: config.program_aware_proposer,
                program_code: explicit_program_text(config.program_grounding)
              )

            report =
              Map.merge(report, %{
                dataset_summary_calls:
                  if(predictor_index == 0, do: dataset_summary_call_count(config), else: 0)
              })

            {proposed, report, proposal_rng}
          else
            {proposed, report} =
              InstructionProposer.propose_with_report(predictor, config.trainset,
                lm: prompt_lm,
                count: config.num_instruct_candidates,
                demo_sets: demo_sets,
                preserve_slots: true,
                program_context: program,
                program_grounding: config.program_grounding,
                predictor_name: name,
                predictor_index: predictor_index,
                rollout_id_offset: predictor_index * config.num_instruct_candidates,
                program_aware: config.program_aware_proposer,
                data_aware: config.data_aware_proposer,
                tip_aware: config.tip_aware_proposer,
                fewshot_aware: config.fewshot_aware_proposer,
                view_data_batch_size: config.view_data_batch_size,
                temperature: optimizer.init_temperature,
                proposal_response_format: optimizer.proposal_response_format,
                seed: config.seed
              )

            {proposed, report, proposal_rng}
          end

        original = predictor.signature.instructions
        pair = {name, replace_first(proposed, original, config.num_instruct_candidates)}

        report =
          Map.merge(report, %{
            init_temperature: optimizer.init_temperature,
            proposal_response_format: optimizer.proposal_response_format
          })

        {pair, {Map.put(metadata, name, report), proposal_rng}}
      end)

    total_setup_calls =
      proposal_metadata
      |> Map.values()
      |> Enum.sum_by(&Map.get(&1, :calls, 0))
      |> Kernel.+(
        if(config.proposer_fidelity == :dspy_3_2_1,
          do: dataset_summary_call_count(config),
          else: 0
        )
      )

    proposal_metadata =
      Map.new(proposal_metadata, fn {name, report} ->
        {name, Map.put(report, :total_setup_calls, total_setup_calls)}
      end)

    instruction_candidates = Map.new(instruction_pairs)
    proposal_errors = proposal_errors(proposal_metadata)

    search_demos = if config.zeroshot, do: nil, else: demo_candidates
    space = categorical_space(predictors, instruction_candidates, search_demos)
    default_params = Map.new(space, fn {key, _choices} -> {key, 0} end)

    baseline =
      Imp.Telemetry.span(
        [:imp, :optimizer, :trial],
        %{optimizer: :mipro_v2, trial: 0, kind: :baseline},
        fn -> evaluate(program, config.valset, optimizer, config) end
      )

    policy =
      config
      |> search_policy(predictors, search_demos)
      |> then(fn {module, extra_opts} ->
        SearchPolicy.new(
          module,
          [space: space, seed: config.seed, startup_trials: optimizer.startup_trials] ++
            extra_opts
        )
      end)
      |> SearchPolicy.observe(%{params: default_params, score: baseline.score})

    state = %{
      policy: policy,
      rng: search_evaluation_rng(config, proposal_rng),
      trials: [],
      combo_scores: %{},
      full_evaluations: [full_record(0, default_params, baseline.score, program, :baseline)],
      next_study_number: 1,
      evaluation_calls: length(config.valset),
      errors: Map.get(bootstrap_metadata, :errors, []) ++ proposal_errors ++ baseline.errors
    }

    artifacts = %{
      instruction_candidates: instruction_candidates,
      search_demos: search_demos,
      bootstrap_metadata: bootstrap_metadata,
      proposal_metadata: proposal_metadata,
      space: space
    }

    {artifacts, state}
  end

  defp restore_programs(state, program, predictors, artifacts) do
    restore = fn record ->
      Map.put(
        record,
        :program,
        apply_params(
          program,
          predictors,
          record.params,
          artifacts.instruction_candidates,
          artifacts.search_demos
        )
      )
    end

    %{
      state
      | trials: Enum.map(state.trials, restore),
        full_evaluations: Enum.map(state.full_evaluations, restore)
    }
  end

  defp run_trial(
         trial,
         state,
         optimizer,
         config,
         program,
         predictors,
         instructions,
         demos
       ) do
    upstream_trial_num = state.next_study_number + 1
    {params, policy} = SearchPolicy.suggest(state.policy, :candidate)
    candidate = apply_params(program, predictors, params, instructions, demos)
    {examples, sampled_indices, rng} = trial_examples(config, state.rng)

    result =
      Imp.Telemetry.span(
        [:imp, :optimizer, :trial],
        %{
          optimizer: :mipro_v2,
          trial: trial,
          kind: if(config.minibatch, do: :minibatch, else: :full)
        },
        fn -> evaluate(candidate, examples, optimizer, config) end
      )

    policy = SearchPolicy.observe(policy, %{params: params, score: result.score})
    key = params_key(params)
    combo_scores = Map.update(state.combo_scores, key, [result.score], &[result.score | &1])

    record = %{
      trial: trial,
      upstream_trial_num: upstream_trial_num,
      kind: if(config.minibatch, do: :minibatch, else: :full),
      params: params,
      score: result.score,
      example_count: length(examples),
      sampled_indices: sampled_indices,
      evaluation_scope:
        if(length(examples) == length(config.valset), do: :full_validation, else: :minibatch),
      program: candidate
    }

    state = %{
      state
      | policy: policy,
        rng: rng,
        trials: state.trials ++ [record],
        next_study_number: state.next_study_number + 1,
        combo_scores: combo_scores,
        evaluation_calls: state.evaluation_calls + length(examples),
        errors: state.errors ++ result.errors
    }

    cond do
      not config.minibatch ->
        %{state | full_evaluations: state.full_evaluations ++ [Map.put(record, :kind, :full)]}

      upstream_full_evaluation_trial?(upstream_trial_num, config) ->
        promote_best_combo(state, upstream_trial_num, optimizer, config)

      true ->
        state
    end
  end

  defp promote_best_combo(state, upstream_trial_num, optimizer, config) do
    evaluated =
      state.full_evaluations
      |> Enum.reject(&(&1.kind == :baseline))
      |> Enum.map(&params_key(&1.params))
      |> MapSet.new()

    ranked = promotion_ranking(state.trials, config)

    candidate =
      Enum.find(ranked, fn {key, _records} -> not MapSet.member?(evaluated, key) end) ||
        List.last(ranked)

    case candidate do
      nil ->
        state

      {_key, records} ->
        representative = hd(records)

        result =
          Imp.Telemetry.span(
            [:imp, :optimizer, :trial],
            %{optimizer: :mipro_v2, trial: upstream_trial_num + 1, kind: :full_evaluation},
            fn -> evaluate(representative.program, config.valset, optimizer, config) end
          )

        policy =
          SearchPolicy.observe(state.policy, %{
            params: representative.params,
            score: result.score
          })

        full =
          full_record(
            upstream_trial_num + 1,
            representative.params,
            result.score,
            representative.program,
            :promoted_full
          )

        %{
          state
          | policy: policy,
            next_study_number: state.next_study_number + 1,
            full_evaluations: state.full_evaluations ++ [full],
            evaluation_calls: state.evaluation_calls + length(config.valset),
            errors: state.errors ++ result.errors
        }
    end
  end

  defp upstream_full_evaluation_trial?(upstream_trial_num, config) do
    upstream_full_evaluation_trial?(
      upstream_trial_num,
      adjusted_trial_count(config),
      config.minibatch_full_eval_steps
    )
  end

  defp upstream_full_evaluation_trial?(upstream_trial_num, adjusted, full_eval_steps),
    do: rem(upstream_trial_num, full_eval_steps + 1) == 0 or upstream_trial_num == adjusted - 1

  defp adjusted_trial_count(config) do
    adjusted_trial_count(config.num_trials, config.minibatch_full_eval_steps)
  end

  defp adjusted_trial_count(num_trials, full_eval_steps) do
    additional = if rem(num_trials, full_eval_steps) == 0, do: 0, else: 1
    num_trials + div(num_trials, full_eval_steps) + 1 + additional
  end

  defp evaluate(program, examples, optimizer, config) do
    evaluator =
      Imp.Evaluate.new(examples, optimizer.metric,
        max_concurrency: optimizer.max_concurrency,
        timeout: optimizer.timeout,
        max_errors: optimizer.max_errors
      )

    # Imp.Evaluate now halts loudly at errors >= max_errors (DSPy
    # parallelizer semantics); translate into MIPROv2's budget error so the
    # optimizer-facing contract stays the same.
    result =
      try do
        Imp.Evaluate.run(evaluator, program)
      rescue
        cancelled in Imp.EvaluationCancelledError ->
          if exact_search_fidelity?(config) do
            case operational_safety_error(cancelled.errors) do
              nil ->
                %Imp.Evaluate.Result{score: 0.0, rows: [], errors: cancelled.errors}

              %OperationalSafetyError{} = safety ->
                raise safety
            end
          else
            reraise RuntimeError,
                    "MIPROv2 error budget exhausted: #{length(cancelled.errors)} errors " <>
                      "(maximum #{optimizer.max_errors})",
                    __STACKTRACE__
          end
      end

    if exact_search_fidelity?(config) do
      case operational_safety_error(result.errors) do
        nil -> :ok
        %OperationalSafetyError{} = safety -> raise safety
      end
    else
      enforce_error_budget!(result.errors, optimizer.max_errors)
    end

    if exact_search_fidelity?(config) do
      # DSPy sums row scores, converts to a percentage, then applies Python's
      # half-even round(..., 2). Keep Imp's 0..1 scale after that exact step.
      scores = Enum.map(result.rows, & &1.score)
      score = if scores == [], do: 0.0, else: upstream_evaluation_score(scores)
      %{result | score: score}
    else
      result
    end
  end

  @doc false
  def upstream_evaluation_score([_ | _] = scores) do
    percentage = 100.0 * Enum.sum(scores) / length(scores)
    round_binary_half_even(percentage, 100) / 100 / 100
  end

  defp round_binary_half_even(value, decimal_scale) when is_float(value) do
    <<sign::1, exponent::11, fraction::52>> = <<value::float>>

    {mantissa, binary_exponent} =
      if exponent == 0,
        do: {fraction, -1074},
        else: {(1 <<< 52) + fraction, exponent - 1023 - 52}

    numerator = mantissa * decimal_scale

    rounded =
      if binary_exponent >= 0 do
        numerator <<< binary_exponent
      else
        denominator = 1 <<< -binary_exponent
        quotient = div(numerator, denominator)
        remainder = rem(numerator, denominator)

        case compare(remainder * 2, denominator) do
          :gt -> quotient + 1
          :lt -> quotient
          :eq -> if rem(quotient, 2) == 0, do: quotient, else: quotient + 1
        end
      end

    if sign == 0, do: rounded, else: -rounded
  end

  defp compare(left, right) when left < right, do: :lt
  defp compare(left, right) when left > right, do: :gt
  defp compare(_left, _right), do: :eq

  defp trial_examples(%{minibatch: false, valset: valset}, rng),
    do: {valset, indices(valset), rng}

  defp trial_examples(
         %{search_fidelity: fidelity, valset: valset, minibatch_size: size},
         %PythonRandom{} = rng
       )
       when fidelity in [
              :dspy_3_2_1_optuna_4_9_0_startup,
              :dspy_3_2_1_optuna_4_9_0
            ] do
    if size >= length(valset) do
      {valset, indices(valset), rng}
    else
      {sampled_indices, rng} = PythonRandom.sample(rng, indices(valset), size)
      {Enum.map(sampled_indices, &Enum.fetch!(valset, &1)), sampled_indices, rng}
    end
  end

  defp trial_examples(config, rng) do
    {shuffled, rng} =
      config.valset
      |> Enum.with_index()
      |> Sampling.shuffle(rng)

    selected = Enum.take(shuffled, config.minibatch_size)
    {Enum.map(selected, &elem(&1, 0)), Enum.map(selected, &elem(&1, 1)), rng}
  end

  defp search_space(predictors, instructions, demos) do
    Enum.reduce(predictors, %{}, fn %{name: name}, space ->
      space = Map.put(space, param_key(name, :instruction), indices(instructions[name]))

      if demos,
        do: Map.put(space, param_key(name, :demos), indices(demos[name])),
        else: space
    end)
  end

  defp apply_params(program, predictors, params, instructions, demos) do
    Enum.reduce(predictors, program, fn %{name: name}, program ->
      instruction = Enum.at(instructions[name], params[param_key(name, :instruction)])
      program = Imp.ProgramParameters.put_instruction(program, name, instruction)

      if demos do
        selected = Enum.at(demos[name], params[param_key(name, :demos)])
        Imp.ProgramParameters.put_demos(program, name, selected)
      else
        program
      end
    end)
  end

  defp param_key(name, kind) when is_atom(name), do: "atom:#{name}:#{kind}"
  defp param_key(name, kind) when is_binary(name), do: "string:#{name}:#{kind}"

  defp proposal_errors(metadata) do
    Enum.flat_map(metadata, fn {name, report} ->
      Enum.map(report.errors, &%{stage: :instruction_proposal, predictor: name, reason: &1})
    end)
  end

  defp replace_first([], original, count), do: List.duplicate(original, count)

  defp replace_first([_generated | rest], original, count),
    do: Enum.take([original | rest], count)

  defp explicit_program_text({:text, context}), do: context
  defp explicit_program_text(_grounding), do: nil

  defp params_key(params),
    do: params |> Enum.sort() |> :erlang.term_to_binary() |> Base.encode16()

  defp indices([]), do: []
  defp indices(values), do: Enum.to_list(0..(length(values) - 1))
  defp trial_indices(count) when count > 0, do: 1..count
  defp trial_indices(_count), do: []

  defp trial_range(first, last) when first <= last, do: first..last
  defp trial_range(_first, _last), do: []

  defp invocation_trial_limit(total, _completed, :infinity), do: total
  defp invocation_trial_limit(total, _completed, nil), do: total
  defp invocation_trial_limit(total, completed, maximum), do: min(total, completed + maximum)

  defp emit_checkpoint(nil, _compatibility, _artifacts, _state), do: :ok

  defp emit_checkpoint(callback, compatibility, artifacts, state) do
    callback.(Checkpoint.dump(compatibility, artifacts, state))
    :ok
  end

  defp resume_compatibility(program, predictors, config, optimizer, metric_identity) do
    payload = %{
      config: config_metadata(config),
      datasets: %{trainset: config.trainset, valset: config.valset},
      evaluation: %{
        metric: metric_identity,
        max_concurrency: optimizer.max_concurrency,
        max_errors: optimizer.max_errors,
        timeout: optimizer.timeout
      },
      search: %{
        fidelity: config.search_fidelity,
        startup_trials: optimizer.startup_trials
      },
      predictors:
        Enum.map(predictors, fn %{name: name, predictor: predictor} ->
          %{
            name: name,
            signature: predictor.signature,
            demos: predictor.demos,
            config: predictor.config,
            lm: DurableCallbackIdentity.runtime_identity(predictor.lm),
            adapter: DurableCallbackIdentity.runtime_identity(predictor.adapter),
            dynamic_lm?: predictor.dynamic_lm?,
            dynamic_adapter?: predictor.dynamic_adapter?
          }
        end),
      program_module: program.__struct__
    }

    digest =
      payload
      |> Report.encode_term()
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    %{
      "sha256" => digest,
      "search_evaluation_rng" =>
        if(exact_search_fidelity?(config) and config.minibatch,
          do: "python_random",
          else: "beam_sampling"
        )
    }
  end

  # Checkpoints reconstruct candidates over the caller-supplied runtime program.
  # Bind semantic runtime values while intentionally excluding live captures: a
  # fresh process may provide new credentials or process handles for the same
  # callback, but it may not silently change the model, adapter, or call policy
  # beneath observations already admitted to the search study.
  defp durable_controls?(run_opts) do
    not is_nil(run_opts[:resume_state]) or not is_nil(run_opts[:checkpoint_fn]) or
      run_opts[:max_trials] != :infinity
  end

  defp full_record(trial, params, score, program, kind),
    do: %{trial: trial, params: params, score: score, program: program, kind: kind}

  defp average([]), do: 0.0
  defp average(values), do: Enum.sum(values) / length(values)

  # Python preserves defaultdict insertion order and its sort is stable. Keep
  # the first occurrence as an explicit secondary key rather than relying on
  # BEAM map enumeration when minibatch means tie.
  defp promotion_ranking(trials, config) do
    {order, groups} =
      Enum.reduce(trials, {[], %{}}, fn record, {order, groups} ->
        key = params_key(record.params)

        if Map.has_key?(groups, key) do
          {order, Map.update!(groups, key, &(&1 ++ [record]))}
        else
          {order ++ [key], Map.put(groups, key, [record])}
        end
      end)

    order
    |> Enum.with_index()
    |> Enum.map(fn {key, first_seen} ->
      records = Map.fetch!(groups, key)
      {key, records, promotion_mean(records, config), first_seen}
    end)
    |> Enum.sort_by(fn {_key, _records, mean, first_seen} -> {-mean, first_seen} end)
    |> Enum.map(fn {key, records, _mean, _first_seen} -> {key, records} end)
  end

  defp promotion_mean(records, config) do
    if exact_search_fidelity?(config) do
      # Pinned DSPy scores are hundredths of a percentage point. Ranking their
      # integer basis points avoids a second runtime-specific float reduction.
      records
      |> Enum.map(&round(&1.score * 10_000))
      |> average()
    else
      average(Enum.map(records, & &1.score))
    end
  end

  defp search_evaluation_rng(config, proposal_rng) do
    if exact_search_fidelity?(config) and config.minibatch,
      do: proposal_rng,
      else: Sampling.new(config.seed)
  end

  defp evaluation_call_accounting(state, config) do
    baseline = length(config.valset)
    objectives = Enum.sum(Enum.map(state.trials, & &1.example_count))
    promotions = Enum.count(state.full_evaluations, &(&1.kind == :promoted_full))
    promoted_full = promotions * length(config.valset)

    %{
      unit: :requested_example_evaluations,
      baseline: baseline,
      objectives: objectives,
      promoted_full: promoted_full,
      total: state.evaluation_calls,
      provider_calls?: false,
      interrupted_attempts_included?: false
    }
  end

  defp bootstrap_demo_limit(%{zeroshot: true}), do: 3
  defp bootstrap_demo_limit(config), do: config.max_bootstrapped_demos

  defp dataset_summary_call_count(config) do
    min(10, ceil(length(config.trainset) / config.view_data_batch_size)) + 1
  end

  defp config_metadata(config) do
    config
    |> Map.from_struct()
    |> Map.drop([:trainset, :valset])
    |> Map.update!(:program_grounding, &program_grounding_identity/1)
    |> Map.put(:trainset_size, length(config.trainset))
    |> Map.put(:valset_size, length(config.valset))
  end

  defp program_grounding_identity(:structure), do: %{mode: :structure}
  defp program_grounding_identity(:module_source), do: %{mode: :module_source}

  defp program_grounding_identity({:text, context}) do
    %{
      mode: :text,
      bytes: byte_size(context),
      sha256: :crypto.hash(:sha256, context) |> Base.encode16(case: :lower)
    }
  end

  defp validate_search_fidelity!(optimizer, config) do
    if exact_search_fidelity?(config) do
      cond do
        optimizer.startup_trials != 10 ->
          raise ArgumentError,
                "pinned DSPy 3.2.1/Optuna 4.9.0 search requires startup_trials: 10"

        startup_only_search_fidelity?(config) and is_integer(config.num_trials) and
            config.num_trials > optimizer.startup_trials - 1 ->
          raise ArgumentError,
                "pinned DSPy 3.2.1/Optuna 4.9.0 startup fidelity supports at most " <>
                  "#{optimizer.startup_trials - 1} objective trials after the baseline; " <>
                  "modeled TPE is not implemented"

        config.seed > 0xFFFFFFFF ->
          raise ArgumentError,
                "pinned NumPy RandomState search seed must be at most 4294967295"

        true ->
          :ok
      end
    else
      :ok
    end
  end

  defp validate_optimizer!(optimizer, config) do
    _optimizer = validate_runtime!(optimizer)
    validate_search_fidelity!(optimizer, config)
  end

  defp search_policy(%{search_fidelity: :beam_native}, _predictors, _demos),
    do: {CategoricalPolicy, []}

  defp search_policy(
         %{search_fidelity: :dspy_3_2_1_optuna_4_9_0_startup},
         predictors,
         demos
       ) do
    parameter_order = pinned_parameter_order(predictors, demos)

    {OptunaStartupPolicy, [parameter_order: parameter_order]}
  end

  defp search_policy(%{search_fidelity: :dspy_3_2_1_optuna_4_9_0}, predictors, demos) do
    parameter_order = pinned_parameter_order(predictors, demos)

    {OptunaTPEPolicy, [parameter_order: parameter_order]}
  end

  defp pinned_parameter_order(predictors, demos) do
    Enum.flat_map(predictors, fn %{name: name} ->
      [param_key(name, :instruction)] ++ if(demos, do: [param_key(name, :demos)], else: [])
    end)
  end

  defp exact_search_fidelity?(%{search_fidelity: :dspy_3_2_1_optuna_4_9_0_startup}),
    do: true

  defp exact_search_fidelity?(%{search_fidelity: :dspy_3_2_1_optuna_4_9_0}), do: true

  defp exact_search_fidelity?(_config), do: false

  defp exact_sampler_sequence_parity?(config), do: startup_only_search_fidelity?(config)

  defp startup_only_search_fidelity?(%{
         search_fidelity: :dspy_3_2_1_optuna_4_9_0_startup
       }),
       do: true

  defp startup_only_search_fidelity?(_config), do: false

  defp sampler_metadata(config) do
    if exact_search_fidelity?(config),
      do:
        if(startup_only_search_fidelity?(config),
          do: :optuna_4_9_0_startup_random,
          else: :optuna_4_9_0_multivariate_categorical_tpe
        ),
      else: :joint_categorical_parzen
  end

  defp sampler_sequence_scope(config) do
    if exact_search_fidelity?(config),
      do:
        if(startup_only_search_fidelity?(config),
          do: :startup_only_before_modeled_tpe,
          else: :modeled_categorical_tpe_with_beam_float_tie_breaking
        ),
      else: :none
  end

  defp optuna_release(config), do: if(exact_search_fidelity?(config), do: "4.9.0")

  defp upstream_release(config),
    do: if(exact_search_fidelity?(config), do: "DSPy 3.2.1", else: "DSPy 3.3.0b1")

  defp upstream_commit(config),
    do:
      if(exact_search_fidelity?(config),
        do: "29448ae12756abdd14bd8796c819247ebb83673c",
        else: "b2829b7"
      )

  defp operational_safety_error(errors) do
    Enum.find_value(errors, fn error -> find_operational_safety(error) end)
  end

  defp find_operational_safety(%OperationalSafetyError{} = error), do: error

  defp find_operational_safety(%_{} = struct),
    do: struct |> Map.from_struct() |> find_operational_safety()

  defp find_operational_safety(map) when is_map(map) do
    Enum.find_value(map, fn {_key, value} -> find_operational_safety(value) end)
  end

  defp find_operational_safety(list) when is_list(list),
    do: Enum.find_value(list, &find_operational_safety/1)

  defp find_operational_safety(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.find_value(&find_operational_safety/1)

  defp find_operational_safety(_value), do: nil

  defp maybe_rebind_task_lm(program, _predictors, nil), do: program

  defp maybe_rebind_task_lm(program, predictors, task_lm) do
    Enum.reduce(predictors, program, fn %{name: name}, program ->
      Imp.ProgramParameters.update_predictor(program, name, fn predictor ->
        Imp.Predict.Predict.with_lm(predictor, task_lm)
      end)
    end)
  end

  defp normalize_options(opts) do
    unknown = Keyword.keys(opts) -- (Config.option_keys() ++ @runtime_keys)
    if unknown != [], do: raise(ArgumentError, "unknown MIPROv2 options: #{inspect(unknown)}")

    runtime = Keyword.take(opts, @runtime_keys)
    config = Keyword.take(opts, Config.option_keys())

    {config, runtime}
  end

  defp validate_compile_options!(opts) do
    resume_state = Keyword.get(opts, :resume_state)
    checkpoint_fn = Keyword.get(opts, :checkpoint_fn)
    max_trials = Keyword.get(opts, :max_trials, :infinity)

    unless is_nil(resume_state) or is_map(resume_state),
      do: raise(ArgumentError, ":resume_state must be a checkpoint map or nil")

    unless is_nil(checkpoint_fn) or is_function(checkpoint_fn, 1),
      do: raise(ArgumentError, ":checkpoint_fn must be an arity-one function or nil")

    unless max_trials == :infinity or (is_integer(max_trials) and max_trials >= 0),
      do: raise(ArgumentError, ":max_trials must be :infinity or a non-negative integer")

    [resume_state: resume_state, checkpoint_fn: checkpoint_fn, max_trials: max_trials]
  end

  defp validate_runtime!(optimizer) do
    :ok = DurableCallbackIdentity.validate_normalized!(optimizer.metric_identity, "MIPROv2")

    unless is_number(optimizer.init_temperature) and optimizer.init_temperature >= 0,
      do: raise(ArgumentError, "init_temperature must be a non-negative number")

    unless optimizer.proposal_response_format in [:off, :auto, :required],
      do:
        raise(
          ArgumentError,
          "proposal_response_format must be :off, :auto, or :required"
        )

    if optimizer.config.proposer_fidelity == :dspy_3_2_1 and
         optimizer.proposal_response_format != :off do
      raise ArgumentError,
            ":dspy_3_2_1 proposer fidelity requires proposal_response_format: :off"
    end

    unless is_integer(optimizer.max_concurrency) and optimizer.max_concurrency > 0,
      do: raise(ArgumentError, "max_concurrency must be a positive integer")

    unless optimizer.timeout == :infinity or
             (is_integer(optimizer.timeout) and optimizer.timeout > 0),
           do: raise(ArgumentError, "timeout must be :infinity or a positive integer")

    unless is_integer(optimizer.startup_trials) and optimizer.startup_trials >= 0,
      do: raise(ArgumentError, "startup_trials must be a non-negative integer")

    unless optimizer.max_errors == :infinity or
             (is_integer(optimizer.max_errors) and optimizer.max_errors >= 0),
           do: raise(ArgumentError, "max_errors must be :infinity or a non-negative integer")

    optimizer
  end

  defp enforce_error_budget!(_errors, :infinity), do: :ok
  defp enforce_error_budget!([], _maximum), do: :ok
  defp enforce_error_budget!(errors, maximum) when length(errors) < maximum, do: :ok

  defp enforce_error_budget!(errors, maximum) do
    raise RuntimeError,
          "MIPROv2 error budget exhausted: #{length(errors)} errors (maximum #{maximum})"
  end
end
