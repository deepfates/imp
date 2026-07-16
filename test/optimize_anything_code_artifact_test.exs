defmodule OptimizeAnythingCodeArtifactTest do
  use ExUnit.Case, async: true

  alias Imp.BenchmarkTruth.OptimizeAnything.CodeArtifact
  alias Imp.Optimize.Anything, as: OptimizeAnything
  alias Imp.Optimize.Anything.Config

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

    assert String.starts_with?(CodeArtifact.baseline(), "if(")
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

  test "feedback exposes training inputs and diagnoses ambiguous nested if syntax" do
    example = Enum.find(CodeArtifact.trainset(), &(&1["id"] == "train-server-hint"))

    ambiguous =
      "if retryable == false, do: -1, else: if retry_after_ms > 0, do: if retry_after_ms > 8000, do: 8000, else: retry_after_ms, else: attempt * 500"

    assert {score,
            %{
              "inputs" => %{
                "attempt" => 2,
                "jitter_slot" => 1,
                "retry_after_ms" => 1_200,
                "retryable" => true,
                "urgent" => false
              },
              "failure" => %{
                "code" => "missing_else_clause",
                "message" => message,
                "phase" => "interpretation"
              }
            }} = CodeArtifact.evaluate(ambiguous, example)

    assert score == 0.0
    assert message =~ "parenthesize every nested conditional"
  end

  test "candidate contract teaches an unambiguous nested conditional form" do
    contract = CodeArtifact.metadata()["candidate_contract"]

    assert contract["canonical_nested_if_syntax"] =~ "if(first_condition"

    candidate =
      "if(retryable == false, do: -1, else: if(urgent == true, do: 0, else: if(retry_after_ms > 0, do: if(retry_after_ms > 8000, do: 8000, else: retry_after_ms), else: attempt * 500 + jitter_slot)))"

    assert {_score, %{"failure" => nil, "inputs" => inputs}} =
             CodeArtifact.evaluate(candidate, hd(CodeArtifact.trainset()))

    assert is_map(inputs)
  end

  test "provider-free reflection receives grammar and public training inputs" do
    test_pid = self()

    lm = fn messages, _opts ->
      send(test_pid, {:reflection_prompt, messages})
      {:ok, "```elixir\n#{CodeArtifact.comparator()}\n```"}
    end

    result =
      OptimizeAnything.run(
        CodeArtifact.baseline(),
        &CodeArtifact.evaluate/2,
        config:
          Config.new(
            engine: [max_candidate_proposals: 1, seed: 17],
            reflection: [
              reflection_lm: lm,
              reflection_minibatch_size: length(CodeArtifact.trainset())
            ]
          ),
        dataset: CodeArtifact.trainset(),
        valset: CodeArtifact.valset(),
        objective: CodeArtifact.metadata()["objective"],
        background: Jason.encode!(CodeArtifact.metadata())
      )

    assert_receive {:reflection_prompt, messages}
    assert [%{content: prompt}] = messages

    assert prompt =~ "canonical_nested_if_syntax"
    assert prompt =~ "Parenthesize every nested conditional"
    assert prompt =~ ~S|"inputs"|
    assert prompt =~ ~S|"jitter_slot"|

    assert OptimizeAnything.Result.best_candidate(result) ==
             String.trim(CodeArtifact.comparator())
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
