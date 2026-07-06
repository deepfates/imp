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

  test "typed dataset records load as examples for GSM8K HotPotQA MATH and Colors" do
    gsm8k_path = tmp_path("typed-gsm8k.jsonl")
    hotpot_path = tmp_path("typed-hotpot.jsonl")
    math_path = tmp_path("typed-math.jsonl")

    File.write!(gsm8k_path, ~s({"question":"2+2?","answer":"4"}\n))
    File.write!(hotpot_path, ~s({"question":"q","context":["c1"],"answer":"a"}\n))
    File.write!(math_path, ~s({"problem":"1+1","solution":"2","answer":"2"}\n))

    assert [%DSEx.Example{} = gsm8k] = Datasets.GSM8K.load(gsm8k_path)
    assert DSEx.Example.to_map(DSEx.Example.inputs(gsm8k)) == %{question: "2+2?"}

    assert [%DSEx.Example{} = hotpot] = Datasets.HotPotQA.load(hotpot_path)

    assert DSEx.Example.to_map(DSEx.Example.inputs(hotpot)) == %{
             question: "q",
             context: ["c1"]
           }

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
