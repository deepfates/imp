defmodule OptimizeAnythingTest do
  use ExUnit.Case, async: true

  alias DSPy.Optimize.Anything

  test "optimizes arbitrary text artifacts while retaining baseline and lineage" do
    artifact = Anything.new_artifact(:prompt, "Answer cautiously.")

    evaluator = fn artifact, examples ->
      score =
        examples
        |> Enum.count(fn required -> String.contains?(artifact.text, required) end)
        |> Kernel./(length(examples))

      %Anything.Evaluation{
        score: score,
        diagnostics: Enum.reject(examples, &String.contains?(artifact.text, &1))
      }
    end

    mutation_fn = fn _artifact, trial, _seed ->
      Enum.at(["Paris", "Paris\nReturn only the answer."], trial - 1, "Return only the answer.")
    end

    report =
      Anything.optimize(artifact, evaluator,
        examples: ["Paris", "Return only the answer."],
        trials: 2,
        seed: 7,
        mutation_fn: mutation_fn
      )

    assert report.baseline.score == 0.0
    assert report.best.score == 1.0
    assert report.best.id == "candidate-2"
    assert report.best.parent_id == "candidate-1"
    assert Enum.map(report.candidates, & &1.id) == ["baseline", "candidate-1", "candidate-2"]
    assert report.metadata.seed == 7
  end

  test "report save/load is JSON-safe and deterministic" do
    artifact = Anything.new_artifact(:config, "timeout=10", id: "config")
    evaluator = fn artifact, _examples -> if artifact.text =~ "timeout", do: 1.0, else: 0.0 end
    report = Anything.optimize(artifact, evaluator, trials: 1, seed: 3)

    path = Path.join(System.tmp_dir!(), "dspy-elixir-optimize-anything-report.json")
    assert :ok = Anything.save_report!(report, path)

    assert Anything.load_report!(path) == report

    File.rm(path)
  end

  test "supports prompt code config and generic string artifact kinds" do
    kinds = [:prompt, :code, :config, :text]

    reports =
      Enum.map(kinds, fn kind ->
        kind
        |> Anything.new_artifact("base")
        |> Anything.optimize(fn artifact, _examples ->
          if artifact.text =~ "candidate", do: 1.0, else: 0.0
        end)
      end)

    assert Enum.map(reports, & &1.best.score) == [1.0, 1.0, 1.0, 1.0]
    assert Enum.map(reports, & &1.metadata.artifact_kind) == kinds
  end
end
