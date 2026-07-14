defmodule Imp.BenchmarkTruth.ProviderTrainingCampaignTest do
  use ExUnit.Case, async: true

  alias Imp.BenchmarkTruth.ProviderTrainingCampaign

  test "the pinned dataset verifies its split and payload digests" do
    dataset =
      "benchmarks/data/provider-training-banking77-v1.json"
      |> File.read!()
      |> Jason.decode!()

    assert ProviderTrainingCampaign.valid_dataset?(dataset)

    tampered = put_in(dataset, ["train", Access.at(0), "route"], "R93")
    refute ProviderTrainingCampaign.valid_dataset?(tampered)
  end

  test "training and held-out inference share the chat representation" do
    signature =
      Imp.signature(
        %{
          inputs: [%{name: :utterance, type: :string}],
          outputs: [
            %{name: :route, type: :string, constraints: %{enum: ["R17", "R42"]}}
          ]
        },
        "Route the query to an opaque code."
      )

    example =
      Imp.example(utterance: "I do not recognize this payment", route: "R42")
      |> Imp.with_inputs(:utterance)

    messages = ProviderTrainingCampaign.training_messages(signature, example)
    assistant = Enum.find(messages, &(&1.role == :assistant))

    assert List.last(messages).role == :assistant
    assert assistant.content =~ "[[ ## route ## ]]\nR42"

    assert {:ok, prediction} = Imp.Adapter.Chat.parse(signature, assistant.content, [])
    assert Imp.get(prediction, :route) == "R42"

    lm = %{
      module: Imp.LM.Static,
      opts: [handler: fn _messages, _opts -> assistant.content end]
    }

    program = ProviderTrainingCampaign.evaluation_program(signature, lm)

    assert program.adapter == Imp.Adapter.Chat

    assert {:ok, prediction} =
             Imp.call(program, %{utterance: "I do not recognize this payment"})

    assert Imp.get(prediction, :route) == "R42"
  end

  test "portable provider program requires an identical freshly credentialed deployment LM" do
    runtime_lm = Imp.req_llm("openai:ft:gpt-test", api_key: "fresh-secret", temperature: 0)

    loaded =
      Imp.predict("question -> answer", lm: runtime_lm)
      |> Imp.Saving.dump()
      |> Imp.Saving.load()

    refute Keyword.has_key?(Imp.ProgramAccess.lm(loaded).opts, :api_key)

    restored = ProviderTrainingCampaign.restore_runtime_credentials!(loaded, runtime_lm)
    assert Imp.ProgramAccess.lm(restored) == runtime_lm

    assert_raise RuntimeError, ~r/changed its credential-free deployment LM/, fn ->
      ProviderTrainingCampaign.restore_runtime_credentials!(
        loaded,
        Imp.req_llm("openai:ft:other", api_key: "fresh-secret", temperature: 0)
      )
    end
  end

  test "independent provider validator rejects envelope and summary forgery" do
    artifact = valid_artifact()
    assert {:ok, ^artifact} = ProviderTrainingCampaign.validate_artifact(artifact)

    assert {:error, [:invalid_run_envelope]} =
             artifact
             |> put_in(["direct_trained", "accuracy"], 0.0)
             |> ProviderTrainingCampaign.validate_artifact()

    forged = reenvelope(artifact, &put_in(&1, ["acceptance", "admissible"], false))
    assert {:error, errors} = ProviderTrainingCampaign.validate_artifact(forged)
    assert :recomputed_acceptance in errors
  end

  defp valid_artifact do
    labels = ["R17", "R42", "R68", "R93"]

    baseline_rows =
      for {label, label_index} <- Enum.with_index(labels), row_index <- 0..9 do
        actual = Enum.at(labels, rem(label_index + 1, length(labels)))
        row("row-#{label_index}-#{row_index}", label, actual)
      end

    trained_rows = Enum.map(baseline_rows, &%{&1 | "actual" => &1["expected"], "correct" => true})
    baseline = result(baseline_rows)
    trained = result(trained_rows)
    acceptance = ProviderTrainingCampaign.acceptance(baseline, trained, trained)

    payload = %{
      "artifact_type" => "imp_paid_provider_training_campaign",
      "schema_version" => 3,
      "status" => "complete",
      "provider" => "openai",
      "base_model" => "openai:gpt-4.1-mini-2025-04-14",
      "dataset" => %{
        "payload_sha256" =>
          "sha256:b84958ebf577bc5d57f2c6cf4a6033d7aafcb3a5cf91a79aa826b4345ebb1f3f",
        "train_rows" => 80,
        "held_out_rows" => 40,
        "overlap" => [],
        "source" => %{"dataset" => "PolyAI/banking77"}
      },
      "upload" => %{
        "mode" => "fresh_upload",
        "rows" => 80,
        "epochs" => 3,
        "jsonl_bytes" => 55_601,
        "jsonl_sha256" => "7421adbb4673d81408969b76c5d95fb655bba68eb59863b2e88c107c018a25ff",
        "training_token_upper_bound" => 166_803,
        "training_cost_upper_bound_usd" => 0.834015,
        "max_cost_usd" => 5.0,
        "pricing" => %{
          "currency" => "USD",
          "training_usd_per_million_tokens" => 5.0,
          "source" => "https://openai.com/api/pricing/"
        }
      },
      "provider_training_file" => "file-test",
      "provider_file_receipt" => %{
        "id" => "file-test",
        "bytes" => 55_601,
        "sha256" => "7421adbb4673d81408969b76c5d95fb655bba68eb59863b2e88c107c018a25ff",
        "purpose" => "fine-tune",
        "status" => "processed"
      },
      "job" => %{
        "id" => "ftjob-test",
        "provider" => "openai",
        "status" => "succeeded",
        "result_model" => "ft:gpt-4.1-mini:test",
        "trained_tokens" => 12_000,
        "error" => nil
      },
      "poll_history" => [
        %{
          "id" => "ftjob-test",
          "poll" => 0,
          "status" => "queued",
          "observed_at" => "2026-07-13T00:00:00Z"
        },
        %{
          "id" => "ftjob-test",
          "poll" => 1,
          "status" => "succeeded",
          "observed_at" => "2026-07-13T00:01:00Z"
        }
      ],
      "checkpoint_sha256" => String.duplicate("a", 64),
      "program_artifact_sha256" => String.duplicate("b", 64),
      "accounting" => %{
        "trained_tokens" => 12_000,
        "training_cost_usd" => 0.06,
        "training_cost_within_bound" => true,
        "max_cost_usd" => 5.0,
        "pricing" => %{"source" => "https://openai.com/api/pricing/"}
      },
      "baseline" => baseline,
      "direct_trained" => trained,
      "reloaded" => trained,
      "effect" => %{
        "accuracy_delta" => 1.0,
        "macro_f1_delta" => 1.0,
        "trained_better" => true,
        "trained_not_worse" => true,
        "all_trained_calls_succeeded" => true
      },
      "acceptance" => acceptance
    }

    Imp.BenchmarkTruth.RunContext.new!(
      source_commits: %{"imp" => "deepfates/imp@test"},
      workspace_state: "clean"
    )
    |> Imp.BenchmarkTruth.RunContext.finish(payload)
  end

  defp reenvelope(artifact, mutate) do
    payload = artifact |> Map.drop(["generated_at", "git_sha", "run_context"]) |> mutate.()

    Imp.BenchmarkTruth.RunContext.new!(
      source_commits: %{"imp" => "deepfates/imp@test"},
      workspace_state: "clean"
    )
    |> Imp.BenchmarkTruth.RunContext.finish(payload)
  end

  defp row(id, expected, actual),
    do: %{
      "id" => id,
      "expected" => expected,
      "actual" => actual,
      "status" => "ok",
      "correct" => expected == actual
    }

  defp result(rows) do
    correct = Enum.count(rows, & &1["correct"])

    %{
      "rows" => rows,
      "total" => length(rows),
      "correct" => correct,
      "failures" => 0,
      "accuracy" => correct / length(rows),
      "macro_f1" => if(correct == length(rows), do: 1.0, else: 0.0),
      "usage" => %{}
    }
  end
end
