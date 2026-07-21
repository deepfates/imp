defmodule Imp.BenchmarkTruth.HotpotFeedback do
  @moduledoc false

  alias Imp.Optimizer.GEPA.ComponentFeedback

  @component_names [:create_query_hop2, :final_answer, :summarize1, :summarize2]

  @doc "Returns the callbacks keyed by the Hotpot program's optimizer component names."
  def callbacks do
    Map.new(@component_names, &{&1, callback(&1)})
  end

  @doc "Returns one Hotpot component feedback callback."
  def callback(:create_query_hop2), do: &create_query_hop2/1
  def callback(:final_answer), do: &final_answer/1
  def callback(:summarize1), do: &summarize1/1
  def callback(:summarize2), do: &summarize2/1

  def callback(component) do
    raise ArgumentError, "unknown Hotpot feedback component: #{inspect(component)}"
  end

  @doc false
  def create_query_hop2(%ComponentFeedback{} = feedback) do
    require_predictor_inputs!(feedback, [:question, :summary_1])
    data = example_data!(feedback)
    outputs = program_outputs!(feedback)
    hop1_titles = outputs |> fetch!(:hop1_docs, "program output") |> document_titles!()
    hop2_titles = outputs |> fetch!(:hop2_docs, "program output") |> document_titles!()
    docs_after_hop2 = MapSet.union(hop1_titles, hop2_titles)
    gold_titles = MapSet.new(data.supporting_titles)

    relevant_after_hop1 = MapSet.intersection(gold_titles, hop1_titles)
    relevant_after_hop2 = MapSet.intersection(gold_titles, docs_after_hop2)
    new_relevant_after_hop2 = MapSet.difference(relevant_after_hop2, relevant_after_hop1)
    remaining_after_hop2 = MapSet.difference(gold_titles, docs_after_hop2)
    remaining_after_hop1 = MapSet.difference(gold_titles, hop1_titles)

    missing_full_docs =
      remaining_after_hop1
      |> MapSet.difference(docs_after_hop2)
      |> sorted()
      |> Enum.map(&full_document!(&1, data.context_by_title))

    new_relevant = sorted(new_relevant_after_hop2)

    text = """
    You are optimizing the query generation for the **second hop** of a multi-hop retrieval system. Your goal is to help the system find all relevant documents necessary to answer the following question:

        "#{data.question}"

    The correct answer is: "#{display_answer(data.answer)}".

    **System behavior overview:**
    - **First hop:** Documents were retrieved directly using the original question.
    - **Second hop (your query):** Your query aims to retrieve additional relevant documents not found in the first hop.

    **Analysis:**
    - Documents relevant to the answer retrieved in the first hop: #{inspect(sorted(relevant_after_hop1))}
    - Documents still needing retrieval after the first hop: #{inspect(sorted(remaining_after_hop2))}
    - New relevant documents your earlier query retrieved in the second hop: #{inspect(new_relevant)}

    **Feedback for improvement:**
    Your query successfully retrieved #{length(new_relevant)} out of #{MapSet.size(remaining_after_hop2)} remaining relevant document(s) in the second hop. To improve:
    - Analyze the missing documents: #{inspect(missing_full_docs)}
    - How can you rephrase or adjust your query to better target these?

    **Tip:** Consider what connections or clues from the retrieved first hop documents could help surface the remaining relevant ones.
    """

    result(outputs, data.answer, text)
  end

  @doc false
  def final_answer(%ComponentFeedback{} = feedback) do
    data = example_data!(feedback)
    outputs = program_outputs!(feedback)
    answer = fetch!(outputs, :answer, "program output")
    score = exact_match!(answer, data.answer)

    context =
      data.supporting_titles
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map_join(&full_document!(&1, data.context_by_title))

    prefix = optional_output_feedback(outputs)

    text =
      if score do
        "The provided answer, '#{answer}' is correct. Here's some additional context behind the answer:\n#{prefix}#{context}"
      else
        "The provided answer, '#{answer}' is incorrect. The correct answer is: #{display_answer(data.answer)}. Here's some context behind the answer, and how you could have reasoned to get the correct answer:\n#{prefix}#{context}"
      end

    %{feedback_score: score, feedback_text: text}
  end

  @doc false
  def summarize1(%ComponentFeedback{} = feedback) do
    data = example_data!(feedback)
    outputs = program_outputs!(feedback)
    hop1_titles = outputs |> fetch!(:hop1_docs, "program output") |> document_titles!()
    gold_titles = MapSet.new(data.supporting_titles)
    relevant = MapSet.intersection(gold_titles, hop1_titles)
    missing = MapSet.difference(gold_titles, hop1_titles)
    full_missing = missing |> sorted() |> Enum.map(&full_document!(&1, data.context_by_title))

    text = """
    You are the first-hop **summarization module** in a multi-hop QA system, responsible for distilling the most critical information from the top retrieved passages in response to the initial question:

        "#{data.question}"

    Your summary must serve two purposes:
    1. **Enable the creation of a focused, effective follow-up query** (for the second hop).
    2. **Provide a strong foundation for the answer generation module** (later stages depend on what you include here).

    **Analysis:**
    - Relevant documents retrieved in the first hop: #{inspect(sorted(relevant))}
    - Relevant documents still missing after first hop: #{inspect(sorted(missing))}

    **Ideal summary for this question would include:**
    -----
    #{ideal_summary(data)}
    -----

    **Feedback:**
    - Ensure you cover all necessary facts and clues from the retrieved passages, especially any information that could help generate queries to surface missing supporting facts (such as connections, entities, or bridging concepts).
    - Try to represent key details from the cited relevant documents (#{inspect(sorted(relevant))}), and highlight information that might help hint or bridge to the remaining facts: #{inspect(full_missing)}
    - If you missed mentioning or signaling these, it may become impossible for the system to retrieve them in the next hop, or generate the correct answer at the end.

    **Tip:** When summarizing, don't just compress; synthesize - include both direct answers and clues required for the system's next steps.
    """

    result(outputs, data.answer, text)
  end

  @doc false
  def summarize2(%ComponentFeedback{} = feedback) do
    require_predictor_inputs!(feedback, [:question, :context, :passages])
    data = example_data!(feedback)
    outputs = program_outputs!(feedback)

    text = """
    You are the summary generation module in a multi-hop QA system, responsible for producing a high-quality, informative summary from the input question, an intermediate summary (context), and newly retrieved passages. Your summary will be used *directly* by the answer generation module to finalize the answer, which has no access to the underlying passages or full context.

    Your goal is to integrate and synthesize information relevant to answering the multi-hop question: "#{data.question}". The correct answer is "#{display_answer(data.answer)}".

    An ideal summary to answer this question would have included all of the following information:
       #{ideal_summary(data)}

    While your input passages may not always contain every necessary detail, you should aim to bridge any gaps by inferring or generalizing, drawing upon information from both the initial summary and new passages. Strive to match the coverage and relevance of the ideal summary, ensuring your output contains all key supporting information needed for accurate answer generation.

    Keep your summary precise and well-structured, including all necessary connections and facts that enable the answer module to confidently arrive at the correct answer.
    """

    # The upstream callback computes these retrieval sets even though they do
    # not enter its final prose. Validation preserves its fail-closed behavior.
    outputs |> fetch!(:hop1_docs, "program output") |> document_titles!()
    outputs |> fetch!(:hop2_docs, "program output") |> document_titles!()

    result(outputs, data.answer, text)
  end

  defp example_data!(%ComponentFeedback{example: %Imp.Example{} = example}) do
    fields = Imp.Example.to_map(example)
    question = fields |> fetch!(:question, "example") |> nonempty_string!(:question)
    answer = fields |> fetch!(:answer, "example") |> answer!()
    supporting = fields |> fetch!(:supporting_facts, "example") |> map!(:supporting_facts)
    context = fields |> fetch!(:context, "example") |> map!(:context)
    titles = supporting |> fetch!(:title, "supporting_facts") |> string_list!(:title)
    sentence_ids = supporting |> fetch!(:sent_id, "supporting_facts") |> sentence_ids!()
    context_titles = context |> fetch!(:title, "context") |> string_list!(:title)
    context_sentences = context |> fetch!(:sentences, "context") |> sentence_lists!()

    if length(titles) != length(sentence_ids) do
      invalid!("supporting_facts.title and supporting_facts.sent_id must have equal lengths")
    end

    if length(context_titles) != length(context_sentences) do
      invalid!("context.title and context.sentences must have equal lengths")
    end

    context_by_title = unique_zip!(context_titles, context_sentences, "context.title")

    Enum.zip(titles, sentence_ids)
    |> Enum.each(fn {title, id} -> supporting_sentence!(title, id, context_by_title) end)

    %{
      question: question,
      answer: answer,
      supporting_titles: titles,
      supporting_sentence_ids: sentence_ids,
      context_by_title: context_by_title
    }
  end

  defp example_data!(%ComponentFeedback{example: other}) do
    invalid!("example must be an Imp.Example, got: #{inspect(other)}")
  end

  defp program_outputs!(%ComponentFeedback{program_output: %Imp.Prediction{} = prediction}),
    do: Imp.Prediction.to_map(prediction)

  defp program_outputs!(%ComponentFeedback{program_output: other}) do
    invalid!("program_output must be an Imp.Prediction, got: #{inspect(other)}")
  end

  defp require_predictor_inputs!(%ComponentFeedback{predictor_inputs: inputs}, keys)
       when is_map(inputs) do
    Enum.each(keys, &fetch!(inputs, &1, "predictor inputs"))
  end

  defp require_predictor_inputs!(%ComponentFeedback{predictor_inputs: other}, _keys) do
    invalid!("predictor_inputs must be a map, got: #{inspect(other)}")
  end

  defp fetch!(map, key, location) when is_map(map) and is_atom(key) do
    string_key = Atom.to_string(key)

    case {Map.fetch(map, key), Map.fetch(map, string_key)} do
      {{:ok, _atom_value}, {:ok, _string_value}} ->
        invalid!("#{location} contains ambiguous atom/string keys for #{inspect(key)}")

      {{:ok, value}, :error} ->
        value

      {:error, {:ok, value}} ->
        value

      {:error, :error} ->
        invalid!("#{location} is missing required field #{inspect(key)}")
    end
  end

  defp map!(value, _field) when is_map(value), do: value
  defp map!(value, field), do: invalid!("#{field} must be a map, got: #{inspect(value)}")

  defp nonempty_string!(value, _field) when is_binary(value) and value != "", do: value

  defp nonempty_string!(value, field),
    do: invalid!("#{field} must be a non-empty string, got: #{inspect(value)}")

  defp answer!(value) when is_binary(value) and value != "", do: value

  defp answer!(values) when is_list(values) and values != [] do
    if Enum.all?(values, &(is_binary(&1) and &1 != "")) do
      values
    else
      invalid!("answer alternatives must all be non-empty strings")
    end
  end

  defp answer!(value),
    do: invalid!("answer must be a non-empty string or list of strings, got: #{inspect(value)}")

  defp string_list!(values, _field) when is_list(values) and values != [] do
    if Enum.all?(values, &(is_binary(&1) and String.trim(&1) != "")) do
      Enum.map(values, &String.trim/1)
    else
      invalid!("expected a non-empty list of non-empty strings")
    end
  end

  defp string_list!(value, field),
    do: invalid!("#{field} must be a non-empty list, got: #{inspect(value)}")

  defp sentence_ids!(values) when is_list(values) and values != [] do
    if Enum.all?(values, &(is_integer(&1) and &1 >= 0)) do
      values
    else
      invalid!("supporting_facts.sent_id must contain non-negative integers")
    end
  end

  defp sentence_ids!(value),
    do: invalid!("supporting_facts.sent_id must be a non-empty list, got: #{inspect(value)}")

  defp sentence_lists!(values) when is_list(values) and values != [] do
    if Enum.all?(values, fn sentences ->
         is_list(sentences) and Enum.all?(sentences, &is_binary/1)
       end) do
      values
    else
      invalid!("context.sentences must be a list of string lists")
    end
  end

  defp sentence_lists!(value),
    do: invalid!("context.sentences must be a non-empty list, got: #{inspect(value)}")

  defp unique_zip!(keys, values, field) do
    Enum.zip(keys, values)
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      if Map.has_key?(acc, key) do
        invalid!("#{field} contains duplicate title #{inspect(key)}")
      end

      Map.put(acc, key, value)
    end)
  end

  defp supporting_sentence!(title, id, context_by_title) do
    sentences =
      Map.get(context_by_title, title) ||
        invalid!("supporting title #{inspect(title)} is missing from context")

    Enum.fetch!(sentences, id)
  rescue
    Enum.OutOfBoundsError ->
      invalid!("supporting sentence index #{id} is out of bounds for #{inspect(title)}")
  end

  defp full_document!(title, context_by_title) do
    sentences =
      Map.get(context_by_title, title) ||
        invalid!("supporting title #{inspect(title)} is missing from context")

    title <> " | " <> Enum.join(sentences)
  end

  defp ideal_summary(data) do
    data.supporting_titles
    |> Enum.zip(data.supporting_sentence_ids)
    |> Enum.map_join("\n   ", fn {title, id} ->
      title <> " | " <> supporting_sentence!(title, id, data.context_by_title)
    end)
  end

  defp document_titles!(documents) when is_list(documents) do
    Enum.reduce(documents, MapSet.new(), fn
      document, titles when is_binary(document) and document != "" ->
        title = document |> String.split(" | ", parts: 2) |> hd() |> String.trim()

        if title == "" do
          invalid!("retrieved document has an empty title")
        end

        MapSet.put(titles, title)

      document, _titles ->
        invalid!("retrieved documents must be non-empty strings, got: #{inspect(document)}")
    end)
  end

  defp document_titles!(value),
    do: invalid!("retrieved documents must be a list, got: #{inspect(value)}")

  defp result(outputs, gold_answer, text) do
    answer = fetch!(outputs, :answer, "program output")
    %{feedback_score: exact_match!(answer, gold_answer), feedback_text: text}
  end

  defp exact_match!(prediction, answer) when is_binary(prediction),
    do: Imp.Metrics.em(prediction, answer)

  defp exact_match!(prediction, _answer),
    do: invalid!("program output answer must be a string, got: #{inspect(prediction)}")

  defp optional_output_feedback(outputs) do
    case optional_fetch!(outputs, :feedback_text, "program output") do
      :missing ->
        ""

      value when is_binary(value) and value != "" ->
        value <> "\n\n"

      value ->
        invalid!(
          "program output feedback_text must be a non-empty string, got: #{inspect(value)}"
        )
    end
  end

  defp optional_fetch!(map, key, location) when is_map(map) and is_atom(key) do
    string_key = Atom.to_string(key)

    case {Map.fetch(map, key), Map.fetch(map, string_key)} do
      {{:ok, _atom_value}, {:ok, _string_value}} ->
        invalid!("#{location} contains ambiguous atom/string keys for #{inspect(key)}")

      {{:ok, value}, :error} ->
        value

      {:error, {:ok, value}} ->
        value

      {:error, :error} ->
        :missing
    end
  end

  defp display_answer(answer) when is_binary(answer), do: answer
  defp display_answer(answers), do: inspect(answers)
  defp sorted(set), do: set |> MapSet.to_list() |> Enum.sort()

  defp invalid!(message), do: raise(ArgumentError, "invalid Hotpot feedback: " <> message)
end
