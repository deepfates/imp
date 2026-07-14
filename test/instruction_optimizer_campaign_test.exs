defmodule DSEx.BenchmarkTruth.InstructionOptimizerCampaignTest do
  use ExUnit.Case, async: true

  alias DSEx.BenchmarkTruth.InstructionOptimizerCampaign

  test "baseline preflight checkpoints dev and frozen test work without replay" do
    root = tmp_dir("baseline")
    dataset = write_aime_dataset!(root)
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    lm = %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn _messages, _opts ->
          Agent.update(calls, &(&1 + 1))
          %{reasoning: "computed", answer: "1"}
        end
      ]
    }

    opts = campaign_opts(root, dataset, lm, arms: [:baseline])
    first = InstructionOptimizerCampaign.run(opts)

    assert first.artifact["summary"]["all_requested_arms_completed"]
    assert first.artifact["summary"]["t3_complete"] == false
    assert first.artifact["evidence_level"] == "research_preflight"
    assert get_in(first.artifact, ["results", "baseline", "dev"]) == 1.0
    assert get_in(first.artifact, ["results", "baseline", "test"]) == 1.0
    assert get_in(first.artifact, ["results", "baseline", "frozen_test_evaluations"]) == 2

    assert get_in(first.artifact, ["dataset", "split_limits"]) == %{
             "train" => 1,
             "dev" => 2,
             "test" => 2
           }

    assert get_in(first.artifact, ["results", "baseline", "latency", "dev_wall_seconds"]) >= 0.0
    assert get_in(first.artifact, ["results", "baseline", "failures"]) == []
    assert first.artifact["failures"] == []

    assert ["cache", false] in get_in(first.artifact, ["results", "baseline", "program", "config"])

    assert Agent.get(calls, & &1) == 4

    second = InstructionOptimizerCampaign.run(opts)
    assert second.artifact["results"] == first.artifact["results"]
    assert Agent.get(calls, & &1) == 4
  end

  test "completed arm checkpoints prevent runner replay and bind configuration identity" do
    root = tmp_dir("resume")
    dataset = write_aime_dataset!(root)
    parent = self()

    runner = fn arm, _context, {_progress, _persist} ->
      send(parent, {:arm_run, arm})
      %{"arm" => Atom.to_string(arm), "dev" => 0.5, "test" => 0.25}
    end

    opts =
      campaign_opts(root, dataset, static_lm(), arms: [:baseline, :mipro_v2], arm_runner: runner)

    InstructionOptimizerCampaign.run(opts)
    assert_received {:arm_run, :baseline}
    assert_received {:arm_run, :mipro_v2}

    never = fn arm, _context, _progress -> flunk("completed arm replayed: #{arm}") end
    InstructionOptimizerCampaign.run(Keyword.put(opts, :arm_runner, never))

    assert_raise ArgumentError, ~r/checkpoint identity mismatch/, fn ->
      opts |> Keyword.put(:model, "openai:different") |> InstructionOptimizerCampaign.run()
    end
  end

  test "evaluation row errors are retained as arm and campaign failure evidence" do
    root = tmp_dir("row-errors")
    dataset = write_aime_dataset!(root)

    lm = %{
      module: DSEx.LM.Static,
      opts: [handler: fn _messages, _opts -> {:error, :provider_unavailable} end]
    }

    result =
      root
      |> campaign_opts(dataset, lm, arms: [:baseline])
      |> InstructionOptimizerCampaign.run()

    arm_failures = get_in(result.artifact, ["results", "baseline", "failures"])

    assert Enum.map(arm_failures, &Map.take(&1, ["type", "split", "index"])) == [
             %{"type" => "evaluation_row_error", "split" => "dev", "index" => 0},
             %{"type" => "evaluation_row_error", "split" => "dev", "index" => 1},
             %{"type" => "evaluation_row_error", "split" => "test", "index" => 0},
             %{"type" => "evaluation_row_error", "split" => "test", "index" => 1}
           ]

    assert Enum.all?(arm_failures, &(not is_nil(&1["error"])))
    assert result.artifact["failures"] == Enum.map(arm_failures, &Map.put(&1, "arm", "baseline"))

    checkpoint = result.checkpoint_path |> File.read!() |> Jason.decode!()
    assert get_in(checkpoint, ["payload", "completed", "baseline", "failures"]) == arm_failures
  end

  test "completed arm reservation evidence cannot be hidden by empty failure lists" do
    root = tmp_dir("active-reservations")
    dataset = write_aime_dataset!(root)

    runner = fn arm, _context, {_progress, _persist} ->
      %{
        "arm" => Atom.to_string(arm),
        "dev" => 1.0,
        "test" => 1.0,
        "failures" => [],
        "budget" => %{
          "active_reservations" => 2,
          "reserved" => %{"input_tokens" => 10, "output_tokens" => 20, "usd" => 0.01}
        }
      }
    end

    result =
      root
      |> campaign_opts(dataset, static_lm(), arms: [:baseline], arm_runner: runner)
      |> InstructionOptimizerCampaign.run()

    [failure] = get_in(result.artifact, ["results", "baseline", "failures"])
    assert failure["type"] == "active_budget_reservations"
    assert failure["active_reservations"] == 2
    assert failure["reserved"] == %{"input_tokens" => 10, "output_tokens" => 20, "usd" => 0.01}
    assert result.artifact["failures"] == [Map.put(failure, "arm", "baseline")]
  end

  test "SIMBA finalist validation uses the trainset like pinned DSPy" do
    root = tmp_dir("simba-final-set")
    dataset = write_aime_dataset!(root)

    result =
      root
      |> campaign_opts(dataset, static_lm(), arms: [:simba])
      |> InstructionOptimizerCampaign.run()

    assert get_in(result.artifact, [
             "results",
             "simba",
             "optimizer_report",
             "metadata",
             "final_evaluation_calls"
           ]) == 1
  end

  test "checkpoint tampering and dataset drift fail closed" do
    root = tmp_dir("tamper")
    dataset = write_aime_dataset!(root)
    opts = campaign_opts(root, dataset, static_lm(), arms: [:baseline])
    result = InstructionOptimizerCampaign.run(opts)

    checkpoint = result.checkpoint_path |> File.read!() |> Jason.decode!()
    tampered = put_in(checkpoint, ["payload", "completed", "baseline", "test"], 0.99)
    File.write!(result.checkpoint_path, Jason.encode!(tampered))

    assert_raise ArgumentError, ~r/checkpoint checksum mismatch/, fn ->
      InstructionOptimizerCampaign.run(opts)
    end

    File.write!(
      Path.join([root, "AIMEBench", "test.jsonl"]),
      Jason.encode!(%{problem: "changed", answer: "1"}) <> "\n"
    )

    assert_raise ArgumentError, ~r/dataset split checksum mismatch/, fn ->
      InstructionOptimizerCampaign.run(Keyword.put(opts, :campaign_id, "dataset-drift"))
    end
  end

  test "ambiguous evaluation dispatch intent is never replayed" do
    root = tmp_dir("ambiguous-evaluation")
    dataset = write_aime_dataset!(root)
    checkpoint_path = Path.join(root, "checkpoints/preflight-test-AIMEBench-17.json")
    {:ok, captured} = Agent.start_link(fn -> nil end)
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    lm = %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn _messages, _opts ->
          Agent.update(calls, &(&1 + 1))

          if is_nil(Agent.get(captured, & &1)) do
            Agent.update(captured, fn _ -> File.read!(checkpoint_path) end)
          end

          %{reasoning: "computed", answer: "1"}
        end
      ]
    }

    opts = campaign_opts(root, dataset, lm, arms: [:baseline])
    InstructionOptimizerCampaign.run(opts)
    File.write!(checkpoint_path, Agent.get(captured, & &1))
    Agent.update(calls, fn _ -> 0 end)

    assert_raise ArgumentError, ~r/durable dispatch intent has an ambiguous outcome/, fn ->
      InstructionOptimizerCampaign.run(opts)
    end

    assert Agent.get(calls, & &1) == 0
  end

  test "checkpointed optimizer predictor config survives JSON loading" do
    program =
      "question -> answer"
      |> DSEx.chain_of_thought(config: [cache: false, rollout_id: 7])
      |> DSEx.Saving.dump()
      |> Jason.encode!()
      |> Jason.decode!()
      |> DSEx.Saving.load()

    [predictor] = DSEx.ProgramParameters.predictors(program)
    assert predictor.predictor.config == [cache: false, rollout_id: 7]
  end

  defp campaign_opts(root, dataset, lm, extra) do
    base = [
      dataset_root: root,
      campaign_id: "preflight-test",
      model: "openai:test",
      lm: lm,
      arms: [:baseline],
      arm_configs: %{
        bootstrap_few_shot: %{max_bootstrapped_demos: 1},
        mipro_v2: %{auto: nil, num_candidates: 2, num_trials: 1, minibatch: false},
        simba: %{bsize: 1, num_candidates: 1, max_steps: 0, max_demos: 1}
      },
      budget: %{requests: 100, input_tokens: 1_000_000, output_tokens: 10_000, usd: 10.0},
      pricing: %{"input_per_million" => 1.0, "output_per_million" => 2.0},
      max_output_tokens: 20,
      source_commits: %{"dspy" => "pinned", "dsex" => "test"},
      git_sha: "test-sha",
      out_dir: Path.join(root, "results"),
      checkpoint_dir: Path.join(root, "checkpoints"),
      split_limits: %{"train" => 1, "dev" => 2, "test" => 2}
    ]

    Keyword.merge(base, extra)
    |> Keyword.put(:dataset_root, dataset)
  end

  defp static_lm do
    %{module: DSEx.LM.Static, opts: [handler: fn _, _ -> %{reasoning: "ok", answer: "1"} end]}
  end

  defp write_aime_dataset!(root) do
    family_dir = Path.join(root, "AIMEBench")
    File.mkdir_p!(family_dir)

    splits = %{
      "train" => [%{problem: "train", answer: "1"}],
      "dev" => [%{problem: "dev one", answer: "1"}, %{problem: "dev two", answer: "1"}],
      "test" => [%{problem: "test one", answer: "1"}, %{problem: "test two", answer: "1"}]
    }

    checksums =
      Map.new(splits, fn {split, rows} ->
        path = Path.join(family_dir, split <> ".jsonl")
        body = Enum.map_join(rows, "", &(Jason.encode!(&1) <> "\n"))
        File.write!(path, body)
        {split, "sha256:" <> sha256(body)}
      end)

    families = %{
      "families" => [
        %{
          "family" => "AIMEBench",
          "program" => "CoT",
          "signature" => "problem -> answer",
          "instructions" => "Solve the problem.",
          "input_keys" => ["problem"],
          "output_key" => "answer",
          "upstream_metric" => "AIME.metric integer exact match",
          "split_checksums" => checksums
        }
      ]
    }

    File.write!(Path.join(root, "families.json"), Jason.encode!(families))
    root
  end

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp tmp_dir(name) do
    path =
      Path.join(
        System.tmp_dir!(),
        "dsex-instruction-campaign-#{name}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
