defmodule OptimizeAnythingCodeArtifactTest do
  use ExUnit.Case, async: true

  alias DSEx.BenchmarkTruth.OptimizeAnything.CodeArtifact

  test "common benchmark contract is complete and JSON-safe" do
    assert is_binary(CodeArtifact.id())
    assert CodeArtifact.artifact_class() == "code_artifact"
    assert is_binary(CodeArtifact.baseline())
    assert is_binary(CodeArtifact.comparator())
    assert [_ | _] = CodeArtifact.trainset()
    assert [_ | _] = CodeArtifact.valset()
    assert {:ok, _json} = Jason.encode(CodeArtifact.metadata())
  end

  test "baseline has meaningful partial credit below the comparator" do
    baseline_score = aggregate_score(CodeArtifact.baseline(), CodeArtifact.trainset())
    comparator_score = aggregate_score(CodeArtifact.comparator(), CodeArtifact.trainset())

    assert baseline_score > 0.1
    assert baseline_score < 0.8
    assert_in_delta comparator_score, 1.0, 1.0e-12
    assert comparator_score - baseline_score > 0.25
  end

  test "comparator generalizes perfectly to held-out branch combinations" do
    assert_in_delta aggregate_score(CodeArtifact.comparator(), CodeArtifact.valset()),
                    1.0,
                    1.0e-12
  end

  test "malformed source returns actionable parse diagnostics" do
    example = hd(CodeArtifact.trainset())

    assert {score,
            %{
              "status" => "failed",
              "failure" => %{"code" => "parse_error", "phase" => "parse"},
              "diagnostics" => [%{"message" => message}]
            }} = CodeArtifact.evaluate("if retryable do", example)

    assert score == 0.0
    assert is_binary(message)
    assert message != ""
  end

  test "host calls are parsed but rejected by the bounded interpreter" do
    example = hd(CodeArtifact.trainset())
    hostile_source = ~S|System.cmd("sh", ["-c", "echo unsafe"])|

    assert {score,
            %{
              "status" => "failed",
              "failure" => %{"code" => "unsafe_ast", "phase" => "safety"}
            }} = CodeArtifact.evaluate(hostile_source, example)

    assert score == 0.0
  end

  test "interpreter exceptions become structured runtime diagnostics" do
    example = hd(CodeArtifact.trainset())

    assert {score,
            %{
              "failure" => %{
                "code" => "runtime_error",
                "phase" => "interpretation",
                "message" => message
              }
            }} = CodeArtifact.evaluate(~S|1 + "not-a-number"|, example)

    assert score == 0.0
    assert message =~ "arithmetic"
  end

  test "evaluation is deterministic and reports structured subscores" do
    example = Enum.at(CodeArtifact.valset(), 3)
    first = CodeArtifact.evaluate(CodeArtifact.comparator(), example)

    assert first == CodeArtifact.evaluate(CodeArtifact.comparator(), example)

    assert {1.0,
            %{
              "actual" => 4_075,
              "expected" => 4_075,
              "status" => "passed",
              "subscores" => %{
                "bounded_output" => 0.05,
                "exact_result" => 0.65,
                "numeric_proximity" => 0.2,
                "result_type" => 0.1
              }
            }} = first
  end

  test "train and validation splits are disjoint and exercise different cases" do
    train_ids = CodeArtifact.trainset() |> Enum.map(& &1["id"]) |> MapSet.new()
    validation_ids = CodeArtifact.valset() |> Enum.map(& &1["id"]) |> MapSet.new()

    assert MapSet.disjoint?(train_ids, validation_ids)
    assert Enum.any?(CodeArtifact.trainset(), &(&1["expected"] == 8_000))
    assert Enum.any?(CodeArtifact.valset(), &(&1["inputs"]["attempt"] > 4))
  end

  defp aggregate_score(candidate, examples) do
    examples
    |> Enum.map(fn example -> candidate |> CodeArtifact.evaluate(example) |> elem(0) end)
    |> then(&(Enum.sum(&1) / length(&1)))
  end
end
