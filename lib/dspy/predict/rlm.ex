defmodule DSPy.Predict.RLM do
  @moduledoc "Retrieve-then-generate module for retrieval language-model workflows."

  @behaviour DSPy.Module

  defstruct [:retriever, :predict, k: 3, context_field: :context, query_field: :question]

  def new(signature, retriever, opts \\ []) do
    %__MODULE__{
      retriever: retriever,
      predict: DSPy.Predict.Predict.new(signature, opts),
      k: Keyword.get(opts, :k, 3),
      context_field: Keyword.get(opts, :context_field, :context),
      query_field: Keyword.get(opts, :query_field, :question)
    }
  end

  @impl true
  def call(%__MODULE__{} = rlm, inputs) do
    inputs = Map.new(inputs)
    query = Map.get(inputs, rlm.query_field) || inputs |> Map.values() |> Enum.join(" ")

    with {:ok, docs} <- DSPy.Retrieve.retrieve(rlm.retriever, query, k: rlm.k) do
      context =
        docs
        |> Enum.map(&(Map.get(&1, :text) || Map.get(&1, "text") || inspect(&1)))
        |> Enum.join("\n")

      DSPy.Predict.Predict.call(rlm.predict, Map.put(inputs, rlm.context_field, context))
    end
  end
end
