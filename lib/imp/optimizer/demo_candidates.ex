defmodule Imp.Optimizer.DemoCandidates do
  @moduledoc false

  alias Imp.Optimizer.{Sampling, TrajectoryRunner}

  @spec build(struct(), [Imp.Example.t()], function(), keyword()) ::
          {%{required(Imp.ProgramParameters.name()) => [[Imp.Example.t()]]}, map()}
  def build(program, trainset, metric, opts \\ []) do
    names = Enum.map(Imp.ProgramParameters.predictors(program), & &1.name)
    candidate_count = Keyword.get(opts, :candidate_count, 6)
    max_bootstrapped = Keyword.get(opts, :max_bootstrapped_demos, 4)
    max_labeled = Keyword.get(opts, :max_labeled_demos, 4)
    threshold = Keyword.get(opts, :metric_threshold)
    teacher = Keyword.get(opts, :teacher, program)
    rng = Sampling.new(Keyword.get(opts, :seed, 0))

    {bootstrap_rounds, rng} =
      Enum.map_reduce(bootstrap_indices(candidate_count, max_labeled), rng, fn index, rng ->
        {bootstrap_size, rng} = bootstrap_size(index, max_bootstrapped, rng)
        {round_trainset, rng} = maybe_shuffle(trainset, index, rng)
        round_teacher = bind_rollout(teacher, index)

        trajectories =
          TrajectoryRunner.run(round_teacher, round_trainset, metric,
            max_concurrency: Keyword.get(opts, :max_concurrency, 1),
            timeout: Keyword.get(opts, :timeout, 5_000),
            runtime: Keyword.get(opts, :runtime, :evaluation),
            rollout_id: index
          )

        enforce_error_budget!(trajectories, Keyword.get(opts, :max_errors, :infinity))

        accepted = Enum.filter(trajectories, &accepted?(&1, threshold))

        {%{
           index: index,
           trajectories: trajectories,
           accepted: accepted,
           bootstrap_size: bootstrap_size,
           demos: extract_bootstrapped(accepted, names)
         }, rng}
      end)

    {candidates, _rng} =
      Enum.map_reduce(candidate_indices(candidate_count), rng, fn index, rng ->
        {shuffled_trainset, rng} = maybe_shuffle(trainset, index, rng)
        bootstrapped = bootstrap_round(bootstrap_rounds, index, names)

        sets =
          Map.new(names, fn name ->
            {name,
             candidate_set(
               index,
               name,
               shuffled_trainset,
               bootstrapped,
               round_bootstrap_size(bootstrap_rounds, index, max_bootstrapped),
               max_labeled
             )}
          end)

        {sets, rng}
      end)

    by_predictor =
      Map.new(names, fn name -> {name, Enum.map(candidates, &Map.fetch!(&1, name))} end)

    trajectories = Enum.flat_map(bootstrap_rounds, & &1.trajectories)
    accepted = Enum.flat_map(bootstrap_rounds, & &1.accepted)

    {by_predictor,
     %{
       trajectory_count: length(trajectories),
       accepted_count: length(accepted),
       rejected_count: length(trajectories) - length(accepted),
       errors:
         trajectories
         |> Enum.reject(&is_nil(&1.error))
         |> Enum.map(&%{stage: :bootstrap, index: &1.index, reason: &1.error}),
       candidate_count: candidate_count,
       max_bootstrapped_demos: max_bootstrapped,
       max_labeled_demos: max_labeled,
       rounds:
         Enum.map(bootstrap_rounds, fn round ->
           %{
             index: round.index,
             rollout_id: round.index,
             bootstrap_size: round.bootstrap_size,
             trajectory_count: length(round.trajectories),
             accepted_count: length(round.accepted)
           }
         end)
     }}
  end

  @doc false
  def arm_plan(candidate_count, max_labeled_demos)
      when is_integer(candidate_count) and candidate_count >= 0 and
             is_integer(max_labeled_demos) and max_labeled_demos >= 0 do
    Enum.map(candidate_indices(candidate_count), fn
      0 -> %{slot: 0, internal_seed: -3, kind: :zero_shot}
      1 when max_labeled_demos > 0 -> %{slot: 1, internal_seed: -2, kind: :labels_only}
      2 -> %{slot: 2, internal_seed: -1, kind: :unshuffled_bootstrap}
      slot -> %{slot: slot, internal_seed: slot - 3, kind: :shuffled_bootstrap}
    end)
  end

  defp accepted?(trajectory, nil), do: trajectory.error == nil and trajectory.score != 0
  defp accepted?(trajectory, 0), do: accepted?(trajectory, nil)

  defp accepted?(trajectory, threshold),
    do: trajectory.error == nil and trajectory.score >= threshold

  @doc false
  def extract_bootstrapped(trajectories, names) do
    Enum.reduce(trajectories, Map.new(names, &{&1, []}), fn trajectory, acc ->
      trace_demos = trace_demos(trajectory.trace)

      Enum.reduce(names, acc, fn name, acc ->
        demos =
          case Map.get(trace_demos, name, []) do
            [] when names == [:main] -> List.wrap(final_demo(trajectory))
            demos -> [List.last(demos)]
          end

        Map.update!(acc, name, &(&1 ++ demos))
      end)
    end)
  end

  defp trace_demos(trace) when is_list(trace) do
    Enum.reduce(trace, %{}, fn
      %{predictor: name, inputs: inputs, outputs: outputs}, acc ->
        Map.update(
          acc,
          name,
          [augmented_demo(inputs, outputs)],
          &(&1 ++ [augmented_demo(inputs, outputs)])
        )

      %{"predictor" => name, "inputs" => inputs, "outputs" => outputs}, acc ->
        Map.update(
          acc,
          name,
          [augmented_demo(inputs, outputs)],
          &(&1 ++ [augmented_demo(inputs, outputs)])
        )

      _step, acc ->
        acc
    end)
  end

  defp trace_demos(_trace), do: %{}

  defp final_demo(%{
         example: %Imp.Example{} = example,
         prediction: %Imp.Prediction{} = prediction
       }) do
    augmented_demo(
      example |> Imp.Example.inputs() |> Imp.Example.to_map(),
      Imp.Prediction.to_map(prediction)
    )
  end

  defp final_demo(_trajectory), do: nil

  defp augmented_demo(inputs, outputs) do
    inputs = Map.new(inputs)

    inputs
    |> Map.merge(Map.new(outputs))
    |> Map.put("imp_augmented", true)
    |> Imp.Example.new()
    |> Imp.Example.with_inputs(Map.keys(inputs))
  end

  defp same_example?(example, demos) do
    fields = example |> normalize_example() |> Imp.Example.to_map()
    Enum.any?(demos, &(Imp.Example.to_map(&1) == fields))
  end

  defp normalize_example(%Imp.Example{} = example), do: example
  defp normalize_example(example), do: Imp.Example.new(example)

  defp candidate_indices(count) when count > 0, do: 0..(count - 1)
  defp candidate_indices(_count), do: []

  defp bootstrap_indices(count, max_labeled) do
    count
    |> arm_plan(max_labeled)
    |> Enum.filter(&(&1.kind in [:unshuffled_bootstrap, :shuffled_bootstrap]))
    |> Enum.map(& &1.slot)
  end

  defp bootstrap_round(rounds, index, names) do
    case Enum.find(rounds, &(&1.index == index)) do
      nil -> Map.new(names, &{&1, []})
      round -> round.demos
    end
  end

  defp round_bootstrap_size(rounds, index, default) do
    case Enum.find(rounds, &(&1.index == index)) do
      nil -> default
      round -> round.bootstrap_size
    end
  end

  defp bootstrap_size(_index, 0, rng), do: {0, rng}
  defp bootstrap_size(index, maximum, rng) when index in [1, 2], do: {maximum, rng}

  defp bootstrap_size(_index, maximum, rng) do
    {offset, rng} = Sampling.integer(maximum, rng)
    {offset + 1, rng}
  end

  defp candidate_set(0, _name, _trainset, _bootstrapped, _max_bootstrapped, _max_labeled),
    do: []

  defp candidate_set(1, _name, trainset, _bootstrapped, _max_bootstrapped, max_labeled)
       when max_labeled > 0,
       do: Enum.take(trainset, max_labeled)

  defp candidate_set(
         _index,
         name,
         trainset,
         bootstrapped,
         max_bootstrapped,
         max_labeled
       ) do
    bootstrapped_demos =
      bootstrapped |> Map.get(name, []) |> Enum.take(max_bootstrapped)

    labeled_demos =
      trainset
      |> Enum.reject(&same_example?(&1, bootstrapped_demos))
      |> Enum.take(max_labeled)

    bootstrapped_demos ++ labeled_demos
  end

  defp maybe_shuffle(values, index, rng) when index in [0, 2], do: {values, rng}
  defp maybe_shuffle(values, _index, rng), do: Sampling.shuffle(values, rng)

  defp bind_rollout(program, rollout_id) do
    Enum.reduce(Imp.ProgramParameters.predictors(program), program, fn %{name: name}, program ->
      Imp.ProgramParameters.update_predictor(program, name, fn predictor ->
        %{predictor | config: Keyword.put(predictor.config, :rollout_id, rollout_id)}
      end)
    end)
  end

  defp enforce_error_budget!(_trajectories, :infinity), do: :ok

  defp enforce_error_budget!(trajectories, maximum)
       when is_integer(maximum) and maximum >= 0 do
    errors = Enum.count(trajectories, &(!is_nil(&1.error)))

    if errors > 0 and errors >= maximum do
      raise RuntimeError,
            "bootstrap error budget exhausted: #{errors} errors (maximum #{maximum})"
    end
  end
end
