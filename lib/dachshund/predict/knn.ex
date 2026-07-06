defmodule Dachshund.Predict.KNN do
  @moduledoc "Callable KNN predictor over examples."

  defstruct [:retriever]

  def new(k, trainset, opts \\ []) do
    field = Keyword.get(opts, :field, :question)
    %__MODULE__{retriever: Dachshund.Retrievers.KNN.new(trainset, k: k, field: field)}
  end

  def call(%__MODULE__{retriever: retriever}, inputs) do
    query =
      inputs
      |> Map.new()
      |> Map.values()
      |> Enum.join(" ")

    retriever |> Dachshund.Retrievers.KNN.call(query)
  end
end
