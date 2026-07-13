defmodule DSEx.BenchmarkTruth.RLMDataset do
  @moduledoc false

  def load_all!(manifest, opts \\ []) do
    root = Keyword.get(opts, :root, Path.dirname(manifest["manifest_path"]))

    Map.new(manifest["datasets"], fn {family, spec} ->
      {family, load!(family, spec, root)}
    end)
  end

  def load!(family, spec, root) do
    path = Path.expand(spec["path"], root)
    bytes = File.read!(path)
    actual = sha256(bytes)

    unless actual == spec["sha256"],
      do:
        raise(
          ArgumentError,
          "dataset hash mismatch for #{family}: expected #{spec["sha256"]}, got #{actual}"
        )

    rows = decode_jsonl!(bytes, path)
    validate_dataset_identity!(rows, spec, family)
    selected = select_rows!(rows, spec, family)
    normalized = Enum.flat_map(selected, &normalize!(family, &1, spec))

    %{
      "family" => family,
      "path" => path,
      "sha256" => actual,
      "source" => spec["source"],
      "revision" => spec["revision"],
      "split" => spec["split"],
      "logical_instances" => length(selected),
      "evaluated_rows" => length(normalized),
      "sample_ids" => Enum.map(selected, & &1["id"]),
      "sample_ids_sha256" => sha256(Jason.encode!(Enum.map(selected, & &1["id"]))),
      "evaluated_keys" =>
        Enum.map(normalized, fn row ->
          %{
            "example_id" => row["id"],
            "query_id" => row["query_id"] || row["id"],
            "context_size" => row["context_size"]
          }
        end),
      "rows" => normalized
    }
  end

  def prompt_payload(row) do
    Map.take(row, ~w(id family query_id context_size question context documents choices))
  end

  defp select_rows!(rows, spec, family) do
    ids = spec["sample_ids"]
    indexed = Map.new(rows, fn row -> {required_string!(row, "id", family), row} end)
    missing = ids -- Map.keys(indexed)

    unless missing == [],
      do: raise(ArgumentError, "dataset #{family} is missing frozen IDs: #{inspect(missing)}")

    Enum.map(ids, &Map.fetch!(indexed, &1))
  end

  defp validate_dataset_identity!(rows, spec, family) do
    Enum.each(rows, fn row ->
      Enum.each(~w(source revision split), fn key ->
        unless row[key] == spec[key] do
          raise ArgumentError,
                "dataset #{family} row #{inspect(row["id"])} #{key} mismatch: expected #{inspect(spec[key])}, got #{inspect(row[key])}"
        end
      end)
    end)
  end

  defp normalize!("s_niah", row, _spec) do
    [base(row, "s_niah") |> put_context!(row) |> put_question_answer!(row)]
  end

  defp normalize!("browsecomp_plus", row, spec) do
    documents = Map.get(row, "documents")

    unless is_list(documents) and length(documents) == spec["docs_per_instance"],
      do:
        raise(
          ArgumentError,
          "BrowseComp+ #{row["id"]} must contain exactly #{spec["docs_per_instance"]} documents"
        )

    evidence = Map.get(row, "evidence_document_ids")

    unless is_list(evidence) and evidence != [],
      do:
        raise(
          ArgumentError,
          "BrowseComp+ #{row["id"]} must identify gold/evidence documents for scoring only"
        )

    [
      base(row, "browsecomp_plus")
      |> Map.put("documents", normalize_documents!(documents, row["id"]))
      |> put_question_answer!(row)
      |> Map.put("evidence_document_ids", evidence)
    ]
  end

  defp normalize!("oolong", row, _spec) do
    [base(row, "oolong") |> put_context!(row) |> put_question_answer!(row)]
  end

  defp normalize!("oolong_pairs", row, spec) do
    contexts = Map.get(row, "contexts")

    unless is_map(contexts),
      do:
        raise(
          ArgumentError,
          "OOLONG-Pairs #{row["id"]} contexts must be keyed by paper context size"
        )

    Enum.map(spec["context_grid"], fn size ->
      context = contexts[Integer.to_string(size)]

      unless is_binary(context) or is_list(context),
        do: raise(ArgumentError, "OOLONG-Pairs #{row["id"]} is missing context size #{size}")

      base(row, "oolong_pairs")
      |> Map.put("query_id", row["id"])
      |> Map.put("id", "#{row["id"]}@#{size}")
      |> Map.put("context_size", size)
      |> Map.put("context", context)
      |> put_question_answer!(row)
    end)
  end

  defp normalize!("longbench_v2_codeqa", row, _spec) do
    choices = Map.get(row, "choices")

    unless (is_list(choices) or is_map(choices)) and map_size_or_length(choices) >= 2,
      do: raise(ArgumentError, "CodeQA #{row["id"]} must have at least two choices")

    [
      base(row, "longbench_v2_codeqa")
      |> put_context!(row)
      |> put_question_answer!(row)
      |> Map.put("choices", choices)
    ]
  end

  defp base(row, family), do: %{"id" => required_string!(row, "id", family), "family" => family}
  defp put_context!(out, row), do: Map.put(out, "context", required_context!(row, out["family"]))

  defp put_question_answer!(out, row),
    do:
      out
      |> Map.put("question", required_string!(row, "question", out["family"]))
      |> Map.put("gold", required_answer!(row, out["family"]))

  defp required_context!(row, family) do
    context = Map.get(row, "context")

    if is_binary(context) or is_list(context),
      do: context,
      else: raise(ArgumentError, "#{family} #{row["id"]} requires string/list context")
  end

  defp required_answer!(row, family) do
    answer = Map.get(row, "answer")

    if is_binary(answer) or is_number(answer),
      do: to_string(answer),
      else: raise(ArgumentError, "#{family} #{row["id"]} requires scalar answer")
  end

  defp required_string!(row, key, family) do
    value = Map.get(row, key)

    if is_binary(value) and value != "",
      do: value,
      else: raise(ArgumentError, "#{family} row requires non-empty #{key}")
  end

  defp normalize_documents!(documents, id) do
    Enum.map(documents, fn
      %{"id" => doc_id, "text" => text} when is_binary(doc_id) and is_binary(text) ->
        %{"id" => doc_id, "text" => text}

      _ ->
        raise ArgumentError, "BrowseComp+ #{id} documents require id and text"
    end)
  end

  defp decode_jsonl!(bytes, path) do
    bytes
    |> String.split("\n", trim: true)
    |> Enum.with_index(1)
    |> Enum.map(fn {line, number} ->
      case Jason.decode(line) do
        {:ok, row} when is_map(row) ->
          row

        {:ok, _} ->
          raise ArgumentError, "dataset #{path}:#{number} must be a JSON object"

        {:error, error} ->
          raise ArgumentError,
                "invalid dataset JSON #{path}:#{number}: #{Exception.message(error)}"
      end
    end)
  end

  defp map_size_or_length(value) when is_map(value), do: map_size(value)
  defp map_size_or_length(value) when is_list(value), do: length(value)
  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
