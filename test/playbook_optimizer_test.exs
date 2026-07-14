defmodule DSEx.Optimizer.PlaybookTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias DSEx.Optimizer.Playbook, as: PlaybookOptimizer
  alias DSEx.Optimizer.Trajectory
  alias DSEx.Playbook
  alias DSEx.Playbook.{Delta, Provenance}
  alias DSEx.Playbook.Operation.{Add, Revise}

  test "canonical workflow contract validates named splits and invocation checkpointing" do
    optimizer = successful_optimizer()
    program = wrapped_program(baseline_playbook())

    assert {:error, {:missing_dataset, :auditset}} =
             DSEx.Optimizer.run(optimizer, program,
               trainset: train_rows(),
               promotionset: promotion_rows()
             )

    owner = self()

    assert {:ok, %PlaybookOptimizer.Result{}} =
             DSEx.Optimizer.run(optimizer, program,
               trainset: train_rows(),
               promotionset: promotion_rows(),
               auditset: audit_rows(),
               checkpoint_fn: fn checkpoint ->
                 send(owner, {:runtime_checkpoint, checkpoint})
                 :ok
               end
             )

    assert_receive {:runtime_checkpoint, %{"payload" => %{"status" => "started"}}}
    assert optimizer.checkpoint_fn == nil
  end

  test "promotes disjoint durable lift, checkpoints exactly, and rolls back deterministically" do
    parent = self()
    baseline = baseline_playbook()
    program = wrapped_program(baseline)

    optimizer =
      optimizer(
        proposer: fn request ->
          send(parent, {:proposal_rows, Enum.map(request.rows, & &1["id"])})

          delta =
            Delta.new(
              [
                Revise.new("strategy", "Verify every coefficient against both sides.",
                  expected_revision: 1,
                  provenance:
                    Provenance.new(
                      source_ids: Enum.map(request.rows, & &1["source_id"]),
                      digests: [sha256("training evidence")]
                    )
                )
              ],
              expected_revision: request.playbook.revision,
              parent_hash: request.playbook.hash
            )

          {:ok, delta, free_usage()}
        end,
        checkpoint_fn: fn checkpoint ->
          send(parent, {:checkpoint, checkpoint})
          :ok
        end
      )

    assert {:ok, result} =
             PlaybookOptimizer.compile(
               optimizer,
               program,
               train_rows(),
               promotion_rows(),
               audit_rows()
             )

    assert result.promoted?

    assert result.scores == %{
             baseline_promotion: 0.0,
             candidate_promotion: 1.0,
             baseline_audit: 0.0,
             candidate_audit: 1.0
           }

    assert result.program.playbook.hash == result.candidate_playbook.hash
    assert PlaybookOptimizer.rollback(result).playbook.hash == baseline.hash
    assert PlaybookOptimizer.rollback(result) == result.baseline_program
    assert_receive {:proposal_rows, ["train-1", "train-2"]}

    checkpoints = collect_checkpoints([])
    assert length(checkpoints) == 7

    assert Enum.map(checkpoints, &get_in(&1, ["payload", "status"])) ==
             List.duplicate("started", 6) ++ ["complete"]

    portable = result.checkpoint |> Jason.encode!() |> Jason.decode!()
    fresh_program = wrapped_program(Playbook.load!(Playbook.dump(baseline)))

    assert {:ok, restored} = PlaybookOptimizer.restore(portable, fresh_program)
    assert restored.promoted?
    assert restored.program.playbook == result.candidate_playbook
    assert restored.scores == result.scores
    assert DSEx.Saving.load(DSEx.Saving.dump(restored.program)) == restored.program
  end

  test "rejects a challenger without replicated lift and preserves the baseline" do
    optimizer =
      optimizer(
        proposer: fn request ->
          {:ok,
           Delta.new(
             [
               Revise.new("strategy", "Still use an unreliable shortcut.",
                 expected_revision: 1,
                 provenance: training_provenance(request.rows)
               )
             ],
             expected_revision: 1,
             parent_hash: request.playbook.hash
           ), free_usage()}
        end
      )

    baseline = baseline_playbook()

    assert {:ok, result} =
             PlaybookOptimizer.compile(
               optimizer,
               wrapped_program(baseline),
               train_rows(),
               promotion_rows(),
               audit_rows()
             )

    refute result.promoted?
    assert result.program.playbook == baseline
    assert length(result.rejection_reasons) == 2
    assert PlaybookOptimizer.rollback(result).playbook == baseline

    portable = result.checkpoint |> Jason.encode!() |> Jason.decode!()
    assert {:ok, restored} = PlaybookOptimizer.restore(portable, wrapped_program(baseline))
    assert restored.rejection_reasons == result.rejection_reasons
    assert PlaybookOptimizer.rollback(restored).playbook == baseline
  end

  test "rejects source and group overlap before invoking callbacks" do
    parent = self()
    optimizer = optimizer(proposer: fn _ -> send(parent, :called) end)
    [promotion | rest] = promotion_rows()
    overlapping = [%{promotion | "group_id" => "train-group-1"} | rest]

    assert {:error, {:split_leakage, "group_id"}} =
             PlaybookOptimizer.compile(
               optimizer,
               wrapped_program(baseline_playbook()),
               train_rows(),
               overlapping,
               audit_rows()
             )

    refute_receive :called
  end

  test "rejects held-out content and provenance leakage before held-out evaluation" do
    parent = self()

    evaluator = fn program, rows, context ->
      send(parent, {:evaluated, context.stage})
      evaluate(program, rows, context)
    end

    content_optimizer =
      optimizer(
        evaluator: evaluator,
        proposer: fn request ->
          {:ok,
           Delta.new(
             [
               Revise.new("strategy", "Memorize PROMOTION-SECRET-ALPHA.",
                 expected_revision: 1,
                 provenance: training_provenance(request.rows)
               )
             ],
             expected_revision: 1,
             parent_hash: request.playbook.hash
           ), free_usage()}
        end
      )

    assert {:error, {:heldout_content_leakage, [_]}} =
             PlaybookOptimizer.compile(
               content_optimizer,
               wrapped_program(baseline_playbook()),
               train_rows(),
               promotion_rows(),
               audit_rows()
             )

    assert_receive {:evaluated, :training_evaluation}
    refute_receive {:evaluated, :baseline_promotion}

    provenance_optimizer =
      optimizer(
        proposer: fn request ->
          {:ok,
           Delta.new(
             [
               Revise.new("strategy", "Verify every coefficient against both sides.",
                 expected_revision: 1,
                 provenance: Provenance.new(source_ids: ["promotion-source-1"])
               )
             ],
             expected_revision: 1,
             parent_hash: request.playbook.hash
           ), free_usage()}
        end
      )

    assert {:error, {:heldout_provenance_leakage, ["promotion-source-1"]}} =
             PlaybookOptimizer.compile(
               provenance_optimizer,
               wrapped_program(baseline_playbook()),
               train_rows(),
               promotion_rows(),
               audit_rows()
             )
  end

  test "fails closed on accounting overflow and refuses ambiguous replay" do
    parent = self()

    reservations =
      Map.put(free_reservations(), :training_evaluation, usage(1, 100, 100, 0.01))

    optimizer =
      optimizer(
        reservations: reservations,
        budget: usage(1, 100, 100, 0.01),
        evaluator: fn program, rows, context ->
          evaluate(program, rows, context)
          |> then(fn {:ok, trajectories, _usage} ->
            {:ok, trajectories, usage(2, 10, 10, 0.001)}
          end)
        end,
        checkpoint_fn: fn checkpoint ->
          send(parent, {:checkpoint, checkpoint})
          :ok
        end
      )

    assert {:error, {:stage_reservation_exceeded, :training_evaluation, _, _}} =
             PlaybookOptimizer.compile(
               optimizer,
               wrapped_program(baseline_playbook()),
               train_rows(),
               promotion_rows(),
               audit_rows()
             )

    assert_receive {:checkpoint, started}

    assert {:error, {:ambiguous_started_checkpoint, "training_evaluation"}} =
             PlaybookOptimizer.compile(
               optimizer,
               wrapped_program(baseline_playbook()),
               train_rows(),
               promotion_rows(),
               audit_rows(),
               resume_state: started
             )
  end

  test "tampered completed checkpoints and mismatched baselines fail closed" do
    optimizer = successful_optimizer()

    assert {:ok, result} =
             PlaybookOptimizer.compile(
               optimizer,
               wrapped_program(baseline_playbook()),
               train_rows(),
               promotion_rows(),
               audit_rows()
             )

    tampered = put_in(result.checkpoint, ["payload", "state", "promoted"], false)

    assert {:error, :checkpoint_integrity_failure} =
             PlaybookOptimizer.restore(tampered, result.baseline_program)

    other =
      Playbook.new(id: "other")
      |> Playbook.apply_delta([Add.new("Use another baseline.", id: "strategy")])
      |> elem(1)

    assert {:error, :checkpoint_baseline_mismatch} =
             PlaybookOptimizer.restore(result.checkpoint, wrapped_program(other))
  end

  property "rollback always returns the byte-identical baseline after accepted revisions" do
    check all(suffix <- string(:alphanumeric, min_length: 8, max_length: 32), max_runs: 30) do
      baseline = baseline_playbook()

      optimizer =
        optimizer(
          proposer: fn request ->
            {:ok,
             Delta.new(
               [
                 Revise.new(
                   "strategy",
                   "Verify every coefficient against both sides. #{suffix}",
                   expected_revision: 1,
                   provenance: training_provenance(request.rows)
                 )
               ],
               expected_revision: 1,
               parent_hash: request.playbook.hash
             ), free_usage()}
          end
        )

      assert {:ok, result} =
               PlaybookOptimizer.compile(
                 optimizer,
                 wrapped_program(baseline),
                 train_rows(),
                 promotion_rows(),
                 audit_rows()
               )

      assert PlaybookOptimizer.rollback(result) == result.baseline_program

      assert Playbook.serialize(PlaybookOptimizer.rollback(result).playbook) ==
               Playbook.serialize(baseline)
    end
  end

  defp successful_optimizer do
    optimizer(
      proposer: fn request ->
        {:ok,
         Delta.new(
           [
             Revise.new("strategy", "Verify every coefficient against both sides.",
               expected_revision: 1,
               provenance: training_provenance(request.rows)
             )
           ],
           expected_revision: 1,
           parent_hash: request.playbook.hash
         ), free_usage()}
      end
    )
  end

  defp optimizer(overrides) do
    PlaybookOptimizer.new(
      proposer:
        Keyword.get(overrides, :proposer, fn _ -> raise "unexpected proposer invocation" end),
      evaluator: Keyword.get(overrides, :evaluator, &evaluate/3),
      reservations: Keyword.get(overrides, :reservations, free_reservations()),
      budget: Keyword.get(overrides, :budget, free_usage()),
      min_lift: 0.5,
      max_growth_bytes: 512,
      max_growth_ratio: 4.0,
      checkpoint_fn: Keyword.get(overrides, :checkpoint_fn)
    )
  end

  defp evaluate(program, rows, _context) do
    learned? = Playbook.render(program.playbook) =~ "Verify every coefficient"
    score = if learned?, do: 1.0, else: 0.0

    trajectories =
      rows
      |> Enum.with_index()
      |> Enum.map(fn {row, index} ->
        Trajectory.project(
          :evaluation,
          %{
            index: index,
            example: Map.take(row, ~w(id source_id group_id)),
            prediction: %{"answer" => if(learned?, do: "correct", else: "incorrect")},
            trace: [],
            score: score,
            feedback: if(learned?, do: "balanced", else: "unbalanced"),
            metric_metadata: %{"exact" => learned?},
            error: nil
          }
        )
      end)

    {:ok, trajectories, free_usage()}
  end

  defp baseline_playbook do
    {:ok, playbook} =
      Playbook.apply_delta(Playbook.new(id: "equation-playbook"), [
        Add.new("Use an unreliable shortcut without checking coefficients.",
          id: "strategy",
          section: "Equation balancing",
          provenance: Provenance.new(source_ids: ["authority:seed"])
        )
      ])

    playbook
  end

  defp wrapped_program(playbook),
    do: DSEx.with_playbook(DSEx.predict("equation -> coefficients"), playbook)

  defp train_rows do
    [
      row("train-1", "train-source-1", "train-group-1", "TRAIN-ANSWER-ALPHA"),
      row("train-2", "train-source-2", "train-group-2", "TRAIN-ANSWER-BRAVO")
    ]
  end

  defp promotion_rows do
    [
      row("promotion-1", "promotion-source-1", "promotion-group-1", "PROMOTION-SECRET-ALPHA"),
      row("promotion-2", "promotion-source-2", "promotion-group-2", "PROMOTION-SECRET-BRAVO")
    ]
  end

  defp audit_rows do
    [
      row("audit-1", "audit-source-1", "audit-group-1", "AUDIT-SECRET-ALPHA"),
      row("audit-2", "audit-source-2", "audit-group-2", "AUDIT-SECRET-BRAVO")
    ]
  end

  defp row(id, source, group, leakage_term) do
    %{
      "id" => id,
      "source_id" => source,
      "group_id" => group,
      "leakage_terms" => [leakage_term],
      "input" => id,
      "expected" => leakage_term
    }
  end

  defp training_provenance(rows) do
    Provenance.new(
      source_ids: Enum.map(rows, & &1["source_id"]),
      digests: [sha256("training evidence")]
    )
  end

  defp free_reservations do
    Map.new(
      ~w(training_evaluation proposal baseline_promotion candidate_promotion baseline_audit candidate_audit)a,
      &{&1, free_usage()}
    )
  end

  defp free_usage,
    do: %{
      requests: 0,
      input_tokens: 0,
      output_tokens: 0,
      cost_usd: 0.0,
      authority: :free,
      models: []
    }

  defp usage(requests, input, output, cost),
    do: %{
      requests: requests,
      input_tokens: input,
      output_tokens: output,
      cost_usd: cost,
      authority: :provider_reported,
      models: ["test:model"]
    }

  defp collect_checkpoints(acc) do
    receive do
      {:checkpoint, checkpoint} -> collect_checkpoints([checkpoint | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
