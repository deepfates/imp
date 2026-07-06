defmodule OptimizeGEPATest do
  use ExUnit.Case, async: true

  alias DSEx.Optimize.Anything
  alias DSEx.Optimize.GEPA

  test "pareto frontier keeps candidates with complementary per-example strengths" do
    candidates = [
      %GEPA.Candidate{id: "a", aggregate_score: 0.5, per_example_scores: [1.0, 0.0]},
      %GEPA.Candidate{id: "b", aggregate_score: 0.5, per_example_scores: [0.0, 1.0]},
      %GEPA.Candidate{id: "c", aggregate_score: 0.25, per_example_scores: [0.5, 0.0]}
    ]

    assert Enum.map(GEPA.pareto_frontier(candidates), & &1.id) == ["a", "b"]
  end

  test "ASI diagnostics drive reflective mutation and lineage" do
    artifact = Anything.new_artifact(:prompt, "Base prompt")

    evaluator = fn artifact, examples ->
      per_example_scores =
        Enum.map(examples, fn required ->
          if artifact.text =~ required, do: 1.0, else: 0.0
        end)

      missing = Enum.reject(examples, &String.contains?(artifact.text, &1))

      %{
        per_example_scores: per_example_scores,
        asi: missing,
        diagnostics: Enum.map(missing, &"missing #{&1}")
      }
    end

    mutation_fn = fn _artifact, asi, generation ->
      "Reflection #{generation}: add #{Enum.join(asi, " and ")}"
    end

    report =
      GEPA.optimize(artifact, evaluator,
        examples: ["Paris", "concise"],
        generations: 2,
        mutation_fn: mutation_fn
      )

    assert report.baseline.asi == ["Paris", "concise"]
    assert Enum.any?(report.candidates, &(&1.mutation =~ "Paris"))
    assert report.best.aggregate_score == 1.0
    assert report.best.parent_id in ["baseline", "gepa-1", nil]
    assert report.metadata.parent_sampling == :pareto_round_robin
    assert report.metadata.component_selector == :actionable_side_information
    assert report.metadata.merge_strategy == :pareto_frontier_union
  end

  test "system-aware merge combines complementary frontier candidates" do
    artifact = Anything.new_artifact(:prompt, "Base")

    evaluator = fn artifact, examples ->
      %{
        per_example_scores:
          Enum.map(examples, fn required ->
            if artifact.text =~ required, do: 1.0, else: 0.0
          end),
        asi: Enum.reject(examples, &String.contains?(artifact.text, &1))
      }
    end

    mutation_fn = fn _artifact, _asi, generation ->
      case generation do
        1 -> {:replace, "alpha"}
        2 -> {:replace, "beta"}
        _ -> "done"
      end
    end

    report =
      GEPA.optimize(artifact, evaluator,
        examples: ["alpha", "beta"],
        generations: 2,
        mutation_fn: mutation_fn
      )

    assert [%{parents: parents}] = report.merges
    assert length(parents) == 2
    assert report.best.aggregate_score == 1.0
    assert report.best.artifact.text =~ "alpha"
    assert report.best.artifact.text =~ "beta"
  end

  test "reflection LM proposer receives ASI and proposes candidate mutations" do
    artifact = Anything.new_artifact(:prompt, "Base")

    reflection_lm = %{
      module: DSEx.LM.Fake,
      opts: [
        handler: fn messages, _opts ->
          Process.put(:gepa_reflection_prompt, Enum.map_join(messages, "\n", & &1.content))
          %{mutation: "Paris\nconcise"}
        end
      ]
    }

    evaluator = fn artifact, examples ->
      %{
        per_example_scores:
          Enum.map(examples, fn required ->
            if artifact.text =~ required, do: 1.0, else: 0.0
          end),
        asi: Enum.reject(examples, &String.contains?(artifact.text, &1))
      }
    end

    report =
      GEPA.optimize(artifact, evaluator,
        examples: ["Paris", "concise"],
        generations: 1,
        reflection_lm: reflection_lm
      )

    assert report.best.aggregate_score == 1.0
    assert report.best.mutation == "Paris\nconcise"
    assert Process.get(:gepa_reflection_prompt) =~ "Paris"
    assert Process.get(:gepa_reflection_prompt) =~ "concise"
  after
    Process.delete(:gepa_reflection_prompt)
  end

  test "dev examples can select a held-out candidate over train-only score" do
    artifact = Anything.new_artifact(:prompt, "Base")

    evaluator = fn artifact, examples ->
      %{
        per_example_scores:
          Enum.map(examples, fn required ->
            if artifact.text =~ required, do: 1.0, else: 0.0
          end),
        asi: Enum.reject(examples, &String.contains?(artifact.text, &1))
      }
    end

    mutation_fn = fn _artifact, _asi, generation ->
      case generation do
        1 -> {:replace, "train"}
        2 -> {:replace, "dev"}
      end
    end

    report =
      GEPA.optimize(artifact, evaluator,
        examples: ["train"],
        dev_examples: ["dev"],
        generations: 2,
        mutation_fn: mutation_fn
      )

    assert report.best.artifact.text == "dev"
    assert report.best.metadata.dev_score == 1.0
    assert report.metadata.dev_examples == 1
  end

  test "covers single-task multi-task and held-out generalization behavior" do
    evaluator = fn artifact, examples ->
      %{
        per_example_scores:
          Enum.map(examples, &if(String.contains?(artifact.text, &1), do: 1.0, else: 0.0)),
        asi: Enum.reject(examples, &String.contains?(artifact.text, &1))
      }
    end

    mutation_fn = fn _artifact, asi, _generation -> Enum.join(asi, "\n") end

    single =
      GEPA.optimize(Anything.new_artifact(:prompt, "Base"), evaluator,
        examples: ["single"],
        generations: 1,
        mutation_fn: mutation_fn
      )

    multi =
      GEPA.optimize(Anything.new_artifact(:prompt, "Base"), evaluator,
        examples: ["task-a", "task-b"],
        generations: 2,
        mutation_fn: mutation_fn
      )

    held_out = fn artifact ->
      if artifact.text =~ "task-a" and artifact.text =~ "task-b", do: 1.0, else: 0.0
    end

    assert single.best.aggregate_score == 1.0
    assert multi.best.aggregate_score == 1.0
    assert held_out.(multi.best.artifact) == 1.0
  end
end
