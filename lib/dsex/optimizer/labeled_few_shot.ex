defmodule DSEx.Optimizer.LabeledFewShot do
  @moduledoc """
  Compile a predictor by attaching the first labeled examples as demos.

  This optimizer does not call the language model or score candidates. It is the
  deterministic few-shot baseline: take up to `k` examples from the trainset and
  attach them as demonstrations. The compiled program carries an optimizer
  report that records the selected examples.
  """

  defstruct k: 4

  def new(opts \\ []), do: %__MODULE__{k: non_negative_integer(Keyword.get(opts, :k, 4))}

  def compile(%__MODULE__{k: k}, program, trainset) do
    {demos, errors} = take_demos(trainset, k)

    program
    |> put_demos(demos)
    |> DSEx.Optimizer.Report.attach(
      DSEx.Optimizer.Report.new(%{
        optimizer: :labeled_few_shot,
        candidate_count: length(demos),
        candidates:
          demos
          |> Enum.with_index()
          |> Enum.map(fn {example, index} ->
            %{index: index, example: example, selected?: true}
          end),
        errors: errors,
        metadata: %{
          requested_k: k,
          selected_count: length(demos)
        }
      })
    )
  end

  defp take_demos(trainset, k) do
    {Enum.take(trainset, k), []}
  rescue
    error -> {[], [%{stage: :trainset, reason: error_message(error)}]}
  catch
    kind, reason -> {[], [%{stage: :trainset, reason: error_message({kind, reason})}]}
  end

  defp put_demos(%DSEx.Predict.Predict{} = program, demos),
    do: DSEx.Predict.Predict.with_demos(program, demos)

  defp put_demos(%DSEx.Predict.ChainOfThought{predict: predict} = program, demos),
    do: %{program | predict: DSEx.Predict.Predict.with_demos(predict, demos)}

  defp put_demos(program, _demos), do: program

  defp non_negative_integer(value) when is_integer(value) and value > 0, do: value
  defp non_negative_integer(_value), do: 0

  defp error_message(%_{} = exception), do: Exception.message(exception)
  defp error_message(error), do: inspect(error)
end
