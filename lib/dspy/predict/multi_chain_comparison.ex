defmodule DSPy.Predict.MultiChainComparison do
  @moduledoc "Compare multiple chain-of-thought completions and ask a predictor for the final output."

  @behaviour DSPy.Module

  defstruct [:predict, :last_key, m: 3]

  def new(signature, opts \\ []) do
    signature = DSPy.Signature.ensure(signature)
    last_key = signature |> DSPy.Signature.output_names() |> List.last()
    m = Keyword.get(opts, :m, Keyword.get(opts, :M, 3))

    comparison_signature =
      1..m
      |> Enum.reduce(signature, fn index, acc ->
        DSPy.Signature.extend(
          acc,
          [%{name: :"reasoning_attempt_#{index}", desc: "Reasoning attempt"}],
          :input
        )
      end)
      |> DSPy.Signature.prepend_output(%{name: :rationale, desc: "Corrected reasoning"})

    %__MODULE__{
      predict: DSPy.Predict.Predict.new(comparison_signature, opts),
      last_key: last_key,
      m: m
    }
  end

  @impl true
  def call(%__MODULE__{} = mcc, inputs) do
    completions = Map.get(Map.new(inputs), :completions, [])

    if length(completions) != mcc.m do
      {:error, {:wrong_completion_count, expected: mcc.m, got: length(completions)}}
    else
      attempts =
        completions
        |> Enum.with_index(1)
        |> Map.new(fn {completion, index} ->
          rationale = Map.get(completion, :rationale) || Map.get(completion, :reasoning) || ""
          answer = Map.get(completion, mcc.last_key) || ""
          {:"reasoning_attempt_#{index}", "I tried #{rationale}; prediction #{answer}"}
        end)

      inputs = inputs |> Map.new() |> Map.drop([:completions]) |> Map.merge(attempts)
      DSPy.Predict.Predict.call(mcc.predict, inputs)
    end
  end
end
