defmodule DSEx.Datasets do
  @moduledoc "Small dataset loaders for examples, JSONL, CSV, GSM8K, HotPotQA, MATH, and Colors records."

  defmodule Error do
    defexception [:message, :path, :line, :record]
  end

  def from_records(records, input_keys, opts \\ []) do
    source = Keyword.get(opts, :source, "records")
    record_module = Keyword.get(opts, :record)

    records
    |> Enum.with_index(1)
    |> Enum.map(fn {record, index} ->
      record
      |> normalize_record(record_module)
      |> validate_record!(input_keys, source, index)
      |> DSEx.Example.new()
      |> DSEx.Example.with_inputs(input_keys)
    end)
  end

  def jsonl(path, input_keys, opts \\ []) do
    path
    |> File.stream!()
    |> Stream.with_index(1)
    |> Stream.map(fn {line, line_number} -> {String.trim(line), line_number} end)
    |> Stream.reject(fn {line, _line_number} -> line == "" end)
    |> Enum.map(fn {line, line_number} -> decode_jsonl_line!(line, path, line_number) end)
    |> from_records(input_keys, Keyword.put_new(opts, :source, path))
  end

  def csv(path, input_keys, opts \\ []) do
    rows =
      path
      |> File.read!()
      |> String.split(~r/\R/, trim: true)
      |> Enum.map(&parse_csv_line/1)

    [header | rows] = require_csv_header!(rows, path)

    rows
    |> Enum.with_index(2)
    |> Enum.map(fn {row, line_number} ->
      validate_csv_row!(row, header, path, line_number)
      header |> Enum.zip(row) |> Map.new()
    end)
    |> from_records(input_keys, Keyword.put_new(opts, :source, path))
  end

  def gsm8k(path), do: jsonl(path, [:question], record: DSEx.Datasets.GSM8K.Record)

  def hotpotqa(path),
    do: jsonl(path, [:question, :context], record: DSEx.Datasets.HotPotQA.Record)

  def split(examples, opts \\ []) do
    train = train_fraction!(Keyword.get(opts, :train, 0.8))
    shuffled = if Keyword.get(opts, :shuffle, true), do: Enum.shuffle(examples), else: examples
    count = floor(length(shuffled) * train)
    Enum.split(shuffled, count)
  end

  defp require_csv_header!([], path) do
    raise Error,
      message: "invalid CSV dataset at #{path}: expected header row",
      path: path,
      line: 1,
      record: nil
  end

  defp require_csv_header!(rows, _path), do: rows

  defp parse_csv_line(line) do
    Regex.scan(~r/(?:^|,)(?:"([^"]*(?:""[^"]*)*)"|([^,]*))/, line)
    |> Enum.map(fn
      [_all, quoted, ""] -> String.replace(quoted, "\"\"", "\"")
      [_all, "", bare] -> bare
    end)
  end

  defp decode_jsonl_line!(line, path, line_number) do
    case Jason.decode(line) do
      {:ok, record} when is_map(record) ->
        record

      {:ok, other} ->
        raise Error,
          message:
            "invalid JSONL record at #{path}:#{line_number}: expected object, got #{inspect(other)}",
          path: path,
          line: line_number,
          record: other

      {:error, %Jason.DecodeError{} = error} ->
        raise Error,
          message: "invalid JSONL at #{path}:#{line_number}: #{Exception.message(error)}",
          path: path,
          line: line_number,
          record: line
    end
  end

  defp normalize_record(%_module{} = record, nil), do: Map.from_struct(record)

  defp normalize_record(%module{} = record, module), do: Map.from_struct(record)

  defp normalize_record(record, nil) when is_map(record), do: record

  defp normalize_record(record, module) when is_map(record),
    do: module |> struct(existing_keys(record)) |> Map.from_struct()

  defp normalize_record(record, _module), do: record

  defp validate_record!(record, input_keys, source, index) when is_map(record) do
    missing =
      input_keys
      |> List.wrap()
      |> Enum.map(&normalize_key/1)
      |> Enum.reject(fn key ->
        match?({:ok, value} when not is_nil(value), fetch_record_key(record, key))
      end)

    case missing do
      [] ->
        record

      keys ->
        raise Error,
          message:
            "invalid dataset record at #{source}:#{index}: missing required input keys #{inspect(keys)}",
          path: source,
          line: index,
          record: record
    end
  end

  defp validate_record!(record, _input_keys, source, index) do
    raise Error,
      message:
        "invalid dataset record at #{source}:#{index}: expected map, got #{inspect(record)}",
      path: source,
      line: index,
      record: record
  end

  defp validate_csv_row!(row, header, path, line_number) do
    if length(row) != length(header) do
      raise Error,
        message:
          "invalid CSV row at #{path}:#{line_number}: expected #{length(header)} fields, got #{length(row)}",
        path: path,
        line: line_number,
        record: row
    end

    :ok
  end

  defp train_fraction!(value) when is_number(value) and value >= 0 and value <= 1,
    do: value

  defp train_fraction!(value) do
    raise ArgumentError,
          "dataset train split must be a number between 0.0 and 1.0, got: #{inspect(value)}"
  end

  defp existing_keys(record),
    do: Map.new(record, fn {key, value} -> {normalize_key(key), value} end)

  defp normalize_key(key) when is_atom(key), do: key
  defp normalize_key(key) when is_binary(key), do: existing_atom_or_string(key)

  defp existing_atom_or_string(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  defp fetch_record_key(record, key) when is_atom(key) do
    cond do
      Map.has_key?(record, key) -> Map.fetch(record, key)
      Map.has_key?(record, Atom.to_string(key)) -> Map.fetch(record, Atom.to_string(key))
      true -> :error
    end
  end

  defp fetch_record_key(record, key) when is_binary(key) do
    cond do
      Map.has_key?(record, key) -> Map.fetch(record, key)
      is_atom(existing_atom_or_string(key)) -> Map.fetch(record, existing_atom_or_string(key))
      true -> :error
    end
  end
end

defmodule DSEx.Datasets.Dataset do
  @moduledoc "Dataset container with train/dev/test splits."
  defstruct train: [], dev: [], test: [], metadata: %{}

  def new(examples, opts \\ []) do
    {train, rest} =
      DSEx.Datasets.split(examples,
        train: Keyword.get(opts, :train, 0.8),
        shuffle: Keyword.get(opts, :shuffle, false)
      )

    {dev, test} = Enum.split(rest, div(length(rest), 2))
    %__MODULE__{train: train, dev: dev, test: test, metadata: Keyword.get(opts, :metadata, %{})}
  end
end

defmodule DSEx.Datasets.DataLoader do
  @moduledoc "Loader facade for JSONL/CSV records."

  def load(path, input_keys, opts \\ []) do
    case Keyword.get(opts, :format, Path.extname(path)) do
      ".csv" -> DSEx.Datasets.csv(path, input_keys)
      _ -> DSEx.Datasets.jsonl(path, input_keys)
    end
  end
end

defmodule DSEx.Datasets.GSM8K do
  @moduledoc "GSM8K-style JSONL dataset loader."
  defmodule Record, do: defstruct([:question, :answer, :canonical_answer, :source_task])

  def load(path), do: DSEx.Datasets.gsm8k(path)

  def metric(example, prediction, _trace \\ nil) do
    DSEx.Metrics.em(
      DSEx.Prediction.get(prediction, :answer),
      DSEx.Example.get(example, :answer)
    )
  end
end

defmodule DSEx.Datasets.HotPotQA do
  @moduledoc "HotPotQA-style JSONL dataset loader."
  defmodule Record,
    do: defstruct([:id, :question, :context, :answer, :supporting_facts, :source_task])

  def load(path), do: DSEx.Datasets.hotpotqa(path)
end

defmodule DSEx.Datasets.MATH do
  @moduledoc "MATH-style JSONL dataset loader."
  defmodule Record, do: defstruct([:problem, :solution, :answer])

  def load(path), do: DSEx.Datasets.jsonl(path, [:problem], record: __MODULE__.Record)
end

defmodule DSEx.Datasets.Colors do
  @moduledoc "Simple color dataset helper."
  defmodule Record, do: defstruct([:input, :label])

  def load(records),
    do: DSEx.Datasets.from_records(records, [:input], record: __MODULE__.Record)
end
