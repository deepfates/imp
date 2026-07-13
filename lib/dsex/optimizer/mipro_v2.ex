defmodule DSEx.Optimizer.MIPROv2 do
  @moduledoc """
  Joint instruction and few-shot optimization using grounded proposals and categorical TPE.

  The implementation follows DSPy MIPROv2's three stages: metric-filtered
  demonstration bootstrapping, predictor-specific grounded instruction
  proposal, and seeded multivariate Bayesian search. Minibatch trials inform
  the surrogate, but only full validation evaluations can select the returned
  program.
  """

  alias DSEx.Optimizer.{CategoricalTPE, DemoCandidates, InstructionProposer, Sampling}
  alias DSEx.Optimizer.MIPROv2.Config

  defstruct [
    :metric,
    :config,
    :prompt_lm,
    :task_lm,
    :teacher,
    :metric_threshold,
    max_errors: :infinity,
    max_concurrency: 1,
    timeout: 5_000,
    startup_trials: 10,
    compatibility: []
  ]

  @runtime_keys [
    :prompt_lm,
    :task_lm,
    :teacher,
    :metric_threshold,
    :max_errors,
    :max_concurrency,
    :timeout,
    :startup_trials
  ]
  @legacy_keys [:trials, :demos_per_candidate, :cold_start]

  def new(metric, opts \\ []) do
    DSEx.FunctionContract.validate!(metric, [2, 3], "DSEx.Optimizer.MIPROv2.new/2", "metric")

    unless Keyword.keyword?(opts),
      do: raise(ArgumentError, "DSEx.Optimizer.MIPROv2.new/2: expected keyword options")

    {config_opts, runtime_opts, compatibility} = normalize_options(opts)

    %__MODULE__{
      metric: metric,
      config: Config.new(config_opts),
      prompt_lm: runtime_opts[:prompt_lm],
      task_lm: runtime_opts[:task_lm],
      teacher: runtime_opts[:teacher],
      metric_threshold: runtime_opts[:metric_threshold],
      max_errors: Keyword.get(runtime_opts, :max_errors, :infinity),
      max_concurrency: Keyword.get(runtime_opts, :max_concurrency, 1),
      timeout: Keyword.get(runtime_opts, :timeout, 5_000),
      startup_trials: Keyword.get(runtime_opts, :startup_trials, 10),
      compatibility: compatibility
    }
    |> validate_runtime!()
  end

  def compile(%__MODULE__{} = optimizer, program, trainset, valset) do
    compile(optimizer, program, trainset: trainset, valset: valset)
  end

  def compile(%__MODULE__{} = optimizer, program, opts) when is_list(opts) do
    unless Keyword.keyword?(opts),
      do: raise(ArgumentError, "DSEx.Optimizer.MIPROv2.compile/3 expects keyword options")

    trainset = Keyword.fetch!(opts, :trainset)
    valset = Keyword.get(opts, :valset)
    compile_overrides = Keyword.drop(opts, [:trainset, :valset])
    predictors = DSEx.ProgramParameters.predictors(program)

    if predictors == [] do
      raise ArgumentError, "MIPROv2 requires a program with at least one optimizer predictor"
    end

    config =
      Config.resolve(optimizer.config, length(predictors), trainset, valset, compile_overrides)

    run(optimizer, config, program, predictors)
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

  defp run(optimizer, config, program, predictors) do
    prompt_lm =
      optimizer.prompt_lm || predictors |> hd() |> Map.fetch!(:predictor) |> Map.get(:lm)

    program = maybe_rebind_task_lm(program, predictors, optimizer.task_lm)
    predictors = DSEx.ProgramParameters.predictors(program)

    if is_nil(prompt_lm) do
      raise ArgumentError,
            "MIPROv2 requires :prompt_lm or a concrete LM on the program's first predictor"
    end

    teacher = optimizer.teacher || program

    {demo_candidates, bootstrap_metadata} =
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

    {instruction_pairs, proposal_metadata} =
      Enum.map_reduce(predictors, %{}, fn %{name: name, predictor: predictor}, metadata ->
        demo_sets = Map.fetch!(demo_candidates, name)

        {proposed, report} =
          InstructionProposer.propose_with_report(predictor, config.trainset,
            lm: prompt_lm,
            count: config.num_instruct_candidates,
            demo_sets: demo_sets,
            preserve_slots: true,
            program_context: program,
            predictor_name: name,
            program_aware: config.program_aware_proposer,
            data_aware: config.data_aware_proposer,
            tip_aware: config.tip_aware_proposer,
            fewshot_aware: config.fewshot_aware_proposer,
            view_data_batch_size: config.view_data_batch_size,
            seed: config.seed
          )

        original = predictor.signature.instructions
        pair = {name, replace_first(proposed, original, config.num_instruct_candidates)}
        {pair, Map.put(metadata, name, report)}
      end)

    instruction_candidates = Map.new(instruction_pairs)
    proposal_errors = proposal_errors(proposal_metadata)

    search_demos = if config.zeroshot, do: nil, else: demo_candidates
    space = categorical_space(predictors, instruction_candidates, search_demos)
    default_params = Map.new(space, fn {key, _choices} -> {key, 0} end)
    baseline = evaluate(program, config.valset, optimizer)

    tpe =
      space
      |> CategoricalTPE.new(seed: config.seed, startup_trials: optimizer.startup_trials)
      |> CategoricalTPE.observe(default_params, baseline.score)

    state = %{
      tpe: tpe,
      rng: Sampling.new(config.seed),
      trials: [],
      combo_scores: %{},
      full_evaluations: [full_record(0, default_params, baseline.score, program, :baseline)],
      next_study_number: 1,
      evaluation_calls: length(config.valset),
      errors: Map.get(bootstrap_metadata, :errors, []) ++ proposal_errors ++ baseline.errors
    }

    state =
      Enum.reduce(trial_indices(config.num_trials), state, fn trial, state ->
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
      end)

    best = Enum.max_by(state.full_evaluations, & &1.score)

    DSEx.Optimizer.Report.attach(
      best.program,
      DSEx.Optimizer.Report.new(%{
        optimizer: :mipro_v2,
        best_score: best.score,
        candidate_count: length(state.trials),
        candidates: Enum.map(state.trials, &Map.drop(&1, [:program])),
        errors: state.errors,
        metadata: %{
          algorithm: :mipro_v2,
          sampler: :joint_categorical_parzen,
          upstream_sampler: :optuna_multivariate_tpe,
          exact_sampler_sequence_parity: false,
          upstream_release: "DSPy 3.3.0b1",
          upstream_commit: "b2829b7",
          seed: config.seed,
          effective_config: config_metadata(config),
          bootstrap: bootstrap_metadata,
          proposals: proposal_metadata,
          predictor_names: Enum.map(predictors, & &1.name),
          search_space: Map.new(space, fn {key, choices} -> {key, length(choices)} end),
          full_evaluations: Enum.map(state.full_evaluations, &Map.drop(&1, [:program])),
          evaluation_calls: state.evaluation_calls,
          compatibility: optimizer.compatibility,
          status: if(state.errors == [], do: :ok, else: :with_errors)
        }
      })
    )
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
    {params, tpe} = CategoricalTPE.suggest(state.tpe)
    candidate = apply_params(program, predictors, params, instructions, demos)
    {examples, rng} = trial_examples(config, state.rng)
    result = evaluate(candidate, examples, optimizer)
    tpe = CategoricalTPE.observe(tpe, params, result.score)
    key = params_key(params)
    combo_scores = Map.update(state.combo_scores, key, [result.score], &[result.score | &1])

    record = %{
      trial: trial,
      upstream_trial_num: upstream_trial_num,
      kind: if(config.minibatch, do: :minibatch, else: :full),
      params: params,
      score: result.score,
      example_count: length(examples),
      program: candidate
    }

    state = %{
      state
      | tpe: tpe,
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

    ranked =
      state.trials
      |> Enum.group_by(&params_key(&1.params))
      |> Enum.sort_by(fn {_key, records} -> average(Enum.map(records, & &1.score)) end, :desc)

    candidate =
      Enum.find(ranked, fn {key, _records} -> not MapSet.member?(evaluated, key) end) ||
        List.last(ranked)

    case candidate do
      nil ->
        state

      {_key, records} ->
        representative = hd(records)
        result = evaluate(representative.program, config.valset, optimizer)
        tpe = CategoricalTPE.observe(state.tpe, representative.params, result.score)

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
          | tpe: tpe,
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

  defp evaluate(program, examples, optimizer) do
    evaluator =
      DSEx.Evaluate.new(examples, optimizer.metric,
        max_concurrency: optimizer.max_concurrency,
        timeout: optimizer.timeout,
        max_errors: evaluator_error_limit(optimizer.max_errors)
      )

    result = DSEx.Evaluate.run(evaluator, program)
    enforce_error_budget!(result.errors, optimizer.max_errors)
    result
  end

  defp trial_examples(%{minibatch: false, valset: valset}, rng), do: {valset, rng}

  defp trial_examples(config, rng) do
    {shuffled, rng} = Sampling.shuffle(config.valset, rng)
    {Enum.take(shuffled, config.minibatch_size), rng}
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
      program = DSEx.ProgramParameters.put_instruction(program, name, instruction)

      if demos do
        selected = Enum.at(demos[name], params[param_key(name, :demos)])
        DSEx.ProgramParameters.put_demos(program, name, selected)
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

  defp params_key(params),
    do: params |> Enum.sort() |> :erlang.term_to_binary() |> Base.encode16()

  defp indices(values), do: Enum.to_list(0..(length(values) - 1))
  defp trial_indices(count) when count > 0, do: 1..count
  defp trial_indices(_count), do: []

  defp full_record(trial, params, score, program, kind),
    do: %{trial: trial, params: params, score: score, program: program, kind: kind}

  defp average([]), do: 0.0
  defp average(values), do: Enum.sum(values) / length(values)

  defp bootstrap_demo_limit(%{zeroshot: true}), do: 3
  defp bootstrap_demo_limit(config), do: config.max_bootstrapped_demos

  defp config_metadata(config) do
    config
    |> Map.from_struct()
    |> Map.drop([:trainset, :valset])
    |> Map.put(:trainset_size, length(config.trainset))
    |> Map.put(:valset_size, length(config.valset))
  end

  defp maybe_rebind_task_lm(program, _predictors, nil), do: program

  defp maybe_rebind_task_lm(program, predictors, task_lm) do
    Enum.reduce(predictors, program, fn %{name: name}, program ->
      DSEx.ProgramParameters.update_predictor(program, name, fn predictor ->
        DSEx.Predict.Predict.with_lm(predictor, task_lm)
      end)
    end)
  end

  defp normalize_options(opts) do
    unknown = Keyword.keys(opts) -- (Config.option_keys() ++ @runtime_keys ++ @legacy_keys)
    if unknown != [], do: raise(ArgumentError, "unknown MIPROv2 options: #{inspect(unknown)}")

    legacy = Keyword.take(opts, @legacy_keys)
    runtime = Keyword.take(opts, @runtime_keys)
    config = Keyword.take(opts, Config.option_keys())

    config =
      if legacy == [] do
        config
      else
        trials = Keyword.get(legacy, :trials, 12)

        config
        |> Keyword.put(:auto, nil)
        |> Keyword.put_new(:num_candidates, max(1, trials))
        |> Keyword.put_new(:num_trials, trials)
        |> Keyword.put_new(:minibatch, false)
        |> Keyword.put_new(:max_bootstrapped_demos, 0)
        |> Keyword.put_new(:max_labeled_demos, Keyword.get(legacy, :demos_per_candidate, 4))
      end

    runtime = Keyword.put_new(runtime, :startup_trials, Keyword.get(legacy, :cold_start, 10))
    {config, runtime, Enum.map(Keyword.keys(legacy), &{:deprecated_option, &1})}
  end

  defp validate_runtime!(optimizer) do
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

  defp evaluator_error_limit(:infinity), do: :infinity
  defp evaluator_error_limit(maximum), do: max(maximum - 1, 0)
end
