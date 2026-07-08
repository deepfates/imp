defmodule DSEx.Predict.MultiChainComparison do
  @moduledoc "Compare multiple chain-of-thought completions and ask a predictor for the final output."

  @behaviour DSEx.Module

  defstruct [:predict, :last_key, m: 3]

  def new(signature, opts \\ []) do
    signature = DSEx.Signature.ensure(signature)
    last_key = signature |> DSEx.Signature.output_names() |> List.last()
    m = positive_m!(Keyword.get(opts, :m, Keyword.get(opts, :M, 3)))

    comparison_signature =
      Enum.reduce(1..m, signature, fn index, acc ->
        DSEx.Signature.extend(
          acc,
          [%{name: :"reasoning_attempt_#{index}", desc: "Reasoning attempt"}],
          :input
        )
      end)
      |> DSEx.Signature.prepend_output(%{name: :rationale, desc: "Corrected reasoning"})

    %__MODULE__{
      predict: DSEx.Predict.Predict.new(comparison_signature, opts),
      last_key: last_key,
      m: m
    }
  end

  @impl true
  def call(%__MODULE__{} = mcc, inputs) do
    inputs = Map.new(inputs)
    completions = Map.get(inputs, :completions, Map.get(inputs, "completions", []))

    cond do
      not is_list(completions) ->
        {:error, {:invalid_completions, inspect(completions)}}

      length(completions) != mcc.m ->
        {:error, {:wrong_completion_count, expected: mcc.m, got: length(completions)}}

      true ->
        attempts =
          completions
          |> Enum.with_index(1)
          |> Map.new(fn {completion, index} ->
            rationale =
              completion_value(completion, :rationale) || completion_value(completion, :reasoning) ||
                ""

            answer = completion_value(completion, mcc.last_key) || ""
            {:"reasoning_attempt_#{index}", "I tried #{rationale}; prediction #{answer}"}
          end)

        inputs =
          inputs
          |> Map.drop([:completions, "completions"])
          |> Map.merge(attempts)

        DSEx.Predict.Predict.call(mcc.predict, inputs)
    end
  end

  defp positive_m!(m) when is_integer(m) and m > 0, do: m

  defp positive_m!(m) do
    raise ArgumentError,
          "MultiChainComparison expects :m to be a positive integer, got: #{inspect(m)}"
  end

  defp completion_value(%DSEx.Prediction{} = prediction, field),
    do: DSEx.Prediction.get(prediction, field)

  defp completion_value(completion, field) when is_map(completion) do
    Map.get(completion, field) || Map.get(completion, to_string(field))
  end

  defp completion_value(_completion, _field), do: nil
end
