defmodule Dachshund.Optimizer.RandomSearch do
  @moduledoc "Try random demo subsets and keep the program with the best dev score."

  defstruct [:metric, candidates: 8, demos_per_candidate: 4]

  def new(metric, opts \\ []) do
    %__MODULE__{
      metric: metric,
      candidates: Keyword.get(opts, :candidates, 8),
      demos_per_candidate: Keyword.get(opts, :demos_per_candidate, 4)
    }
  end

  def compile(%__MODULE__{} = optimizer, program, trainset, devset) do
    evaluator = Dachshund.Evaluate.new(devset, optimizer.metric)

    results =
      1..optimizer.candidates
      |> Enum.map(fn index ->
        demos = trainset |> Enum.shuffle() |> Enum.take(optimizer.demos_per_candidate)

        candidate =
          Dachshund.Optimizer.LabeledFewShot.compile(
            %Dachshund.Optimizer.LabeledFewShot{k: optimizer.demos_per_candidate},
            program,
            demos
          )

        evaluate_candidate(evaluator, candidate, %{index: index, demos: demos})
      end)

    {best_score, best, report_candidates, errors} = summarize(results)

    best
    |> Dachshund.Optimizer.Report.attach(
      Dachshund.Optimizer.Report.new(%{
        optimizer: :random_search,
        best_score: best_score,
        candidate_count: length(report_candidates),
        candidates: report_candidates,
        errors: errors
      })
    )
  end

  defp evaluate_candidate(evaluator, candidate, metadata) do
    result = Dachshund.Evaluate.run(evaluator, candidate)
    {:ok, result.score, candidate, metadata}
  rescue
    error -> {:error, error, metadata}
  end

  defp summarize(results) do
    successes =
      Enum.flat_map(results, fn
        {:ok, score, candidate, metadata} -> [{score, candidate, metadata}]
        _ -> []
      end)

    errors =
      Enum.flat_map(results, fn
        {:error, error, metadata} -> [%{error: Exception.message(error), metadata: metadata}]
        _ -> []
      end)

    {best_score, best, _metadata} =
      Enum.max_by(successes, fn {score, _candidate, _metadata} -> score end)

    report_candidates =
      Enum.map(successes, fn {score, _candidate, metadata} -> Map.put(metadata, :score, score) end)

    {best_score, best, report_candidates, errors}
  end
end
