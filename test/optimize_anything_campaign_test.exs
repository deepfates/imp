defmodule OptimizeAnythingCampaignTest do
  use ExUnit.Case, async: false

  alias Imp.BenchmarkTruth.{BudgetedLM, CampaignBudget}

  alias Imp.BenchmarkTruth.OptimizeAnything.{
    AgentConfig,
    Artifact,
    Campaign,
    CodeArtifact,
    PricingPolicy,
    SchedulingHeuristic
  }

  defmodule ReasoningTransportStub do
    def generate_text(model, messages, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:reasoning_transport, opts})

      {:ok,
       %ReqLLM.Response{
         id: "oa-review-response",
         model: to_string(model),
         context: ReqLLM.Context.new(messages),
         message: ReqLLM.Context.assistant("bounded"),
         object: nil
       }}
    end
  end

  test "campaign runs every evaluator across seeds and records measured usage" do
    responses =
      [CodeArtifact, AgentConfig, SchedulingHeuristic]
      |> Enum.flat_map(fn evaluator -> List.duplicate(evaluator.comparator(), 3) end)

    {:ok, queue} = Agent.start_link(fn -> responses end)

    lm =
      Imp.Test.FunLM.new(fn _messages, _opts ->
        response = Agent.get_and_update(queue, fn [next | rest] -> {next, rest} end)

        Task.async(fn ->
          :telemetry.execute(
            [:req_llm, :token_usage],
            %{total_cost: 10.0, tokens: %{input_tokens: 50_000, output_tokens: 50_000}},
            %{}
          )
        end)
        |> Task.await()

        :telemetry.execute(
          [:req_llm, :token_usage],
          %{total_cost: 0.002, tokens: %{input_tokens: 120, output_tokens: 40}},
          %{}
        )

        {:ok, "```text\n#{response}\n```"}
      end)

    out_dir = tmp_dir("optimize-anything-campaign")
    checkpoint_dir = Path.join(out_dir, "checkpoints")

    %{artifact: artifact, out_path: path} =
      Campaign.run(
        lm: lm,
        provider: "openai",
        model: "gpt-5.4-mini-2026-03-17",
        seeds: [17, 23, 31],
        max_proposals: 1,
        run_id: "oa-campaign-contract-test",
        out_dir: out_dir,
        checkpoint_dir: checkpoint_dir,
        limits: budget_limits(),
        pricing: pricing(),
        pricing_profile: "custom",
        pricing_source_url: "https://example.test/pricing",
        max_output_tokens_per_request: 1_000
      )

    assert Artifact.full_artifact?(artifact)
    assert Imp.BenchmarkTruth.RunContext.verify!(artifact) == artifact

    assert File.regular?(path)
    assert Agent.get(queue, & &1) == []
    assert length(artifact["rows"]) == 3

    for row <- artifact["rows"] do
      assert row["optimized"]["score"] > row["baseline"]["score"]
      assert row["input_tokens"] == 360
      assert row["output_tokens"] == 120
      assert_in_delta row["cost_usd"], 0.006, 1.0e-12
      assert row["campaign_budget"]["limits"]["usd"] == 0.5
      assert row["campaign_budget"]["requests"] == 9
      assert row["campaign_budget"]["active_reservations"] == 0
      assert_in_delta row["campaign_budget"]["usage"]["usd"], 0.018, 1.0e-12
      assert File.regular?(row["provenance"]["budget_checkpoint"])
      assert length(row["reproducibility"]["runs"]) == 3
      assert row["test_count"] > 0
      assert row["test_digest"] not in [row["train_digest"], row["val_digest"]]
      assert Enum.all?(row["reproducibility"]["runs"], &(&1["test_lift"] > 0))

      assert Enum.all?(row["reproducibility"]["runs"], fn run ->
               run["baseline_test_score"] == row["baseline"]["score"] and
                 run["test_score"] > run["baseline_test_score"] and
                 is_number(run["selection_score"])
             end)

      assert Enum.all?(row["reproducibility"]["runs"], &(&1["request_count"] == 1))
      assert Enum.all?(row["reproducibility"]["runs"], &File.regular?(&1["checkpoint"]))

      assert row["reproducibility"]["source_commits"]["gepa"] ==
               "8b0ce6cd99a234f6b74daf37558a2ac0ce18f975"
    end

    assert get_in(artifact, ["run_context", "source_commits", "gepa"]) ==
             "gepa-ai/gepa@8b0ce6cd99a234f6b74daf37558a2ac0ce18f975"

    budget_evidence =
      checkpoint_dir
      |> Path.join("oa-campaign-contract-test/campaign-budget.json")
      |> File.read!()
      |> Jason.decode!()

    assert budget_evidence["payload"]["kind"] == "optimize_anything_campaign_budget"
    assert budget_evidence["payload"]["budget"]["requests"] == 9
    assert budget_evidence["payload"]["budget"]["reservations"] == []
    assert budget_evidence["payload_sha256"] == digest(budget_evidence["payload"])
    assert artifact["budget_checkpoint"] == budget_evidence

    File.rm!(Path.join(checkpoint_dir, "oa-campaign-contract-test/campaign-budget.json"))

    assert_raise ArgumentError, ~r/already has checkpoint state/, fn ->
      Campaign.run(
        lm: Imp.Test.FunLM.new(fn _, _ -> {:ok, "must not run"} end),
        provider: "openai",
        model: "gpt-5.4-mini-2026-03-17",
        seeds: [17, 23, 31],
        max_proposals: 1,
        run_id: "oa-campaign-contract-test",
        out_dir: out_dir,
        checkpoint_dir: checkpoint_dir,
        limits: budget_limits(),
        pricing: pricing(),
        pricing_profile: "custom",
        pricing_source_url: "https://example.test/pricing",
        max_output_tokens_per_request: 1_000
      )
    end
  end

  test "campaign requires distinct reproducibility seeds" do
    assert_raise ArgumentError, ~r/at least three distinct integers/, fn ->
      Campaign.run(
        lm: Imp.Test.FunLM.new(fn _, _ -> {:ok, "unused"} end),
        provider: "test",
        model: "test",
        seeds: [1],
        limits: budget_limits(),
        pricing: pricing(),
        pricing_source_url: "https://example.test/pricing",
        max_output_tokens_per_request: 1_000
      )
    end
  end

  test "campaign refuses a request ceiling that cannot cover declared proposal opportunity" do
    root = tmp_dir("optimize-anything-request-opportunity")
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    lm =
      Imp.Test.FunLM.new(fn _, _ ->
        Agent.update(calls, &(&1 + 1))
        {:ok, "must not execute"}
      end)

    assert_raise ArgumentError, ~r/requires at least 45 requests/, fn ->
      Campaign.run(
        lm: lm,
        provider: "test",
        model: "test",
        seeds: [17, 23, 31],
        max_proposals: 5,
        run_id: "oa-insufficient-request-opportunity",
        checkpoint_dir: Path.join(root, "checkpoints"),
        out_dir: Path.join(root, "runs"),
        limits: budget_limits(),
        pricing: pricing(),
        pricing_profile: "custom",
        pricing_source_url: "https://example.test/pricing",
        max_output_tokens_per_request: 1_000
      )
    end

    assert Agent.get(calls, & &1) == 0
    refute File.exists?(Path.join(root, "checkpoints"))
    refute File.exists?(Path.join(root, "runs"))
  end

  test "representative selection never consults held-out test score" do
    runs = [
      %{seed: 17, selection_score: 0.9, test_score: 0.1},
      %{seed: 23, selection_score: 0.8, test_score: 1.0}
    ]

    assert Campaign.select_representative(runs).seed == 17
  end

  test "cost ceiling stops the next call before cumulative overspend" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)
    checkpoint_dir = tmp_dir("optimize-anything-budget-rejection")

    lm =
      Imp.Test.FunLM.new(fn _messages, _opts ->
        Agent.update(calls, &(&1 + 1))

        :telemetry.execute(
          [:req_llm, :token_usage],
          %{total_cost: 0.02, tokens: %{input_tokens: 1_000, output_tokens: 1_000}},
          %{}
        )

        {:ok, "```text\n#{CodeArtifact.comparator()}\n```"}
      end)

    assert_raise RuntimeError, ~r/campaign_budget_exhausted.*usd/, fn ->
      Campaign.run(
        lm: lm,
        provider: "test",
        model: "test",
        seeds: [17, 23, 31],
        max_proposals: 1,
        run_id: "oa-budget-rejection-test",
        checkpoint_dir: checkpoint_dir,
        out_dir: checkpoint_dir,
        limits: %{requests: 9, input_tokens: 100_000, output_tokens: 20_000, usd: 0.04},
        pricing: pricing(),
        pricing_profile: "custom",
        pricing_source_url: "https://example.test/pricing",
        max_output_tokens_per_request: 1_500
      )
    end

    assert Agent.get(calls, & &1) == 1

    budget_evidence =
      checkpoint_dir
      |> Path.join("oa-budget-rejection-test/campaign-budget.json")
      |> File.read!()
      |> Jason.decode!()

    assert budget_evidence["payload"]["budget"]["requests"] == 1
    assert_in_delta budget_evidence["payload"]["budget"]["usage"]["usd"], 0.02, 1.0e-12
    assert budget_evidence["payload"]["budget"]["exhausted"] == "usd"
  end

  test "missing or zero telemetry cost fails closed" do
    responses = List.duplicate(CodeArtifact.comparator(), 3)
    {:ok, queue} = Agent.start_link(fn -> responses end)
    out_dir = tmp_dir("optimize-anything-zero-cost")

    lm =
      Imp.Test.FunLM.new(fn _messages, _opts ->
        response = Agent.get_and_update(queue, fn [next | rest] -> {next, rest} end)

        :telemetry.execute(
          [:req_llm, :token_usage],
          %{tokens: %{input_tokens: 120, output_tokens: 40}},
          %{}
        )

        {:ok, "```text\n#{response}\n```"}
      end)

    assert_raise RuntimeError, ~r/missing, zero, or non-finite cost/, fn ->
      Campaign.run(
        lm: lm,
        provider: "test",
        model: "test",
        seeds: [17, 23, 31],
        max_proposals: 1,
        run_id: "oa-zero-cost-test",
        checkpoint_dir: Path.join(out_dir, "checkpoints"),
        out_dir: out_dir,
        limits: budget_limits(),
        pricing: pricing(),
        pricing_profile: "custom",
        pricing_source_url: "https://example.test/pricing",
        max_output_tokens_per_request: 1_000
      )
    end
  end

  test "unexpected final-call provider charge overrun cannot emit full evidence" do
    responses =
      [CodeArtifact, AgentConfig, SchedulingHeuristic]
      |> Enum.flat_map(fn evaluator -> List.duplicate(evaluator.comparator(), 3) end)

    {:ok, queue} = Agent.start_link(fn -> responses end)
    {:ok, calls} = Agent.start_link(fn -> 0 end)
    out_dir = tmp_dir("optimize-anything-final-overrun")
    checkpoint_dir = Path.join(out_dir, "checkpoints")

    lm =
      Imp.Test.FunLM.new(fn _messages, _opts ->
        response = Agent.get_and_update(queue, fn [next | rest] -> {next, rest} end)
        call = Agent.get_and_update(calls, fn count -> {count + 1, count + 1} end)
        cost = if call == 9, do: 0.60, else: 0.002

        :telemetry.execute(
          [:req_llm, :token_usage],
          %{total_cost: cost, tokens: %{input_tokens: 120, output_tokens: 40}},
          %{}
        )

        {:ok, "```text\n#{response}\n```"}
      end)

    assert_raise RuntimeError, ~r/exceeded its declared usd ceiling/, fn ->
      Campaign.run(
        lm: lm,
        provider: "test",
        model: "test",
        seeds: [17, 23, 31],
        max_proposals: 1,
        run_id: "oa-final-overrun-test",
        checkpoint_dir: checkpoint_dir,
        out_dir: out_dir,
        limits: budget_limits(),
        pricing: pricing(),
        pricing_profile: "custom",
        pricing_source_url: "https://example.test/pricing",
        max_output_tokens_per_request: 1_000
      )
    end

    assert Agent.get(calls, & &1) == 9
    assert Path.wildcard(Path.join(out_dir, "optimize-anything-replication-*.json")) == []

    checkpoint =
      checkpoint_dir
      |> Path.join("oa-final-overrun-test/campaign-budget.json")
      |> File.read!()
      |> Jason.decode!()

    assert checkpoint["payload"]["budget"]["exhausted"] == "usd"
    assert checkpoint["payload"]["budget"]["usage"]["usd"] > 0.5
  end

  test "credential-bearing pricing source is rejected before calls or artifacts" do
    root = tmp_dir("optimize-anything-unsafe-pricing-url")
    out_dir = Path.join(root, "runs")
    checkpoint_dir = Path.join(root, "checkpoints")
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    lm =
      Imp.Test.FunLM.new(fn _messages, _opts ->
        Agent.update(calls, &(&1 + 1))
        {:ok, "must not execute"}
      end)

    assert_raise ArgumentError, ~r/ordinary credential-free HTTP\(S\) documentation URL/, fn ->
      Campaign.run(
        lm: lm,
        provider: "test",
        model: "test",
        seeds: [17, 23, 31],
        max_proposals: 1,
        run_id: "oa-unsafe-pricing-url-test",
        checkpoint_dir: checkpoint_dir,
        out_dir: out_dir,
        limits: budget_limits(),
        pricing: pricing(),
        pricing_profile: "custom",
        pricing_source_url:
          "https://user:password@pricing.example/rates?api_key=CANARY_OA_PRICING",
        max_output_tokens_per_request: 1_000
      )
    end

    assert Agent.get(calls, & &1) == 0
    refute File.exists?(out_dir)
    refute File.exists?(checkpoint_dir)

    persisted =
      root
      |> Path.join("**/*")
      |> Path.wildcard()
      |> Enum.filter(&File.regular?/1)
      |> Enum.map_join("", &File.read!/1)

    refute persisted =~ "CANARY_OA_PRICING"
  end

  @tag :evidence_infrastructure
  test "live task requires explicit pricing and all spend ceilings" do
    base = [
      "--live",
      "--provider",
      "openai",
      "--model",
      "gpt-5.4-2026-03-05",
      "--seeds",
      "17,23,31",
      "--max-requests",
      "20",
      "--max-input-tokens",
      "100000",
      "--max-output-tokens",
      "20000",
      "--max-output-tokens-per-request",
      "1000"
    ]

    assert_raise Mix.Error, ~r/--pricing-profile.*required for --live/, fn ->
      Mix.Tasks.Imp.Benchmark.OptimizeAnything.run(base ++ ["--max-cost-usd", "0.50"])
    end

    assert_raise Mix.Error, ~r/--max-cost-usd is required/, fn ->
      Mix.Tasks.Imp.Benchmark.OptimizeAnything.run(
        base ++ ["--pricing-profile", "openai-gpt-5.4-standard-2026-03-05"]
      )
    end

    unsafe_custom =
      base ++
        [
          "--max-cost-usd",
          "0.50",
          "--input-price-per-million",
          "2.50",
          "--output-price-per-million",
          "15.00",
          "--pricing-source-url",
          "https://pricing.example/rates?api_key=CANARY_OA_CLI"
        ]

    assert_raise Mix.Error, ~r/ordinary credential-free HTTP\(S\) documentation URL/, fn ->
      Mix.Tasks.Imp.Benchmark.OptimizeAnything.run(unsafe_custom)
    end
  end

  test "budgeted LM injects the reserved output cap and rejects oversized requests pre-call" do
    {:ok, budget} =
      CampaignBudget.start_link(
        limits: %{requests: 2, input_tokens: 10_000, output_tokens: 128, usd: 1.0},
        pricing: %{"input_per_million" => 1.0, "output_per_million" => 1.0},
        default_max_output_tokens: 64
      )

    owner = self()

    inner =
      Imp.Test.FunLM.new(fn _messages, opts ->
        send(owner, {:provider_called, opts})
        {:ok, "bounded"}
      end)

    lm = %BudgetedLM{inner: inner, budget: budget, max_output_tokens: 64}

    assert {:ok, "bounded"} = Imp.LM.generate(lm, [%{content: "first"}])
    assert_receive {:provider_called, opts}
    assert Keyword.fetch!(opts, :max_tokens) == 64

    assert {:error, {:max_output_tokens_exceeded, 65, 64}} =
             Imp.LM.generate(lm, [%{content: "second"}], max_tokens: 65)

    refute_receive {:provider_called, _opts}

    assert {:error, {:max_output_tokens_exceeded, 128, 64}} =
             Imp.LM.generate(lm, [%{content: "third"}], max_completion_tokens: 128)

    refute_receive {:provider_called, _opts}
    assert CampaignBudget.snapshot(budget)["requests"] == 1
  end

  test "budgeted ReqLLM overrides hidden token aliases and forces one uncached attempt" do
    {:ok, budget} =
      CampaignBudget.start_link(
        limits: %{requests: 1, input_tokens: 10_000, output_tokens: 64, usd: 1.0},
        pricing: %{"input_per_million" => 1.0, "output_per_million" => 1.0},
        default_max_output_tokens: 64
      )

    inner =
      Imp.req_llm("openai:gpt-5.4-2026-03-05",
        req_module: ReasoningTransportStub,
        test_pid: self(),
        cache: true,
        max_retries: 3,
        max_completion_tokens: 9_999,
        provider_options: [max_completion_tokens: 8_888, max_retries: 3]
      )

    lm = %BudgetedLM{inner: inner, budget: budget, max_output_tokens: 64}

    assert {:ok, _response} = Imp.LM.generate(lm, [%{role: :user, content: "bounded"}])
    assert_receive {:reasoning_transport, opts}
    assert Keyword.fetch!(opts, :max_completion_tokens) == 64
    assert Keyword.fetch!(opts, :max_retries) == 0
    refute Keyword.has_key?(opts, :max_tokens)
    refute Keyword.has_key?(opts, :request_options)
    refute Keyword.has_key?(Keyword.get(opts, :provider_options, []), :max_completion_tokens)
    refute Keyword.has_key?(Keyword.get(opts, :provider_options, []), :max_retries)
  end

  test "pricing profiles are exact and custom URLs use the same strict policy" do
    profile =
      PricingPolicy.profile!(
        "openai",
        "gpt-5.4-2026-03-05",
        "openai-gpt-5.4-standard-2026-03-05"
      )

    assert profile.pricing == %{
             "input_per_million" => 2.5,
             "output_per_million" => 15.0
           }

    assert_raise ArgumentError, ~r/does not match its exact rates/, fn ->
      PricingPolicy.resolve!(
        "openai",
        "gpt-5.4-2026-03-05",
        profile.profile,
        %{"input_per_million" => 0.001, "output_per_million" => 0.001},
        profile.source_url
      )
    end

    assert_raise ArgumentError, ~r/requires provider openai/, fn ->
      PricingPolicy.profile!(
        "other",
        "gpt-5.4-2026-03-05",
        "openai-gpt-5.4-standard-2026-03-05"
      )
    end

    assert_raise ArgumentError, ~r/ordinary credential-free/, fn ->
      PricingPolicy.custom!(
        "test",
        "test",
        pricing(),
        "https://pricing.example/api%255fkey/CANARY_OA"
      )
    end

    for url <- [
          "https://example.test/pricing?ref=public",
          "https://example.test/pricing#public"
        ] do
      assert_raise ArgumentError, ~r/ordinary credential-free/, fn ->
        PricingPolicy.custom!("test", "test", pricing(), url)
      end
    end

    assert_raise ArgumentError, ~r/custom pricing requires/, fn ->
      PricingPolicy.custom!(
        "test",
        "test",
        Map.put(pricing(), "api_key", "CANARY_OA"),
        "https://example.test/pricing"
      )
    end
  end

  defp budget_limits do
    %{requests: 20, input_tokens: 100_000, output_tokens: 20_000, usd: 0.5}
  end

  defp pricing do
    %{"input_per_million" => 2.5, "output_per_million" => 15.0}
  end

  defp digest(value) do
    encoded = :erlang.term_to_binary(value, [:deterministic])
    "sha256:" <> (:crypto.hash(:sha256, encoded) |> Base.encode16(case: :lower))
  end

  defp tmp_dir(name) do
    path = Path.join(System.tmp_dir!(), "imp-#{name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
