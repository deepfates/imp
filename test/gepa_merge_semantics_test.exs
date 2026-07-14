defmodule Imp.Optimizer.GEPA.MergeSemanticsTest do
  use ExUnit.Case, async: true

  alias Imp.Optimizer.GEPA.Merge

  @ancestor %{planner: "base planner", writer: "base writer", critic: "base critic"}
  @left %{planner: "left planner", writer: "base writer", critic: "left critic"}
  @right %{planner: "base planner", writer: "right writer", critic: "right critic"}

  @candidates %{root: @ancestor, left: @left, right: @right}
  @lineage %{root: [], left: [:root], right: [:root]}
  @scores %{
    left: %{a: 1.0, b: 0.0, tied: 0.5},
    right: %{a: 0.0, b: 1.0, tied: 0.5}
  }

  test "merges complementary named changes and records component-level lineage" do
    evaluator = fn candidate, validation_ids ->
      assert validation_ids == [:a, :b]

      assert candidate == %{
               planner: "left planner",
               writer: "right writer",
               critic: "left critic"
             }

      %{a: 1.0, b: 1.0}
    end

    acceptance = fn evaluation, context ->
      assert context.parent_scores == %{
               left: %{a: 1.0, b: 0.0},
               right: %{a: 0.0, b: 1.0}
             }

      Enum.sum(Map.values(evaluation)) >
        context.parent_scores
        |> Map.values()
        |> Enum.map(&Enum.sum(Map.values(&1)))
        |> Enum.max()
    end

    assert {:accepted, result} =
             Merge.merge(:left, :right, @candidates, @lineage, @scores, evaluator, acceptance)

    assert result.status == :accepted

    assert result.lineage == %{
             operation: :merge,
             parents: [:left, :right],
             ancestor: :root,
             component_sources: %{
               planner: :left,
               writer: :right,
               critic: :left
             }
           }
  end

  test "returns a fully described rejected attempt when acceptance finds no improvement" do
    assert {:rejected, result} =
             Merge.merge(
               :left,
               :right,
               @candidates,
               @lineage,
               @scores,
               fn _candidate, _ids -> %{a: 1.0, b: 0.0} end,
               fn _evaluation, _context -> {:reject, :not_better_than_both_parents} end
             )

    assert result.status == :rejected
    assert result.acceptance == :not_better_than_both_parents
    assert result.candidate.planner == "left planner"
    assert result.candidate.writer == "right writer"
    assert result.lineage.parents == [:left, :right]
    assert result.lineage.ancestor == :root
  end

  test "uses discriminating score evidence when both parents changed a component" do
    scores = %{
      left: %{a: 0.6, b: 0.0},
      right: %{a: 0.5, b: 1.0}
    }

    assert {:ok, candidate, sources} =
             Merge.crossover(@left, @right, @ancestor, scores.left, scores.right,
               left_id: :left,
               right_id: :right,
               ancestor_id: :root
             )

    assert candidate.planner == "left planner"
    assert candidate.writer == "right writer"
    assert candidate.critic == "right critic"
    assert sources.critic == :right
  end

  test "exposes ancestor-relative differences and discriminating validation partitions" do
    assert Merge.differing_components(@left, @right, @ancestor) == %{
             planner: %{
               ancestor: "base planner",
               left: "left planner",
               right: "base planner",
               left_changed: true,
               right_changed: false
             },
             writer: %{
               ancestor: "base writer",
               left: "base writer",
               right: "right writer",
               left_changed: false,
               right_changed: true
             },
             critic: %{
               ancestor: "base critic",
               left: "left critic",
               right: "right critic",
               left_changed: true,
               right_changed: true
             }
           }

    assert Merge.validation_partition(@scores.left, @scores.right) == %{
             left: [:a],
             right: [:b],
             tied: [:tied]
           }

    assert Merge.discriminating_validation_ids(@scores.left, @scores.right) == {:ok, [:a, :b]}
  end

  test "chooses the nearest common ancestor deterministically and rejects ancestor pairs" do
    lineage = %{
      root: [],
      older_left: [:root],
      older_right: [:root],
      shared: [:older_left, :older_right],
      left: [:shared],
      right: [:shared]
    }

    assert Merge.common_ancestor(:left, :right, lineage) == {:ok, :shared}

    assert {:error, :parent_is_ancestor} =
             Merge.merge(
               :shared,
               :left,
               %{shared: @ancestor, left: @left},
               lineage,
               %{shared: %{a: 0.0}, left: %{a: 1.0}},
               fn _, _ -> flunk("ancestor pairs must not be evaluated") end,
               fn _, _ -> true end
             )
  end

  test "requires shared score evidence that discriminates between the parents" do
    tied_scores = %{left: %{only: 1.0}, right: %{only: 1.0}}

    assert {:error, :no_discriminating_validation_instances} =
             Merge.merge(
               :left,
               :right,
               @candidates,
               @lineage,
               tied_scores,
               fn _, _ -> flunk("an unsupported merge must not be evaluated") end,
               fn _, _ -> true end
             )
  end

  test "source proposer samples eligible frontier siblings and balanced validation evidence" do
    scores = %{
      left: %{a: 1.0, b: 0.0, c: 0.5, d: 0.5, e: 0.5},
      right: %{a: 0.0, b: 1.0, c: 0.5, d: 0.5, e: 0.5}
    }

    aggregate_scores = %{root: 0.0, left: 0.4, right: 0.4}
    rng_state = :rand.seed_s(:exsss, {2, 3, 4})

    assert {:ok, proposal, attempts, _rng_state} =
             Merge.propose_source(
               @candidates,
               @lineage,
               scores,
               aggregate_scores,
               [:left, :right],
               %{},
               rng_state
             )

    assert proposal.candidate.planner == "left planner"
    assert proposal.candidate.writer == "right writer"
    assert proposal.parent_ids == [:left, :right]
    assert proposal.ancestor == :root
    assert length(proposal.validation_instances) == 5
    assert Enum.any?(proposal.validation_instances, &(&1 in [:c, :d, :e]))
    assert attempts.ancestors == [{:left, :right, :root}]
    assert length(attempts.descriptions) == 1

    assert {:none, ^attempts, _rng_state} =
             Merge.propose_source(
               @candidates,
               @lineage,
               scores,
               aggregate_scores,
               [:left, :right],
               attempts,
               rng_state
             )
  end
end
