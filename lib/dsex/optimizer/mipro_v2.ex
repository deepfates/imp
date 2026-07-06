defmodule DSEx.Optimizer.MIPROv2 do
  @moduledoc "Categorical TPE search over instructions and demonstration sets."

  defstruct [:metric, trials: 12, demos_per_candidate: 4, cold_start: 4]

  def new(metric, opts \\ []) do
    %__MODULE__{
      metric: metric,
      trials: Keyword.get(opts, :trials, 12),
      demos_per_candidate: Keyword.get(opts, :demos_per_candidate, 4),
      cold_start: Keyword.get(opts, :cold_start, 4)
    }
  end

  def compile(%__MODULE__{} = optimizer, program, trainset, devset) do
    instructions = DSEx.Optimizer.InstructionSearch.candidate_instructions(program, trainset)
    demo_sets = demo_candidates(trainset, optimizer.demos_per_candidate)
    evaluator = DSEx.Evaluate.new(devset, optimizer.metric)

    baseline =
      {DSEx.Evaluate.run(evaluator, program).score, program, %{trial: 0, baseline: true}}

    search_space = candidate_pairs(instructions, demo_sets)

    results =
      search_space
      |> tpe_trial_order(optimizer.trials, optimizer.cold_start, fn {instruction, demos} ->
        candidate = build_candidate(program, instruction, demos, optimizer.demos_per_candidate)
        DSEx.Evaluate.run(evaluator, candidate).score
      end)
      |> Enum.map(fn {{instruction, demos}, trial, score, source} ->
        candidate = build_candidate(program, instruction, demos, optimizer.demos_per_candidate)

        {score, candidate,
         %{trial: trial, instruction: instruction, demos: demos, source: source}}
      end)
      |> Kernel.++([baseline])

    {best_score, best, _metadata} =
      Enum.max_by(results, fn {score, _candidate, _metadata} -> score end)

    DSEx.Optimizer.Report.attach(
      best,
      DSEx.Optimizer.Report.new(%{
        optimizer: :mipro_v2,
        best_score: best_score,
        candidate_count: length(results),
        candidates:
          Enum.map(results, fn {score, _candidate, metadata} ->
            Map.put(metadata, :score, score)
          end),
        metadata: %{
          search: :categorical_tpe,
          acquisition: :laplace_density_ratio,
          cold_start: min(optimizer.cold_start, length(search_space)),
          instruction_count: length(instructions),
          demo_candidate_count: length(demo_sets)
        }
      })
    )
  end

  defp candidate_pairs(instructions, demo_sets) do
    for instruction <- instructions, demos <- demo_sets, do: {instruction, demos}
  end

  defp tpe_trial_order(search_space, trials, _cold_start, _score_fn)
       when trials <= 0 or search_space == [] do
    []
  end

  defp tpe_trial_order(search_space, trials, cold_start, score_fn) do
    search_space
    |> Enum.take(trials)
    |> Enum.reduce({[], []}, fn candidate, {selected, observations} ->
      trial = length(selected) + 1

      {candidate, source} =
        if trial <= cold_start or length(observations) < 2 do
          {candidate, :random_cold_start}
        else
          best_tpe_candidate(search_space, observations)
        end

      score = score_fn.(candidate)
      observation = %{candidate: candidate, score: score}
      {[{candidate, trial, score, source} | selected], [observation | observations]}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp best_tpe_candidate(search_space, observations) do
    tried = MapSet.new(Enum.map(observations, & &1.candidate))

    ranked =
      observations
      |> Enum.sort_by(& &1.score, :desc)

    split = max(1, div(length(ranked) + 1, 2))
    {good, bad} = Enum.split(ranked, split)

    candidate =
      search_space
      |> Enum.reject(&MapSet.member?(tried, &1))
      |> Enum.max_by(fn candidate -> density_ratio(candidate, good, bad) end, fn ->
        hd(search_space)
      end)

    {candidate, :tpe_density_ratio}
  end

  defp density_ratio({instruction, demos}, good, bad) do
    instruction_ratio =
      categorical_ratio(instruction, good, bad, fn {candidate_instruction, _demos} ->
        candidate_instruction
      end)

    demo_ratio =
      categorical_ratio(demos, good, bad, fn {_instruction, candidate_demos} ->
        candidate_demos
      end)

    instruction_ratio * demo_ratio
  end

  defp categorical_ratio(value, good, bad, projection) do
    good_hits = Enum.count(good, &(projection.(&1.candidate) == value))
    bad_hits = Enum.count(bad, &(projection.(&1.candidate) == value))

    # Laplace smoothing keeps unexplored categorical arms eligible.
    (good_hits + 1) / (bad_hits + 1)
  end

  defp demo_candidates(_trainset, k) when k <= 0, do: [[]]

  defp demo_candidates([], _k), do: [[]]

  defp demo_candidates(trainset, k) do
    1..length(trainset)
    |> Enum.map(fn index ->
      offset = index - 1

      trainset
      |> Stream.cycle()
      |> Stream.drop(offset)
      |> Enum.take(k)
    end)
    |> Enum.uniq()
  end

  defp build_candidate(program, instruction, demos, k) do
    %DSEx.Optimizer.LabeledFewShot{k: k}
    |> DSEx.Optimizer.LabeledFewShot.compile(
      DSEx.Optimizer.InstructionSearch.put_instruction(program, instruction),
      demos
    )
  end
end
