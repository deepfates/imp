defmodule Imp.BenchmarkTruth.InstructionOptimizerExperimentTest do
  use ExUnit.Case, async: true

  alias Imp.BenchmarkTruth.{ArtifactFile, InstructionOptimizerExperiment, RunContext}

  test "economical AIME preflight reserves enough output for structured reasoning" do
    manifest =
      "benchmarks/config/instruction-optimizer-aime-economical-preflight.json"
      |> File.read!()
      |> Jason.decode!()

    assert manifest["provider"]["max_output_tokens"] >= 8_192
    assert manifest["budget"]["output_tokens"] >= manifest["provider"]["max_output_tokens"]
  end

  test "derives one matched Imp run and one all-arm DSPy run" do
    fixture = fixture!("derive")
    derived = derive(fixture)

    assert Keyword.fetch!(derived.imp_options, :model) == "openai:gpt-test"

    assert Keyword.fetch!(derived.imp_options, :split_limits) == %{
             "train" => 1,
             "dev" => 1,
             "test" => 1
           }

    assert Keyword.fetch!(derived.imp_options, :budget) == %{
             "requests" => 40,
             "input_tokens" => 600,
             "output_tokens" => 400,
             "usd" => 2.0
           }

    assert derived.python.config["provider"]["model"] == "openai/gpt-test"
    assert derived.python.config["budget_scope"] == "per_arm"
    assert derived.python.config["dependency_identity"] == %{"optuna" => "4.9.0"}
    assert derived.python.config["split_limits"] == %{"train" => 1, "dev" => 1, "test" => 1}
    assert derived.plan["network_calls"] == 0
    assert derived.plan["worst_case_aggregate"]["usd"] == 16.0

    assert derived.python.config["per_arm_ceilings"] == %{
             "requests" => 40,
             "input_tokens" => 600,
             "output_tokens" => 400,
             "usd" => 2.0
           }

    assert Enum.map(derived.python.config["arms"], & &1["name"]) == [
             "baseline",
             "BootstrapFewShot",
             "MIPROv2",
             "SIMBA"
           ]

    bootstrap = arm(derived.python.config, "BootstrapFewShot")["config"]
    assert bootstrap["max_labeled_demos"] == 0

    mipro = arm(derived.python.config, "MIPROv2")["config"]
    assert mipro["constructor"]["num_candidates"] == 3
    assert mipro["compile"] == %{"minibatch" => false, "num_trials" => 3}
    refute Map.has_key?(mipro["constructor"], "timeout")
    refute Map.has_key?(mipro["compile"], "startup_trials")

    simba = arm(derived.python.config, "SIMBA")["config"]
    refute Map.has_key?(simba, "timeout")
    assert simba["temperature_for_sampling"] == 0.3
    assert simba["temperature_for_candidates"] == 0.4
    refute Map.has_key?(simba, "sampling_temperature")
    assert Keyword.fetch!(derived.imp_options, :arm_configs)["mipro_v2"]["startup_trials"] == 10
    assert derived.identity["design"]["mipro_v2"]["deviation"] =~ "native Optuna TPE"
  end

  test "injectable executors run each campaign once and emit baseline-relative preflight evidence" do
    fixture = fixture!("execute")
    parent = self()

    imp_executor = fn options ->
      send(parent, {:imp, options})
      imp_artifact(options, fixture)
    end

    python_executor = fn invocation ->
      send(parent, {:dspy, invocation})
      dspy_artifact(invocation.config, fixture)
    end

    result =
      InstructionOptimizerExperiment.run(
        manifest: fixture.manifest,
        manifest_path: fixture.manifest_path,
        out_dir: fixture.out,
        checkpoint_dir: fixture.checkpoints,
        run_context: fixture.context,
        imp_executor: imp_executor,
        python_executor: python_executor
      )

    assert_received {:imp, imp_options}
    assert_received {:dspy, invocation}
    assert length(invocation.config["arms"]) == 4
    assert invocation.checkpoint_path =~ "dspy.checkpoint.json"

    assert invocation.env
           |> Map.new()
           |> Map.fetch!("PYTHONPATH")
           |> String.starts_with?(invocation.dspy_pythonpath)

    assert Keyword.fetch!(imp_options, :campaign_id) == "matched-aime"
    refute_received {:dspy, _another}

    merged = ArtifactFile.read_run_json!(result.merged.path)
    assert merged["scope"]["not_t3"]
    assert merged["summary"]["global_winner_selected"] == false
    assert merged["descriptive_dev_leaders"]["label"] =~ "descriptive only"

    delta =
      get_in(merged, [
        "comparisons_to_baseline",
        "dspy",
        "mipro_v2",
        "frozen_test_delta_vs_baseline"
      ])

    assert_in_delta delta, 0.3, 1.0e-9
  end

  test "existing complete artifacts can be merged without invoking either runtime" do
    fixture = fixture!("existing")
    derived = derive(fixture)
    imp = imp_artifact(derived.imp_options, fixture)
    dspy = dspy_artifact(derived.python.config, fixture)

    result =
      InstructionOptimizerExperiment.run(
        manifest: fixture.manifest,
        manifest_path: fixture.manifest_path,
        out_dir: fixture.out,
        checkpoint_dir: fixture.checkpoints,
        run_context: fixture.context,
        runtimes: [],
        imp_artifact: imp,
        dspy_artifact: dspy,
        imp_executor: fn _ -> flunk("Imp executor was called") end,
        python_executor: fn _ -> flunk("DSPy executor was called") end
      )

    assert result.merged.path
  end

  test "dataset, authority, and runtime identity drift fail closed" do
    fixture = fixture!("drift")

    File.write!(fixture.test_path, Jason.encode!(%{problem: "changed", answer: "1"}) <> "\n")

    assert_raise ArgumentError, ~r/dataset test hash mismatch/, fn ->
      derive(fixture)
    end

    fixture = fixture!("authority")
    drifted = put_in(fixture.manifest, ["dspy_authority", "commit"], String.duplicate("0", 40))

    assert_raise ArgumentError, ~r/dspy_authority.commit/, fn ->
      InstructionOptimizerExperiment.validate_manifest!(drifted,
        manifest_path: fixture.manifest_path
      )
    end

    derived = derive(fixture)
    imp = imp_artifact(derived.imp_options, fixture)
    dspy = dspy_artifact(derived.python.config, fixture)
    tampered = put_in(dspy, ["config", "provider", "model"], "openai/wrong")

    assert_raise ArgumentError, ~r/DSPy artifact identity/, fn ->
      InstructionOptimizerExperiment.merge_outputs!(derived, imp, tampered)
    end

    unsupported = put_in(fixture.manifest, ["arm_configs", "simba", "raw_temperature"], 0.5)

    assert_raise ArgumentError, ~r/unsupported simba config keys/, fn ->
      InstructionOptimizerExperiment.validate_manifest!(unsupported,
        manifest_path: fixture.manifest_path
      )
    end

    assert_raise ArgumentError, ~r/pinned DSPy source root is absent/, fn ->
      InstructionOptimizerExperiment.derive!(fixture.manifest,
        manifest_path: fixture.manifest_path,
        run_context: fixture.context,
        dspy_pythonpath: Path.join(fixture.root, "missing-dspy")
      )
    end

    dependency_drift = put_in(fixture.manifest, ["dependency_identity", "optuna"], "4.8.0")

    assert_raise ArgumentError, ~r/dependency_identity must pin optuna 4\.9\.0/, fn ->
      InstructionOptimizerExperiment.validate_manifest!(dependency_drift,
        manifest_path: fixture.manifest_path
      )
    end
  end

  test "plan rejects aggregate exposure before any executor can run" do
    fixture = fixture!("aggregate-cap")
    unsafe = put_in(fixture.manifest, ["preflight", "max_aggregate", "usd"], 15.99)

    assert_raise ArgumentError, ~r/planned two-runtime usd exposure 16\.0 exceeds/, fn ->
      InstructionOptimizerExperiment.plan!(unsafe,
        manifest_path: fixture.manifest_path,
        run_context: fixture.context
      )
    end
  end

  defp derive(fixture) do
    InstructionOptimizerExperiment.derive!(fixture.manifest,
      manifest_path: fixture.manifest_path,
      out_dir: fixture.out,
      checkpoint_dir: fixture.checkpoints,
      run_context: fixture.context
    )
  end

  defp fixture!(name) do
    root = tmp_dir(name)
    family_dir = Path.join(root, "AIMEBench")
    File.mkdir_p!(family_dir)

    checksums =
      Map.new(~w(train dev test), fn split ->
        path = Path.join(family_dir, split <> ".jsonl")
        body = Jason.encode!(%{problem: "#{split} problem", answer: "1"}) <> "\n"
        File.write!(path, body)
        {split, sha(body)}
      end)

    families = %{
      "families" => [
        %{
          "family" => "AIMEBench",
          "signature" => "problem -> answer",
          "instructions" => "Solve the problem.",
          "input_keys" => ["problem"],
          "output_key" => "answer",
          "split_checksums" =>
            Map.new(checksums, fn {split, hash} -> {split, "sha256:" <> hash} end)
        }
      ]
    }

    File.write!(Path.join(root, "families.json"), Jason.encode!(families))
    authority = authority()
    dspy_source = authority["repository"] <> "@" <> authority["commit"]

    manifest = %{
      "schema_version" => 1,
      "campaign_id" => "matched-aime",
      "family" => "AIMEBench",
      "model" => %{
        "logical" => "gpt-test",
        "imp" => "openai:gpt-test",
        "dspy" => "openai/gpt-test"
      },
      "seed" => 17,
      "arms" => ~w(baseline bootstrap_few_shot mipro_v2 simba),
      "arm_configs" => %{
        "bootstrap_few_shot" => %{"max_bootstrapped_demos" => 2},
        "mipro_v2" => %{
          "auto" => nil,
          "num_candidates" => 3,
          "num_trials" => 3,
          "minibatch" => false,
          "max_bootstrapped_demos" => 2,
          "max_labeled_demos" => 2,
          "startup_trials" => 10,
          "max_errors" => 1,
          "timeout" => 30_000
        },
        "simba" => %{
          "bsize" => 2,
          "num_candidates" => 2,
          "max_steps" => 1,
          "max_demos" => 2,
          "sampling_temperature" => 0.3,
          "candidate_temperature" => 0.4,
          "timeout" => 30_000
        }
      },
      "budget" => %{
        "requests" => 40,
        "input_tokens" => 600,
        "output_tokens" => 400,
        "usd" => 2.0
      },
      "preflight" => %{
        "split_limits" => %{"train" => 1, "dev" => 1, "test" => 1},
        "max_aggregate" => %{
          "requests" => 320,
          "input_tokens" => 4_800,
          "output_tokens" => 3_200,
          "usd" => 16.0
        }
      },
      "max_output_tokens" => 50,
      "temperature" => 1.0,
      "reservation_pricing" => %{"input_per_million" => 1.0, "output_per_million" => 2.0},
      "provider" => %{"api_key_env" => "TEST_API_KEY", "input_tokens_per_byte" => 1},
      "dataset" => %{
        "root" => root,
        "splits" => Map.new(checksums, fn {split, hash} -> {split, %{"sha256" => hash}} end)
      },
      "dspy_authority" =>
        Map.take(authority, ["version", "commit", "repository", "source_hashes"]),
      "dependency_identity" => %{"optuna" => "4.9.0"},
      "source_commits" => %{
        "dspy" => dspy_source,
        "imp" => "resolved from campaign git_sha"
      }
    }

    context =
      RunContext.new!(
        source_commits: %{"imp" => "deepfates/imp@test-sha", "dspy" => dspy_source},
        workspace_state: "synthetic"
      )

    %{
      root: root,
      manifest: manifest,
      manifest_path: Path.join(root, "manifest.json"),
      out: Path.join(root, "results"),
      checkpoints: Path.join(root, "checkpoints"),
      context: context,
      checksums: checksums,
      test_path: Path.join(family_dir, "test.jsonl")
    }
  end

  defp imp_artifact(options, fixture) do
    arms = Enum.map(Keyword.fetch!(options, :arms), &Atom.to_string/1)
    configs = options |> Keyword.fetch!(:arm_configs) |> json()

    %{
      "schema_version" => 1,
      "runner" => "imp-instruction-optimizer-campaign",
      "evidence_level" => "research_preflight",
      "identity" => %{
        "campaign_id" => Keyword.fetch!(options, :campaign_id),
        "family" => Keyword.fetch!(options, :family),
        "model" => Keyword.fetch!(options, :model),
        "seed" => Keyword.fetch!(options, :seed),
        "arms" => arms,
        "arm_configs" => configs,
        "split_limits" => Keyword.fetch!(options, :split_limits),
        "budget" => options |> Keyword.fetch!(:budget) |> json(),
        "budget_scope" => "per_arm",
        "split_checksums" =>
          Map.new(fixture.checksums, fn {split, hash} -> {split, "sha256:" <> hash} end),
        "source_commits" => Keyword.fetch!(options, :source_commits)
      },
      "results" => Map.new(arms, fn arm -> {arm, imp_score(arm)} end),
      "summary" => %{
        "all_requested_arms_completed" => true,
        "multi_seed" => false,
        "t3_complete" => false
      }
    }
  end

  defp dspy_artifact(config, _fixture) do
    %{
      "schema_version" => 1,
      "runner" => "python-dspy-instruction-optimizer-campaign",
      "campaign_id" => config["campaign_id"],
      "status" => "complete",
      "scope" => %{"research_preflight" => true, "not_t3" => true},
      "source_identity" =>
        authority() |> Map.take(["project", "repository", "version", "commit", "source_hashes"]),
      "dependency_identity" => config["dependency_identity"],
      "dataset" =>
        Map.new(config["dataset"], fn {split, spec} ->
          {split, Map.put(spec, "count", 1)}
        end),
      "config" => config,
      "config_sha256" => canonical_digest(config),
      "budget_scope" => "per_arm",
      "per_arm_ceilings" => config["per_arm_ceilings"],
      "selected_arm" => "MIPROv2",
      "arms" => Enum.map(config["arms"], &dspy_score/1),
      "failures" => []
    }
  end

  defp imp_score("baseline"), do: %{"dev" => 0.4, "test" => 0.4}
  defp imp_score("mipro_v2"), do: %{"dev" => 0.8, "test" => 0.7}
  defp imp_score(_), do: %{"dev" => 0.6, "test" => 0.5}

  defp dspy_score(%{"name" => "baseline"} = arm),
    do: Map.merge(arm, %{"dev" => %{"score" => 0.4}, "test" => %{"score" => 0.4}})

  defp dspy_score(%{"name" => "MIPROv2"} = arm),
    do: Map.merge(arm, %{"dev" => %{"score" => 0.8}, "test" => %{"score" => 0.7}})

  defp dspy_score(arm),
    do: Map.merge(arm, %{"dev" => %{"score" => 0.6}, "test" => %{"score" => 0.5}})

  defp arm(config, name), do: Enum.find(config["arms"], &(&1["name"] == name))

  defp authority,
    do:
      Imp.UpstreamAuthorityRegistry.load!()
      |> Imp.UpstreamAuthorityRegistry.authority!(
        "t1_instruction_optimizer_differential_contract"
      )

  defp json(value), do: value |> Jason.encode!() |> Jason.decode!()
  defp sha(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp canonical_digest(value),
    do: value |> canonical() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

  defp canonical(%{} = map),
    do:
      "{" <>
        (map
         |> Enum.sort_by(&elem(&1, 0))
         |> Enum.map_join(",", fn {key, value} ->
           Jason.encode!(key) <> ":" <> canonical(value)
         end)) <>
        "}"

  defp canonical(list) when is_list(list),
    do: "[" <> Enum.map_join(list, ",", &canonical/1) <> "]"

  defp canonical(value), do: Jason.encode!(value)

  defp tmp_dir(name) do
    path =
      Path.join(
        System.tmp_dir!(),
        "instruction-optimizer-experiment-#{name}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
