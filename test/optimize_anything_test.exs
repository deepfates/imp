defmodule OptimizeAnythingTest do
  use ExUnit.Case, async: true

  alias DSEx.Optimize.Anything

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

    path = Path.join(System.tmp_dir!(), "dsex-optimize-anything-report.json")
    assert :ok = Anything.save_report!(report, path)

    assert Anything.load_report!(path) == report

    File.rm(path)
  end

  test "zero trials evaluate only the baseline artifact" do
    artifact = Anything.new_artifact(:prompt, "baseline")

    report =
      Anything.optimize(
        artifact,
        fn artifact, _examples ->
          if artifact.text == "baseline", do: 0.75, else: flunk("unexpected candidate")
        end,
        trials: 0,
        mutation_fn: fn _artifact, _trial, _seed -> flunk("unexpected mutation") end
      )

    assert report.best.id == "baseline"
    assert report.best.score == 0.75
    assert Enum.map(report.candidates, & &1.id) == ["baseline"]
    assert report.metadata.trials == 0
    assert report.errors == []
  end

  test "artifact and optimizer boundaries reject invalid option and callback shapes" do
    artifact = Anything.new_artifact(:prompt, "baseline")
    evaluator = fn _artifact, _examples -> 1.0 end

    assert_raise ArgumentError,
                 ~r/DSEx\.Optimize\.Anything\.new_artifact\/3: expected keyword options/,
                 fn ->
                   Anything.new_artifact(:prompt, "baseline", %{id: "bad"})
                 end

    assert_raise ArgumentError,
                 ~r/DSEx\.Optimize\.Anything\.new_artifact\/3 expects artifact text to be a binary/,
                 fn ->
                   Anything.new_artifact(:prompt, :not_text)
                 end

    assert_raise ArgumentError,
                 ~r/DSEx\.Optimize\.Anything\.optimize\/3: expected keyword options/,
                 fn ->
                   Anything.optimize(artifact, evaluator, %{trials: 1})
                 end

    assert_raise ArgumentError,
                 ~r/DSEx\.Optimize\.Anything\.optimize\/3: invalid value for :trials option: expected non negative integer/,
                 fn ->
                   Anything.optimize(artifact, evaluator, trials: -1)
                 end

    assert_raise ArgumentError,
                 ~r/DSEx\.Optimize\.Anything\.optimize\/3: invalid value for :seed option: expected integer/,
                 fn ->
                   Anything.optimize(artifact, evaluator, seed: "seven")
                 end

    assert_raise ArgumentError,
                 ~r/DSEx\.Optimize\.Anything\.optimize\/3: invalid value for :mutation_fn option: expected nil or an arity-3 function/,
                 fn ->
                   Anything.optimize(artifact, evaluator, mutation_fn: fn _artifact -> "bad" end)
                 end

    assert_raise ArgumentError,
                 ~r/DSEx\.Optimize\.Anything\.optimize\/3 expects an evaluator function with arity 2/,
                 fn ->
                   Anything.optimize(artifact, fn _artifact -> 1.0 end)
                 end
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

  test "captures evaluator errors as failed candidates without aborting search" do
    artifact = Anything.new_artifact(:prompt, "base")

    evaluator = fn artifact, _examples ->
      if artifact.id == "candidate-1" do
        raise "bad candidate"
      else
        0.5
      end
    end

    report = Anything.optimize(artifact, evaluator, trials: 2)

    assert report.best.score == 0.5
    assert [%{candidate_id: "candidate-1", diagnostics: ["bad candidate"]}] = report.errors
    assert Enum.find(report.candidates, &(&1.id == "candidate-1")).score == 0.0
  end

  test "captures mutation errors as failed candidates without aborting search" do
    artifact = Anything.new_artifact(:prompt, "base")

    evaluator = fn artifact, _examples ->
      if artifact.text =~ "good", do: 1.0, else: 0.25
    end

    mutation_fn = fn _artifact, trial, _seed ->
      case trial do
        1 -> raise "mutation engine failed"
        2 -> "good"
      end
    end

    report = Anything.optimize(artifact, evaluator, trials: 2, mutation_fn: mutation_fn)

    assert report.best.id == "candidate-2"
    assert report.best.score == 1.0

    assert [%{candidate_id: "candidate-1", diagnostics: ["mutation engine failed"]}] =
             report.errors

    assert Enum.find(report.candidates, &(&1.id == "candidate-1")).mutation == :mutation_failed
  end

  test "artifacts carry named text parameters through mutation and report roundtrip" do
    artifact =
      Anything.new_artifact(:code, "def answer, do: :old",
        id: "solver",
        parameters: %{source: "def answer, do: :old", config: "mode=safe"}
      )

    report =
      Anything.optimize(artifact, fn artifact, _examples ->
        if artifact.parameters.main =~ "candidate", do: 1.0, else: 0.0
      end)

    assert report.best.artifact.parameters.source == "def answer, do: :old"
    assert report.best.artifact.parameters.config == "mode=safe"
    assert report.best.artifact.parameters.main =~ "candidate"

    path = Path.join(System.tmp_dir!(), "dsex-optimize-anything-parameters.json")
    Anything.save_report!(report, path)
    assert Anything.load_report!(path) == report
    File.rm(path)
  end
end
