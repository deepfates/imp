defmodule Imp.BenchmarkTruth.RLMDataset do
  @moduledoc false

  @oolong_pairs_context_grid [
    1024,
    2048,
    4096,
    8192,
    16384,
    32768,
    65536,
    131_072,
    262_144,
    524_288,
    1_048_576
  ]
  @oolong_pairs_query_count 20
  @metadata_chunk_size 1_048_576

  def load_all!(manifest, opts \\ []) do
    root = Keyword.get(opts, :root, Path.dirname(manifest["manifest_path"]))

    Map.new(manifest["datasets"], fn {family, spec} ->
      {family, load!(family, spec, root)}
    end)
  end

  def metadata_all!(manifest, opts \\ []) do
    root = Keyword.get(opts, :root, Path.dirname(manifest["manifest_path"]))

    Map.new(manifest["datasets"], fn {family, spec} ->
      {family, metadata!(family, spec, root)}
    end)
  end

  def metadata!(family, spec, root) do
    path = Path.expand(spec["path"], root)
    expected_hash = spec["sha256"]

    unless File.regular?(path), do: raise(ArgumentError, "dataset #{family} is missing: #{path}")

    {actual, row_count, markers} = scan_metadata_file!(path, family, spec)

    unless actual == expected_hash,
      do:
        raise(
          ArgumentError,
          "dataset hash mismatch for #{family}: expected #{expected_hash}, got #{actual}"
        )

    validate_metadata_markers!(markers, spec, family)

    expected_rows =
      if family == "oolong_pairs", do: 1 + @oolong_pairs_query_count, else: spec["sample_count"]

    unless row_count == expected_rows,
      do:
        raise(
          ArgumentError,
          "dataset #{family} expected #{expected_rows} JSONL rows, found #{row_count}"
        )

    ids = spec["sample_ids"]
    normalized_rows = metadata_rows(family, ids, spec["context_grid"])

    %{
      "family" => family,
      "path" => path,
      "sha256" => actual,
      "source" => spec["source"],
      "revision" => spec["revision"],
      "split" => spec["split"],
      "context_grid" => spec["context_grid"],
      "logical_instances" => length(ids),
      "evaluated_rows" => length(normalized_rows),
      "sample_ids" => ids,
      "sample_ids_sha256" => sha256(Jason.encode!(ids)),
      "evaluated_keys" => Enum.map(normalized_rows, &metadata_key/1),
      "rows" => normalized_rows
    }
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

    normalized =
      case family do
        "oolong_pairs" ->
          contexts = shared_contexts!(rows)
          Enum.flat_map(selected, &normalize_pair!(&1, spec, contexts))

        _ ->
          Enum.flat_map(selected, &normalize!(family, &1, spec))
      end

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

  defp metadata_rows("oolong_pairs", ids, context_grid) do
    Enum.flat_map(ids, fn query_id ->
      Enum.map(context_grid, fn size ->
        %{
          "id" => "#{query_id}@#{size}",
          "family" => "oolong_pairs",
          "query_id" => query_id,
          "context_size" => size
        }
      end)
    end)
  end

  defp metadata_rows(family, ids, _context_grid),
    do: Enum.map(ids, &%{"id" => &1, "family" => family, "query_id" => &1, "context_size" => nil})

  defp metadata_key(row),
    do: %{
      "example_id" => row["id"],
      "query_id" => row["query_id"],
      "context_size" => row["context_size"]
    }

  defp scan_metadata_file!(path, family, spec) do
    markers = %{
      "source" => "\"source\":" <> Jason.encode!(spec["source"]),
      "revision" => "\"revision\":" <> Jason.encode!(spec["revision"]),
      "split" => "\"split\":" <> Jason.encode!(spec["split"]),
      "reserved" => "\"id\":\"__contexts__\""
    }

    max_marker_size = markers |> Map.values() |> Enum.map(&byte_size/1) |> Enum.max()
    digest = :crypto.hash_init(:sha256)

    {digest, row_count, counts, _tail} =
      Enum.reduce(
        File.stream!(path, [], @metadata_chunk_size),
        {digest, 0, Map.new(markers, fn {key, _} -> {key, 0} end), <<>>},
        fn chunk, {digest, row_count, counts, tail} ->
          data = tail <> chunk

          counts =
            Map.new(markers, fn {key, marker} ->
              {key, counts[key] + length(:binary.matches(data, marker))}
            end)

          tail_size = min(byte_size(data), max_marker_size - 1)
          tail = binary_part(data, byte_size(data) - tail_size, tail_size)

          {:crypto.hash_update(digest, chunk), row_count + length(:binary.matches(chunk, "\n")),
           counts, tail}
        end
      )

    {Base.encode16(:crypto.hash_final(digest), case: :lower), row_count,
     Map.put(counts, "family", family)}
  end

  defp validate_metadata_markers!(markers, spec, "oolong_pairs") do
    Enum.each(~w(source revision split), fn key ->
      unless markers[key] > 0, do: raise(ArgumentError, "OOLONG-Pairs metadata is missing #{key}")
    end)

    unless markers["reserved"] == 1,
      do: raise(ArgumentError, "OOLONG-Pairs requires exactly one __contexts__ row")

    unless spec["context_grid"] == @oolong_pairs_context_grid,
      do: raise(ArgumentError, "OOLONG-Pairs requires the exact 11-size context grid")
  end

  defp validate_metadata_markers!(_markers, _spec, _family), do: :ok

  defp select_rows!(rows, spec, family) do
    ids = spec["sample_ids"]

    rows =
      if family == "oolong_pairs",
        do: Enum.reject(rows, &(&1["id"] == "__contexts__")),
        else: rows

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

  defp normalize_pair!(row, spec, contexts) do
    gold_by_context_size = Map.get(row, "gold_by_context_size")

    unless spec["context_grid"] == @oolong_pairs_context_grid,
      do: raise(ArgumentError, "OOLONG-Pairs requires the exact 11-size context grid")

    unless is_map(gold_by_context_size),
      do:
        raise(
          ArgumentError,
          "OOLONG-Pairs #{row["id"]} gold_by_context_size must be keyed by paper context size"
        )

    unless pair_context_keys?(gold_by_context_size),
      do: raise(ArgumentError, "OOLONG-Pairs #{row["id"]} must contain exactly 11 gold sets")

    Enum.map(@oolong_pairs_context_grid, fn size ->
      context = contexts[Integer.to_string(size)]
      gold_pairs = gold_by_context_size[Integer.to_string(size)]

      unless is_binary(context) or is_list(context),
        do: raise(ArgumentError, "OOLONG-Pairs #{row["id"]} is missing context size #{size}")

      gold = required_pair_answer!(gold_pairs, row["id"])

      base(row, "oolong_pairs")
      |> Map.put("query_id", row["id"])
      |> Map.put("id", "#{row["id"]}@#{size}")
      |> Map.put("context_size", size)
      |> Map.put("context", context)
      |> put_question!(row)
      |> Map.put("gold", gold)
    end)
  end

  defp shared_contexts!(rows) do
    reserved = Enum.filter(rows, &(&1["id"] == "__contexts__"))

    unless length(reserved) == 1,
      do: raise(ArgumentError, "OOLONG-Pairs requires exactly one __contexts__ row")

    unless List.first(rows)["id"] == "__contexts__",
      do: raise(ArgumentError, "OOLONG-Pairs __contexts__ row must be first")

    query_rows = Enum.reject(rows, &(&1["id"] == "__contexts__"))

    unless length(query_rows) == @oolong_pairs_query_count,
      do: raise(ArgumentError, "OOLONG-Pairs requires exactly 20 query rows after __contexts__")

    query_ids = Enum.map(query_rows, &required_string!(&1, "id", "oolong_pairs"))

    unless length(query_ids) == length(Enum.uniq(query_ids)),
      do: raise(ArgumentError, "OOLONG-Pairs query IDs must be unique")

    Enum.each(query_rows, fn row ->
      if Map.has_key?(row, "contexts"),
        do: raise(ArgumentError, "OOLONG-Pairs query rows must not contain contexts")

      gold = Map.get(row, "gold_by_context_size")

      unless is_map(gold) and pair_context_keys?(gold),
        do: raise(ArgumentError, "OOLONG-Pairs query gold must contain exactly 11 sizes")
    end)

    contexts = Map.get(hd(reserved), "contexts")

    unless is_map(contexts) and pair_context_keys?(contexts),
      do: raise(ArgumentError, "OOLONG-Pairs __contexts__ must contain exactly 11 contexts")

    Enum.each(@oolong_pairs_context_grid, fn size ->
      unless is_binary(contexts[Integer.to_string(size)]),
        do: raise(ArgumentError, "OOLONG-Pairs context #{size} must be a string")
    end)

    contexts
  end

  defp pair_context_keys?(value) when is_map(value) do
    expected = Enum.map(@oolong_pairs_context_grid, &Integer.to_string/1)
    Enum.sort(Map.keys(value)) == Enum.sort(expected)
  end

  defp pair_context_keys?(_value), do: false

  defp base(row, family), do: %{"id" => required_string!(row, "id", family), "family" => family}
  defp put_context!(out, row), do: Map.put(out, "context", required_context!(row, out["family"]))

  defp put_question_answer!(out, row),
    do:
      out
      |> Map.put("question", required_string!(row, "question", out["family"]))
      |> Map.put("gold", required_answer!(row, out["family"]))

  defp put_question!(out, row),
    do: Map.put(out, "question", required_string!(row, "question", out["family"]))

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

  defp required_pair_answer!(answer, id) do
    if is_list(answer) and Enum.all?(answer, &(is_binary(&1) and String.trim(&1) != "")),
      do: Enum.join(answer, "\n"),
      else: raise(ArgumentError, "oolong_pairs #{id} requires a list of pair strings")
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
