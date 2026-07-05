defmodule DSPy.Datasets do
  @moduledoc "Small dataset loaders for examples, JSONL, CSV, GSM8K, and HotPotQA-style records."

  def from_records(records, input_keys) do
    Enum.map(records, fn record ->
      record
      |> DSPy.Example.new()
      |> DSPy.Example.with_inputs(input_keys)
    end)
  end

  def jsonl(path, input_keys) do
    path
    |> File.stream!()
    |> Stream.map(&String.trim/1)
    |> Stream.reject(&(&1 == ""))
    |> Enum.map(&Jason.decode!/1)
    |> from_records(input_keys)
  end

  def csv(path, input_keys) do
    [header | rows] =
      path
      |> File.read!()
      |> String.split(~r/\R/, trim: true)
      |> Enum.map(&parse_csv_line/1)

    rows
    |> Enum.map(fn row -> header |> Enum.zip(row) |> Map.new() end)
    |> from_records(input_keys)
  end

  def gsm8k(path), do: jsonl(path, [:question])
  def hotpotqa(path), do: jsonl(path, [:question, :context])

  def split(examples, opts \\ []) do
    train = Keyword.get(opts, :train, 0.8)
    shuffled = if Keyword.get(opts, :shuffle, true), do: Enum.shuffle(examples), else: examples
    count = floor(length(shuffled) * train)
    Enum.split(shuffled, count)
  end

  defp parse_csv_line(line) do
    Regex.scan(~r/(?:^|,)(?:"([^"]*(?:""[^"]*)*)"|([^,]*))/, line)
    |> Enum.map(fn
      [_all, quoted, ""] -> String.replace(quoted, "\"\"", "\"")
      [_all, "", bare] -> bare
    end)
  end
end

defmodule DSPy.Datasets.Dataset do
  @moduledoc "Dataset container with train/dev/test splits."
  defstruct train: [], dev: [], test: [], metadata: %{}

  def new(examples, opts \\ []) do
    {train, rest} =
      DSPy.Datasets.split(examples,
        train: Keyword.get(opts, :train, 0.8),
        shuffle: Keyword.get(opts, :shuffle, false)
      )

    {dev, test} = Enum.split(rest, div(length(rest), 2))
    %__MODULE__{train: train, dev: dev, test: test, metadata: Keyword.get(opts, :metadata, %{})}
  end
end

defmodule DSPy.Datasets.DataLoader do
  @moduledoc "Loader facade for JSONL/CSV records."

  def load(path, input_keys, opts \\ []) do
    case Keyword.get(opts, :format, Path.extname(path)) do
      ".csv" -> DSPy.Datasets.csv(path, input_keys)
      _ -> DSPy.Datasets.jsonl(path, input_keys)
    end
  end
end

defmodule DSPy.Datasets.GSM8K do
  @moduledoc "GSM8K-style JSONL dataset loader."
  def load(path), do: DSPy.Datasets.gsm8k(path)

  def metric(example, prediction, _trace \\ nil) do
    DSPy.Metrics.em(DSPy.Prediction.get(prediction, :answer), DSPy.Example.get(example, :answer))
  end
end

defmodule DSPy.Datasets.HotPotQA do
  @moduledoc "HotPotQA-style JSONL dataset loader."
  def load(path), do: DSPy.Datasets.hotpotqa(path)
end

defmodule DSPy.Datasets.MATH do
  @moduledoc "MATH-style JSONL dataset loader."
  def load(path), do: DSPy.Datasets.jsonl(path, [:problem])
end

defmodule DSPy.Datasets.Colors do
  @moduledoc "Simple color dataset helper."
  def load(records), do: DSPy.Datasets.from_records(records, [:input])
end
