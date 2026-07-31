defmodule Imp.Optimizer.MIPROv2.UpstreamBootstrap do
  @moduledoc false

  alias Imp.Optimizer.{DemoCandidates, Report, TrajectoryRunner}
  alias Imp.Optimizer.MIPROv2.PythonRandom

  # DSPy 3.2.1 always constructs its few-shot arms before instruction proposal.
  # A zero-shot compile discards them after their calls advance MIPRO's shared
  # Python RNG. A few-shot compile retains the exact ordered arm shape and
  # searches those demonstrations jointly with each predictor's instruction.
  def build!(program, teacher, trainset, metric, rng, opts) do
    predictors = Imp.ProgramParameters.predictors(program)
    teacher_predictors = Imp.ProgramParameters.predictors(teacher)
    validate_compatible!(predictors, teacher_predictors)
    names = Enum.map(predictors, & &1.name)
    candidate_count = Keyword.fetch!(opts, :candidate_count)
    configured_bootstrapped = Keyword.get(opts, :max_bootstrapped_demos, 0)
    configured_labeled = Keyword.get(opts, :max_labeled_demos, 0)
    zeroshot? = configured_bootstrapped == 0 and configured_labeled == 0
    max_bootstrapped = if zeroshot?, do: 3, else: configured_bootstrapped
    max_labeled = if zeroshot?, do: 0, else: configured_labeled

    unless candidate_count > 0,
      do: raise(ArgumentError, "DSPy 3.2.1 public bootstrap requires candidates")

    {rounds, rng} =
      Enum.map_reduce(-3..(candidate_count - 4), rng, fn internal_seed, rng ->
        build_arm(
          internal_seed,
          teacher,
          trainset,
          metric,
          names,
          max_bootstrapped,
          max_labeled,
          rng,
          opts
        )
      end)

    candidates =
      Map.new(names, fn name ->
        sets = Enum.map(rounds, &Map.fetch!(&1.demos, name))
        {name, if(zeroshot?, do: List.duplicate([], candidate_count), else: sets)}
      end)

    trajectories = Enum.flat_map(rounds, & &1.trajectories)

    metadata = %{
      fidelity: :dspy_3_2_1,
      candidate_count: candidate_count,
      demos_retained: not zeroshot?,
      max_bootstrapped_demos: max_bootstrapped,
      max_labeled_demos: max_labeled,
      trajectory_count: length(trajectories),
      maximum_task_calls: max(candidate_count - 1, 0) * length(trainset),
      accepted_count:
        Enum.count(trajectories, &accepted?(&1, Keyword.get(opts, :metric_threshold))),
      rejected_count:
        Enum.count(trajectories, &(not accepted?(&1, Keyword.get(opts, :metric_threshold)))),
      errors:
        trajectories
        |> Enum.reject(&is_nil(&1.error))
        |> Enum.map(&%{stage: :bootstrap, index: &1.index, reason: &1.error}),
      rounds: Enum.map(rounds, &Map.drop(&1, [:trajectories, :demos]))
    }

    {candidates, metadata, rng}
  end

  defp validate_compatible!(predictors, teacher_predictors) do
    student_shape = Enum.map(predictors, &{&1.name, &1.predictor.signature})
    teacher_shape = Enum.map(teacher_predictors, &{&1.name, &1.predictor.signature})

    unless student_shape == teacher_shape do
      raise ArgumentError,
            "DSPy 3.2.1 MIPRO teacher must expose the same ordered predictor names and signatures as the student"
    end
  end

  defp build_arm(
         -3,
         _program,
         _trainset,
         _metric,
         names,
         _max_bootstrapped,
         _max_labeled,
         rng,
         _opts
       ) do
    {%{
       internal_seed: -3,
       kind: :zero_shot,
       maximum: 0,
       calls: 0,
       accepted: 0,
       demos: empty_demos(names),
       trajectories: []
     }, rng}
  end

  defp build_arm(
         -2,
         _program,
         trainset,
         _metric,
         names,
         _max_bootstrapped,
         max_labeled,
         rng,
         _opts
       )
       when max_labeled > 0 do
    demos = labeled_demos(names, trainset, max_labeled)

    {%{
       internal_seed: -2,
       kind: :labels_only,
       maximum: 0,
       calls: 0,
       accepted: 0,
       demos: demos,
       trajectories: []
     }, rng}
  end

  defp build_arm(-1, program, trainset, metric, names, max_bootstrapped, max_labeled, rng, opts) do
    result =
      bootstrap_arm(
        program,
        trainset,
        metric,
        names,
        max_bootstrapped,
        max_labeled,
        -1,
        opts
      )

    {result, rng}
  end

  defp build_arm(
         internal_seed,
         program,
         trainset,
         metric,
         names,
         max_bootstrapped,
         max_labeled,
         rng,
         opts
       ) do
    {shuffled, rng} = PythonRandom.shuffle(rng, trainset)
    {maximum, rng} = PythonRandom.randint(rng, 1, max_bootstrapped)

    result =
      bootstrap_arm(
        program,
        shuffled,
        metric,
        names,
        maximum,
        max_labeled,
        internal_seed,
        opts
      )

    {result, rng}
  end

  defp bootstrap_arm(program, trainset, metric, names, maximum, max_labeled, internal_seed, opts) do
    teacher = prepare_teacher(program, trainset, max_labeled)

    {trajectories, accepted_indices, accepted_demos, _teacher} =
      Enum.reduce_while(
        Enum.with_index(trainset),
        {[], [], empty_demos(names), teacher},
        fn {example, index}, {trajectories, accepted_indices, accepted_demos, teacher} ->
          if length(accepted_indices) >= maximum do
            {:halt, {trajectories, accepted_indices, accepted_demos, teacher}}
          else
            stripped_teacher = remove_example_demos(teacher, example)

            [trajectory] =
              TrajectoryRunner.run(stripped_teacher, [example], metric,
                max_concurrency: 1,
                timeout: Keyword.fetch!(opts, :timeout),
                runtime: :mipro_v2,
                rollout_id: 0
              )

            trajectory = %{trajectory | index: index}
            trajectories = trajectories ++ [trajectory]

            enforce_error_budget!(
              trajectories,
              Keyword.fetch!(opts, :max_errors),
              internal_seed
            )

            teacher = if program_call_failed?(trajectory), do: stripped_teacher, else: teacher

            if accepted?(trajectory, Keyword.get(opts, :metric_threshold)) do
              demos = DemoCandidates.extract_bootstrapped([trajectory], names)

              {:cont,
               {trajectories, accepted_indices ++ [index], merge_demos(accepted_demos, demos),
                teacher}}
            else
              {:cont, {trajectories, accepted_indices, accepted_demos, teacher}}
            end
          end
        end
      )

    demos =
      train_student_demos(
        names,
        trainset,
        accepted_indices,
        accepted_demos,
        maximum,
        max_labeled
      )

    %{
      internal_seed: internal_seed,
      kind: if(internal_seed == -1, do: :unshuffled_bootstrap, else: :shuffled_bootstrap),
      maximum: maximum,
      calls: length(trajectories),
      accepted: length(accepted_indices),
      demos: demos,
      trajectories: trajectories
    }
  end

  defp prepare_teacher(teacher, _trainset, 0), do: teacher

  defp prepare_teacher(teacher, trainset, max_labeled) do
    if compiled_teacher?(teacher) do
      teacher
    else
      teacher
      |> clear_demos()
      |> put_labeled_demos(trainset, max_labeled)
    end
  end

  defp compiled_teacher?(teacher), do: match?(%Report{}, Report.fetch(teacher))

  defp clear_demos(program) do
    Enum.reduce(Imp.ProgramParameters.predictors(program), program, fn %{name: name}, program ->
      Imp.ProgramParameters.put_demos(program, name, [])
    end)
  end

  defp put_labeled_demos(program, trainset, max_labeled) do
    {program, _rng} =
      Enum.reduce(Imp.ProgramParameters.predictors(program), {program, PythonRandom.new(0)}, fn %{
                                                                                                  name:
                                                                                                    name
                                                                                                },
                                                                                                {program,
                                                                                                 rng} ->
        {sampled, rng} = PythonRandom.sample(rng, trainset, min(max_labeled, length(trainset)))
        {Imp.ProgramParameters.put_demos(program, name, sampled), rng}
      end)

    program
  end

  defp labeled_demos(names, trainset, max_labeled) do
    {pairs, _rng} =
      Enum.map_reduce(names, PythonRandom.new(0), fn name, rng ->
        {sampled, rng} = PythonRandom.sample(rng, trainset, min(max_labeled, length(trainset)))
        {{name, sampled}, rng}
      end)

    Map.new(pairs)
  end

  defp train_student_demos(
         names,
         trainset,
         accepted_indices,
         accepted_demos,
         max_bootstrapped,
         max_labeled
       ) do
    accepted_indices = MapSet.new(accepted_indices)

    validation =
      trainset
      |> Enum.with_index()
      |> Enum.reject(fn {_example, index} -> MapSet.member?(accepted_indices, index) end)
      |> Enum.map(&elem(&1, 0))

    {validation, _rng} = PythonRandom.shuffle(PythonRandom.new(0), validation)

    {pairs, _validation, _rng} =
      Enum.reduce(names, {[], validation, PythonRandom.new(0)}, fn name,
                                                                   {pairs, raw_demos, rng} ->
        augmented = accepted_demos |> Map.fetch!(name) |> Enum.take(max_bootstrapped)
        count = max(0, min(max_labeled - length(augmented), length(raw_demos)))
        {sampled, rng} = PythonRandom.sample(rng, raw_demos, count)
        {[{name, augmented ++ sampled} | pairs], sampled, rng}
      end)

    Map.new(pairs)
  end

  defp remove_example_demos(program, example) do
    Enum.reduce(Imp.ProgramParameters.predictors(program), program, fn %{
                                                                         name: name,
                                                                         predictor: predictor
                                                                       },
                                                                       program ->
      demos = Enum.reject(predictor.demos, &same_example?(&1, example))
      Imp.ProgramParameters.put_demos(program, name, demos)
    end)
  end

  defp same_example?(left, right), do: normalize_example(left) == normalize_example(right)
  defp normalize_example(%Imp.Example{} = example), do: Imp.Example.to_map(example)
  defp normalize_example(example), do: example |> Imp.Example.new() |> Imp.Example.to_map()

  defp merge_demos(left, right),
    do: Map.merge(left, right, fn _name, current, additions -> current ++ additions end)

  defp empty_demos(names), do: Map.new(names, &{&1, []})

  defp program_call_failed?(%{error: nil}), do: false
  defp program_call_failed?(%{error: {:metric_error, _reason}}), do: false
  defp program_call_failed?(_trajectory), do: true

  defp accepted?(trajectory, nil), do: is_nil(trajectory.error) and trajectory.score != 0
  defp accepted?(trajectory, 0), do: accepted?(trajectory, nil)

  defp accepted?(trajectory, threshold),
    do: is_nil(trajectory.error) and trajectory.score >= threshold

  defp enforce_error_budget!(_trajectories, :infinity, _internal_seed), do: :ok

  defp enforce_error_budget!(trajectories, maximum, internal_seed) do
    failures = Enum.reject(trajectories, &is_nil(&1.error))

    if failures != [] and length(failures) >= maximum do
      first = hd(failures)

      raise Imp.EvaluationCancelledError,
        message: failure_message(first.error),
        rows: Enum.map(trajectories, &bootstrap_row(&1, internal_seed)),
        errors: Enum.map(failures, &bootstrap_failure(&1, internal_seed)),
        max_errors: maximum
    end
  end

  defp bootstrap_row(trajectory, internal_seed) do
    %{
      index: trajectory.index,
      identity_sha256: example_identity(trajectory.example),
      candidate_identity: %{bootstrap_arm: internal_seed, rollout_id: trajectory.rollout_id},
      score: trajectory.score,
      failed: not is_nil(trajectory.error)
    }
  end

  defp bootstrap_failure(trajectory, internal_seed) do
    %{
      stage: :mipro_bootstrap,
      index: trajectory.index,
      identity_sha256: example_identity(trajectory.example),
      candidate_identity: %{bootstrap_arm: internal_seed, rollout_id: trajectory.rollout_id},
      reason: Imp.Redaction.redact(trajectory.error),
      logical_attempts: known_attempt_count(trajectory, :logical_attempts),
      transport_attempts: known_attempt_count(trajectory, :transport_attempts),
      completed_predictor_calls: length(trajectory.trace || [])
    }
  end

  defp example_identity(nil), do: nil

  defp example_identity(example) do
    example
    |> Imp.Example.to_map()
    |> Report.encode_term()
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp known_attempt_count(trajectory, key) do
    values =
      [trajectory.error, trajectory.metric_metadata, trajectory.metadata]
      |> Enum.flat_map(&find_counts(&1, key))
      |> Enum.filter(&(is_integer(&1) and &1 >= 0))

    case values do
      [] -> nil
      _ -> Enum.max(values)
    end
  end

  defp find_counts(value, key) when is_struct(value),
    do: value |> Map.from_struct() |> find_counts(key)

  defp find_counts(value, key) when is_map(value) do
    own = [Map.get(value, key), Map.get(value, Atom.to_string(key))]
    nested = value |> Map.values() |> Enum.flat_map(&find_counts(&1, key))
    own ++ nested
  end

  defp find_counts([], _key), do: []

  defp find_counts([head | tail], key),
    do: find_counts(head, key) ++ find_counts(tail, key)

  defp find_counts(value, key) when is_tuple(value),
    do: value |> Tuple.to_list() |> find_counts(key)

  defp find_counts(_value, _key), do: []

  defp failure_message(%{__exception__: true} = error),
    do: error |> Exception.message() |> Imp.Redaction.redact()

  defp failure_message({:metric_error, reason}), do: format_reason(reason)
  defp failure_message(reason), do: format_reason(reason)

  defp format_reason(reason) when is_binary(reason), do: Imp.Redaction.redact(reason)
  defp format_reason(reason), do: inspect(Imp.Redaction.redact(reason))
end
