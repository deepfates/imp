defmodule DSEx.BenchmarkTruth.HoverMultiHop do
  @moduledoc false

  @behaviour DSEx.Module

  defstruct [
    :lm,
    :retriever,
    hops: 3,
    docs_per_hop: 8,
    instruction: "Generate focused HoVer evidence search queries."
  ]

  def new(lm, retrieval, opts \\ []) do
    retriever =
      if Keyword.get(opts, :upstream_python, false) do
        DSEx.BenchmarkTruth.HoverBM25.UpstreamPython.new(retrieval,
          k: Keyword.get(opts, :docs_per_hop, 8)
        )
      else
        DSEx.BenchmarkTruth.HoverBM25.new(retrieval, k: Keyword.get(opts, :docs_per_hop, 8))
      end

    %__MODULE__{
      lm: lm,
      retriever: retriever,
      hops: Keyword.get(opts, :hops, 3),
      docs_per_hop: Keyword.get(opts, :docs_per_hop, 8),
      instruction:
        Keyword.get(opts, :instruction, "Generate focused HoVer evidence search queries.")
    }
  end

  def put_instruction(%__MODULE__{} = program, instruction),
    do: %{program | instruction: instruction}

  def current_instruction(%__MODULE__{instruction: instruction}), do: instruction

  @impl true
  def call(%__MODULE__{} = program, inputs) do
    claim =
      inputs
      |> Map.new()
      |> Map.get(:claim, Map.get(Map.new(inputs), "claim", ""))

    docs =
      1..program.hops
      |> Enum.reduce([], fn hop, docs ->
        query = query(program, claim, docs, hop)
        {:ok, hop_docs} = search(program.retriever, query)
        merge_docs(docs, hop_docs)
      end)

    {:ok, DSEx.Prediction.new(retrieved_docs: docs)}
  rescue
    error -> {:error, {:hover_multi_hop_failed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:hover_multi_hop_failed, {kind, reason}}}
  end

  defp query(program, claim, docs, hop) do
    prompt = """
    #{program.instruction}

    Claim:
    #{claim}

    Retrieved evidence so far:
    #{context(docs)}

    Write one concise search query for hop #{hop}. Return only the query text.
    """

    case DSEx.LM.generate(program.lm, [%{role: :user, content: prompt}], []) do
      {:ok, value} -> value |> output_text() |> clean_query(claim)
      {:error, _reason} -> claim
    end
  end

  defp search(%DSEx.BenchmarkTruth.HoverBM25.UpstreamPython{} = retriever, query) do
    DSEx.BenchmarkTruth.HoverBM25.UpstreamPython.search(retriever, query)
  end

  defp search(%DSEx.BenchmarkTruth.HoverBM25{} = retriever, query) do
    docs =
      retriever
      |> DSEx.BenchmarkTruth.HoverBM25.retrieve(query)
      |> Enum.map(fn doc -> "#{doc.title} | #{doc.text}" end)

    {:ok, docs}
  end

  defp output_text(%DSEx.Prediction{} = prediction) do
    DSEx.Prediction.get(prediction, :query) ||
      DSEx.Prediction.get(prediction, :answer) ||
      prediction |> DSEx.Prediction.to_map() |> inspect()
  end

  defp output_text(%{query: query}), do: query
  defp output_text(%{"query" => query}), do: query
  defp output_text(%{answer: answer}), do: answer
  defp output_text(%{"answer" => answer}), do: answer
  defp output_text(value), do: to_string(value)

  defp clean_query("", claim), do: claim

  defp clean_query(value, claim) do
    value
    |> String.split("\n")
    |> List.first()
    |> to_string()
    |> String.trim()
    |> String.trim_leading("\"")
    |> String.trim_trailing("\"")
    |> case do
      "" -> claim
      query -> query
    end
  end

  defp context([]), do: "None."

  defp context(docs) do
    docs
    |> Enum.take(6)
    |> Enum.map_join("\n", &String.slice(&1, 0, 500))
  end

  defp merge_docs(existing, new_docs) do
    (existing ++ new_docs)
    |> Enum.uniq()
  end
end
