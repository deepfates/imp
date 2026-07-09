defmodule GepaCampaignTest do
  use ExUnit.Case, async: false

  test "DSEx GEPA campaign writes partial dsex_gepa rows that merge into full evidence" do
    dataset_root = tmp_dir("gepa-campaign-data")
    upstream_dir = tmp_dir("gepa-campaign-upstream")
    rows_dir = tmp_dir("gepa-campaign-rows")
    final_dir = tmp_dir("gepa-campaign-final")

    write_dataset_root!(dataset_root)
    write_upstream_gepa_results!(upstream_dir, "gpt-41-mini")

    result =
      DSEx.BenchmarkTruth.GepaCampaign.run(
        dataset_root: dataset_root,
        campaign_id: "gepa-campaign-test",
        model: "openai:gpt-4.1-mini-2025-04-14",
        reflection_model: "openai:gpt-5",
        out_dir: rows_dir,
        seeds: [0, 1],
        generations: 1,
        pricing_source: "test provider usage export",
        token_cost: %{"usd" => 0.01, "input_tokens" => 100, "output_tokens" => 50},
        source_commits: %{
          "dspy" => "stanfordnlp/dspy@abcdef1",
          "dsex" => "deepfates/dsex@abcdef2",
          "gepa_artifact" => "gepa-ai/gepa-artifact@abcdef3"
        },
        lm: static_gold_lm()
      )

    assert File.exists?(result.out_path)
    assert %{"rows" => rows} = File.read!(result.out_path) |> Jason.decode!()
    assert length(rows) == 6

    assert Enum.all?(rows, fn row ->
             is_map(get_in(row, ["results", "dsex_gepa"])) and
               get_in(row, ["results", "dsex_gepa", "source"]) =~ "DSEx GEPA campaign runner" and
               is_map(row["dataset"]) and
               is_map(row["token_cost"]) and
               row["seed_variance"]["seeds"] == [0, 1]
           end)

    Mix.Task.reenable("dsex.benchmark.gepa_replication")

    Mix.Tasks.Dsex.Benchmark.GepaReplication.run([
      "--from-gepa-artifact",
      upstream_dir,
      "--dsex-input",
      result.out_path,
      "--campaign-id",
      "gepa-campaign-test",
      "--artifact-model",
      "gpt-41-mini",
      "--out",
      final_dir
    ])

    [path] = Path.wildcard(Path.join(final_dir, "gepa-replication-*.json"))
    artifact = path |> File.read!() |> Jason.decode!()

    assert artifact["summary"]["full_gepa_replication"]
    assert DSEx.BenchmarkTruth.GepaReplicationContract.full_artifact?(artifact)
  end

  defp static_gold_lm do
    %{
      module: DSEx.LM.Static,
      opts: [handler: fn _messages, _opts -> %{answer: "gold"} end]
    }
  end

  defp write_dataset_root!(root) do
    families =
      Enum.map(family_programs(), fn {family, program, budget} ->
        family_dir = Path.join(root, family)
        File.mkdir_p!(family_dir)

        Enum.each(["train", "dev", "test"], fn split ->
          File.write!(
            Path.join(family_dir, "#{split}.jsonl"),
            Jason.encode!(%{question: "#{family} #{split} question", answer: "gold"}) <> "\n"
          )
        end)

        %{
          "family" => family,
          "program" => program,
          "signature" => "question -> answer",
          "instructions" => "Answer the question.",
          "input_keys" => ["question"],
          "output_key" => "answer",
          "metric_calls" => budget
        }
      end)

    File.write!(Path.join(root, "families.json"), Jason.encode!(%{"families" => families}))
  end

  defp write_upstream_gepa_results!(artifact_dir, model) do
    Enum.each(family_programs(), fn {family, program, _budget} ->
      Enum.each([{"Baseline", 0.5}, {"GEPA", 0.6}, {"MIPROv2-Heavy", 0.55}], fn {optimizer, score} ->
        run_dir =
          Path.join([
            artifact_dir,
            "experiment_runs",
            "seed_0",
            "#{family}_#{program}_#{optimizer}_#{model}",
            "evaluation_results"
          ])

        File.mkdir_p!(run_dir)

        File.write!(
          Path.join(run_dir, "evaluation_result.txt"),
          "score,cost,input_tokens,output_tokens\n#{score},0.25,1000,200\n"
        )
      end)
    end)
  end

  defp family_programs do
    [
      {"AIMEBench", "CoT", 1839},
      {"HotpotQABench", "HotpotMultiHop", 6871},
      {"hoverBench", "HoverMultiHop", 7051},
      {"IFBench", "IFBenchCoT2StageProgram", 3593},
      {"LiveBenchMathBench", "CoT", 1839},
      {"Papillon", "PAPILLON", 2426}
    ]
  end

  defp tmp_dir(name) do
    path = Path.join(System.tmp_dir!(), "dsex-#{name}-#{System.unique_integer([:positive])}")
    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end
end
