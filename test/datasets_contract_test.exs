defmodule DatasetsContractTest do
  use ExUnit.Case

  alias Imp.Datasets

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
      Datasets.GSM8K.read!(path)
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
      Imp.example(question: "a", answer: "b") |> Imp.with_inputs(:question)
    ]

    assert_raise ArgumentError,
                 ~r/Imp\.Datasets\.split\/2: invalid value for :train option: expected a number between 0.0 and 1.0/,
                 fn ->
                   Datasets.split(examples, train: 1.5)
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Datasets\.split\/2: invalid value for :train option: expected a number between 0.0 and 1.0/,
                 fn ->
                   Datasets.split(examples, train: "0.8")
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Datasets\.Dataset\.new\/2: invalid value for :train option: expected a number between 0.0 and 1.0/,
                 fn ->
                   Datasets.Dataset.new(examples, train: -0.1)
                 end
  end

  test "dataset APIs report invalid option containers clearly" do
    examples = [
      Imp.example(question: "a", answer: "b") |> Imp.with_inputs(:question)
    ]

    assert_raise ArgumentError,
                 ~r/Imp\.Datasets\.from_records\/3: expected keyword options/,
                 fn ->
                   Datasets.from_records([%{question: "a"}], [:question], :not_options)
                 end

    assert_raise ArgumentError, ~r/Imp\.Datasets\.split\/2: expected keyword options/, fn ->
      Datasets.split(examples, :not_options)
    end

    assert_raise ArgumentError,
                 ~r/Imp\.Datasets\.Dataset\.new\/2: expected keyword options/,
                 fn ->
                   Datasets.Dataset.new(examples, :not_options)
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Datasets\.Dataset\.new\/2.*:metadata.*expected.*map/s,
                 fn ->
                   Datasets.Dataset.new(examples, metadata: :not_metadata)
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Datasets\.DataLoader\.read!\/3: expected keyword options/,
                 fn ->
                   Datasets.DataLoader.read!("missing.jsonl", [:question], :not_options)
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Datasets\.DataLoader\.read!\/3: invalid value for :format option: expected string/,
                 fn ->
                   Datasets.DataLoader.read!("missing.jsonl", [:question], format: :csv)
                 end
  end

  test "dataset APIs report invalid collection and path boundaries clearly" do
    assert_raise ArgumentError,
                 ~r/Imp\.Datasets\.from_records\/3 expects records to be an enumerable/,
                 fn ->
                   Datasets.from_records(:not_records, [:question])
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Datasets\.split\/2 expects examples to be an enumerable/,
                 fn ->
                   Datasets.split(:not_examples)
                 end

    assert_raise ArgumentError, ~r/Imp\.Datasets\.jsonl\/3 expects path to be a binary/, fn ->
      Datasets.jsonl(:not_a_path, [:question])
    end

    assert_raise ArgumentError, ~r/Imp\.Datasets\.csv\/3 expects path to be a binary/, fn ->
      Datasets.csv(:not_a_path, [:question])
    end

    assert_raise ArgumentError,
                 ~r/Imp\.Datasets\.DataLoader\.read!\/3 expects path to be a binary/,
                 fn ->
                   Datasets.DataLoader.read!(:not_a_path, [:question])
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Datasets\.DataLoader\.read!\/3 supports format/,
                 fn ->
                   Datasets.DataLoader.read!("records.tsv", [:question])
                 end
  end

  test "DataLoader supports explicit JSONL and CSV format names" do
    jsonl_path = tmp_path("loader-records.data")
    csv_path = tmp_path("loader-records.records")

    File.write!(jsonl_path, ~s({"question":"2+2?","answer":"4"}\n))
    File.write!(csv_path, "question,answer\n2+2?,4\n")

    assert [%Imp.Example{} = jsonl] =
             Datasets.DataLoader.read!(jsonl_path, [:question], format: "jsonl")

    assert Imp.Example.get(jsonl, :answer) == "4"

    assert [%Imp.Example{} = csv] =
             Datasets.DataLoader.read!(csv_path, [:question], format: "csv")

    assert Imp.Example.get(csv, :answer) == "4"
  after
    cleanup_tmp("loader-records.data")
    cleanup_tmp("loader-records.records")
  end

  test "dataset APIs report invalid input and record keys clearly" do
    assert_raise ArgumentError,
                 ~r/Imp\.Datasets input keys and record keys must be atoms or strings/,
                 fn ->
                   Datasets.from_records([%{question: "a"}], [123])
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Datasets input keys and record keys must be atoms or strings/,
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

    assert [%Imp.Example{} = gsm8k] = Datasets.GSM8K.read!(gsm8k_path)
    assert Imp.Example.to_map(Imp.Example.inputs(gsm8k)) == %{question: "2+2?"}
    assert Imp.Example.get(gsm8k, :canonical_answer) == "4"
    assert Imp.Example.get(gsm8k, :source_task) == "gsm8k"

    assert [%Imp.Example{} = hotpot] = Datasets.HotPotQA.read!(hotpot_path)

    assert Imp.Example.to_map(Imp.Example.inputs(hotpot)) == %{
             question: "q",
             context: ["c1"]
           }

    assert Imp.Example.get(hotpot, :id) == "hp"
    assert Imp.Example.get(hotpot, :supporting_facts) == %{"title" => ["t"], "sent_id" => [0]}

    assert [%Imp.Example{} = math] = Datasets.MATH.read!(math_path)
    assert Imp.Example.to_map(Imp.Example.inputs(math)) == %{problem: "1+1"}

    colors = Datasets.Colors.load!([%Datasets.Colors.Record{input: "red", label: "warm"}])
    assert [%Imp.Example{} = color] = colors
    assert Imp.Example.to_map(Imp.Example.inputs(color)) == %{input: "red"}
  after
    cleanup_tmp("typed-gsm8k.jsonl")
    cleanup_tmp("typed-hotpot.jsonl")
    cleanup_tmp("typed-math.jsonl")
  end

  defp tmp_path(name),
    do: Path.join(System.tmp_dir!(), "imp-#{:erlang.phash2(self())}-#{name}")

  defp cleanup_tmp(name), do: File.rm(tmp_path(name))
end
