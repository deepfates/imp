defmodule Imp.Optimizer.SIMBA do
  @behaviour Imp.Optimizer
  @moduledoc """
  Stochastic Introspective Mini-Batch Ascent over arbitrary Imp programs.

  SIMBA repeatedly samples program trajectories, prioritizes examples whose
  outputs vary most, and creates candidates by appending successful trace demos
  or predictor-specific reflective rules. It maintains an exploratory program
  population and performs final selection on the full validation dataset.
  """

  alias Imp.Optimizer.{Report, Sampling, SearchPolicy, TrajectoryRunner}
  alias Imp.Optimizer.SIMBA.{Buckets, Checkpoint, Population}

  defstruct [
    :metric,
    :prompt_lm,
    :teacher_lm,
    bsize: 32,
    num_candidates: 6,
    max_steps: 8,
    max_demos: 4,
    demo_input_field_maxlen: 100_000,
    max_concurrency: 1,
    timeout: :infinity,
    sampling_temperature: 0.2,
    candidate_temperature: 0.2,
    seed: 0
  ]

  @option_keys [
    :bsize,
    :num_candidates,
    :max_steps,
    :max_demos,
    :prompt_lm,
    :teacher_lm,
    :demo_input_field_maxlen,
    :max_concurrency,
    :timeout,
    :sampling_temperature,
    :candidate_temperature,
    :seed
  ]
  @compile_runtime_keys [:resume_state, :checkpoint_fn, :max_steps]

  def new(metric, opts \\ []) do
    Imp.FunctionContract.validate!(metric, [2, 3], "Imp.Optimizer.SIMBA.new/2", "metric")

    unless Keyword.keyword?(opts),
      do: raise(ArgumentError, "Imp.Optimizer.SIMBA.new/2: expected keyword options")

    unknown = Keyword.keys(opts) -- @option_keys
    if unknown != [], do: raise(ArgumentError, "unknown SIMBA options: #{inspect(unknown)}")

    %__MODULE__{
      metric: metric,
      bsize: Keyword.get(opts, :bsize, 32),
      num_candidates: Keyword.get(opts, :num_candidates, 6),
      max_steps: Keyword.get(opts, :max_steps, 8),
      max_demos: Keyword.get(opts, :max_demos, 4),
      prompt_lm: opts[:prompt_lm],
      teacher_lm: opts[:teacher_lm],
      demo_input_field_maxlen: Keyword.get(opts, :demo_input_field_maxlen, 100_000),
      max_concurrency: Keyword.get(opts, :max_concurrency, 1),
      timeout: Keyword.get(opts, :timeout, :infinity),
      sampling_temperature: Keyword.get(opts, :sampling_temperature, 0.2),
      candidate_temperature: Keyword.get(opts, :candidate_temperature, 0.2),
      seed: Keyword.get(opts, :seed, 0)
    }
    |> validate!()
  end

  @impl true
  def __optimizer__,
    do: %{
      kind: :program,
      datasets: %{trainset: :required, validation: :optional},
      result: :program
    }

  @impl true
  def run(%__MODULE__{} = optimizer, program, opts) do
    trainset = Imp.Optimizer.fetch_dataset!(opts, :trainset)
    invocation_opts = Imp.Optimizer.invocation_options(opts)

    compiled =
      if Keyword.has_key?(opts, :validation) do
        compile(optimizer, program, trainset, Keyword.fetch!(opts, :validation), invocation_opts)
      else
        compile(optimizer, program, trainset, invocation_opts)
      end

    {:ok, compiled}
  end

  def compile(%__MODULE__{} = optimizer, program, trainset) do
    compile_run(optimizer, program, trainset, nil, [])
  end

  def compile(%__MODULE__{} = optimizer, program, trainset, final_set_or_opts) do
    if Keyword.keyword?(final_set_or_opts) do
      compile_run(optimizer, program, trainset, nil, final_set_or_opts)
    else
      compile_run(optimizer, program, trainset, final_set_or_opts, [])
    end
  end

  @doc """
  Compiles with invocation-level durable checkpoint and resume controls.

  `:max_steps` limits new completed search steps in this invocation.
  `:checkpoint_fn` receives a JSON-safe checkpoint before work, after every
  completed step, and after every completed final evaluation. Pass any emitted
  checkpoint back through `:resume_state`. Step and final-evaluation boundaries
  are atomic; interrupted in-flight work is retried.
  """
  def compile(%__MODULE__{} = optimizer, program, trainset, final_set, opts) do
    compile_run(optimizer, program, trainset, final_set, opts)
  end

  @doc false
  def finalist_indices(max_winning_index, num_candidates)
      when is_integer(max_winning_index) and max_winning_index >= 0 and
             is_integer(num_candidates) and num_candidates >= 0 do
    count = num_candidates + 1

    indices =
      if max_winning_index < 1 or count == 1 do
        List.duplicate(0, count)
      else
        Enum.map(0..(count - 1), &round_half_even(&1 * max_winning_index / (count - 1)))
      end

    Enum.uniq(indices)
  end

  @doc false
  def rollout_id_plan(start_rollout_id, num_candidates, teacher?)
      when is_integer(start_rollout_id) and is_integer(num_candidates) and num_candidates > 0 and
             is_boolean(teacher?) do
    Enum.map(0..(num_candidates - 1), fn offset ->
      %{
        rollout_id: start_rollout_id + offset,
        teacher?: teacher? and offset == 0,
        force_temperature?: not (teacher? and offset == 0)
      }
    end)
  end

  @doc false
  def rule_disposition(
        good_score,
        bad_score,
        batch_10th_percentile_score,
        batch_90th_percentile_score
      )
      when is_number(good_score) and is_number(bad_score) and
             is_number(batch_10th_percentile_score) and
             is_number(batch_90th_percentile_score) do
    cond do
      good_score <= batch_10th_percentile_score or bad_score >= batch_90th_percentile_score ->
        :skip

      good_score > bad_score ->
        :normal

      good_score > batch_90th_percentile_score ->
        :suppress_bad

      true ->
        :suppress_good
    end
  end

  @doc false
  def eviction_parameters(demo_count, max_demos)
      when is_integer(demo_count) and demo_count >= 0 and is_integer(max_demos) do
    denominator = if max_demos > 0, do: max_demos, else: 3

    %{
      demo_count: demo_count,
      poisson_mean: demo_count / denominator,
      poisson_denominator: denominator,
      minimum_drop_count: if(demo_count >= denominator, do: 1, else: 0),
      sample_with_replacement?: true,
      shared_indices_across_predictors?: true
    }
  end

  defp compile_run(optimizer, program, trainset, final_set, opts) do
    run_opts = validate_compile_options!(opts)
    trainset = materialize!(trainset, "trainset")
    final_set = if is_nil(final_set), do: trainset, else: materialize!(final_set, "final_set")

    if length(trainset) < optimizer.bsize do
      raise ArgumentError,
            "SIMBA trainset too small: #{length(trainset)} < bsize #{optimizer.bsize}"
    end

    predictors = Imp.ProgramParameters.predictors(program)

    if predictors == [],
      do: raise(ArgumentError, "SIMBA requires at least one optimizer predictor")

    if final_set == [], do: raise(ArgumentError, "SIMBA final_set must not be empty")

    prompt_lm =
      optimizer.prompt_lm || predictors |> hd() |> Map.fetch!(:predictor) |> Map.get(:lm)

    if is_nil(prompt_lm),
      do: raise(ArgumentError, "SIMBA requires :prompt_lm or a concrete program LM")

    compatibility = resume_compatibility(program, predictors, trainset, final_set, optimizer)

    {state, resumed?} =
      case run_opts[:resume_state] do
        nil ->
          {order, rng} =
            Sampling.shuffle(
              Enum.to_list(0..(length(trainset) - 1)),
              Sampling.new(optimizer.seed)
            )

          state = %{
            completed_steps: 0,
            population: Population.new(program, rng: rng),
            winning_programs: [program],
            trial_logs: [],
            order: order,
            cursor: 0,
            poisson_rng: Sampling.new(optimizer.seed + 1_000_003),
            errors: [],
            trajectory_calls: 0,
            candidate_evaluation_calls: 0,
            final_evaluation_calls: 0,
            final_evaluations: []
          }

          emit_checkpoint(run_opts[:checkpoint_fn], compatibility, state)
          {state, false}

        checkpoint ->
          state = Checkpoint.load!(checkpoint, compatibility, program)
          validate_resumed_state!(state, optimizer, trainset)
          {state, true}
      end

    run_limit =
      invocation_step_limit(optimizer.max_steps, state.completed_steps, run_opts[:max_steps])

    state =
      Enum.reduce(step_range(state.completed_steps + 1, run_limit), state, fn step, state ->
        state = run_step(step, state, optimizer, trainset, prompt_lm)
        emit_checkpoint(run_opts[:checkpoint_fn], compatibility, state)
        state
      end)

    state =
      if state.completed_steps == optimizer.max_steps do
        complete_final_evaluations(
          state,
          optimizer,
          final_set,
          compatibility,
          run_opts[:checkpoint_fn]
        )
      else
        state
      end

    checkpoint = Checkpoint.dump(compatibility, state)
    complete? = state.completed_steps == optimizer.max_steps
    scored_finalists = state.final_evaluations
    best = if complete?, do: Enum.max_by(scored_finalists, & &1.score), else: nil
    attached_program = if best, do: best.program, else: List.last(state.winning_programs)

    final_candidates =
      scored_finalists
      |> Enum.sort_by(& &1.score, :desc)
      |> Enum.map(&Map.drop(&1, [:program]))

    Report.attach(
      attached_program,
      Report.new(%{
        optimizer: :simba,
        best_score: if(best, do: best.score, else: nil),
        candidate_count: state.population.next_id - 1,
        candidates:
          state.population.program_ids
          |> Enum.reject(&(&1 == Population.baseline_id()))
          |> Enum.map(fn id ->
            %{
              id: id,
              scores: Population.scores(state.population, id),
              average_score: Population.average_score(state.population, id)
            }
          end),
        errors: state.errors,
        metadata: %{
          algorithm: :stochastic_introspective_minibatch_ascent,
          upstream_release: "DSPy 3.3.0b1",
          upstream_commit: "b2829b7",
          seed: optimizer.seed,
          trial_logs: state.trial_logs,
          final_candidates: final_candidates,
          baseline_score: if(scored_finalists == [], do: nil, else: hd(scored_finalists).score),
          population_size: length(state.population.program_ids),
          trajectory_calls: state.trajectory_calls,
          candidate_evaluation_calls: state.candidate_evaluation_calls,
          final_evaluation_calls: state.final_evaluation_calls,
          search_policy: SearchPolicy.dump(state.population.policy),
          resumed: resumed?,
          run_status: if(complete?, do: :complete, else: :paused),
          completed_steps: state.completed_steps,
          resume_state: checkpoint,
          budgets: %{
            max_steps: optimizer.max_steps,
            completed_steps: state.completed_steps,
            remaining_steps: optimizer.max_steps - state.completed_steps,
            trajectory_calls: state.trajectory_calls,
            candidate_evaluation_calls: state.candidate_evaluation_calls,
            final_evaluation_calls: state.final_evaluation_calls
          },
          status: if(state.errors == [], do: :ok, else: :with_errors)
        }
      })
    )
  end

  defp run_step(step, state, optimizer, trainset, prompt_lm) do
    {batch, state} = next_batch(state, trainset, optimizer.bsize)

    {sampled, population, sampling_errors} =
      sample_trajectories(state.population, batch, optimizer)

    {p10, p90} = Buckets.batch_percentiles(sampled)

    analysis = %{
      buckets: Buckets.rank(sampled, length(batch)),
      batch_10th_percentile_score: p10,
      batch_90th_percentile_score: p90
    }

    state = %{
      state
      | population: population,
        trajectory_calls: state.trajectory_calls + length(sampled),
        errors: state.errors ++ sampling_errors
    }

    {candidates, state} =
      build_candidates(analysis, state, optimizer, prompt_lm, optimizer.num_candidates + 1)

    {evaluated, state} = evaluate_candidates(candidates, batch, state, optimizer)

    winning_programs =
      case evaluated do
        [] ->
          state.winning_programs

        _ ->
          state.winning_programs ++
            [evaluated |> Enum.max_by(& &1.average_score) |> Map.fetch!(:program)]
      end

    log = %{
      step: step,
      batch_indices: Enum.map(batch, &elem(&1, 0)),
      baseline_score: average_score(sampled),
      bucket_ranks: Enum.map(analysis.buckets, & &1.rank),
      candidate_ids: Enum.map(evaluated, & &1.id),
      candidate_scores: Enum.map(evaluated, & &1.average_score)
    }

    %{
      state
      | completed_steps: step,
        winning_programs: winning_programs,
        trial_logs: state.trial_logs ++ [log]
    }
  end

  defp sample_trajectories(population, batch, optimizer) do
    rollout_models =
      population
      |> Population.fetch_program!(Population.baseline_id())
      |> prepare_rollout_models(optimizer)

    {jobs, population} =
      Enum.reduce(rollout_models, {[], population}, fn rollout, {jobs, population} ->
        Enum.reduce(batch, {jobs, population}, fn {_index, example}, {jobs, population} ->
          {source_id, population} =
            Population.select_source(
              population,
              optimizer.num_candidates,
              optimizer.sampling_temperature
            )

          source =
            population
            |> Population.fetch_program!(source_id)
            |> bind_rollout(rollout)

          job = %{
            program: source,
            example: example,
            source_id: source_id,
            rollout_id: rollout.rollout_id
          }

          {jobs ++ [job], population}
        end)
      end)

    rows =
      jobs
      |> Imp.Tasks.async_stream(
        fn job ->
          [trajectory] =
            TrajectoryRunner.run(job.program, [job.example], optimizer.metric,
              max_concurrency: 1,
              timeout: optimizer.timeout,
              runtime: :simba,
              program_id: job.source_id,
              rollout_id: job.rollout_id
            )

          trajectory
        end,
        ordered: true,
        max_concurrency: optimizer.max_concurrency,
        timeout: optimizer.timeout,
        on_timeout: :kill_task
      )
      |> Enum.map(fn
        {:ok, trajectory} ->
          trajectory

        {:exit, reason} ->
          %Imp.Optimizer.Trajectory{
            index: -1,
            example: nil,
            score: 0.0,
            trace: [],
            error: {:sampling_task_exit, reason}
          }
      end)

    {rows, population, trajectory_errors(rows, :trajectory_sampling)}
  end

  defp build_candidates(analysis, state, optimizer, prompt_lm, limit) do
    Enum.reduce_while(analysis.buckets, {[], state}, fn bucket, {candidates, state} ->
      if length(candidates) >= limit do
        {:halt, {candidates, state}}
      else
        {source_id, population} =
          Population.select_source(
            state.population,
            optimizer.num_candidates,
            optimizer.candidate_temperature
          )

        source = Population.fetch_program!(population, source_id)

        {source, policy, poisson_rng} =
          evict_demos(source, optimizer.max_demos, population.policy, state.poisson_rng)

        population = %{population | policy: policy}

        strategies =
          if optimizer.max_demos > 0, do: [:append_demo, :append_rule], else: [:append_rule]

        {strategy, policy} = SearchPolicy.suggest(population.policy, {:choose, strategies})
        population = %{population | policy: policy}

        case apply_strategy(strategy, source, bucket, analysis, optimizer, prompt_lm) do
          {:ok, candidate} ->
            {:cont,
             {candidates ++ [%{program: candidate, source_id: source_id, strategy: strategy}],
              %{state | population: population, poisson_rng: poisson_rng}}}

          {:error, reason} ->
            error = %{stage: :strategy, strategy: strategy, reason: reason}

            {:cont,
             {candidates,
              %{
                state
                | population: population,
                  poisson_rng: poisson_rng,
                  errors: state.errors ++ [error]
              }}}

          {:skip, _reason} ->
            skipped = %{program: source, source_id: source_id, strategy: {:skipped, strategy}}

            {:cont,
             {candidates ++ [skipped],
              %{state | population: population, poisson_rng: poisson_rng}}}
        end
      end
    end)
  end

  defp evaluate_candidates(candidates, batch, state, optimizer) do
    examples = Enum.map(batch, &elem(&1, 1))

    Enum.map_reduce(candidates, state, fn candidate, state ->
      trajectories =
        TrajectoryRunner.run(candidate.program, examples, optimizer.metric,
          max_concurrency: optimizer.max_concurrency,
          timeout: optimizer.timeout,
          runtime: :simba
        )

      scores = Enum.map(trajectories, & &1.score)
      {id, population} = Population.register_with_id(state.population, candidate.program, scores)
      errors = trajectory_errors(trajectories, :candidate_evaluation)

      {Map.merge(candidate, %{id: id, scores: scores, average_score: average_score(trajectories)}),
       %{
         state
         | population: population,
           candidate_evaluation_calls: state.candidate_evaluation_calls + length(examples),
           errors: state.errors ++ errors
       }}
    end)
  end

  defp apply_strategy(:append_demo, program, bucket, analysis, optimizer, _prompt_lm) do
    best = hd(bucket.trajectories)

    if best.score <= analysis.batch_10th_percentile_score do
      {:skip, :best_score_at_or_below_tenth_percentile}
    else
      demos = trajectory_demos(best, optimizer.demo_input_field_maxlen)

      predictors = Imp.ProgramParameters.predictors(program)

      program =
        Enum.reduce(predictors, program, fn %{
                                              name: name,
                                              predictor: predictor
                                            },
                                            program ->
          fallback = if length(predictors) == 1, do: Map.get(demos, :main), else: nil

          case Map.get(demos, name) || fallback do
            nil -> program
            demo -> Imp.ProgramParameters.put_demos(program, name, predictor.demos ++ [demo])
          end
        end)

      {:ok, program}
    end
  end

  defp apply_strategy(:append_rule, program, bucket, analysis, _optimizer, prompt_lm) do
    good = hd(bucket.trajectories)
    bad = List.last(bucket.trajectories)

    disposition =
      rule_disposition(
        good.score,
        bad.score,
        analysis.batch_10th_percentile_score,
        analysis.batch_90th_percentile_score
      )

    case disposition do
      :skip ->
        {:skip, :insufficient_reward_contrast}

      disposition ->
        {good, bad} = suppress_trajectory(good, bad, disposition)
        payload = reflection_payload(program, good, bad)

        case Imp.Optimizer.SIMBA.Reflection.run(prompt_lm, payload) do
          {:ok, advice, _discussion} -> apply_advice(program, advice)
          {:error, reason} -> {:error, {:prompt_lm, reason}}
        end
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp apply_advice(program, advice) when is_map(advice) do
    updated =
      Enum.reduce(Imp.ProgramParameters.predictors(program), program, fn %{
                                                                           name: name,
                                                                           predictor: predictor
                                                                         },
                                                                         program ->
        case Map.get(advice, name) || Map.get(advice, to_string(name)) do
          instruction when is_binary(instruction) ->
            combined = predictor.signature.instructions <> "\n\n" <> instruction
            Imp.ProgramParameters.put_instruction(program, name, combined)

          _ ->
            program
        end
      end)

    {:ok, updated}
  end

  defp apply_advice(_program, _advice), do: {:error, :invalid_advice}

  defp reflection_payload(program, good, bad) do
    %{
      program_code: program_representation(program),
      modules_defn: module_definitions(program),
      module_names: Enum.map(Imp.ProgramParameters.predictors(program), & &1.name),
      program_inputs: example_inputs(good.example),
      oracle_metadata: example_labels(good.example),
      better_program_trajectory: reflection_trajectory(good.trace),
      better_program_outputs: prediction_fields(good.prediction),
      better_reward_value: good.score,
      better_reward_info: good.metric_metadata || %{},
      worse_program_trajectory: reflection_trajectory(bad.trace),
      worse_program_outputs: prediction_fields(bad.prediction),
      worse_reward_value: bad.score,
      worse_reward_info: bad.metric_metadata || %{}
    }
  end

  defp suppress_trajectory(good, bad, :normal), do: {good, bad}

  defp suppress_trajectory(good, bad, disposition)
       when disposition in [:suppress_good, :suppress_bad] do
    unavailable = %{trace: [], score: "N/A", prediction: %{"N/A" => "Prediction not available"}}

    if disposition == :suppress_bad,
      do: {good, Map.merge(bad, unavailable)},
      else: {Map.merge(good, unavailable), bad}
  end

  defp reflection_trajectory(trace) when is_list(trace) do
    Enum.map(trace, fn
      %{predictor: name, inputs: inputs, outputs: outputs} ->
        %{module_name: name, inputs: inputs, outputs: Map.new(outputs)}

      step ->
        step
    end)
  end

  defp reflection_trajectory(_trace), do: []

  defp program_representation(%module{} = program) do
    case module_source(module) do
      nil ->
        "Program module: #{inspect(module)}\nOptimizer predictors: " <>
          inspect(Enum.map(Imp.ProgramParameters.predictors(program), & &1.name))

      source ->
        source
    end
  end

  defp module_source(module) do
    source = module.module_info(:compile)[:source]

    if source && File.regular?(source),
      do: source |> File.read!() |> String.slice(0, 20_000),
      else: nil
  rescue
    _error -> nil
  end

  defp module_definitions(program) do
    separator = String.duplicate("-", 80)

    definitions =
      Enum.map(Imp.ProgramParameters.predictors(program), fn entry ->
        signature = entry.predictor.signature

        """
        Module #{entry.name}

        \tInput Fields:
        #{format_fields(signature.inputs)}
        \tOutput Fields:
        #{format_fields(signature.outputs)}
        \tOriginal Instructions:
        \t\t#{indent_lines(signature.instructions)}
        """
        |> String.trim()
      end)

    Enum.join([separator | definitions] ++ [separator], "\n")
  end

  defp format_fields(fields) do
    fields
    |> Enum.map(fn field ->
      description = if field.desc in [nil, ""], do: "", else: " - #{field.desc}"
      "\t\t#{field.name}: #{field.type}#{description}"
    end)
    |> Enum.join("\n")
  end

  defp indent_lines(value) do
    value
    |> to_string()
    |> String.split("\n")
    |> Enum.join("\n\t\t")
  end

  defp trajectory_demos(trajectory, maxlen) do
    case trajectory.trace do
      trace when is_list(trace) ->
        Enum.reduce(trace, %{}, fn
          %{predictor: name, inputs: inputs, outputs: outputs}, acc ->
            Map.put(acc, name, make_demo(inputs, outputs, maxlen))

          _step, acc ->
            acc
        end)

      _ ->
        if trajectory.example && trajectory.prediction do
          %{
            main:
              make_demo(
                example_inputs(trajectory.example),
                prediction_fields(trajectory.prediction),
                maxlen
              )
          }
        else
          %{}
        end
    end
  end

  defp trajectory_errors(trajectories, stage) do
    trajectories
    |> Enum.reject(&is_nil(&1.error))
    |> Enum.map(&%{stage: stage, index: &1.index, reason: &1.error})
  end

  defp make_demo(inputs, outputs, maxlen) do
    inputs = Map.new(inputs, fn {key, value} -> {key, truncate(value, maxlen)} end)

    inputs
    |> Map.merge(Map.new(outputs))
    |> Imp.Example.new()
    |> Imp.Example.with_inputs(Map.keys(inputs))
  end

  defp truncate(value, maxlen) when is_integer(maxlen) and maxlen > 0 do
    representation = input_value_representation(value)

    if String.length(representation) > maxlen,
      do: String.slice(representation, 0, maxlen) <> "\n\t\t... <TRUNCATED FOR BREVITY>",
      else: value
  end

  defp truncate(value, _maxlen), do: value

  defp input_value_representation(value) when is_binary(value), do: value

  defp input_value_representation(value)
       when is_atom(value) or is_number(value),
       do: to_string(value)

  defp input_value_representation(value),
    do: inspect(value, limit: :infinity, printable_limit: :infinity)

  defp evict_demos(program, max_demos, policy, poisson_rng) do
    predictors = Imp.ProgramParameters.predictors(program)
    demo_count = predictors |> Enum.map(&length(&1.predictor.demos)) |> Enum.max(fn -> 0 end)
    parameters = eviction_parameters(demo_count, max_demos)
    {poisson, poisson_rng} = Sampling.poisson(parameters.poisson_mean, poisson_rng)

    drop_count =
      max(poisson, parameters.minimum_drop_count)
      |> min(demo_count)

    {indices, policy} =
      Enum.map_reduce(step_indices(drop_count), policy, fn _, policy ->
        SearchPolicy.suggest(policy, {:integer, max(1, demo_count)})
      end)

    program =
      Enum.reduce(predictors, program, fn %{name: name, predictor: predictor}, program ->
        demos =
          predictor.demos
          |> Enum.with_index()
          |> Enum.reject(fn {_demo, index} -> index in indices end)
          |> Enum.map(&elem(&1, 0))

        Imp.ProgramParameters.put_demos(program, name, demos)
      end)

    {program, policy, poisson_rng}
  end

  defp prepare_rollout_models(program, optimizer) do
    baseline_predictor =
      program
      |> Imp.ProgramParameters.predictors()
      |> hd()
      |> Map.fetch!(:predictor)

    start_rollout_id =
      Keyword.get(
        baseline_predictor.config,
        :rollout_id,
        lm_option(baseline_predictor.lm, :rollout_id, 0)
      )

    rollout_id_plan(start_rollout_id, optimizer.num_candidates, not is_nil(optimizer.teacher_lm))
    |> Enum.map(fn rollout ->
      %{
        lm: if(rollout.teacher?, do: optimizer.teacher_lm, else: baseline_predictor.lm),
        rollout_id: rollout.rollout_id,
        force_temperature?: rollout.force_temperature?
      }
    end)
  end

  defp bind_rollout(program, rollout) do
    Enum.reduce(Imp.ProgramParameters.predictors(program), program, fn %{name: name}, program ->
      Imp.ProgramParameters.update_predictor(program, name, fn predictor ->
        config = Keyword.put(predictor.config, :rollout_id, rollout.rollout_id)

        config =
          if rollout.force_temperature?,
            do: Keyword.put(config, :temperature, 1.0),
            else: config

        %{
          predictor
          | lm: rollout.lm,
            config: config
        }
      end)
    end)
  end

  defp lm_option(%{opts: opts}, key, default) when is_list(opts),
    do: Keyword.get(opts, key, default)

  defp lm_option(_lm, _key, default), do: default

  defp next_batch(state, trainset, bsize) do
    if state.cursor + bsize > length(state.order) do
      {order, policy} = SearchPolicy.suggest(state.population.policy, {:shuffle, state.order})
      population = %{state.population | policy: policy}
      next_batch(%{state | order: order, cursor: 0, population: population}, trainset, bsize)
    else
      indices = Enum.slice(state.order, state.cursor, bsize)
      batch = Enum.map(indices, &{&1, Enum.at(trainset, &1)})
      {batch, %{state | cursor: state.cursor + bsize}}
    end
  end

  defp complete_final_evaluations(
         state,
         optimizer,
         final_set,
         compatibility,
         checkpoint_fn
       ) do
    finalists = finalist_programs(state.winning_programs, optimizer.num_candidates + 1)
    completed = length(state.final_evaluations)

    finalists
    |> Enum.drop(completed)
    |> Enum.with_index(completed)
    |> Enum.reduce(state, fn {finalist, finalist_index}, state ->
      trajectories =
        TrajectoryRunner.run(finalist, final_set, optimizer.metric,
          max_concurrency: optimizer.max_concurrency,
          timeout: optimizer.timeout,
          runtime: :simba
        )

      errors = trajectory_errors(trajectories, :final_evaluation)

      evaluation = %{
        finalist_index: finalist_index,
        program: finalist,
        score: average_score(trajectories),
        scores: Enum.map(trajectories, & &1.score),
        errors: errors
      }

      trial_logs =
        if finalist_index == 0 do
          state.trial_logs
        else
          List.update_at(
            state.trial_logs,
            finalist_index - 1,
            &Map.put(&1, :train_score, evaluation.score)
          )
        end

      state = %{
        state
        | final_evaluations: state.final_evaluations ++ [evaluation],
          final_evaluation_calls: state.final_evaluation_calls + length(final_set),
          trial_logs: trial_logs,
          errors: state.errors ++ errors
      }

      emit_checkpoint(checkpoint_fn, compatibility, state)
      state
    end)
  end

  defp emit_checkpoint(nil, _compatibility, _state), do: :ok

  defp emit_checkpoint(callback, compatibility, state) do
    callback.(Checkpoint.dump(compatibility, state))
    :ok
  end

  defp invocation_step_limit(total, _completed, :infinity), do: total
  defp invocation_step_limit(total, completed, maximum), do: min(total, completed + maximum)

  defp step_range(first, last) when first <= last, do: first..last
  defp step_range(_first, _last), do: []

  defp validate_resumed_state!(state, optimizer, trainset) do
    expected_order = Enum.to_list(0..(length(trainset) - 1))

    unless Enum.sort(state.order) == expected_order and state.cursor <= length(state.order) do
      raise ArgumentError, "invalid SIMBA resume state: minibatch order or cursor is invalid"
    end

    unless state.completed_steps <= optimizer.max_steps do
      raise ArgumentError,
            "invalid SIMBA resume state: completed steps exceed the configured budget"
    end

    finalists = finalist_programs(state.winning_programs, optimizer.num_candidates + 1)

    unless length(state.final_evaluations) <= length(finalists) and
             (state.final_evaluations == [] or state.completed_steps == optimizer.max_steps) do
      raise ArgumentError, "invalid SIMBA resume state: final evaluation progress is inconsistent"
    end

    state
  end

  defp resume_compatibility(program, predictors, trainset, final_set, optimizer) do
    payload = %{
      optimizer: %{
        bsize: optimizer.bsize,
        num_candidates: optimizer.num_candidates,
        max_steps: optimizer.max_steps,
        max_demos: optimizer.max_demos,
        demo_input_field_maxlen: optimizer.demo_input_field_maxlen,
        max_concurrency: optimizer.max_concurrency,
        timeout: optimizer.timeout,
        sampling_temperature: optimizer.sampling_temperature,
        candidate_temperature: optimizer.candidate_temperature,
        seed: optimizer.seed
      },
      datasets: %{trainset: trainset, final_set: final_set},
      metric: runtime_identity(optimizer.metric),
      prompt_lm: runtime_identity(optimizer.prompt_lm),
      teacher_lm: runtime_identity(optimizer.teacher_lm),
      predictors:
        Enum.map(predictors, fn %{name: name, predictor: predictor} ->
          %{
            name: name,
            signature: predictor.signature,
            demos: predictor.demos,
            lm: runtime_identity(predictor.lm)
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

    %{"sha256" => digest}
  end

  defp runtime_identity(callback) when is_function(callback) do
    Map.new([:module, :name, :arity, :type, :uniq, :index], fn key ->
      {key, callback |> :erlang.fun_info(key) |> elem(1)}
    end)
  end

  defp runtime_identity(%_{} = struct),
    do: struct |> Map.from_struct() |> runtime_identity()

  defp runtime_identity(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {key, runtime_identity(value)} end)

  defp runtime_identity(list) when is_list(list), do: Enum.map(list, &runtime_identity/1)

  defp runtime_identity(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&runtime_identity/1) |> List.to_tuple()

  defp runtime_identity(pid) when is_pid(pid), do: :runtime_pid
  defp runtime_identity(reference) when is_reference(reference), do: :runtime_reference
  defp runtime_identity(port) when is_port(port), do: :runtime_port
  defp runtime_identity(value), do: value

  defp finalist_programs(winners, limit) do
    winners
    |> then(&finalist_indices(length(&1) - 1, limit - 1))
    |> Enum.map(&Enum.at(winners, &1))
  end

  defp average_score([]), do: 0.0

  defp average_score(trajectories),
    do: Enum.sum(Enum.map(trajectories, & &1.score)) / length(trajectories)

  defp round_half_even(value) do
    lower = floor(value)
    fraction = value - lower

    cond do
      fraction < 0.5 -> lower
      fraction > 0.5 -> lower + 1
      rem(lower, 2) == 0 -> lower
      true -> lower + 1
    end
  end

  defp prediction_fields(%Imp.Prediction{} = prediction), do: Imp.Prediction.to_map(prediction)
  defp prediction_fields(prediction) when is_map(prediction), do: prediction
  defp prediction_fields(_prediction), do: %{}

  defp example_inputs(%Imp.Example{} = example),
    do: example |> Imp.Example.inputs() |> Imp.Example.to_map()

  defp example_inputs(_example), do: %{}

  defp example_labels(%Imp.Example{} = example),
    do: example |> Imp.Example.labels() |> Imp.Example.to_map()

  defp example_labels(_example), do: %{}
  defp step_indices(count) when count > 0, do: 1..count
  defp step_indices(_count), do: []

  defp materialize!(enumerable, name) do
    Enum.to_list(enumerable)
  rescue
    Protocol.UndefinedError ->
      reraise ArgumentError, [message: "#{name} must be enumerable"], __STACKTRACE__
  end

  defp validate_compile_options!(opts) do
    unless Keyword.keyword?(opts) do
      raise ArgumentError, "Imp.Optimizer.SIMBA.compile/5 expects keyword options"
    end

    unknown = Keyword.keys(opts) -- @compile_runtime_keys

    if unknown != [],
      do: raise(ArgumentError, "unknown SIMBA compile options: #{inspect(unknown)}")

    resume_state = Keyword.get(opts, :resume_state)
    checkpoint_fn = Keyword.get(opts, :checkpoint_fn)
    max_steps = Keyword.get(opts, :max_steps, :infinity)

    unless is_nil(resume_state) or is_map(resume_state),
      do: raise(ArgumentError, ":resume_state must be a checkpoint map or nil")

    unless is_nil(checkpoint_fn) or is_function(checkpoint_fn, 1),
      do: raise(ArgumentError, ":checkpoint_fn must be an arity-one function or nil")

    unless max_steps == :infinity or (is_integer(max_steps) and max_steps >= 0),
      do: raise(ArgumentError, ":max_steps must be :infinity or a non-negative integer")

    [resume_state: resume_state, checkpoint_fn: checkpoint_fn, max_steps: max_steps]
  end

  defp validate!(optimizer) do
    for {key, value, minimum} <- [
          {:bsize, optimizer.bsize, 1},
          {:num_candidates, optimizer.num_candidates, 1},
          {:max_steps, optimizer.max_steps, 0},
          {:max_demos, optimizer.max_demos, 0},
          {:demo_input_field_maxlen, optimizer.demo_input_field_maxlen, 0},
          {:max_concurrency, optimizer.max_concurrency, 1},
          {:seed, optimizer.seed, 0}
        ] do
      unless is_integer(value) and value >= minimum,
        do: raise(ArgumentError, "#{key} must be an integer >= #{minimum}")
    end

    for {key, value} <- [
          sampling_temperature: optimizer.sampling_temperature,
          candidate_temperature: optimizer.candidate_temperature
        ] do
      unless is_number(value) and value > 0, do: raise(ArgumentError, "#{key} must be positive")
    end

    validate_lm!(optimizer.prompt_lm, :prompt_lm)
    validate_lm!(optimizer.teacher_lm, :teacher_lm)

    optimizer
  end

  defp validate_lm!(lm, key) do
    case Imp.LM.validate_lm(lm) do
      {:ok, _lm} -> :ok
      {:error, reason} -> raise ArgumentError, "#{key} #{reason}"
    end
  end
end
