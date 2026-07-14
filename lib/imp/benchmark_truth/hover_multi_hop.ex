defmodule Imp.BenchmarkTruth.HoverMultiHop do
  @moduledoc false

  @behaviour Imp.Module

  alias Imp.BenchmarkTruth.HoverBM25
  alias Imp.BenchmarkTruth.HoverBM25.UpstreamPython
  alias Imp.Predict.ChainOfThought

  @components [:summarize1, :create_query_hop2, :summarize2, :create_query_hop3]

  defstruct [
    :retriever,
    :summarize1,
    :create_query_hop2,
    :summarize2,
    :create_query_hop3,
    :retrieval_source,
    k: 7,
    final_k: 10
  ]

  @doc "Builds HoVer over verified Wiki17 retrieval provenance."
  def new(lm, retrieval, opts \\ []) do
    upstream? = Keyword.get(opts, :upstream_python, false)

    retriever =
      if upstream? do
        UpstreamPython.new(retrieval,
          k: 7,
          python: Keyword.get(opts, :python, System.get_env("IMP_GEPA_PYTHON") || "python3")
        )
      else
        HoverBM25.new(retrieval, k: 7)
      end

    from_retriever(lm, retriever)
  end

  @doc false
  def from_retriever(lm, retriever) do
    %__MODULE__{
      retriever: retriever,
      summarize1: predictor("claim, passages -> summary", lm, :summarize1),
      create_query_hop2: predictor("claim, summary_1 -> query", lm, :create_query_hop2),
      summarize2: predictor("claim, context, passages -> summary", lm, :summarize2),
      create_query_hop3:
        predictor("claim, summary_1, summary_2 -> query", lm, :create_query_hop3),
      retrieval_source: if(is_map(retriever), do: Map.get(retriever, :metadata), else: :injected)
    }
  end

  @doc false
  def optimizer_predictors(%__MODULE__{} = program) do
    Enum.map(@components, fn name -> {name, Map.fetch!(program, name).predict} end)
  end

  @doc false
  def update_optimizer_predictor(%__MODULE__{} = program, name, update)
      when name in @components and is_function(update, 1) do
    component = Map.fetch!(program, name)
    Map.put(program, name, %{component | predict: update.(component.predict)})
  end

  @impl true
  def call(%__MODULE__{} = program, inputs) when is_map(inputs) or is_list(inputs) do
    with {:ok, claim} <- claim(inputs),
         {:ok, hop1_docs} <- retrieve(program.retriever, claim, program.k, :hop1),
         {:ok, summary_1} <-
           predict(program.summarize1, %{claim: claim, passages: hop1_docs}, :summarize1),
         {:ok, hop2_query} <-
           predict(
             program.create_query_hop2,
             %{claim: claim, summary_1: summary_1},
             :create_query_hop2
           ),
         {:ok, hop2_docs} <- retrieve(program.retriever, hop2_query, program.k, :hop2),
         {:ok, summary_2} <-
           predict(
             program.summarize2,
             %{claim: claim, context: summary_1, passages: hop2_docs},
             :summarize2
           ),
         {:ok, hop3_query} <-
           predict(
             program.create_query_hop3,
             %{claim: claim, summary_1: summary_1, summary_2: summary_2},
             :create_query_hop3
           ),
         {:ok, hop3_docs} <- retrieve(program.retriever, hop3_query, program.final_k, :hop3) do
      {:ok, Imp.Prediction.new(retrieved_docs: hop1_docs ++ hop2_docs ++ hop3_docs)}
    end
  end

  def call(%__MODULE__{}, inputs),
    do:
      {:error,
       {:invalid_hover_inputs, "expected a map or field pair list, got: #{inspect(inputs)}"}}

  defp predictor(signature, lm, name) do
    ChainOfThought.new(signature, lm: lm, metadata: %{optimizer_predictor_name: name})
  end

  defp claim(inputs) do
    inputs = Map.new(inputs)

    case Map.get(inputs, :claim, Map.get(inputs, "claim")) do
      claim when is_binary(claim) and claim != "" -> {:ok, claim}
      _other -> {:error, {:missing_input_fields, [:claim]}}
    end
  rescue
    _error -> {:error, {:invalid_hover_inputs, "expected inputs as {key, value} pairs"}}
  end

  defp retrieve(%UpstreamPython{} = retriever, query, k, hop) do
    retriever
    |> Map.put(:k, k)
    |> UpstreamPython.search(query)
    |> normalize_retrieval(hop, k)
  end

  defp retrieve(%HoverBM25{} = retriever, query, k, hop) do
    docs =
      retriever
      |> Map.put(:k, k)
      |> HoverBM25.retrieve(query)
      |> Enum.map(fn doc -> "#{doc.title} | #{doc.text}" end)

    normalize_retrieval({:ok, docs}, hop, k)
  end

  defp retrieve(retriever, query, k, hop) do
    retriever
    |> Imp.Retrieve.retrieve(query, k: k)
    |> normalize_retrieval(hop, k)
  end

  defp normalize_retrieval({:ok, docs}, hop, k) when is_list(docs) do
    docs
    |> Enum.take(k)
    |> Enum.reduce_while({:ok, []}, fn doc, {:ok, passages} ->
      case passage(doc) do
        {:ok, passage} -> {:cont, {:ok, [passage | passages]}}
        {:error, reason} -> {:halt, {:error, {:hover_multi_hop_failed, hop, reason}}}
      end
    end)
    |> case do
      {:ok, passages} -> {:ok, Enum.reverse(passages)}
      error -> error
    end
  end

  defp normalize_retrieval({:error, reason}, hop, _k),
    do: {:error, {:hover_multi_hop_failed, hop, reason}}

  defp normalize_retrieval(other, hop, _k),
    do: {:error, {:hover_multi_hop_failed, hop, {:invalid_retrieval_result, other}}}

  defp passage(passage) when is_binary(passage), do: {:ok, passage}

  defp passage(doc) when is_map(doc) do
    title = Map.get(doc, :title, Map.get(doc, "title"))
    text = Map.get(doc, :text, Map.get(doc, "text"))

    cond do
      is_binary(title) and is_binary(text) -> {:ok, "#{title} | #{text}"}
      is_binary(text) -> {:ok, text}
      true -> {:error, {:invalid_hover_passage, doc}}
    end
  end

  defp passage(other), do: {:error, {:invalid_hover_passage, other}}

  defp predict(component, inputs, stage) do
    output = if(stage in [:summarize1, :summarize2], do: :summary, else: :query)

    case Imp.Module.call(component, inputs) do
      {:ok, prediction} ->
        case Imp.Prediction.get(prediction, output) do
          value when is_binary(value) -> {:ok, value}
          value -> {:error, {:hover_multi_hop_failed, stage, {:invalid_output, output, value}}}
        end

      {:error, reason} ->
        {:error, {:hover_multi_hop_failed, stage, reason}}
    end
  end
end
