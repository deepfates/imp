defmodule DSEx.Optimizer.Report do
  @moduledoc "Optimizer candidate history and audit metadata."

  defstruct optimizer: nil,
            best_score: nil,
            candidate_count: 0,
            candidates: [],
            errors: [],
            metadata: %{}

  def new(attrs \\ %{}) do
    attrs = Map.new(attrs)

    %__MODULE__{
      optimizer: Map.get(attrs, :optimizer),
      best_score: Map.get(attrs, :best_score),
      candidate_count: Map.get(attrs, :candidate_count, 0),
      candidates: Map.get(attrs, :candidates, []),
      errors: Map.get(attrs, :errors, []),
      metadata: Map.get(attrs, :metadata, %{})
    }
  end

  def attach(program, %__MODULE__{} = report),
    do: put_metadata(program, :optimizer_report, report)

  def fetch(program), do: get_metadata(program, :optimizer_report)

  defp put_metadata(%DSEx.Predict.Predict{metadata: metadata} = program, key, value) do
    %{program | metadata: Map.put(metadata, key, value)}
  end

  defp put_metadata(%DSEx.Predict.ChainOfThought{predict: predict} = program, key, value) do
    %{program | predict: put_metadata(predict, key, value)}
  end

  defp put_metadata(program, _key, _value), do: program

  defp get_metadata(%DSEx.Predict.Predict{metadata: metadata}, key),
    do: Map.get(metadata, key)

  defp get_metadata(%DSEx.Predict.ChainOfThought{predict: predict}, key),
    do: get_metadata(predict, key)

  defp get_metadata(_program, _key), do: nil
end
