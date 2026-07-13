defmodule DSEx.Optimizer.RandomSearch do
  @moduledoc """
  Try random demo subsets and keep the program with the best dev score.

  `RandomSearch` is a useful first optimizer because it is easy to reason
  about: sample candidate demo sets from the train set, evaluate each candidate
  on the dev set, and attach a report to the best program. The original
  program is always evaluated as a baseline so random sampling cannot silently
  regress a working program. Sampling uses explicit optimizer-local RNG state;
  `:seed` defaults to `0`, and the final replayable policy checkpoint is stored
  in the optimizer report.

  ## Example

      iex> lm = %{
      ...>   module: DSEx.LM.Static,
      ...>   opts: [handler: fn _messages, _opts -> %{answer: "Paris"} end]
      ...> }
      iex> program = DSEx.predict("question -> answer", lm: lm)
      iex> trainset = [
      ...>   DSEx.example(question: "Eiffel Tower city?", answer: "Paris")
      ...>   |> DSEx.with_inputs(:question)
      ...> ]
      iex> devset = [
      ...>   DSEx.example(question: "Capital of France?", answer: "Paris")
      ...>   |> DSEx.with_inputs(:question)
      ...> ]
      iex> metric = DSEx.Metrics.exact_match(:answer)
      iex> compiled =
      ...>   metric
      ...>   |> DSEx.Optimizer.RandomSearch.new(candidates: 1, demos_per_candidate: 1)
      ...>   |> DSEx.Optimizer.RandomSearch.compile(program, trainset, devset)
      iex> DSEx.Optimizer.Report.fetch(compiled).optimizer
      :random_search

  Keep candidate counts small while developing. Raise them only after your
  metric and dev set are trustworthy. If every candidate fails because the
  evaluation setup is broken, `compile/4` returns the original program with an
  optimizer report describing the failures instead of raising from inside the
  search loop.
  """

  alias DSEx.Optimizer.SearchPolicy
  alias DSEx.Optimizer.SearchPolicy.Sampling

  defstruct [:metric, candidates: 8, demos_per_candidate: 4, seed: 0]

  @option_schema [
    candidates: [type: :non_neg_integer, default: 8],
    demos_per_candidate: [type: :non_neg_integer, default: 4],
    seed: [type: :integer, default: 0]
  ]

  def new(metric, opts \\ []) do
    DSEx.FunctionContract.validate!(
      metric,
      [2, 3],
      "DSEx.Optimizer.RandomSearch.new/2",
      "metric"
    )

    opts = DSEx.Options.validate!(opts, @option_schema, "DSEx.Optimizer.RandomSearch.new/2")

    %__MODULE__{
      metric: metric,
      candidates: opts[:candidates],
      demos_per_candidate: opts[:demos_per_candidate],
      seed: opts[:seed]
    }
  end

  def compile(%__MODULE__{} = optimizer, program, trainset, devset) do
    policy = SearchPolicy.new(Sampling, seed: optimizer.seed)

    {sampled_results, baseline_result, policy} =
      case new_evaluator(devset, optimizer.metric) do
        {:ok, evaluator} ->
          {sampled_results, policy} =
            optimizer.candidates
            |> candidate_indices()
            |> Enum.map_reduce(policy, fn index, policy ->
              build_and_evaluate_candidate(
                index,
                evaluator,
                program,
                trainset,
                optimizer,
                policy
              )
            end)

          {sampled_results,
           evaluate_candidate(evaluator, program, %{index: :baseline, demos: []}), policy}

        {:error, error} ->
          sampled_results =
            optimizer.candidates
            |> candidate_indices()
            |> Enum.map(fn index -> {:error, error, %{index: index, demos: []}} end)

          {sampled_results, {:error, error, %{index: :baseline, demos: []}}, policy}
      end

    {best_score, best, report_candidates, errors, metadata} =
      summarize(sampled_results ++ [baseline_result], program)

    policy_dump = SearchPolicy.dump(policy)

    metadata =
      Map.merge(metadata, %{
        search_policy_id: policy_dump["policy"],
        seed: optimizer.seed,
        search_policy: policy_dump
      })

    best
    |> DSEx.Optimizer.Report.attach(
      DSEx.Optimizer.Report.new(%{
        optimizer: :random_search,
        best_score: best_score,
        candidate_count: sampled_success_count(report_candidates),
        candidates: report_candidates,
        errors: errors,
        metadata: metadata
      })
    )
  end

  defp new_evaluator(devset, metric) do
    {:ok, DSEx.Evaluate.new(devset, metric)}
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp build_and_evaluate_candidate(
         index,
         evaluator,
         program,
         trainset,
         optimizer,
         policy
       ) do
    {shuffled, policy} = SearchPolicy.suggest(policy, {:shuffle, Enum.to_list(trainset)})
    demos = Enum.take(shuffled, optimizer.demos_per_candidate)

    candidate =
      DSEx.Optimizer.LabeledFewShot.compile(
        %DSEx.Optimizer.LabeledFewShot{k: optimizer.demos_per_candidate},
        program,
        demos
      )

    {evaluate_candidate(evaluator, candidate, %{index: index, demos: demos}), policy}
  rescue
    error -> {{:error, error, %{index: index, demos: []}}, policy}
  catch
    kind, reason -> {{:error, {kind, reason}, %{index: index, demos: []}}, policy}
  end

  defp evaluate_candidate(evaluator, candidate, metadata) do
    DSEx.Telemetry.span(
      [:dsex, :optimizer, :trial],
      Map.merge(%{optimizer: :random_search}, metadata),
      fn ->
        result = DSEx.Evaluate.run(evaluator, candidate)
        {:ok, result.score, candidate, metadata}
      end
    )
  rescue
    error -> {:error, error, metadata}
  catch
    kind, reason -> {:error, {kind, reason}, metadata}
  end

  defp summarize(results, fallback) do
    successes =
      Enum.flat_map(results, fn
        {:ok, score, candidate, metadata} -> [{score, candidate, metadata}]
        _ -> []
      end)

    errors =
      Enum.flat_map(results, fn
        {:error, error, metadata} -> [%{error: error_message(error), metadata: metadata}]
        _ -> []
      end)

    report_candidates =
      Enum.map(successes, fn {score, _candidate, metadata} -> Map.put(metadata, :score, score) end)

    case successes do
      [] ->
        {nil, fallback, [], errors, %{status: :all_candidates_failed}}

      _ ->
        {best_score, best, _metadata} =
          Enum.max_by(successes, fn {score, _candidate, _metadata} -> score end)

        metadata = %{
          status: :ok,
          baseline_score: baseline_score(report_candidates),
          successful_candidates: length(report_candidates)
        }

        {best_score, best, report_candidates, errors, metadata}
    end
  end

  defp candidate_indices(count) when count > 0, do: 1..count
  defp candidate_indices(_count), do: []

  defp sampled_success_count(candidates),
    do: Enum.count(candidates, &(&1.index != :baseline))

  defp baseline_score(candidates) do
    candidates
    |> Enum.find(&(&1.index == :baseline))
    |> case do
      nil -> nil
      candidate -> candidate.score
    end
  end

  defp error_message(%_{} = exception), do: Exception.message(exception)
  defp error_message(error), do: inspect(error)
end
