defmodule Imp.Optimizer.MIPROv2.UpstreamBootstrap do
  @moduledoc false

  alias Imp.Optimizer.{TrajectoryRunner, MIPROv2.PythonRandom}

  # DSPy 3.2.1 still builds its declared number of few-shot arms during a
  # zero-shot compile. The resulting demos are later discarded, but task calls and
  # mutations of MIPRO's shared Python RNG are observable and therefore part of
  # a genuinely matched public compile.
  def build!(program, trainset, metric, rng, opts) do
    names = Enum.map(Imp.ProgramParameters.predictors(program), & &1.name)
    candidate_count = Keyword.fetch!(opts, :candidate_count)

    unless candidate_count > 0,
      do: raise(ArgumentError, "DSPy 3.2.1 public zero-shot bootstrap requires candidates")

    {rounds, rng} =
      Enum.map_reduce(-3..(candidate_count - 4), rng, fn
        -3, rng ->
          {%{internal_seed: -3, kind: :zero_shot, calls: 0, accepted: 0}, rng}

        -1, rng ->
          {round(program, trainset, metric, 3, -1, opts), rng}

        seed, rng ->
          {shuffled, rng} = PythonRandom.shuffle(rng, trainset)
          {maximum, rng} = PythonRandom.randint(rng, 1, 3)
          {round(program, shuffled, metric, maximum, seed, opts), rng}
      end)

    candidates = Map.new(names, &{&1, List.duplicate([], candidate_count)})
    trajectories = Enum.flat_map(rounds, &Map.get(&1, :trajectories, []))

    metadata = %{
      fidelity: :dspy_3_2_1,
      candidate_count: candidate_count,
      max_bootstrapped_demos: 3,
      max_labeled_demos: 0,
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
      rounds: Enum.map(rounds, &Map.drop(&1, [:trajectories]))
    }

    {candidates, metadata, rng}
  end

  defp round(program, trainset, metric, maximum, internal_seed, opts) do
    {trajectories, accepted} =
      Enum.reduce_while(trainset, {[], 0}, fn example, {trajectories, accepted} ->
        [trajectory] =
          TrajectoryRunner.run(program, [example], metric,
            max_concurrency: 1,
            timeout: Keyword.fetch!(opts, :timeout),
            runtime: :mipro_v2,
            rollout_id: 0
          )

        trajectories = trajectories ++ [trajectory]
        enforce_error_budget!(trajectories, Keyword.fetch!(opts, :max_errors))

        accepted =
          if accepted?(trajectory, Keyword.get(opts, :metric_threshold)),
            do: accepted + 1,
            else: accepted

        if accepted >= maximum,
          do: {:halt, {trajectories, accepted}},
          else: {:cont, {trajectories, accepted}}
      end)

    %{
      internal_seed: internal_seed,
      kind: if(internal_seed == -1, do: :unshuffled_bootstrap, else: :shuffled_bootstrap),
      maximum: maximum,
      calls: length(trajectories),
      accepted: accepted,
      trajectories: trajectories
    }
  end

  defp accepted?(trajectory, nil), do: is_nil(trajectory.error) and trajectory.score != 0
  defp accepted?(trajectory, 0), do: accepted?(trajectory, nil)

  defp accepted?(trajectory, threshold),
    do: is_nil(trajectory.error) and trajectory.score >= threshold

  defp enforce_error_budget!(_trajectories, :infinity), do: :ok

  defp enforce_error_budget!(trajectories, maximum) do
    errors = Enum.count(trajectories, &(!is_nil(&1.error)))

    if errors > 0 and errors >= maximum do
      raise RuntimeError,
            "MIPROv2 error budget exhausted during DSPy 3.2.1 bootstrap: #{errors} errors (maximum #{maximum})"
    end
  end
end
