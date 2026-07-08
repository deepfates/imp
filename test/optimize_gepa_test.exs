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

  test "non-positive generations evaluate only the baseline artifact" do
    artifact = Anything.new_artifact(:prompt, "Base prompt")

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
        examples: ["Base"],
        generations: 0,
        mutation_fn: fn _artifact, _asi, _generation -> flunk("unexpected mutation") end
      )

    assert report.best.id == "baseline"
    assert Enum.map(report.candidates, & &1.id) == ["baseline"]
    assert report.metadata.generations == 0
  end

  test "optimizer boundary rejects invalid option and callback shapes" do
    artifact = Anything.new_artifact(:prompt, "Base prompt")

    evaluator = fn _artifact, examples ->
      %{per_example_scores: Enum.map(examples, fn _example -> 1.0 end)}
    end

    assert_raise ArgumentError,
                 ~r/DSEx\.Optimize\.GEPA\.optimize\/3: expected keyword options/,
                 fn ->
                   GEPA.optimize(artifact, evaluator, %{generations: 1})
                 end

    assert_raise ArgumentError,
                 ~r/DSEx\.Optimize\.GEPA\.optimize\/3: invalid value for :generations option: expected non negative integer/,
                 fn ->
                   GEPA.optimize(artifact, evaluator, generations: -1)
                 end

    assert_raise ArgumentError,
                 ~r/DSEx\.Optimize\.GEPA\.optimize\/3 expects :mutation_fn to be an arity-3 function/,
                 fn ->
                   GEPA.optimize(artifact, evaluator, mutation_fn: fn _artifact -> "bad" end)
                 end

    assert_raise ArgumentError,
                 ~r/DSEx\.Optimize\.GEPA\.optimize\/3 expects an evaluator function with arity 2/,
                 fn ->
                   GEPA.optimize(artifact, fn _artifact -> %{per_example_scores: []} end)
                 end
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
      module: DSEx.LM.Static,
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

  test "captures mutation errors as failed candidates without aborting search" do
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
        1 -> raise "reflection failed"
        2 -> "target"
      end
    end

    report =
      GEPA.optimize(artifact, evaluator,
        examples: ["target"],
        generations: 2,
        mutation_fn: mutation_fn
      )

    assert report.best.aggregate_score == 1.0
    assert [%{candidate_id: "gepa-1", diagnostics: ["reflection failed"]}] = report.errors
    assert Enum.find(report.candidates, &(&1.id == "gepa-1")).mutation == :mutation_failed
  end

  test "captures invalid evaluator results as failed candidates" do
    artifact = Anything.new_artifact(:prompt, "Base")

    evaluator = fn artifact, examples ->
      if artifact.id == "baseline" or artifact.text == "Base" do
        %{per_example_scores: Enum.map(examples, fn _example -> 0.25 end), asi: ["target"]}
      else
        :invalid
      end
    end

    report =
      GEPA.optimize(artifact, evaluator,
        examples: ["target"],
        generations: 1,
        mutation_fn: fn _artifact, _asi, _generation -> "target" end
      )

    assert report.best.id == "baseline"

    assert [
             %{
               candidate_id: "gepa-1",
               diagnostics: [
                 "GEPA evaluator must return a map with :per_example_scores; got: :invalid"
               ]
             }
           ] = report.errors
  end

  test "captures dev evaluator failures while preserving train-side optimization" do
    artifact = Anything.new_artifact(:prompt, "Base")

    evaluator = fn artifact, examples ->
      if examples == [:dev] do
        raise "dev service unavailable"
      end

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
        examples: ["target"],
        dev_examples: [:dev],
        generations: 1,
        mutation_fn: fn _artifact, _asi, _generation -> "target" end
      )

    assert report.best.aggregate_score == 1.0
    assert report.best.metadata.dev_score == 0.0
    assert report.best.metadata.dev_error == RuntimeError
    assert Enum.any?(report.errors, &(&1.candidate_id == report.best.id))
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
