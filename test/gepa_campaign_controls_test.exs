defmodule GepaCampaignControlsTest do
  use ExUnit.Case, async: false

  alias DSEx.BenchmarkTruth.{GepaCampaign, GepaCampaignBudget, GepaCampaignManifest}
  alias Mix.Tasks.Dsex.Benchmark.GepaCampaign, as: GepaTask

  @manifest "benchmarks/config/gepa-paper-campaign-v2.json"

  test "rejects a provider reservation that would exceed aggregate or shard ceilings" do
    path = checkpoint_path("over-budget")

    {:ok, budget} =
      start_budget(path,
        aggregate: %{requests: 2, input_tokens: 10_000, output_tokens: 10_000, usd: 10.0},
        per_shard: %{
          AIMEBench: %{requests: 1, input_tokens: 10_000, output_tokens: 10_000, usd: 10.0}
        }
      )

    assert {:ok, first} =
             GepaCampaignBudget.reserve(budget, "AIMEBench", [%{content: "one"}], max_tokens: 0)

    assert {:error, :requests} =
             GepaCampaignBudget.reserve(budget, "AIMEBench", [%{content: "two"}], max_tokens: 0)

    assert :ok = GepaCampaignBudget.release(budget, first)
    GenServer.stop(budget)

    File.rm(path)
  end

  test "family shard identities are deterministic and family selection is immutable" do
    manifest = GepaCampaignManifest.load!(@manifest)
    opts = GepaCampaignManifest.task_options!(manifest, manifest: @manifest, plan: true)

    plan_opts =
      Keyword.take(Map.to_list(opts), [
        :dataset_root,
        :campaign_id,
        :model,
        :reflection_model,
        :families,
        :budgets,
        :sharding,
        :semantic_progress
      ])

    first = GepaCampaign.plan(plan_opts)
    second = GepaCampaign.plan(plan_opts)

    assert Enum.map(first["shards"], & &1["shard_identity"]) ==
             Enum.map(second["shards"], & &1["shard_identity"])

    changed_sharding = Map.put(opts[:sharding], "shards", Enum.reverse(opts[:sharding]["shards"]))

    assert_raise ArgumentError, ~r/immutable/, fn ->
      GepaCampaign.plan(Keyword.put(plan_opts, :sharding, changed_sharding))
    end
  end

  test "rejects an undeclared shard selector" do
    manifest = GepaCampaignManifest.load!(@manifest)
    opts = GepaCampaignManifest.task_options!(manifest, manifest: @manifest, plan: true)

    assert_raise ArgumentError, ~r/unknown GEPA campaign shard selector/, fn ->
      GepaCampaign.plan(
        opts
        |> Map.to_list()
        |> Keyword.take([
          :dataset_root,
          :campaign_id,
          :model,
          :reflection_model,
          :families,
          :budgets,
          :sharding
        ])
        |> Keyword.put(:shard, "family:NotDeclared")
      )
    end
  end

  test "parent identity is stable across selected shard plans" do
    manifest = GepaCampaignManifest.load!(@manifest)
    opts = GepaCampaignManifest.task_options!(manifest, manifest: @manifest, plan: true)

    plan_opts =
      opts
      |> Map.to_list()
      |> Keyword.take([
        :dataset_root,
        :campaign_id,
        :model,
        :reflection_model,
        :families,
        :budgets,
        :sharding,
        :manifest_identity
      ])

    aime = GepaCampaign.plan(Keyword.put(plan_opts, :shard, "family:AIMEBench"))
    live = GepaCampaign.plan(Keyword.put(plan_opts, :shard, "family:LiveBenchMathBench"))

    assert aime["budget_identity"] == live["budget_identity"]
    assert aime["parent_families"] == live["parent_families"]
    assert aime["parent_families"] == manifest["families"]
    assert aime["families"] == ["AIMEBench"]
    assert live["families"] == ["LiveBenchMathBench"]
    assert aime["shards"] |> length() == 1
    assert live["shards"] |> length() == 1
    refute hd(aime["shards"])["shard_identity"] == hd(live["shards"])["shard_identity"]
  end

  test "selected shard plans use disjoint checkpoint paths" do
    manifest = GepaCampaignManifest.load!(@manifest)
    opts = GepaCampaignManifest.task_options!(manifest, manifest: @manifest, plan: true)

    checkpoint_dir =
      Path.join(System.tmp_dir!(), "gepa-shards-#{System.unique_integer([:positive])}")

    plan_opts =
      opts
      |> Map.to_list()
      |> Keyword.take([
        :dataset_root,
        :campaign_id,
        :model,
        :reflection_model,
        :families,
        :budgets,
        :sharding
      ])
      |> Keyword.put(:checkpoint_dir, checkpoint_dir)

    aime = GepaCampaign.plan(Keyword.put(plan_opts, :shard, "family:AIMEBench"))
    live = GepaCampaign.plan(Keyword.put(plan_opts, :shard, "family:LiveBenchMathBench"))

    assert aime["checkpoint"]["budget_path"] != live["checkpoint"]["budget_path"]
    refute String.contains?(aime["checkpoint"]["budget_path"], live["checkpoint"]["budget_path"])
    refute String.contains?(live["checkpoint"]["budget_path"], aime["checkpoint"]["budget_path"])
  end

  test "durable budget requests and usage are not reset on resume" do
    path = checkpoint_path("resume")
    identity = "sha256:budget-resume"

    {:ok, first} =
      start_budget(path,
        identity: identity,
        aggregate: %{requests: 1, input_tokens: 10_000, output_tokens: 10_000, usd: 10.0},
        per_shard: %{
          AIMEBench: %{requests: 1, input_tokens: 10_000, output_tokens: 10_000, usd: 10.0}
        }
      )

    assert {:ok, reservation} =
             GepaCampaignBudget.reserve(first, "AIMEBench", [%{content: "one"}], max_tokens: 0)

    :ok = GepaCampaignBudget.release(first, reservation)
    handler = GepaCampaignBudget.attach_req_llm(first, "AIMEBench")

    :telemetry.execute(
      [:req_llm, :token_usage],
      %{total_cost: 0.5, tokens: %{input_tokens: 10, output_tokens: 5}},
      %{}
    )

    :telemetry.detach(handler)
    snapshot = GepaCampaignBudget.snapshot(first)
    assert snapshot["aggregate"]["requests"] == 1
    assert snapshot["aggregate"]["usage"]["usd"] == 0.5
    GenServer.stop(first)

    {:ok, resumed} =
      start_budget(path,
        identity: identity,
        aggregate: %{requests: 1, input_tokens: 10_000, output_tokens: 10_000, usd: 10.0},
        per_shard: %{
          AIMEBench: %{requests: 1, input_tokens: 10_000, output_tokens: 10_000, usd: 10.0}
        }
      )

    assert {:error, :requests} =
             GepaCampaignBudget.reserve(resumed, "AIMEBench", [%{content: "again"}],
               max_tokens: 0
             )

    GenServer.stop(resumed)
    File.rm(path)
  end

  test "resume reconciles an in-flight reservation once across restart and restart again" do
    path = checkpoint_path("reconcile")

    {:ok, first} =
      start_budget(path,
        aggregate: %{requests: 2, input_tokens: 10_000, output_tokens: 10_000, usd: 10.0},
        per_shard: %{
          AIMEBench: %{requests: 2, input_tokens: 10_000, output_tokens: 10_000, usd: 10.0}
        }
      )

    assert {:ok, _reservation} =
             GepaCampaignBudget.reserve(first, "AIMEBench", [%{content: "in flight"}],
               max_tokens: 0
             )

    GenServer.stop(first)

    {:ok, resumed} =
      start_budget(path,
        link: false,
        aggregate: %{requests: 2, input_tokens: 10_000, output_tokens: 10_000, usd: 10.0},
        per_shard: %{
          AIMEBench: %{requests: 2, input_tokens: 10_000, output_tokens: 10_000, usd: 10.0}
        }
      )

    first_snapshot = GepaCampaignBudget.snapshot(resumed)
    assert first_snapshot["aggregate"]["requests"] == 1
    assert first_snapshot["active_reservations"] == 0
    assert length(first_snapshot["reconciliations"]) == 1

    assert first_snapshot["aggregate"]["usage"] ==
             first_snapshot["reconciliations"] |> hd() |> Map.fetch!("charged")

    GenServer.stop(resumed)

    {:ok, restarted} =
      start_budget(path,
        link: false,
        aggregate: %{requests: 2, input_tokens: 10_000, output_tokens: 10_000, usd: 10.0},
        per_shard: %{
          AIMEBench: %{requests: 2, input_tokens: 10_000, output_tokens: 10_000, usd: 10.0}
        }
      )

    second_snapshot = GepaCampaignBudget.snapshot(restarted)
    assert second_snapshot["aggregate"] == first_snapshot["aggregate"]
    assert second_snapshot["reconciliations"] == first_snapshot["reconciliations"]
    GenServer.stop(restarted)
    File.rm(path)
  end

  test "snapshot reports per-shard exhaustion" do
    path = checkpoint_path("shard-exhaustion")

    {:ok, budget} =
      start_budget(path,
        aggregate: %{requests: 2, input_tokens: 1, output_tokens: 10_000, usd: 10.0},
        per_shard: %{
          AIMEBench: %{requests: 2, input_tokens: 1, output_tokens: 10_000, usd: 10.0}
        }
      )

    handler = GepaCampaignBudget.attach_req_llm(budget, "AIMEBench")

    :telemetry.execute(
      [:req_llm, :token_usage],
      %{tokens: %{input_tokens: 2, output_tokens: 0}, total_cost: 0.0},
      %{}
    )

    :telemetry.detach(handler)
    snapshot = GepaCampaignBudget.snapshot(budget)
    assert snapshot["exhausted"] == "input_tokens"
    assert snapshot["shard_exhausted"]["AIMEBench"] == "input_tokens"
    assert snapshot["shards"]["AIMEBench"]["exhausted"] == "input_tokens"
    GenServer.stop(budget)
    File.rm(path)
  end

  test "canonical plan is explicitly zero-network" do
    manifest = GepaCampaignManifest.load!(@manifest)
    opts = GepaCampaignManifest.task_options!(manifest, manifest: @manifest, plan: true)

    plan =
      opts
      |> Map.to_list()
      |> Keyword.take([
        :dataset_root,
        :campaign_id,
        :model,
        :reflection_model,
        :families,
        :budgets,
        :sharding
      ])
      |> GepaCampaign.plan()

    assert plan["provider_calls"] == 0
    assert plan["network_calls"] == 0
    assert plan["network_access"] == false
    assert plan["metric_call_budgets"] == manifest["optimizer"]["metric_call_budgets"]
    assert plan["semantic_progress"] == %{"max_consecutive_proposal_errors" => 5}
  end

  test "manifest plan does not require credentials or upstream environment" do
    Mix.Task.reenable("dsex.benchmark.gepa_campaign")

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        assert :ok = GepaTask.run(["--manifest", @manifest, "--plan"])
      end)

    plan = Jason.decode!(output)
    assert plan["provider_calls"] == 0
    assert plan["network_calls"] == 0
    assert plan["semantic_progress"] == %{"max_consecutive_proposal_errors" => 5}
  end

  defp start_budget(path, overrides) do
    link? = Keyword.get(overrides, :link, true)

    aggregate =
      Keyword.get(overrides, :aggregate, %{
        requests: 10,
        input_tokens: 10_000,
        output_tokens: 10_000,
        usd: 10.0
      })

    per_shard = Keyword.get(overrides, :per_shard, %{AIMEBench: aggregate})

    opts =
      [
        identity: Keyword.get(overrides, :identity, "sha256:test"),
        checkpoint_path: path,
        limits: aggregate,
        shard_limits: per_shard,
        pricing: %{"input_per_million" => 0.4, "output_per_million" => 1.6}
      ]

    if link?,
      do: GepaCampaignBudget.start_link(opts),
      else: GenServer.start(GepaCampaignBudget, opts)
  end

  defp checkpoint_path(label),
    do:
      Path.join(
        System.tmp_dir!(),
        "gepa-budget-#{label}-#{System.unique_integer([:positive])}.json"
      )
end
