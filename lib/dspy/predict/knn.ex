defmodule DSPy.Predict.KNN do
  @moduledoc "Callable KNN predictor over examples."

  defstruct [:retriever]

  def new(k, trainset, opts \\ []) do
    field = Keyword.get(opts, :field, :question)
    %__MODULE__{retriever: DSPy.Retrievers.KNN.new(trainset, k: k, field: field)}
  end

  def call(%__MODULE__{retriever: retriever}, inputs) do
    query =
      inputs
      |> Map.new()
      |> Map.values()
      |> Enum.join(" ")

    retriever |> DSPy.Retrievers.KNN.call(query)
  end
end
