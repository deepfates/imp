defmodule Dachshund.Evaluate.Result do
  @moduledoc "Evaluation result with aggregate score and per-example rows."

  defstruct [:score, rows: []]
end

defmodule Dachshund.Evaluate do
  @moduledoc "Evaluate a program against examples and a metric."

  defstruct [:devset, :metric, display_progress: false]

  def new(devset, metric, opts \\ []) when is_function(metric, 2) or is_function(metric, 3) do
    %__MODULE__{
      devset: devset,
      metric: metric,
      display_progress: Keyword.get(opts, :display_progress, false)
    }
  end

  def run(%__MODULE__{} = evaluator, program) do
    rows =
      evaluator.devset
      |> Enum.with_index()
      |> Enum.map(fn {example, index} ->
        inputs = example |> Dachshund.Example.inputs() |> Dachshund.Example.to_map()

        case call_program(program, inputs) do
          {:ok, prediction} ->
            score = score(evaluator.metric, example, prediction)
            %{index: index, example: example, prediction: prediction, score: score, error: nil}

          {:error, reason} ->
            %{index: index, example: example, prediction: nil, score: 0.0, error: reason}
        end
      end)

    %Dachshund.Evaluate.Result{score: average(rows), rows: rows}
  end

  defp call_program(%module{} = program, inputs) do
    cond do
      function_exported?(module, :call, 2) -> module.call(program, inputs)
      true -> {:error, {:not_a_program, module}}
    end
  end

  defp score(metric, example, prediction) when is_function(metric, 2),
    do: metric.(example, prediction)

  defp score(metric, example, prediction) when is_function(metric, 3),
    do: metric.(example, prediction, nil)

  defp average([]), do: 0.0
  defp average(rows), do: Enum.sum(Enum.map(rows, &numeric_score/1)) / length(rows)
  defp numeric_score(%{score: true}), do: 1.0
  defp numeric_score(%{score: false}), do: 0.0
  defp numeric_score(%{score: score}) when is_number(score), do: score
end
