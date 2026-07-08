defmodule DatasetsContractTest do
  use ExUnit.Case

  alias DSEx.Datasets

  test "GSM8K JSONL loader rejects malformed JSON with path and line context" do
    path = tmp_path("bad-gsm8k.jsonl")
    File.write!(path, ~s({"question":"2+2?","answer":"4"}\n{"question":\n))

    assert_raise Datasets.Error, ~r/invalid JSONL at #{Regex.escape(path)}:2/, fn ->
      Datasets.gsm8k(path)
    end
  after
    cleanup_tmp("bad-gsm8k.jsonl")
  end

  test "dataset loaders reject rows missing declared input keys" do
    path = tmp_path("missing-question.jsonl")
    File.write!(path, ~s({"answer":"4"}\n))

    assert_raise Datasets.Error, ~r/missing required input keys \[:question\]/, fn ->
      Datasets.GSM8K.load(path)
    end
  after
    cleanup_tmp("missing-question.jsonl")
  end

  test "CSV loader rejects rows with the wrong number of fields" do
    path = tmp_path("ragged.csv")
    File.write!(path, "question,answer\n2+2?,4,extra\n")

    assert_raise Datasets.Error, ~r/invalid CSV row .*:2: expected 2 fields, got 3/, fn ->
      Datasets.csv(path, [:question])
    end
  after
    cleanup_tmp("ragged.csv")
  end

  test "CSV loader rejects empty files with dataset context" do
    path = tmp_path("empty.csv")
    File.write!(path, "")

    assert_raise Datasets.Error, ~r/invalid CSV dataset .*: expected header row/, fn ->
      Datasets.csv(path, [:question])
    end
  after
    cleanup_tmp("empty.csv")
  end

  test "dataset split validates train fraction" do
    examples = [
      DSEx.example(question: "a", answer: "b") |> DSEx.with_inputs(:question)
    ]

    assert_raise ArgumentError, ~r/train split must be a number between 0.0 and 1.0/, fn ->
      Datasets.split(examples, train: 1.5)
    end

    assert_raise ArgumentError, ~r/train split must be a number between 0.0 and 1.0/, fn ->
      Datasets.Dataset.new(examples, train: -0.1)
    end
  end

  test "dataset APIs report invalid option containers clearly" do
    examples = [
      DSEx.example(question: "a", answer: "b") |> DSEx.with_inputs(:question)
    ]

    assert_raise ArgumentError,
                 ~r/DSEx\.Datasets\.from_records\/3: expected keyword options/,
                 fn ->
                   Datasets.from_records([%{question: "a"}], [:question], :not_options)
                 end

    assert_raise ArgumentError, ~r/DSEx\.Datasets\.split\/2: expected keyword options/, fn ->
      Datasets.split(examples, :not_options)
    end

    assert_raise ArgumentError,
                 ~r/DSEx\.Datasets\.Dataset\.new\/2: expected keyword options/,
                 fn ->
                   Datasets.Dataset.new(examples, :not_options)
                 end

    assert_raise ArgumentError,
                 ~r/DSEx\.Datasets\.Dataset\.new\/2.*:metadata.*expected.*map/s,
                 fn ->
                   Datasets.Dataset.new(examples, metadata: :not_metadata)
                 end

    assert_raise ArgumentError,
                 ~r/DSEx\.Datasets\.DataLoader\.load\/3: expected keyword options/,
                 fn ->
                   Datasets.DataLoader.load("missing.jsonl", [:question], :not_options)
                 end
  end

  test "dataset APIs report invalid input and record keys clearly" do
    assert_raise ArgumentError,
                 ~r/DSEx\.Datasets input keys and record keys must be atoms or strings/,
                 fn ->
                   Datasets.from_records([%{question: "a"}], [123])
                 end

    assert_raise ArgumentError,
                 ~r/DSEx\.Datasets input keys and record keys must be atoms or strings/,
                 fn ->
                   Datasets.from_records([%{123 => "a"}], [:question],
                     record: Datasets.GSM8K.Record
                   )
                 end
  end

  test "JSONL option validation preserves path-backed source context" do
    path = tmp_path("missing-with-options.jsonl")
    File.write!(path, ~s({"answer":"4"}\n))

    assert_raise Datasets.Error, ~r/invalid dataset record at #{Regex.escape(path)}:1/, fn ->
      Datasets.jsonl(path, [:question], record: Datasets.GSM8K.Record)
    end
  after
    cleanup_tmp("missing-with-options.jsonl")
  end

  test "typed dataset records load as examples for GSM8K HotPotQA MATH and Colors" do
    gsm8k_path = tmp_path("typed-gsm8k.jsonl")
    hotpot_path = tmp_path("typed-hotpot.jsonl")
    math_path = tmp_path("typed-math.jsonl")

    File.write!(
      gsm8k_path,
      ~s({"question":"2+2?","answer":"work #### 4","canonical_answer":"4","source_task":"gsm8k"}\n)
    )

    File.write!(
      hotpot_path,
      ~s({"id":"hp","question":"q","context":["c1"],"answer":"a","supporting_facts":{"title":["t"],"sent_id":[0]},"source_task":"hotpotqa"}\n)
    )

    File.write!(math_path, ~s({"problem":"1+1","solution":"2","answer":"2"}\n))

    assert [%DSEx.Example{} = gsm8k] = Datasets.GSM8K.load(gsm8k_path)
    assert DSEx.Example.to_map(DSEx.Example.inputs(gsm8k)) == %{question: "2+2?"}
    assert DSEx.Example.get(gsm8k, :canonical_answer) == "4"
    assert DSEx.Example.get(gsm8k, :source_task) == "gsm8k"

    assert [%DSEx.Example{} = hotpot] = Datasets.HotPotQA.load(hotpot_path)

    assert DSEx.Example.to_map(DSEx.Example.inputs(hotpot)) == %{
             question: "q",
             context: ["c1"]
           }

    assert DSEx.Example.get(hotpot, :id) == "hp"
    assert DSEx.Example.get(hotpot, :supporting_facts) == %{"title" => ["t"], "sent_id" => [0]}

    assert [%DSEx.Example{} = math] = Datasets.MATH.load(math_path)
    assert DSEx.Example.to_map(DSEx.Example.inputs(math)) == %{problem: "1+1"}

    colors = Datasets.Colors.load([%Datasets.Colors.Record{input: "red", label: "warm"}])
    assert [%DSEx.Example{} = color] = colors
    assert DSEx.Example.to_map(DSEx.Example.inputs(color)) == %{input: "red"}
  after
    cleanup_tmp("typed-gsm8k.jsonl")
    cleanup_tmp("typed-hotpot.jsonl")
    cleanup_tmp("typed-math.jsonl")
  end

  defp tmp_path(name),
    do: Path.join(System.tmp_dir!(), "dsex-#{:erlang.phash2(self())}-#{name}")

  defp cleanup_tmp(name), do: File.rm(tmp_path(name))
end
