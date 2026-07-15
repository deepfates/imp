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
    row_limit = Keyword.get(opts, :row_limit)

    Map.new(manifest["datasets"], fn {family, spec} ->
      {family, load!(family, spec, root, row_limit: row_limit)}
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

  def load!(family, spec, root, opts \\ []) do
    row_limit = Keyword.get(opts, :row_limit)

    unless is_nil(row_limit) or (is_integer(row_limit) and row_limit > 0),
      do: raise(ArgumentError, "row limit must be a positive integer")

    if family == "oolong_pairs" and is_integer(row_limit) do
      load_limited_oolong_pairs!(spec, root, row_limit)
    else
      load_eager!(family, spec, root)
    end
  end

  defp load_eager!(family, spec, root) do
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
          Enum.flat_map(selected, &normalize_pair!(&1, spec, contexts, spec["context_grid"]))

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

  defp load_limited_oolong_pairs!(spec, root, row_limit) do
    path = Path.expand(spec["path"], root)
    file_identity = file_identity!(path)
    actual = sha256_file!(path)

    unless actual == spec["sha256"],
      do:
        raise(
          ArgumentError,
          "dataset oolong_pairs hash mismatch: expected #{spec["sha256"]}, got #{actual}"
        )

    requested =
      "oolong_pairs"
      |> metadata_rows(spec["sample_ids"], spec["context_grid"])
      |> Enum.take(row_limit)

    requested_ids = requested |> Enum.map(& &1["query_id"]) |> Enum.uniq()
    sizes_by_query = Enum.group_by(requested, & &1["query_id"], & &1["context_size"])
    ranges = jsonl_ranges!(path)

    unless length(ranges) == 1 + @oolong_pairs_query_count,
      do: raise(ArgumentError, "OOLONG-Pairs JSONL row count does not match frozen IDs")

    reserved = ranges |> hd() |> read_range!(path) |> decode_jsonl_line!(path, 1)

    selected =
      Map.new(requested_ids, fn id ->
        line_number = Enum.find_index(spec["sample_ids"], &(&1 == id)) + 2
        range = Enum.at(ranges, line_number - 1)

        {id,
         decode_limited_pair_range!(
           path,
           range,
           line_number,
           id,
           Map.fetch!(sizes_by_query, id)
         )}
      end)

    selected_rows = Enum.map(requested_ids, &Map.fetch!(selected, &1))
    validate_dataset_identity!([reserved | selected_rows], spec, "oolong_pairs")
    contexts = contexts_from_reserved!(reserved)

    normalized =
      Enum.flat_map(selected_rows, fn row ->
        normalize_pair!(row, spec, contexts, Map.fetch!(sizes_by_query, row["id"]))
      end)

    verify_unchanged_file!(path, file_identity, actual)

    %{
      "family" => "oolong_pairs",
      "path" => path,
      "sha256" => actual,
      "source" => spec["source"],
      "revision" => spec["revision"],
      "split" => spec["split"],
      "logical_instances" => length(requested_ids),
      "evaluated_rows" => length(normalized),
      "sample_ids" => requested_ids,
      "sample_ids_sha256" => sha256(Jason.encode!(requested_ids)),
      "evaluated_keys" => Enum.map(normalized, &metadata_key/1),
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

    unless valid_pair_context_grid?(spec["context_grid"]),
      do:
        raise(
          ArgumentError,
          "OOLONG-Pairs context grid must be a non-empty ordered paper-grid subset"
        )
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

  defp normalize_pair!(row, spec, contexts, sizes) do
    gold_by_context_size = Map.get(row, "gold_by_context_size")

    unless valid_pair_context_grid?(spec["context_grid"]),
      do:
        raise(
          ArgumentError,
          "OOLONG-Pairs context grid must be a non-empty ordered paper-grid subset"
        )

    unless is_map(gold_by_context_size),
      do:
        raise(
          ArgumentError,
          "OOLONG-Pairs #{row["id"]} gold_by_context_size must be keyed by paper context size"
        )

    expected_gold_keys = Enum.map(sizes, &Integer.to_string/1)

    unless Enum.all?(expected_gold_keys, &Map.has_key?(gold_by_context_size, &1)),
      do:
        raise(
          ArgumentError,
          "OOLONG-Pairs #{row["id"]} must contain the selected gold sets"
        )

    Enum.map(sizes, fn size ->
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

    contexts_from_reserved!(hd(reserved))
  end

  defp contexts_from_reserved!(reserved) do
    contexts = Map.get(reserved, "contexts")

    unless is_map(contexts) and pair_context_keys?(contexts),
      do: raise(ArgumentError, "OOLONG-Pairs __contexts__ must contain exactly 11 contexts")

    Enum.each(@oolong_pairs_context_grid, fn size ->
      unless is_binary(contexts[Integer.to_string(size)]),
        do: raise(ArgumentError, "OOLONG-Pairs context #{size} must be a string")
    end)

    contexts
  end

  defp decode_jsonl_line!(line, path, number) do
    case Jason.decode(line) do
      {:ok, row} when is_map(row) ->
        row

      {:ok, _} ->
        raise ArgumentError, "dataset #{path}:#{number} must be a JSON object"

      {:error, error} ->
        raise ArgumentError,
              "invalid dataset JSON #{path}:#{number}: #{Exception.message(error)}"
    end
  end

  defp decode_limited_pair_range!(path, range, number, id, sizes) do
    decoded_id = jaxon_one!(path, range, [:root, "id"], number)

    unless decoded_id == id,
      do:
        raise(
          ArgumentError,
          "dataset #{path}:#{number} expected id #{inspect(id)}, got #{inspect(decoded_id)}"
        )

    %{
      "id" => decoded_id,
      "source" => jaxon_one!(path, range, [:root, "source"], number),
      "revision" => jaxon_one!(path, range, [:root, "revision"], number),
      "split" => jaxon_one!(path, range, [:root, "split"], number),
      "question" => jaxon_one!(path, range, [:root, "question"], number),
      "gold_by_context_size" =>
        Map.new(sizes, fn size ->
          key = Integer.to_string(size)

          {key,
           jaxon_all!(
             path,
             range,
             [:root, "gold_by_context_size", key, :all],
             number
           )}
        end)
    }
  end

  defp jaxon_one!(path, range, query, number) do
    case jaxon_all!(path, range, query, number) do
      [value] ->
        value

      values ->
        raise ArgumentError,
              "dataset #{path}:#{number} expected one #{inspect(query)}, got #{length(values)}"
    end
  end

  defp jaxon_all!(path, range, query, number) do
    path
    |> range_stream(range)
    |> Jaxon.Stream.from_enumerable()
    |> Jaxon.Stream.query(query)
    |> Enum.to_list()
    |> Enum.map(&detach_json/1)
  rescue
    error in [Jaxon.ParseError] ->
      reraise ArgumentError,
              [message: "invalid dataset JSON #{path}:#{number}: #{Exception.message(error)}"],
              __STACKTRACE__
  end

  defp jsonl_ranges!(path) do
    {offset, line_start, ranges} =
      path
      |> File.stream!([], @metadata_chunk_size)
      |> Enum.reduce({0, 0, []}, fn chunk, {offset, line_start, ranges} ->
        {line_start, ranges} =
          Enum.reduce(:binary.matches(chunk, "\n"), {line_start, ranges}, fn {at, 1},
                                                                             {current_start,
                                                                              ranges} ->
            newline = offset + at
            {newline + 1, [{current_start, newline - current_start} | ranges]}
          end)

        {offset + byte_size(chunk), line_start, ranges}
      end)

    ranges =
      if line_start < offset, do: [{line_start, offset - line_start} | ranges], else: ranges

    Enum.reverse(ranges)
  end

  defp read_range!({start, length}, path) do
    {:ok, io} = File.open(path, [:read, :binary, :raw])

    try do
      {:ok, bytes} = :file.pread(io, start, length)
      bytes
    after
      File.close(io)
    end
  end

  defp range_stream(path, {start, length}) do
    Stream.resource(
      fn ->
        io = File.open!(path, [:read, :binary, :raw])
        {:ok, ^start} = :file.position(io, start)
        {io, length}
      end,
      fn
        {io, 0} ->
          {:halt, {io, 0}}

        {io, remaining} ->
          count = min(remaining, @metadata_chunk_size)

          case IO.binread(io, count) do
            bytes when is_binary(bytes) -> {[bytes], {io, remaining - byte_size(bytes)}}
            :eof -> raise ArgumentError, "unexpected end of JSONL range"
            {:error, reason} -> raise File.Error, reason: reason, action: "read", path: path
          end
      end,
      fn {io, _remaining} -> File.close(io) end
    )
  end

  defp detach_json(value) when is_binary(value), do: :binary.copy(value)
  defp detach_json(value), do: value

  defp pair_context_keys?(value) when is_map(value) do
    expected = Enum.map(@oolong_pairs_context_grid, &Integer.to_string/1)
    Enum.sort(Map.keys(value)) == Enum.sort(expected)
  end

  defp pair_context_keys?(_value), do: false

  defp valid_pair_context_grid?(grid) when is_list(grid) do
    grid != [] and grid == Enum.filter(@oolong_pairs_context_grid, &(&1 in grid))
  end

  defp valid_pair_context_grid?(_grid), do: false

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

  defp sha256_file!(path) do
    digest =
      path
      |> File.stream!([], @metadata_chunk_size)
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))

    digest |> :crypto.hash_final() |> Base.encode16(case: :lower)
  end

  defp file_identity!(path) do
    stat = File.stat!(path)
    {stat.major_device, stat.inode, stat.size, stat.mtime, stat.ctime}
  end

  defp verify_unchanged_file!(path, expected_identity, expected_sha256) do
    identity = file_identity!(path)
    sha256 = sha256_file!(path)

    unless identity == expected_identity and sha256 == expected_sha256,
      do: raise(ArgumentError, "dataset changed while loading: #{path}")
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
