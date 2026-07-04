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
