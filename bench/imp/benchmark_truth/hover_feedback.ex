defmodule Imp.BenchmarkTruth.HoverFeedback do
  @moduledoc false

  alias Imp.Optimizer.GEPA.ComponentFeedback

  @summary_components [:summarize1, :summarize2]
  @query_components [:create_query_hop2, :create_query_hop3]
  @components @query_components ++ @summary_components

  @type feedback :: %{feedback_score: boolean(), feedback_text: String.t()}

  @doc "Returns callbacks keyed by the upstream program's Imp predictor names."
  @spec callbacks() :: %{atom() => ComponentFeedback.callback()}
  def callbacks do
    %{
      create_query_hop2: &query/1,
      create_query_hop3: &query/1,
      summarize1: &summary/1,
      summarize2: &summary/1
    }
  end

  @doc "Returns callbacks only when a program exposes the complete source predictor graph."
  @spec callbacks_for(struct()) :: {:ok, map()} | {:error, {:incompatible_predictors, map()}}
  def callbacks_for(program) when is_struct(program) do
    actual = program |> Imp.ProgramParameters.predictors() |> Enum.map(& &1.name)
    missing = @components -- actual
    unexpected = actual -- @components

    if missing == [] and unexpected == [] do
      {:ok, callbacks()}
    else
      {:error,
       {:incompatible_predictors,
        %{required: @components, actual: actual, missing: missing, unexpected: unexpected}}}
    end
  end

  @doc "Computes upstream HoVer feedback for either summary component."
  @spec summary(ComponentFeedback.t()) :: feedback()
  def summary(%ComponentFeedback{} = context) do
    ensure_component!(context.component, @summary_components)
    hop_sets = hop_sets!(context)
    score = MapSet.subset?(hop_sets.gold, hop_sets.final)

    text =
      cond do
        score ->
          "Your summaries are correct and useful in guiding query generation to retrieve relevant evidence documents."

        has_key?(context.predictor_inputs, :context) ->
          retrieval_feedback(
            "summaries are used to generate queries to identify evidence relevant to the claim.",
            "summary",
            MapSet.difference(hop_sets.gold, hop_sets.hop2),
            MapSet.difference(hop_sets.gold, hop_sets.final),
            "make the connection between the provided passages and the missed evidence relevant to the claim."
          )

        true ->
          retrieval_feedback(
            "summaries are used to generate queries to identify evidence relevant to the claim.",
            "summary",
            MapSet.difference(hop_sets.gold, hop_sets.hop1),
            MapSet.difference(hop_sets.gold, hop_sets.final),
            "make the connection between the provided passages and the missed evidence relevant to the claim."
          )
      end

    %{feedback_score: score, feedback_text: text}
  end

  @doc "Computes upstream HoVer feedback for either query-generation component."
  @spec query(ComponentFeedback.t()) :: feedback()
  def query(%ComponentFeedback{} = context) do
    ensure_component!(context.component, @query_components)
    hop_sets = hop_sets!(context)
    score = MapSet.subset?(hop_sets.gold, hop_sets.final)

    text =
      cond do
        score ->
          "Your queries are correct and useful in retrieving relevant evidence documents."

        has_key?(context.predictor_inputs, :summary_2) ->
          retrieval_feedback(
            "queries are used to identify evidence relevant to the claim.",
            "query",
            MapSet.difference(hop_sets.gold, hop_sets.hop2),
            MapSet.difference(hop_sets.gold, hop_sets.final),
            "modify your query to make the connection between the provided summary and the missed evidence relevant to the claim."
          )

        true ->
          remaining_after_hop1 = MapSet.difference(hop_sets.gold, hop_sets.hop1)
          remaining_after_hop2 = MapSet.difference(hop_sets.gold, hop_sets.hop2)

          retrieval_feedback(
            "queries are used to identify evidence relevant to the claim.",
            "query",
            remaining_after_hop1,
            remaining_after_hop2,
            "modify your query to make the connection between the provided summary and the missed evidence relevant to the claim."
          )
      end

    %{feedback_score: score, feedback_text: text}
  end

  defp hop_sets!(context) do
    hop1 = trace_passages(context.trace, :summarize1)
    hop2 = trace_passages(context.trace, :summarize2)

    if is_nil(hop1) or is_nil(hop2) do
      raise ArgumentError,
            "HoVer feedback requires summarize1 and summarize2 trace inputs with passages"
    end

    %{
      gold: context.example |> example_value(:supporting_facts, []) |> supporting_titles(),
      hop1: hop1,
      hop2: MapSet.union(hop1, hop2),
      final:
        context.program_output
        |> prediction_value(:retrieved_docs, [])
        |> retrieved_titles()
        |> MapSet.union(hop1)
        |> MapSet.union(hop2)
    }
  end

  defp trace_passages(trace, component) do
    Enum.find_value(trace, fn
      %{predictor: ^component, inputs: inputs} ->
        inputs |> value(:passages) |> passages_or_nil()

      _other ->
        nil
    end)
  end

  defp passages_or_nil(nil), do: nil
  defp passages_or_nil(passages), do: retrieved_titles(passages)

  defp supporting_titles(facts) do
    facts
    |> List.wrap()
    |> Enum.map(&value(&1, :key))
    |> title_set()
  end

  defp retrieved_titles(docs) do
    docs
    |> List.wrap()
    |> Enum.map(fn
      doc when is_binary(doc) -> doc |> String.split(" | ", parts: 2) |> hd()
      doc -> value(doc, :title)
    end)
    |> title_set()
  end

  defp title_set(titles) do
    titles
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&Imp.Metrics.normalize_text/1)
    |> MapSet.new()
  end

  defp retrieval_feedback(subject, kind, remaining_before, remaining_after, advice) do
    helped = MapSet.difference(remaining_before, remaining_after)
    missed = MapSet.intersection(remaining_before, remaining_after)

    successful =
      sentence(
        helped,
        "**Successful retrieval:** Your #{kind} correctly helped retrieve the following evidence: "
      )

    missing =
      sentence(
        missed,
        "**Missing evidence:** However, your #{kind} could not help " <>
          if(kind == "query",
            do: "retrieve these key evidence: ",
            else: "make the connection to these key evidence: "
          )
      )

    "Your #{subject}\n#{successful}#{missing}\n\nThink about how you can #{advice}"
  end

  defp sentence(set, prefix) do
    case set |> MapSet.to_list() |> Enum.sort() do
      [] -> ""
      titles -> prefix <> Enum.join(titles, ", ") <> ". "
    end
  end

  defp ensure_component!(component, allowed) do
    unless component in allowed do
      raise ArgumentError,
            "invalid HoVer feedback component #{inspect(component)}; expected one of #{inspect(allowed)}"
    end
  end

  defp has_key?(map, key), do: Map.has_key?(map, key) or Map.has_key?(map, Atom.to_string(key))

  defp example_value(%Imp.Example{} = example, key, default),
    do: Imp.Example.get(example, key, default)

  defp example_value(example, key, default), do: value(example, key) || default

  defp prediction_value(%Imp.Prediction{} = prediction, key, default),
    do: Imp.Prediction.get(prediction, key, default)

  defp prediction_value(prediction, key, default), do: value(prediction, key) || default

  defp value(map, key) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp value(_other, _key), do: nil
end
