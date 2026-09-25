defmodule Imp.Datasets do
  @moduledoc """
  Local dataset loaders for examples, JSONL, CSV, GSM8K, HotPotQA, MATH, and
  Colors records.

  Named loaders accept an existing local path; they do not download datasets.
  Source-checkout benchmark fixtures are fetched explicitly with the
  `imp.benchmark.fetch` Mix task.
  """

  defmodule Error do
    @moduledoc """
    Raised by a file loader for a file it cannot read or a record it cannot
    parse: `path` is the file, `line` the line number when there is one, and
    `record` the value that could not be read.
    """

    defexception [:message, :path, :line, :record]
  end

  @records_option_schema [
    source: [type: :any, default: "records"],
    record: [type: :any, default: nil]
  ]

  @file_records_option_schema [
    source: [type: :any],
    record: [type: :any]
  ]

  @split_option_schema [
    train: [
      type: {:custom, __MODULE__, :validate_train_fraction, []},
      default: 0.8
    ],
    shuffle: [type: :boolean, default: true],
    seed: [type: :non_neg_integer, default: 0]
  ]

  def from_records(records, input_keys, opts \\ []) do
    opts = Imp.Options.validate!(opts, @records_option_schema, "Imp.Datasets.from_records/3")
    records = validate_enumerable!(records, "Imp.Datasets.from_records/3", "records")
    source = opts[:source]
    record_module = opts[:record]

    records
    |> Enum.with_index(1)
    |> Enum.map(fn {record, index} ->
      record
      |> normalize_record(record_module)
      |> validate_record!(input_keys, source, index)
      |> Imp.Example.new()
      |> Imp.Example.with_inputs(input_keys)
    end)
  end

  def jsonl(path, input_keys, opts \\ []) do
    opts = Imp.Options.validate!(opts, @file_records_option_schema, "Imp.Datasets.jsonl/3")
    path = validate_path!(path, "Imp.Datasets.jsonl/3")

    path
    |> File.stream!()
    |> Stream.with_index(1)
    |> Stream.map(fn {line, line_number} -> {String.trim(line), line_number} end)
    |> Stream.reject(fn {line, _line_number} -> line == "" end)
    |> Enum.map(fn {line, line_number} -> decode_jsonl_line!(line, path, line_number) end)
    |> from_records(input_keys, Keyword.put_new(opts, :source, path))
  end

  def csv(path, input_keys, opts \\ []) do
    opts = Imp.Options.validate!(opts, @file_records_option_schema, "Imp.Datasets.csv/3")
    path = validate_path!(path, "Imp.Datasets.csv/3")

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

  def gsm8k(path), do: jsonl(path, [:question], record: Imp.Datasets.GSM8K.Record)

  def hotpotqa(path),
    do: jsonl(path, [:question, :context], record: Imp.Datasets.HotPotQA.Record)

  @doc """
  Splits examples into `{train, rest}` at the `:train` fraction (default `0.8`).

  With `shuffle: true` (the default) the examples are shuffled with a seeded
  RNG before splitting. The shuffle is deterministic: the same examples and
  the same `:seed` (default `0`) always produce the same split, so downstream
  consumers such as `Imp.Optimizer.LabeledFewShot` see the same trainset on
  every run. Pass a different `seed:` for a different permutation, or
  `shuffle: false` to preserve input order.
  """
  def split(examples, opts \\ []) do
    opts = Imp.Options.validate!(opts, @split_option_schema, "Imp.Datasets.split/2")

    examples =
      examples
      |> validate_enumerable!("Imp.Datasets.split/2", "examples")
      |> Enum.to_list()

    train = opts[:train]

    shuffled =
      if opts[:shuffle] do
        {shuffled, _rng} =
          Imp.Optimizer.Sampling.shuffle(examples, Imp.Optimizer.Sampling.new(opts[:seed]))

        shuffled
      else
        examples
      end

    count = floor(length(shuffled) * train)
    Enum.split(shuffled, count)
  end

  @doc false
  def validate_train_fraction(value) when is_number(value) and value >= 0 and value <= 1,
    do: {:ok, value}

  def validate_train_fraction(value),
    do: {:error, "expected a number between 0.0 and 1.0, got: #{inspect(value)}"}

  @doc false
  def validate_path!(path, _context) when is_binary(path), do: path

  def validate_path!(path, context) do
    raise ArgumentError, "#{context} expects path to be a binary; got: #{inspect(path)}"
  end

  defp validate_enumerable!(value, context, name) do
    if Enumerable.impl_for(value) do
      value
    else
      raise ArgumentError,
            "#{context} expects #{name} to be an enumerable; got: #{inspect(value)}"
    end
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

  defp existing_keys(record),
    do: Map.new(record, fn {key, value} -> {normalize_key(key), value} end)

  defp normalize_key(key) when is_atom(key), do: key
  defp normalize_key(key) when is_binary(key), do: existing_atom_or_string(key)

  defp normalize_key(key) do
    raise ArgumentError,
          "Imp.Datasets input keys and record keys must be atoms or strings; got: #{inspect(key)}"
  end

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

defmodule Imp.Datasets.Dataset do
  @moduledoc "Dataset container with train/dev/test splits."
  defstruct train: [], dev: [], test: [], metadata: %{}

  @option_schema [
    train: [
      type: {:custom, Imp.Datasets, :validate_train_fraction, []},
      default: 0.8
    ],
    shuffle: [type: :boolean, default: false],
    seed: [type: :non_neg_integer, default: 0],
    metadata: [type: {:map, :any, :any}, default: %{}]
  ]

  def new(examples, opts \\ []) do
    opts = Imp.Options.validate!(opts, @option_schema, "Imp.Datasets.Dataset.new/2")

    {train, rest} =
      Imp.Datasets.split(examples,
        train: opts[:train],
        shuffle: opts[:shuffle],
        seed: opts[:seed]
      )

    {dev, test} = Enum.split(rest, div(length(rest), 2))
    %__MODULE__{train: train, dev: dev, test: test, metadata: opts[:metadata]}
  end
end

defmodule Imp.Datasets.DataLoader do
  @moduledoc "Loader facade for JSONL/CSV records."

  @option_schema [
    format: [type: :string]
  ]

  @doc "Reads a JSONL or CSV file into examples, choosing the format by `:format` or the extension."
  def read!(path, input_keys, opts \\ []) do
    opts = Imp.Options.validate!(opts, @option_schema, "Imp.Datasets.DataLoader.read!/3")
    path = Imp.Datasets.validate_path!(path, "Imp.Datasets.DataLoader.read!/3")

    case normalize_format!(Keyword.get(opts, :format, Path.extname(path))) do
      :csv -> Imp.Datasets.csv(path, input_keys)
      :jsonl -> Imp.Datasets.jsonl(path, input_keys)
    end
  end

  defp normalize_format!(format) when format in [".csv", "csv"], do: :csv
  defp normalize_format!(format) when format in [".jsonl", "jsonl", ".json", "json"], do: :jsonl

  defp normalize_format!(format) do
    raise ArgumentError,
          "Imp.Datasets.DataLoader.read!/3 supports format .jsonl, jsonl, .json, json, .csv, or csv; got: #{inspect(format)}"
  end
end

defmodule Imp.Datasets.GSM8K do
  @moduledoc "GSM8K-style JSONL dataset loader."
  defmodule Record do
    @moduledoc false
    defstruct [:question, :answer, :canonical_answer, :source_task]
  end

  @doc "Reads a GSM8K JSONL file into examples."
  def read!(path), do: Imp.Datasets.gsm8k(path)

  # Fetched GSM8K rows keep the full rationale (ending "#### N") in :answer
  # and the bare number in :canonical_answer. DSPy's gsm8k_metric
  # (dspy/datasets/gsm8k.py) compares parse_integer_answer on BOTH sides, so
  # a prediction of exactly "18" scores true against gold "... #### 18".
  # Scoring text EM on the raw :answer marked every correct prediction as a
  # failure on the repo's own fetched data. This mirrors the benchmark
  # runner's internal scorer (Imp.BenchmarkTruth.Runner metric(:gsm8k)):
  # canonical gold first, numeric equivalence, then normalized text EM.
  def metric(example, prediction, _trace \\ nil) do
    gold =
      example
      |> Imp.Example.get(:canonical_answer, Imp.Example.get(example, :answer))
      |> canonical_gold()

    predicted = Imp.Prediction.get(prediction, :answer)

    numeric_answer_equal?(predicted, gold) or Imp.Metrics.em(predicted, gold)
  end

  # Rows without :canonical_answer may still carry the raw "#### N" rationale;
  # extract the final answer the way the fetcher does.
  defp canonical_gold(nil), do: nil

  defp canonical_gold(value) do
    value
    |> to_string()
    |> String.split("####")
    |> List.last()
    |> String.trim()
  end

  defp numeric_answer_equal?(predicted, gold) do
    with {:ok, predicted_number} <- parse_numeric_answer(predicted),
         {:ok, gold_number} <- parse_numeric_answer(gold) do
      abs(predicted_number - gold_number) <= 1.0e-9
    else
      _other -> false
    end
  end

  defp parse_numeric_answer(value) do
    text =
      value
      |> to_string()
      |> String.trim()
      |> String.replace(",", "")
      |> String.trim_leading("$")

    if String.match?(text, ~r/^-?\d+(?:\.\d+)?$/) do
      case Float.parse(text) do
        {number, ""} -> {:ok, number}
        _other -> :error
      end
    else
      :error
    end
  end
end

defmodule Imp.Datasets.HotPotQA do
  @moduledoc "HotPotQA-style JSONL dataset loader."
  defmodule Record do
    @moduledoc false
    defstruct [:id, :question, :context, :answer, :supporting_facts, :source_task]
  end

  @doc "Reads a HotPotQA JSONL file into examples."
  def read!(path), do: Imp.Datasets.hotpotqa(path)
end

defmodule Imp.Datasets.MATH do
  @moduledoc "MATH-style JSONL dataset loader."
  defmodule Record do
    @moduledoc false
    defstruct [:problem, :solution, :answer]
  end

  @doc "Reads a MATH JSONL file into examples."
  def read!(path), do: Imp.Datasets.jsonl(path, [:problem], record: __MODULE__.Record)
end

defmodule Imp.Datasets.Colors do
  @moduledoc "Simple color dataset helper."
  defmodule Record do
    @moduledoc false
    defstruct [:input, :label]
  end

  @doc "Builds examples from color records, raising on a malformed one."
  def load!(records),
    do: Imp.Datasets.from_records(records, [:input], record: __MODULE__.Record)
end
