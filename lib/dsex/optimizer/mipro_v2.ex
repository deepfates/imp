defmodule DSEx.Optimizer.MIPROv2 do
  @moduledoc "Categorical TPE search over instructions and demonstration sets."

  defstruct [:metric, trials: 12, demos_per_candidate: 4, cold_start: 4]

  @option_schema [
    trials: [type: :non_neg_integer, default: 12],
    demos_per_candidate: [type: :non_neg_integer, default: 4],
    cold_start: [type: :non_neg_integer, default: 4]
  ]

  def new(metric, opts \\ []) do
    validate_metric!(metric)
    opts = DSEx.Options.validate!(opts, @option_schema, "DSEx.Optimizer.MIPROv2.new/2")

    %__MODULE__{
      metric: metric,
      trials: opts[:trials],
      demos_per_candidate: opts[:demos_per_candidate],
      cold_start: opts[:cold_start]
    }
  end

  def compile(%__MODULE__{} = optimizer, program, trainset, devset) do
    {trainset, setup_errors} = materialize_trainset(trainset)

    with {:ok, evaluator} <- new_evaluator(devset, optimizer.metric),
         {:ok, baseline_score} <- evaluate_score(evaluator, program) do
      {instructions, instruction_errors} = candidate_instructions(program, trainset)
      demo_sets = demo_candidates(trainset, optimizer.demos_per_candidate)
      search_space = candidate_pairs(instructions, demo_sets)

      {trial_results, trial_errors} =
        search_space
        |> tpe_trial_order(optimizer.trials, optimizer.cold_start, fn {instruction, demos} ->
          candidate = build_candidate(program, instruction, demos, optimizer.demos_per_candidate)
          evaluate_score(evaluator, candidate)
        end)
        |> Enum.map(fn
          {{instruction, demos}, trial, {:ok, score}, source} ->
            candidate =
              build_candidate(program, instruction, demos, optimizer.demos_per_candidate)

            {{:ok, score, candidate,
              %{trial: trial, instruction: instruction, demos: demos, source: source}}, []}

          {{instruction, demos}, trial, {:error, reason}, source} ->
            metadata = %{trial: trial, instruction: instruction, demos: demos, source: source}

            {{:error, reason, metadata},
             [%{stage: :candidate_evaluation, reason: reason, metadata: metadata}]}
        end)
        |> Enum.unzip()

      results =
        trial_results ++
          [{:ok, baseline_score, program, %{trial: 0, baseline: true}}]

      errors = setup_errors ++ instruction_errors ++ List.flatten(trial_errors)

      summarize_and_attach(program, optimizer, results, errors, %{
        search: :categorical_tpe,
        acquisition: :laplace_density_ratio,
        cold_start: min(optimizer.cold_start, length(search_space)),
        instruction_count: length(instructions),
        demo_candidate_count: length(demo_sets),
        status: if(errors == [], do: :ok, else: :with_errors)
      })
    else
      {:error, reason} ->
        summarize_and_attach(
          program,
          optimizer,
          [],
          setup_errors ++ [%{stage: :setup, reason: reason}],
          %{
            search: :categorical_tpe,
            acquisition: :laplace_density_ratio,
            cold_start: 0,
            instruction_count: 0,
            demo_candidate_count: 0,
            status: :all_candidates_failed
          }
        )
    end
  end

  defp summarize_and_attach(program, _optimizer, results, errors, metadata) do
    successes =
      Enum.flat_map(results, fn
        {:ok, score, candidate, candidate_metadata} -> [{score, candidate, candidate_metadata}]
        _other -> []
      end)

    report_candidates =
      Enum.map(successes, fn {score, _candidate, candidate_metadata} ->
        Map.put(candidate_metadata, :score, score)
      end)

    {best_score, best} =
      case successes do
        [] ->
          {nil, program}

        _ ->
          {score, candidate, _metadata} =
            Enum.max_by(successes, fn {score, _candidate, _} -> score end)

          {score, candidate}
      end

    DSEx.Optimizer.Report.attach(
      best,
      DSEx.Optimizer.Report.new(%{
        optimizer: :mipro_v2,
        best_score: best_score,
        candidate_count: length(report_candidates),
        candidates: report_candidates,
        errors: errors,
        metadata: metadata
      })
    )
  end

  defp materialize_trainset(trainset) do
    {Enum.to_list(trainset), []}
  rescue
    error -> {[], [%{stage: :trainset, reason: error_message(error)}]}
  catch
    kind, reason -> {[], [%{stage: :trainset, reason: error_message({kind, reason})}]}
  end

  defp new_evaluator(devset, metric) do
    {:ok, DSEx.Evaluate.new(devset, metric)}
  rescue
    error -> {:error, error_message(error)}
  catch
    kind, reason -> {:error, error_message({kind, reason})}
  end

  defp candidate_instructions(program, trainset) do
    {DSEx.Optimizer.InstructionSearch.candidate_instructions(program, trainset), []}
  rescue
    error -> {[], [%{stage: :instruction_proposal, reason: error_message(error)}]}
  catch
    kind, reason -> {[], [%{stage: :instruction_proposal, reason: error_message({kind, reason})}]}
  end

  defp evaluate_score(evaluator, program) do
    {:ok, DSEx.Evaluate.run(evaluator, program).score}
  rescue
    error -> {:error, error_message(error)}
  catch
    kind, reason -> {:error, error_message({kind, reason})}
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

      result = score_fn.(candidate)

      observations =
        case result do
          {:ok, score} -> [%{candidate: candidate, score: score} | observations]
          {:error, _reason} -> observations
        end

      {[{candidate, trial, result, source} | selected], observations}
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

  defp validate_metric!(metric) when is_function(metric, 2) or is_function(metric, 3), do: :ok

  defp validate_metric!(metric) do
    raise ArgumentError,
          "DSEx.Optimizer.MIPROv2.new/2 expects a metric function with arity 2 or 3; got: #{inspect(metric)}"
  end

  defp error_message(%_{} = exception), do: Exception.message(exception)
  defp error_message(error), do: inspect(error)
end
