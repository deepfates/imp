defmodule Imp.TestSupport.BetterTogetherLedgerObserver do
  @moduledoc false

  alias Imp.Optimizer.Report

  def classify!(calls, report, opts) when is_list(calls) and is_map(report) do
    train_ids = opts |> Keyword.fetch!(:train_ids) |> MapSet.new()
    validation_ids = opts |> Keyword.fetch!(:validation_ids) |> MapSet.new()
    base_model = opts |> Keyword.fetch!(:base_model) |> Path.expand()
    weighted_model = opts |> Keyword.fetch!(:weighted_model) |> Path.expand()

    if not MapSet.disjoint?(train_ids, validation_ids) do
      raise ArgumentError, "train and validation identities overlap"
    end

    report = report_identity!(report)

    prefixes =
      report.candidates
      |> Enum.filter(&(fetch!(&1, :status) in [:ok, "ok"]))
      |> Enum.map(&fetch!(&1, :strategy))

    entries =
      Enum.map(calls, fn call ->
        id = fetch!(call, :id)
        model = call |> fetch!(:response_model) |> Path.expand()
        rendered = rendered_system!(call)
        row_set = row_set!(id, train_ids, validation_ids)
        phase = phase!(row_set, model, base_model, weighted_model)

        %{
          id: id,
          phase: phase,
          prefixes: phase_prefixes(phase, prefixes),
          model: model,
          rendered_system: rendered,
          rendered_identity: digest(rendered),
          program_identity: digest(%{model: model, rendered_system: rendered}),
          score: fetch!(call, :score)
        }
      end)

    grouped = Enum.group_by(entries, & &1.phase)

    %{
      entries: entries,
      baseline: summarize(Map.get(grouped, :baseline_selection, [])),
      prefix_selection: summarize(Map.get(grouped, :prefix_selection, [])),
      prompt_candidates:
        grouped
        |> Map.get(:prompt_candidate_evaluation, [])
        |> Enum.group_by(& &1.program_identity)
        |> Map.values()
        |> Enum.map(&summarize/1)
        |> Enum.sort_by(& &1.program_identity),
      rendered_instruction_count:
        entries |> Enum.map(& &1.rendered_identity) |> Enum.uniq() |> length(),
      program_identity_count:
        entries |> Enum.map(& &1.program_identity) |> Enum.uniq() |> length(),
      candidate_scores: Enum.map(report.candidates, &{fetch!(&1, :strategy), fetch!(&1, :score)}),
      selected_strategy: report.selected_strategy
    }
  end

  defp report_identity!(%Report{} = report) do
    %{candidates: report.candidates, selected_strategy: report.metadata.selected_strategy}
  end

  defp report_identity!(report) do
    decoded = decode_projection(report)

    %{
      candidates: Map.fetch!(decoded, "candidates"),
      selected_strategy: get_in(decoded, ["metadata", "selected_strategy"])
    }
  end

  defp row_set!(id, train_ids, validation_ids) do
    cond do
      MapSet.member?(train_ids, id) -> :train
      MapSet.member?(validation_ids, id) -> :validation
      true -> raise ArgumentError, "unknown durable row identity: #{inspect(id)}"
    end
  end

  defp phase!(:validation, model, base_model, _weighted_model) when model == base_model,
    do: :baseline_selection

  defp phase!(:validation, model, _base_model, weighted_model) when model == weighted_model,
    do: :prefix_selection

  defp phase!(:train, model, _base_model, weighted_model) when model == weighted_model,
    do: :prompt_candidate_evaluation

  defp phase!(row_set, model, base_model, weighted_model) do
    raise ArgumentError,
          "call identity does not belong to a BetterTogether phase: " <>
            inspect(%{
              row_set: row_set,
              model: model,
              base_model: base_model,
              weighted_model: weighted_model
            })
  end

  defp phase_prefixes(:baseline_selection, prefixes), do: Enum.filter(prefixes, &(&1 == ""))
  defp phase_prefixes(:prefix_selection, prefixes), do: Enum.reject(prefixes, &(&1 == ""))
  defp phase_prefixes(:prompt_candidate_evaluation, _prefixes), do: ["w -> p/candidate"]

  defp summarize([]),
    do: %{calls: 0, score: nil, models: [], rendered_identities: [], program_identities: []}

  defp summarize(entries) do
    %{
      calls: length(entries),
      score: Enum.sum(Enum.map(entries, & &1.score)) / length(entries),
      models: entries |> Enum.map(& &1.model) |> Enum.uniq(),
      rendered_identities: entries |> Enum.map(& &1.rendered_identity) |> Enum.uniq(),
      program_identities: entries |> Enum.map(& &1.program_identity) |> Enum.uniq(),
      program_identity: entries |> hd() |> Map.fetch!(:program_identity),
      ids: Enum.map(entries, & &1.id)
    }
  end

  defp rendered_system!(call) do
    messages = call |> fetch!(:trace) |> fetch!(:messages)

    case Enum.find(messages, &(role(fetch!(&1, :role)) in [:system, "system"])) do
      nil -> raise ArgumentError, "call lacks a canonical rendered system message"
      message -> fetch!(message, :content)
    end
  end

  defp role(%{"__imp_type__" => "atom", "value" => value}), do: value
  defp role(value), do: value

  defp decode_projection(%{"__imp_type__" => "atom", "value" => value}), do: value

  defp decode_projection(%{"__imp_type__" => "map", "entries" => entries}) do
    Map.new(entries, fn [key, value] -> {decode_projection(key), decode_projection(value)} end)
  end

  defp decode_projection(%{"__imp_type__" => "tuple", "items" => items}),
    do: Enum.map(items, &decode_projection/1)

  defp decode_projection(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {key, decode_projection(value)} end)

  defp decode_projection(list) when is_list(list), do: Enum.map(list, &decode_projection/1)
  defp decode_projection(value), do: value

  defp fetch!(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.fetch!(map, Atom.to_string(key))
    end
  end

  defp digest(value) do
    value
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
