defmodule Imp.BenchmarkTruth.HotpotMultiHop do
  @moduledoc false

  @behaviour Imp.Module

  alias Imp.BenchmarkTruth.HoverBM25.UpstreamPython
  alias Imp.Predict.ChainOfThought

  @k 7
  @upstream_source %{
    "kind" => "bm25s_wiki_abstracts_2017",
    "source_url" => "https://huggingface.co/dspy/cache/resolve/main/wiki.abstracts.2017.tar.gz",
    "implementation" => "upstream_python_bm25s",
    "ranking_parity" => "source_exact"
  }
  @component_names [:summarize1, :create_query_hop2, :summarize2, :final_answer]

  defstruct [
    :retriever,
    :summarize1,
    :create_query_hop2,
    :summarize2,
    :final_answer,
    :retrieval_source,
    k: @k
  ]

  @doc "Builds the program around any retriever supported by `Imp.Retrieve`."
  def new(lm, retriever) do
    %__MODULE__{
      retriever: retriever,
      summarize1: predictor("question, passages -> summary", lm, :summarize1),
      create_query_hop2: predictor("question, summary_1 -> query", lm, :create_query_hop2),
      summarize2: predictor("question, context, passages -> summary", lm, :summarize2),
      final_answer: predictor("question, summary_1, summary_2 -> answer", lm, :final_answer),
      retrieval_source: :injected
    }
  end

  @doc """
  Builds the source-faithful integration program.

  Pass either an existing `HoverBM25.UpstreamPython` retriever or a HoVer
  retrieval provenance map containing the pinned corpus/index paths and
  checksums. The map form accepts the `:python` option used by the existing
  adapter. Construction raises when exact retrieval is unavailable.
  """
  def integration(lm, %UpstreamPython{} = retriever) do
    validate_exact_retriever!(retriever)
    %{new(lm, retriever) | retrieval_source: retriever.metadata}
  end

  def integration(lm, retrieval) when is_map(retrieval), do: integration(lm, retrieval, [])

  def integration(_lm, _retrieval) do
    raise ArgumentError,
          "exact Hotpot retrieval unavailable; provide HoVer BM25s retrieval provenance"
  end

  def integration(lm, retrieval, opts) when is_map(retrieval) and is_list(opts) do
    unless Keyword.keyword?(opts) do
      raise ArgumentError, "HotpotMultiHop.integration/3 expects keyword options"
    end

    validate_retrieval_provenance!(retrieval)
    retriever = UpstreamPython.new(retrieval, Keyword.take(opts, [:python]) ++ [k: @k])
    integration(lm, retriever)
  end

  def integration(_lm, _retrieval, _opts) do
    raise ArgumentError,
          "HotpotMultiHop.integration/3 expects a retrieval provenance map and keyword options"
  end

  @doc "Returns the source identity required by the exact Hotpot integration."
  def upstream_retrieval_source, do: @upstream_source

  @doc false
  @impl true
  def optimizer_predictors(%__MODULE__{} = program) do
    Enum.map(@component_names, fn name ->
      {name, Map.fetch!(program, name).predict}
    end)
  end

  @doc false
  @impl true
  def update_optimizer_predictor(%__MODULE__{} = program, name, update)
      when name in @component_names and is_function(update, 1) do
    component = Map.fetch!(program, name)
    Map.put(program, name, %{component | predict: update.(component.predict)})
  end

  @impl true
  def call(%__MODULE__{} = program, inputs) when is_map(inputs) or is_list(inputs) do
    with {:ok, question} <- question(inputs),
         {:ok, hop1_docs} <- retrieve(program, question, :hop1),
         {:ok, summary_1} <-
           predict(program.summarize1, %{question: question, passages: hop1_docs}, :summarize1),
         {:ok, hop2_query} <-
           predict(
             program.create_query_hop2,
             %{question: question, summary_1: summary_1},
             :create_query_hop2
           ),
         {:ok, hop2_docs} <- retrieve(program, hop2_query, :hop2),
         {:ok, summary_2} <-
           predict(
             program.summarize2,
             %{question: question, context: summary_1, passages: hop2_docs},
             :summarize2
           ),
         {:ok, answer} <-
           predict(
             program.final_answer,
             %{question: question, summary_1: summary_1, summary_2: summary_2},
             :final_answer
           ) do
      {:ok, Imp.Prediction.new(answer: answer, hop1_docs: hop1_docs, hop2_docs: hop2_docs)}
    end
  end

  def call(%__MODULE__{}, inputs),
    do:
      {:error,
       {:invalid_hotpot_inputs, "expected a map or field pair list, got: #{inspect(inputs)}"}}

  defp predictor(signature, lm, name) do
    ChainOfThought.new(signature,
      lm: lm,
      metadata: %{optimizer_predictor_name: name}
    )
  end

  defp question(inputs) do
    inputs = Map.new(inputs)

    case Map.get(inputs, :question, Map.get(inputs, "question")) do
      question when is_binary(question) and question != "" -> {:ok, question}
      _other -> {:error, {:missing_input_fields, [:question]}}
    end
  rescue
    _error -> {:error, {:invalid_hotpot_inputs, "expected inputs as {key, value} pairs"}}
  end

  defp retrieve(program, query, hop) do
    result =
      case program.retriever do
        %UpstreamPython{} = retriever -> UpstreamPython.search(retriever, query)
        retriever -> Imp.Retrieve.retrieve(retriever, query, k: program.k)
      end

    case result do
      {:ok, docs} -> normalize_passages(docs, program.k, hop)
      {:error, reason} -> {:error, {:hotpot_multi_hop_failed, hop, reason}}
    end
  end

  defp normalize_passages(docs, k, hop) do
    docs
    |> Enum.take(k)
    |> Enum.reduce_while({:ok, []}, fn doc, {:ok, passages} ->
      case passage(doc) do
        {:ok, passage} -> {:cont, {:ok, [passage | passages]}}
        {:error, reason} -> {:halt, {:error, {:hotpot_multi_hop_failed, hop, reason}}}
      end
    end)
    |> case do
      {:ok, passages} -> {:ok, Enum.reverse(passages)}
      error -> error
    end
  end

  defp passage(text) when is_binary(text), do: {:ok, text}

  defp passage(doc) when is_map(doc) do
    title = Map.get(doc, :title, Map.get(doc, "title"))

    text =
      Map.get(
        doc,
        :long_text,
        Map.get(doc, "long_text", Map.get(doc, :text, Map.get(doc, "text")))
      )

    case {title, text} do
      {title, text} when is_binary(title) and is_binary(text) ->
        {:ok, title <> " | " <> text}

      {_title, text} when is_binary(text) ->
        {:ok, text}

      _other ->
        {:error, {:invalid_hotpot_passage, doc}}
    end
  end

  defp validate_retrieval_provenance!(retrieval) do
    expected = Map.take(@upstream_source, ["kind", "source_url"])
    actual = Map.take(retrieval, ["kind", "source_url"])

    unless actual == expected and retrieval["status"] == "present" do
      raise ArgumentError,
            "HotpotMultiHop requires present HoVer wiki.abstracts.2017 BM25s provenance"
    end

    corpus_path = retrieval["corpus_path"]
    index_path = retrieval["index_path"]

    expected_index =
      if is_binary(corpus_path),
        do: corpus_path |> Path.dirname() |> Path.join("bm25s_retriever") |> Path.expand()

    unless is_binary(corpus_path) and
             String.ends_with?(
               Path.expand(corpus_path),
               Path.join(["gepa_artifact", "benchmarks", "hover", "wiki.abstracts.2017.jsonl"])
             ) and is_binary(index_path) and Path.expand(index_path) == expected_index do
      raise ArgumentError,
            "HotpotMultiHop requires the pinned HoVer corpus and bm25s_retriever paths"
    end
  end

  defp validate_exact_retriever!(%UpstreamPython{
         k: @k,
         gepa_root: gepa_root,
         python: python,
         metadata: metadata
       }) do
    required = Map.take(@upstream_source, ["implementation", "ranking_parity"])

    unless Map.take(metadata, ["implementation", "ranking_parity"]) == required do
      raise ArgumentError, "HotpotMultiHop requires source-exact upstream Python BM25s"
    end

    hover_dir = Path.join(gepa_root, "gepa_artifact/benchmarks/hover")

    unless File.regular?(Path.join(hover_dir, "wiki.abstracts.2017.jsonl")) and
             File.dir?(Path.join(hover_dir, "bm25s_retriever")) and python_available?(python) do
      raise ArgumentError,
            "exact Hotpot HoVer BM25s retriever unavailable: corpus, index, or Python missing"
    end

    :ok
  end

  defp validate_exact_retriever!(%UpstreamPython{}) do
    raise ArgumentError, "HotpotMultiHop source-exact retriever must use k=7"
  end

  defp python_available?(python) when is_binary(python) do
    if Path.type(python) == :absolute,
      do: File.regular?(python),
      else: not is_nil(System.find_executable(python))
  end

  defp python_available?(_python), do: false

  defp predict(component, inputs, stage) do
    output = stage_output(stage)

    case Imp.Module.call(component, inputs) do
      {:ok, prediction} ->
        case Imp.Prediction.get(prediction, output) do
          value when is_binary(value) -> {:ok, value}
          value -> {:error, {:hotpot_multi_hop_failed, stage, {:invalid_output, output, value}}}
        end

      {:error, reason} ->
        {:error, {:hotpot_multi_hop_failed, stage, reason}}
    end
  end

  defp stage_output(:summarize1), do: :summary
  defp stage_output(:create_query_hop2), do: :query
  defp stage_output(:summarize2), do: :summary
  defp stage_output(:final_answer), do: :answer
end
