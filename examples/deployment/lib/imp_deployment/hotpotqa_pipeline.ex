defmodule ImpDeployment.HotPotQAPipeline do
  @moduledoc """
  Four-stage, row-local HotPotQA program used by the deployment example.

  The caller supplies the question and that row's distractor context. The
  program retrieves a first set of passages, summarizes them, writes a second
  query, retrieves again, summarizes the new evidence, and answers. The gold
  answer is never a program input.
  """

  @behaviour Imp.Module

  @predictor_names [:summarize1, :create_query_hop2, :summarize2, :final_answer]

  defstruct @predictor_names ++ [k: 4]

  def new(opts \\ []) when is_list(opts) do
    k = Keyword.get(opts, :k, 4)
    adapter = Keyword.get(opts, :adapter, Imp.Adapter.Chat)

    unless is_integer(k) and k > 0 do
      raise ArgumentError, "k must be a positive integer"
    end

    %__MODULE__{
      summarize1:
        predictor(
          "question, passages -> summary_1",
          "Summarize the passages that help answer the question. Preserve names and relations.",
          adapter
        ),
      create_query_hop2:
        predictor(
          "question, summary_1 -> query_2",
          "Write a focused second-hop search query for the missing fact.",
          adapter
        ),
      summarize2:
        predictor(
          "question, summary_1, passages -> summary_2",
          "Combine the first summary with the new passages into the evidence needed to answer.",
          adapter
        ),
      final_answer:
        predictor(
          "question, summary_1, summary_2 -> answer",
          "Answer with only the shortest supported answer span.",
          adapter
        ),
      k: k
    }
  end

  @impl true
  def optimizer_predictors(program),
    do: Enum.map(@predictor_names, &{&1, Map.fetch!(program, &1)})

  @impl true
  def update_optimizer_predictor(program, name, update)
      when name in @predictor_names and is_function(update, 1),
      do: Map.update!(program, name, update)

  @impl true
  def call(program, inputs) when is_map(inputs) or is_list(inputs) do
    inputs = Map.new(inputs)
    question = fetch(inputs, :question)
    context = fetch(inputs, :context)

    with true <-
           (is_binary(question) and question != "") ||
             {:error, {:missing_input_fields, [:question]}},
         {:ok, memory} <- memory(context),
         {:ok, passages_1} <- retrieve(memory, question, program.k, :hop1),
         {:ok, summary_1} <-
           predict(program.summarize1, %{question: question, passages: passages_1}, :summary_1),
         {:ok, query_2} <-
           predict(
             program.create_query_hop2,
             %{question: question, summary_1: summary_1},
             :query_2
           ),
         {:ok, passages_2} <- retrieve(memory, query_2, program.k, :hop2),
         {:ok, summary_2} <-
           predict(
             program.summarize2,
             %{question: question, summary_1: summary_1, passages: passages_2},
             :summary_2
           ),
         {:ok, answer} <-
           predict(
             program.final_answer,
             %{question: question, summary_1: summary_1, summary_2: summary_2},
             :answer
           ) do
      {:ok,
       Imp.Prediction.new(
         answer: answer,
         summary_1: summary_1,
         query_2: query_2,
         summary_2: summary_2,
         passages_1: passages_1,
         passages_2: passages_2
       )}
    end
  rescue
    error -> {:error, {:hotpotqa_pipeline_failed, Exception.message(error)}}
  end

  def call(_program, inputs), do: {:error, {:invalid_hotpotqa_inputs, inputs}}

  defp predictor(signature, instruction, adapter) do
    config =
      [cache: false, json_fallback: false] ++
        if(adapter == Imp.Adapter.JSON, do: [native_json_schema: true], else: [])

    Imp.predict(Imp.signature(signature, instruction),
      adapter: adapter,
      config: config
    )
  end

  defp memory(%{"title" => titles, "sentences" => sentences})
       when is_list(titles) and is_list(sentences) and length(titles) == length(sentences) do
    documents =
      Enum.zip_with(titles, sentences, fn title, lines ->
        %{title: title, text: Enum.join(lines, " ")}
      end)

    {:ok, Imp.memory(documents)}
  end

  defp memory(%{title: titles, sentences: sentences}),
    do: memory(%{"title" => titles, "sentences" => sentences})

  defp memory(other), do: {:error, {:invalid_hotpotqa_context, other}}

  defp retrieve(memory, query, k, hop) do
    case Imp.retrieve(memory, query, k: k) do
      {:ok, documents} ->
        passages =
          Enum.map(documents, fn document ->
            "#{fetch(document, :title)} | #{fetch(document, :text)}"
          end)

        {:ok, passages}

      {:error, reason} ->
        {:error, {:hotpotqa_retrieval_failed, hop, reason}}
    end
  end

  defp predict(predictor, inputs, output) do
    case Imp.call(predictor, inputs) do
      {:ok, prediction} ->
        case Imp.get(prediction, output) do
          value when is_binary(value) and value != "" -> {:ok, value}
          value -> {:error, {:invalid_hotpotqa_stage_output, output, value}}
        end

      {:error, reason} ->
        {:error, {:hotpotqa_stage_failed, output, reason}}
    end
  end

  defp fetch(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
