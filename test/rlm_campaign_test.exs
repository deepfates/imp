defmodule Imp.BenchmarkTruth.RLMCampaignTest do
  use ExUnit.Case, async: false

  alias Imp.BenchmarkTruth.{
    CampaignBudget,
    RLMCampaign,
    RLMCheckpoint,
    RLMDataset,
    RLMManifest,
    RLMProtocol,
    RLMRuntime,
    RLMStatistics
  }

  test "manifest admits explicit current ReqLLM models without embedding credentials" do
    fixture = fixture!()
    manifest = fixture.manifest_path |> File.read!() |> Jason.decode!()

    explicit = %{
      "provider" => "openrouter",
      "id" => "deepseek/deepseek-v4-flash-20260423",
      "base_url" => "https://openrouter.ai/api/v1",
      "api_key_env" => "OPENROUTER_API_KEY",
      "context_window" => 1_048_576
    }

    manifest =
      update_in(manifest, ["models"], fn models ->
        Map.new(models, fn {role, model} -> {role, Map.put(model, "imp", explicit)} end)
      end)

    File.write!(fixture.manifest_path, Jason.encode!(manifest, pretty: true))
    loaded = RLMManifest.load!(fixture.manifest_path)

    assert get_in(loaded, ["models", "root", "imp"]) == explicit
    refute fixture.manifest_path |> File.read!() |> String.contains?("sk-or-")
  end

  test "explicit ReqLLM model credentials are environment references and fail closed" do
    fixture = fixture!()
    manifest = fixture.manifest_path |> File.read!() |> Jason.decode!()

    invalid = %{
      "provider" => "openrouter",
      "id" => "deepseek/deepseek-v4-flash-20260423",
      "base_url" => "https://openrouter.ai/api/v1",
      "api_key_env" => "sk-or-secret",
      "context_window" => 1_048_576
    }

    manifest = put_in(manifest, ["models", "root", "imp"], invalid)
    File.write!(fixture.manifest_path, Jason.encode!(manifest, pretty: true))

    assert_raise ArgumentError,
                 ~r/api_key_env must be an uppercase environment variable name/,
                 fn ->
                   RLMManifest.load!(fixture.manifest_path)
                 end
  end

  test "standard provider credentials cannot be redirected to another endpoint" do
    fixture = fixture!()
    manifest = fixture.manifest_path |> File.read!() |> Jason.decode!()

    redirected = %{
      "provider" => "openrouter",
      "id" => "google/gemini-3.5-flash",
      "base_url" => "https://credential-collector.example/v1",
      "api_key_env" => "OPENROUTER_API_KEY",
      "context_window" => 1_048_576
    }

    manifest = put_in(manifest, ["models", "root", "imp"], redirected)
    File.write!(fixture.manifest_path, Jason.encode!(manifest, pretty: true))

    assert_raise ArgumentError, ~r/must use the canonical openrouter endpoint/, fn ->
      RLMManifest.load!(fixture.manifest_path)
    end
  end

  test "nonstandard providers require a dedicated campaign credential" do
    fixture = fixture!()
    manifest = fixture.manifest_path |> File.read!() |> Jason.decode!()
    model = get_in(manifest, ["models", "root", "imp"])
    unsafe = %{model | "api_key_env" => "HOME"}
    manifest = put_in(manifest, ["models", "root", "imp"], unsafe)
    File.write!(fixture.manifest_path, Jason.encode!(manifest, pretty: true))

    assert_raise ArgumentError, ~r/must use a dedicated IMP_RLM_ credential/, fn ->
      RLMManifest.load!(fixture.manifest_path)
    end
  end

  test "explicit model capacity covers the declared dataset context grid" do
    fixture = fixture!()
    manifest = fixture.manifest_path |> File.read!() |> Jason.decode!()
    manifest = put_in(manifest, ["models", "root", "imp", "context_window"], 1024)
    File.write!(fixture.manifest_path, Jason.encode!(manifest, pretty: true))

    assert_raise ArgumentError, ~r/context_window must cover.*1048576/, fn ->
      RLMManifest.load!(fixture.manifest_path)
    end
  end

  test "nonstandard string providers require an explicit credential-bearing model spec" do
    fixture = fixture!()
    manifest = fixture.manifest_path |> File.read!() |> Jason.decode!()
    manifest = put_in(manifest, ["models", "root", "imp"], "custom:model")
    File.write!(fixture.manifest_path, Jason.encode!(manifest, pretty: true))

    assert_raise ArgumentError, ~r/use an explicit model object with api_key_env/, fn ->
      RLMManifest.load!(fixture.manifest_path)
    end
  end

  test "OOLONG-Pairs row limits are pushed into JSONL decoding" do
    fixture = fixture!()
    manifest = fixture.manifest_path |> File.read!() |> Jason.decode!()
    path = manifest["datasets"]["oolong_pairs"]["path"]
    lines = path |> File.read!() |> String.split("\n", trim: true)
    File.write!(path, Enum.join(List.replace_at(lines, 2, "not-json"), "\n") <> "\n")

    manifest = put_in(manifest, ["datasets", "oolong_pairs", "sha256"], sha(path))
    File.write!(fixture.manifest_path, Jason.encode!(manifest, pretty: true))
    loaded = RLMManifest.load!(fixture.manifest_path)

    assert %{"oolong_pairs" => %{"rows" => [row]}} =
             RLMDataset.load_all!(loaded, row_limit: 1)

    assert row["id"] == "oolong_pairs-1@1024"
  end

  defmodule UsageFixture do
    @rates %{"input_per_million" => 1.0, "output_per_million" => 1.0}

    def provider_reported(requests, input_per_call, output_per_call, usd_per_call) do
      audits =
        for request <- 1..requests do
          %{
            "request" => request,
            "role" => "root",
            "authority" => "provider_reported",
            "input_tokens" => input_per_call,
            "output_tokens" => output_per_call,
            "usd" => usd_per_call,
            "provider_reported_usd" => usd_per_call,
            "rates" => @rates
          }
        end

      usage(requests, input_per_call, output_per_call, usd_per_call, "provider_reported", audits)
    end

    def pricing_derived(input_tokens, output_tokens) do
      usd = (input_tokens + output_tokens) / 1_000_000

      audits = [
        %{
          "request" => 1,
          "role" => "root",
          "authority" => "pricing_derived",
          "input_tokens" => input_tokens,
          "output_tokens" => output_tokens,
          "usd" => usd,
          "provider_reported_usd" => nil,
          "rates" => @rates
        }
      ]

      usage(1, input_tokens, output_tokens, usd, "pricing_derived", audits)
    end

    def free do
      audits = [
        %{
          "request" => 1,
          "role" => "root",
          "authority" => "free",
          "input_tokens" => 1,
          "output_tokens" => 1,
          "usd" => 0.0,
          "provider_reported_usd" => 0.0,
          "rates" => @rates
        }
      ]

      usage(1, 1, 1, 0.0, "free", audits)
    end

    def empty(rates \\ @rates),
      do: %{
        "requests" => 0,
        "root_calls" => 0,
        "sub_calls" => 0,
        "input_tokens" => 0,
        "output_tokens" => 0,
        "usd" => 0.0,
        "cost_authority" => "unavailable",
        "cost_rates" => rates,
        "cost_audit" => []
      }

    def rates, do: @rates

    defp usage(requests, input_per_call, output_per_call, usd_per_call, authority, audits) do
      %{
        "requests" => requests,
        "root_calls" => requests,
        "sub_calls" => 0,
        "input_tokens" => requests * input_per_call,
        "output_tokens" => requests * output_per_call,
        "usd" => requests * usd_per_call,
        "cost_authority" => authority,
        "cost_rates" => @rates,
        "cost_audit" => audits
      }
    end
  end

  defmodule GoodRuntime do
    @behaviour Imp.BenchmarkTruth.RLMRuntime
    alias Imp.BenchmarkTruth.RLMCampaignTest.UsageFixture

    def execute(row, approach, _context) do
      if Map.has_key?(row, "gold") or Map.has_key?(row, "evidence_document_ids"),
        do: raise("gold leaked into runtime payload")

      {:ok,
       %{
         "answer" => "yes",
         "latency_ms" => 1.0,
         "usage" => UsageFixture.provider_reported(1, 1, 1, 0.25),
         "trace_shape" => [approach],
         "trace" => [],
         "call_semantics" => %{
           "provider_calls" => 1,
           "root_calls" => 1,
           "sub_calls" => 0,
           "max_llm_calls_scope" =>
             if(approach == "rlm", do: "total_provider_calls", else: "not_applicable"),
           "configured_max_depth" => if(approach == "rlm", do: 1, else: 0),
           "max_observed_depth" => 0
         }
       }}
    end
  end

  defmodule CrashRuntime do
    @behaviour Imp.BenchmarkTruth.RLMRuntime
    def execute(_row, _approach, _context), do: raise("ambiguous dispatch")
  end

  defmodule MalformedRuntime do
    @behaviour Imp.BenchmarkTruth.RLMRuntime
    def execute(_row, _approach, _context),
      do:
        {:ok,
         %{
           "latency_ms" => 1.0,
           "usage" => %{"requests" => 0, "input_tokens" => 0, "output_tokens" => 0, "usd" => 0.0},
           "trace_shape" => ["bad"],
           "trace" => []
         }}
  end

  defmodule OverBudgetRuntime do
    @behaviour Imp.BenchmarkTruth.RLMRuntime
    alias Imp.BenchmarkTruth.RLMCampaignTest.UsageFixture

    def execute(_row, approach, _context),
      do:
        {:ok,
         %{
           "answer" => "yes",
           "latency_ms" => 1.0,
           "usage" => UsageFixture.provider_reported(2, 1, 1, 0.25),
           "trace_shape" => [approach],
           "trace" => [],
           "call_semantics" => %{
             "provider_calls" => 2,
             "root_calls" => 2,
             "sub_calls" => 0,
             "max_llm_calls_scope" => "not_applicable",
             "configured_max_depth" => 0,
             "max_observed_depth" => 0
           }
         }}
  end

  defmodule ChargedErrorRuntime do
    @behaviour Imp.BenchmarkTruth.RLMRuntime
    alias Imp.BenchmarkTruth.RLMCampaignTest.UsageFixture

    def execute(_row, approach, _context) do
      usage = UsageFixture.pricing_derived(7, 0)

      {:error,
       %{
         "reason" => "provider rejected request after charging input",
         "usage" => usage,
         "call_semantics" => %{
           "provider_calls" => 1,
           "root_calls" => 1,
           "sub_calls" => 0,
           "max_llm_calls_scope" =>
             if(approach == "rlm", do: "total_provider_calls", else: "not_applicable"),
           "configured_max_depth" => if(approach == "rlm", do: 1, else: 0),
           "max_observed_depth" => 0
         }
       }}
    end
  end

  test "five adapters run without exposing gold and committed rows resume without replay" do
    fixture = fixture!()
    result = run!(fixture, GoodRuntime)
    assert result.artifact["evidence_tier"] == "t2_live_sample"
    assert result.artifact["summary"]["total"] == 60
    assert result.artifact["summary"]["all_passing"]
    refute result.artifact["summary"]["paper_protocol_complete"]
    refute result.artifact["environment"]["dspy_used"]
    assert result.artifact["environment"]["python"] == nil
    assert String.match?(result.artifact["environment"]["lock_sha256"], ~r/^[0-9a-f]{64}$/)

    assert result.artifact["environment"]["input_setup_path"] ==
             "scripts/setup_rlm_pilot_inputs.sh"

    assert String.match?(
             result.artifact["environment"]["input_setup_sha256"],
             ~r/^[0-9a-f]{64}$/
           )

    assert is_boolean(result.artifact["untracked_worktree_dirty"])

    assert Enum.all?(result.artifact["rows"], fn row ->
             row["usage"]["cost_authority"] == "provider_reported" and
               row["usage"]["cost_rates"] == UsageFixture.rates()
           end)

    gate = RLMProtocol.evaluate(result.artifact)
    assert Enum.find(gate["checks"], &(&1["id"] == "cost_accounting"))["passing"]

    assert get_in(result.artifact, ["aggregate", "approaches", "imp:direct", "usd"]) ==
             3.75

    resumed = run!(fixture, CrashRuntime)
    assert resumed.artifact["summary"]["total"] == 60
    assert resumed.artifact["summary"]["all_passing"]
  end

  test "plan selection is deterministic and enumerates exact jobs" do
    fixture = fixture!()

    opts = [families: ["oolong", "s_niah"], approaches: ["rlm", "direct"], row_limit: 1]
    plan = RLMCampaign.plan(fixture.manifest_path, opts)
    repeated = RLMCampaign.plan(fixture.manifest_path, Enum.reverse(opts))

    assert plan["provider_calls"] == 0
    assert plan["selection"]["families"] == ~w(s_niah oolong)
    assert plan["selection"]["approaches"] == ~w(direct rlm)
    assert plan["job_count"] == 4
    assert plan["jobs"] == repeated["jobs"]

    assert Enum.map(plan["jobs"], & &1["key"]) == [
             "imp:direct:oolong:oolong-1",
             "imp:direct:s_niah:s_niah-1",
             "imp:rlm:oolong:oolong-1",
             "imp:rlm:s_niah:s_niah-1"
           ]
  end

  test "an adapted manifest defaults to its declared families" do
    fixture = fixture!()
    manifest = Jason.decode!(File.read!(fixture.manifest_path))
    manifest = put_in(manifest["datasets"], Map.take(manifest["datasets"], ["oolong_pairs"]))
    path = Path.join(Path.dirname(fixture.manifest_path), "adapted-manifest.json")
    File.write!(path, Jason.encode!(manifest))

    plan = RLMCampaign.plan(path, approaches: ["direct"], row_limit: 1)

    assert plan["selection"]["families"] == ["oolong_pairs"]
    assert plan["families"] == %{"oolong_pairs" => 1}
    assert plan["job_count"] == 1
  end

  test "invalid campaign filters fail before dispatch" do
    fixture = fixture!()

    assert_raise ArgumentError, ~r/invalid family filter: missing/, fn ->
      RLMCampaign.plan(fixture.manifest_path, families: ["missing"])
    end

    assert_raise ArgumentError, ~r/invalid approach filter: fake/, fn ->
      RLMCampaign.plan(fixture.manifest_path, approaches: ["fake"])
    end

    assert_raise ArgumentError, ~r/row limit must be a positive integer/, fn ->
      RLMCampaign.plan(fixture.manifest_path, row_limit: 0)
    end
  end

  test "selection changes are checkpoint identity mismatches" do
    fixture = fixture!()
    run!(fixture, GoodRuntime, families: ["oolong"], approaches: ["direct"], row_limit: 1)

    assert_raise ArgumentError, ~r/checkpoint identity mismatch/, fn ->
      run!(fixture, GoodRuntime, families: ["oolong"], approaches: ["direct"])
    end
  end

  test "filtered committed rows resume without replay" do
    fixture = fixture!()
    opts = [families: ["oolong"], approaches: ["direct", "rlm"], row_limit: 1]
    result = run!(fixture, GoodRuntime, opts)
    assert result.artifact["summary"]["total"] == 2
    assert result.artifact["execution"]["subset"]

    resumed = run!(fixture, CrashRuntime, opts)
    assert resumed.artifact["summary"]["total"] == 2
  end

  test "a bounded subset of a T3 manifest is labeled only T2" do
    manifest = fixture!() |> canonical_manifest_with_fixture_oolong!()

    plan =
      RLMCampaign.plan(manifest,
        families: ["oolong"],
        approaches: ["direct", "simple_retrieval", "rlm"],
        runtime: "both",
        row_limit: 1
      )

    assert plan["requested_evidence_tier"] == "t3_paper_scale"
    assert plan["evidence_tier"] == "t2_live_sample"
    assert plan["subset"]
    assert plan["job_count"] == 6
  end

  test "an unavailable selected family fails closed while pinned families remain runnable" do
    manifest = fixture!() |> canonical_manifest_with_fixture_oolong!()

    assert_raise ArgumentError, ~r/unavailable or unpinned: s_niah/, fn ->
      RLMCampaign.plan(manifest, families: ["s_niah"], row_limit: 1)
    end

    assert RLMCampaign.plan(manifest, families: ["oolong"], row_limit: 1)["job_count"] == 4
  end

  test "dataset drift is rejected before dispatch" do
    fixture = fixture!()
    File.write!(fixture.dataset_paths["s_niah"], "{}\n", [:append])

    assert_raise ArgumentError, ~r/dataset hash mismatch for s_niah/, fn ->
      run!(fixture, GoodRuntime)
    end
  end

  test "ambiguous dispatch is durable and resume refuses replay" do
    fixture = fixture!()

    assert_raise RuntimeError, ~r/crashed after durable intent/, fn ->
      run!(fixture, CrashRuntime)
    end

    assert_raise ArgumentError, ~r/ambiguous outcomes/, fn -> run!(fixture, GoodRuntime) end
  end

  test "malformed output commits terminal errors and does not replay" do
    fixture = fixture!()
    result = run!(fixture, MalformedRuntime)
    assert Enum.all?(result.artifact["rows"], &(&1["status"] == "error" and is_nil(&1["score"])))
    resumed = run!(fixture, CrashRuntime)
    assert Enum.all?(resumed.artifact["rows"], &(&1["status"] == "error" and is_nil(&1["score"])))
  end

  test "exact request boundary rejects a row reporting more calls than remain" do
    fixture = fixture!(request_limit: 1)
    result = run!(fixture, OverBudgetRuntime)
    assert Enum.all?(result.artifact["rows"], &(&1["status"] == "error"))

    assert Enum.any?(
             result.artifact["rows"],
             &String.contains?(&1["error"], "campaign_budget_exhausted")
           )

    assert Enum.all?(result.artifact["rows"], fn row ->
             row["usage"]["requests"] == 2 and row["usage"]["input_tokens"] == 2 and
               row["usage"]["output_tokens"] == 2 and
               row["usage"]["cost_authority"] == "provider_reported"
           end)

    assert get_in(result.artifact, ["aggregate", "approaches", "imp:direct", "calls"]) == 30
    assert get_in(result.artifact, ["aggregate", "approaches", "imp:direct", "usd"]) == 7.5

    resumed = run!(fixture, CrashRuntime)
    assert Enum.all?(resumed.artifact["rows"], &(&1["usage"]["requests"] == 2))
    assert Enum.all?(resumed.artifact["rows"], &(length(&1["usage"]["cost_audit"]) == 2))
  end

  test "external input-only provider errors retain charged usage in rows, aggregates, and resume" do
    fixture = fixture!()
    result = run!(fixture, ChargedErrorRuntime)

    assert Enum.all?(result.artifact["rows"], fn row ->
             row["status"] == "error" and row["usage"]["requests"] == 1 and
               row["usage"]["input_tokens"] == 7 and row["usage"]["output_tokens"] == 0 and
               row["usage"]["cost_authority"] == "pricing_derived"
           end)

    direct = get_in(result.artifact, ["aggregate", "approaches", "imp:direct"])
    assert direct["completed"] == 0
    assert direct["calls"] == 15
    assert direct["input_tokens"] == 105
    assert direct["output_tokens"] == 0
    assert direct["cost_authorities"] == %{"pricing_derived" => 15}

    resumed = run!(fixture, CrashRuntime)
    assert Enum.all?(resumed.artifact["rows"], &(&1["usage"]["input_tokens"] == 7))
  end

  test "metered LM records input-only provider error usage and derives missing cost" do
    rates = UsageFixture.rates()

    {:ok, budget} =
      CampaignBudget.start_link(
        limits: %{
          "requests" => 2,
          "input_tokens" => 10_000,
          "output_tokens" => 100,
          "usd" => 1.0
        },
        pricing: rates,
        default_max_output_tokens: 10
      )

    {:ok, usage_agent} = Agent.start_link(fn -> UsageFixture.empty(rates) end)

    inner = fn _messages, _opts ->
      {:error, %{usage: %{input_tokens: 9, output_tokens: 0, total_cost: 0.0}, reason: :rejected}}
    end

    lm = %RLMRuntime.MeteredLM{
      inner: inner,
      budget: budget,
      usage: usage_agent,
      max_tokens: 10,
      role: "root",
      pricing: rates
    }

    assert {:error, {:provider_error_with_usage, _reason}} =
             RLMRuntime.MeteredLM.generate(lm, [%{role: :user, content: "charged"}], [])

    usage = Agent.get(usage_agent, & &1)
    assert usage["requests"] == 1
    assert usage["input_tokens"] == 9
    assert usage["output_tokens"] == 0
    assert usage["cost_authority"] == "pricing_derived"
    assert_in_delta usage["usd"], 0.000009, 1.0e-12

    snapshot = CampaignBudget.snapshot(budget)
    assert snapshot["usage"]["input_tokens"] == 9
    assert_in_delta snapshot["usage"]["usd"], 0.000009, 1.0e-12
  end

  test "metered LM never serializes an unauditable provider request" do
    rates = UsageFixture.rates()

    {:ok, budget} =
      CampaignBudget.start_link(
        limits: %{
          "requests" => 2,
          "input_tokens" => 10_000,
          "output_tokens" => 100,
          "usd" => 1.0
        },
        pricing: rates,
        default_max_output_tokens: 10
      )

    {:ok, usage_agent} = Agent.start_link(fn -> UsageFixture.empty(rates) end)
    secret = "sk-secret-request-body-123456789"
    inner = fn _messages, _opts -> {:error, %{request_body: secret, response_body: secret}} end

    lm = %RLMRuntime.MeteredLM{
      inner: inner,
      budget: budget,
      usage: usage_agent,
      max_tokens: 10,
      role: "root",
      pricing: rates
    }

    error =
      assert_raise RLMRuntime.AmbiguousExternalCall, fn ->
        RLMRuntime.MeteredLM.generate(lm, [%{role: :user, content: "private"}], [])
      end

    assert error.message == "provider call returned without auditable usage (map)"
    refute error.message =~ secret
  end

  test "metered LM charges but rejects token-incomplete provider success" do
    rates = UsageFixture.rates()

    {:ok, budget} =
      CampaignBudget.start_link(
        limits: %{
          "requests" => 2,
          "input_tokens" => 10_000,
          "output_tokens" => 100,
          "usd" => 1.0
        },
        pricing: rates,
        default_max_output_tokens: 10
      )

    {:ok, usage_agent} = Agent.start_link(fn -> UsageFixture.empty(rates) end)

    inner = fn _messages, _opts ->
      {:ok, %{usage: %{input_tokens: 9, output_tokens: 0, total_cost: 0.0}}}
    end

    lm = %RLMRuntime.MeteredLM{
      inner: inner,
      budget: budget,
      usage: usage_agent,
      max_tokens: 10,
      role: "root",
      pricing: rates
    }

    assert {:error, :provider_success_usage_incomplete} =
             RLMRuntime.MeteredLM.generate(lm, [%{role: :user, content: "charged"}], [])

    usage = Agent.get(usage_agent, & &1)
    assert usage["requests"] == 1
    assert usage["input_tokens"] == 9
    assert usage["output_tokens"] == 0
    assert usage["cost_authority"] == "pricing_derived"
    assert_in_delta usage["usd"], 0.000009, 1.0e-12
  end

  test "metered LM rejects conflicting zero and positive provider cost aliases" do
    rates = UsageFixture.rates()

    {:ok, budget} =
      CampaignBudget.start_link(
        limits: %{
          "requests" => 2,
          "input_tokens" => 10_000,
          "output_tokens" => 100,
          "usd" => 1.0
        },
        pricing: rates,
        default_max_output_tokens: 10
      )

    {:ok, usage_agent} = Agent.start_link(fn -> UsageFixture.empty(rates) end)

    inner = fn _messages, _opts ->
      {:ok, %{usage: %{input_tokens: 9, output_tokens: 2, total_cost: 0.0, cost: 0.25}}}
    end

    lm = %RLMRuntime.MeteredLM{
      inner: inner,
      budget: budget,
      usage: usage_agent,
      max_tokens: 10,
      role: "root",
      pricing: rates
    }

    assert {:error, :provider_cost_unauditable} =
             RLMRuntime.MeteredLM.generate(lm, [%{role: :user, content: "conflict"}], [])

    usage = Agent.get(usage_agent, & &1)
    assert usage["requests"] == 1
    assert usage["input_tokens"] == 9
    assert usage["output_tokens"] == 2
    assert usage["cost_authority"] == "unavailable"
  end

  test "metered LM ignores structured ReqLLM cost metadata and derives pinned cost" do
    rates = UsageFixture.rates()

    {:ok, budget} =
      CampaignBudget.start_link(
        limits: %{
          "requests" => 2,
          "input_tokens" => 10_000,
          "output_tokens" => 100,
          "usd" => 1.0
        },
        pricing: rates,
        default_max_output_tokens: 10
      )

    {:ok, usage_agent} = Agent.start_link(fn -> UsageFixture.empty(rates) end)

    inner = fn _messages, _opts ->
      {:ok,
       %{
         usage: %{
           input_tokens: 9,
           output_tokens: 2,
           total_cost: 0.0,
           cost: %{total: 0.0}
         }
       }}
    end

    lm = %RLMRuntime.MeteredLM{
      inner: inner,
      budget: budget,
      usage: usage_agent,
      max_tokens: 10,
      role: "root",
      pricing: rates
    }

    assert {:ok, _result} =
             RLMRuntime.MeteredLM.generate(lm, [%{role: :user, content: "charged"}], [])

    usage = Agent.get(usage_agent, & &1)
    assert usage["cost_authority"] == "pricing_derived"
    assert_in_delta usage["usd"], 0.000011, 1.0e-12
    assert get_in(usage, ["cost_audit", Access.at(0), "provider_reported_usd"]) == nil
  end

  test "RLM controller adapter decodes ReqLLM metadata content after metering" do
    action = %{"reasoning" => "inspect", "code" => "submit(%{answer: \"yes\"})"}

    inner = fn _messages, _opts ->
      {:ok,
       %{
         __imp_lm_output__: action,
         __imp_lm_metadata__: %{
           req_llm: %{content: Jason.encode!(action), usage: %{input_tokens: 1}}
         }
       }}
    end

    lm = %RLMRuntime.ControllerLM{inner: inner}
    assert {:ok, encoded} = RLMRuntime.ControllerLM.generate(lm, [], [])
    assert Jason.decode!(encoded) == action
  end

  test "RLM controller adapter accepts a single JSON markdown fence" do
    action = %{"reasoning" => "inspect", "code" => "submit(%{answer: \"yes\"})"}
    encoded = "```json\n#{Jason.encode!(action)}\n```"
    lm = %RLMRuntime.ControllerLM{inner: fn _messages, _opts -> {:ok, encoded} end}

    assert {:ok, ^encoded} = RLMRuntime.ControllerLM.generate(lm, [], [])
  end

  test "RLM controller adapter accepts one exact constrained-Elixir fence" do
    encoded = "```elixir\ncontext = load(\"context\")\nprint(context)\n```"
    lm = %RLMRuntime.ControllerLM{inner: fn _messages, _opts -> {:ok, encoded} end}

    assert {:ok, ^encoded} = RLMRuntime.ControllerLM.generate(lm, [], [])
  end

  test "RLM action decoder rejects prose around fenced code" do
    assert {:error, :invalid_rlm_action_serialization} =
             Imp.Predict.RLM.Action.decode("try this:\n```elixir\nprint(1)\n```")
  end

  test "checkpoint payload tamper is rejected" do
    root = tmp_dir("checkpoint")
    path = Path.join(root, "checkpoint.json")
    {:ok, pid} = RLMCheckpoint.start_link(path: path, identity: %{"id" => "x"})
    GenServer.stop(pid)
    envelope = path |> File.read!() |> Jason.decode!()
    tampered = put_in(envelope, ["payload", "committed", "x"], %{"key" => "x"})
    File.write!(path, Jason.encode!(tampered))
    Process.flag(:trap_exit, true)

    assert {:error, {%ArgumentError{message: message}, _stack}} =
             RLMCheckpoint.start_link(path: path, identity: %{"id" => "x"})

    assert message =~ "checksum mismatch"
  after
    Process.flag(:trap_exit, false)
  end

  test "false T3 flags and partial family evidence fail the mechanical gate" do
    artifact = %{
      "evidence_tier" => "t3_paper_scale",
      "manifest" => %{
        "authorities" => %{
          "paper" => %{"arxiv" => "2512.24601v3"},
          "rlm" => %{"commit" => "72d6940142ddfb84ee6be573dc999a37e633e671"},
          "dspy" => %{"version" => "3.3.0b1"}
        },
        "models" => %{"root" => %{}, "submodel" => %{}, "compaction" => %{}},
        "deviations" => []
      },
      "datasets" => %{"s_niah" => %{"logical_instances" => 50, "evaluated_rows" => 50}},
      "execution" => %{"runtime_selection" => "both"},
      "rows" => [],
      "summary" => %{"paper_protocol_complete" => true}
    }

    gate = RLMProtocol.evaluate(artifact)
    refute gate["paper_protocol_complete"]
    refute Enum.find(gate["checks"], &(&1["id"] == "dataset_protocol"))["passing"]
  end

  test "a hand-selected matrix without coding-agent model blocks fails exact protocol" do
    protocol = %{
      "reference_runtime" => "alexzhang13_rlm",
      "reference_commit" => "72d6940142ddfb84ee6be573dc999a37e633e671",
      "model_method_matrix" => %{
        "gpt_5" =>
          ~w(base_model codeact_bm25 codeact_subcalls compaction_agent rlm_depth_0 rlm_depth_1 rlm_depth_2 rlm_depth_3)
      },
      "dataset_selection" => %{
        "browsecomp_plus" => "operator_sample_paper_ids_unpublished"
      },
      "compaction" => "iterative_threshold_agent",
      "max_llm_calls_scope" => "subcalls_only",
      "provider_call_accounting" => "root_and_subcalls",
      "cache" => false,
      "reasoning_profiles" => %{
        "gpt_5" => "medium",
        "qwen3_coder_480b_a35b" => "paper_qwen_sampling",
        "claude_opus_4_1" => "claude_code_v2.0.0_default"
      },
      "runtime_matrix" => ~w(imp standalone_rlm)
    }

    gate = RLMProtocol.evaluate(%{"manifest" => %{"paper_protocol" => protocol}})
    refute Enum.find(gate["checks"], &(&1["id"] == "exact_paper_manifest"))["passing"]
  end

  test "operator dataset reconstructions cannot satisfy paper-exact authority" do
    manifest = %{
      "paper_protocol" => %{
        "dataset_selection" => %{
          "s_niah" => "operator_generated_ruler",
          "browsecomp_plus" => "operator_sample_paper_ids_unpublished",
          "oolong_pairs" => "operator_gold_with_unpublished_paper_scorer"
        }
      },
      "datasets" => %{
        "browsecomp_plus" => %{"split" => "operator_hash_150_not_paper_selection"}
      }
    }

    datasets = %{
      "s_niah" => %{"selection_authority" => "operator_generated"},
      "browsecomp_plus" => %{
        "split" => "operator_hash_150_not_paper_selection",
        "selection_authority" => "operator_generated"
      },
      "oolong_pairs" => %{"scorer_authority" => "operator_defined"}
    }

    gate = RLMProtocol.evaluate(%{"manifest" => manifest, "datasets" => datasets})
    refute Enum.find(gate["checks"], &(&1["id"] == "dataset_authority"))["passing"]
    refute gate["paper_protocol_complete"]
  end

  test "paper authority labels cannot self-attest unpublished dataset identities" do
    manifest = %{
      "paper_protocol" => %{
        "dataset_selection" => %{
          "s_niah" => "published_paper_frozen_instances",
          "browsecomp_plus" => "published_paper_frozen_ids_and_document_lists",
          "oolong_pairs" => "published_paper_gold_and_scorer"
        }
      }
    }

    datasets = %{
      "s_niah" => %{"selection_authority" => "paper_published"},
      "browsecomp_plus" => %{"selection_authority" => "paper_published"},
      "oolong_pairs" => %{"scorer_authority" => "paper_published"}
    }

    gate = RLMProtocol.evaluate(%{"manifest" => manifest, "datasets" => datasets})
    refute Enum.find(gate["checks"], &(&1["id"] == "dataset_authority"))["passing"]
  end

  test "cost gate permits explicit free authority and rejects zero or inconsistent unaudited cost" do
    free_row = %{"status" => "ok", "usage" => UsageFixture.free()}
    free_gate = RLMProtocol.evaluate(%{"rows" => [free_row]})
    assert Enum.find(free_gate["checks"], &(&1["id"] == "cost_accounting"))["passing"]

    unaudited =
      free_row
      |> put_in(["usage", "cost_authority"], "pricing_derived")
      |> put_in(["usage", "cost_audit", Access.at(0), "authority"], "pricing_derived")
      |> put_in(["usage", "cost_audit", Access.at(0), "provider_reported_usd"], nil)

    unaudited_gate = RLMProtocol.evaluate(%{"rows" => [unaudited]})
    refute Enum.find(unaudited_gate["checks"], &(&1["id"] == "cost_accounting"))["passing"]

    inconsistent = put_in(free_row, ["usage", "cost_audit", Access.at(0), "usd"], 0.1)
    inconsistent_gate = RLMProtocol.evaluate(%{"rows" => [inconsistent]})
    refute Enum.find(inconsistent_gate["checks"], &(&1["id"] == "cost_accounting"))["passing"]

    malformed = put_in(free_row, ["usage", "cost_audit"], ["not-an-audit"])
    malformed_gate = RLMProtocol.evaluate(%{"rows" => [malformed]})
    refute Enum.find(malformed_gate["checks"], &(&1["id"] == "cost_accounting"))["passing"]
  end

  test "paired bootstrap aggregation is deterministic" do
    rows =
      for approach <- ~w(direct rlm),
          id <- ~w(a b c),
          do: %{
            "runtime" => "imp",
            "approach" => approach,
            "family" => "s_niah",
            "example_id" => id,
            "query_id" => id,
            "context_size" => nil,
            "metric" => "exact_match",
            "status" => "ok",
            "score" => if(approach == "rlm", do: 1.0, else: 0.0),
            "latency_ms" => 1.0,
            "usage" => %{"requests" => 1, "input_tokens" => 1, "output_tokens" => 1, "usd" => 0.1}
          }

    manifest = %{"execution" => %{"bootstrap_samples" => 100, "confidence" => 0.95, "seed" => 17}}
    assert RLMStatistics.aggregate(rows, manifest) == RLMStatistics.aggregate(rows, manifest)
  end

  test "OOLONG-Pairs uses canonical pair-set F1 rather than token overlap" do
    assert RLMCampaign.score("(b, a)\n(c, d)\n(a, b)", "(a, b)\n(c, x)", "set_f1") == 0.5
    assert RLMCampaign.score("no pairs", "no pairs", "set_f1") == 1.0
    assert RLMCampaign.score("No pairs exist.", "", "set_f1") == 1.0

    assert RLMCampaign.score("No pairs exist, because only one user qualifies.", "", "set_f1") ==
             0.0

    assert RLMCampaign.score(
             "Reasoning, with ordinary prose.\n\n(No pairs found)",
             "",
             "set_f1"
           ) == 0.0

    assert RLMCampaign.score("Reasoning, with ordinary prose.", "", "set_f1") == 0.0
    assert RLMCampaign.score("explanation\n(a, b)", "(a, b)", "set_f1") == 0.0
  end

  test "failed rows are excluded from paired bootstrap comparisons" do
    rows =
      Enum.map([{"direct", "ok", 1.0}, {"rlm", "error", 0.0}], fn
        {approach, status, score} ->
          %{
            "runtime" => "imp",
            "approach" => approach,
            "family" => "oolong_pairs",
            "example_id" => "q1@1024",
            "query_id" => "q1",
            "context_size" => 1024,
            "metric" => "set_f1",
            "status" => status,
            "score" => score,
            "latency_ms" => 1.0,
            "usage" => %{
              "requests" => 1,
              "input_tokens" => 1,
              "output_tokens" => 1,
              "usd" => 0.1
            }
          }
      end)

    manifest = %{"execution" => %{"bootstrap_samples" => 20, "confidence" => 0.95, "seed" => 17}}
    [comparison] = RLMStatistics.aggregate(rows, manifest)["comparisons"]

    assert comparison["paired_rows"] == 0
    assert comparison["bootstrap_clusters"] == 0
    assert comparison["mean_score_difference"] == nil
    assert comparison["confidence_interval"] == %{"low" => nil, "high" => nil}
  end

  test "OOLONG-Pairs expands the frozen query into all 11 sizes with size-specific gold" do
    fixture = fixture!()
    manifest = Jason.decode!(File.read!(fixture.manifest_path))
    spec = manifest["datasets"]["oolong_pairs"]

    loaded = RLMDataset.load!("oolong_pairs", spec, Path.dirname(fixture.manifest_path))

    assert loaded["logical_instances"] == 1
    assert loaded["evaluated_rows"] == 11

    assert Enum.map(loaded["rows"], & &1["context_size"]) ==
             [1024, 2048, 4096, 8192, 16384, 32768, 65536, 131_072, 262_144, 524_288, 1_048_576]

    assert Enum.map(loaded["rows"], & &1["gold"]) ==
             ["(1, 2)", "", "(3, 4)", "", "(5, 6)", "", "(7, 8)", "", "(9, 10)", "", "(11, 12)"]

    bounded =
      RLMDataset.load!(
        "oolong_pairs",
        Map.put(spec, "context_grid", [1024]),
        Path.dirname(fixture.manifest_path)
      )

    assert bounded["evaluated_rows"] == 1
    assert Enum.map(bounded["rows"], & &1["context_size"]) == [1024]

    for invalid <- [[], [2048, 1024], [1024, 1024], [1234]] do
      assert_raise ArgumentError, ~r/non-empty ordered paper-grid subset/, fn ->
        RLMDataset.load!(
          "oolong_pairs",
          Map.put(spec, "context_grid", invalid),
          Path.dirname(fixture.manifest_path)
        )
      end
    end
  end

  test "OOLONG-Pairs rejects malformed shared-context contracts" do
    fixture = fixture!()
    manifest = Jason.decode!(File.read!(fixture.manifest_path))
    spec = manifest["datasets"]["oolong_pairs"]
    path = fixture.dataset_paths["oolong_pairs"]
    rows = path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

    assert_rejected = fn mutated, message ->
      File.write!(path, Enum.map_join(mutated, "\n", &Jason.encode!/1) <> "\n")
      mutated_spec = Map.put(spec, "sha256", sha(path))

      assert_raise ArgumentError, message, fn ->
        RLMDataset.load!("oolong_pairs", mutated_spec, Path.dirname(fixture.manifest_path))
      end
    end

    assert_rejected.([hd(rows) | rows], ~r/exactly one __contexts__ row/)

    assert_rejected.(
      [Map.update!(hd(rows), "contexts", &Map.delete(&1, "1024")) | tl(rows)],
      ~r/exactly 11 contexts/
    )

    assert_rejected.(
      [Map.update!(hd(rows), "contexts", &Map.put(&1, "2097152", "extra")) | tl(rows)],
      ~r/exactly 11 contexts/
    )

    assert_rejected.(
      [hd(rows), Map.put(Enum.at(rows, 1), "contexts", %{}) | Enum.drop(rows, 2)],
      ~r/must not contain contexts/
    )
  end

  test "filtered OOLONG-Pairs planning is labeled T2 and makes no provider calls" do
    fixture = fixture!()

    plan =
      RLMCampaign.plan(fixture.manifest_path,
        families: ["oolong_pairs"],
        approaches: ["direct"],
        runtime: "imp",
        row_limit: 1
      )

    assert plan["requested_evidence_tier"] == "t2_live_sample"
    assert plan["evidence_tier"] == "t2_live_sample"
    assert plan["provider_calls"] == 0
    assert plan["families"] == %{"oolong_pairs" => 1}
    assert Enum.all?(plan["jobs"], &(&1["context_size"] == 1024))
  end

  test "bounded OOLONG-Pairs loading validates row identity rather than manifest position" do
    fixture = fixture!()
    manifest = Jason.decode!(File.read!(fixture.manifest_path))
    spec = manifest["datasets"]["oolong_pairs"]
    mismatched = Map.put(spec, "sample_ids", ["wrong-id"])

    assert_raise ArgumentError, ~r/expected id .* got/, fn ->
      RLMDataset.load!(
        "oolong_pairs",
        mismatched,
        Path.dirname(fixture.manifest_path),
        row_limit: 1
      )
    end
  end

  test "direct dataset loading rejects non-positive row limits" do
    fixture = fixture!()
    manifest = Jason.decode!(File.read!(fixture.manifest_path))
    spec = manifest["datasets"]["oolong_pairs"]
    root = Path.dirname(fixture.manifest_path)

    for row_limit <- [0, -1] do
      assert_raise ArgumentError, ~r/row limit must be a positive integer/, fn ->
        RLMDataset.load!("oolong_pairs", spec, root, row_limit: row_limit)
      end
    end
  end

  test "plan metadata stays bounded and never hydrates context or gold bodies" do
    fixture = fixture!()
    manifest = Jason.decode!(File.read!(fixture.manifest_path))
    spec = manifest["datasets"]["oolong_pairs"]

    metadata = RLMDataset.metadata!("oolong_pairs", spec, Path.dirname(fixture.manifest_path))

    assert metadata["logical_instances"] == 1
    assert metadata["evaluated_rows"] == 11

    assert Enum.all?(metadata["rows"], fn row ->
             Map.keys(row) == ~w(context_size family id query_id)
           end)
  end

  test "official scorer contracts do not fall back to generic exact match" do
    assert_in_delta RLMCampaign.score("12", "10", "oolong_official"), 0.5625, 1.0e-12
    assert RLMCampaign.score("['entity']", "['entity']", "oolong_official") == 1.0
    assert RLMCampaign.score("11-ish", "10", "oolong_official") == 0.0

    assert_raise ArgumentError, ~r/pinned official LLM judge and trec_eval/, fn ->
      RLMCampaign.score("answer", "answer", "official_llm_judge")
    end
  end

  test "OOLONG-Pairs bootstrap clusters context sizes by logical query" do
    rows =
      for approach <- ~w(base rlm), query <- ~w(q1 q2), size <- [1024, 2048] do
        %{
          "runtime" => "imp",
          "approach" => approach,
          "family" => "oolong_pairs",
          "example_id" => "#{query}@#{size}",
          "query_id" => query,
          "context_size" => size,
          "metric" => "set_f1",
          "status" => "ok",
          "score" => if(approach == "rlm", do: 1.0, else: 0.0),
          "latency_ms" => 1.0,
          "usage" => %{"requests" => 1, "input_tokens" => 1, "output_tokens" => 1, "usd" => 0.0}
        }
      end

    manifest = %{"execution" => %{"bootstrap_samples" => 20, "confidence" => 0.95, "seed" => 17}}
    [comparison] = RLMStatistics.aggregate(rows, manifest)["comparisons"]
    assert comparison["paired_rows"] == 4
    assert comparison["bootstrap_clusters"] == 2
    assert comparison["family"] == "oolong_pairs"
  end

  test "forged duplicate zero-usage rows fail exact key and row evidence checks" do
    datasets =
      Map.new(
        %{
          "s_niah" => {50, nil, nil},
          "browsecomp_plus" => {150, nil, 1000},
          "oolong" => {50, "trec_coarse", nil},
          "oolong_pairs" => {220, "trec_coarse", nil},
          "longbench_v2_codeqa" => {50, nil, nil}
        },
        fn {family, {count, split, docs}} ->
          keys =
            for index <- 1..count,
                do: %{
                  "example_id" => "#{family}-#{index}",
                  "query_id" => "q-#{index}",
                  "context_size" => nil
                }

          {family,
           %{
             "logical_instances" => if(family == "oolong_pairs", do: 20, else: count),
             "evaluated_rows" => count,
             "split" => split,
             "docs_per_instance" => docs,
             "context_grid" =>
               if(family == "oolong_pairs",
                 do: Enum.map(10..20, &round(:math.pow(2, &1))),
                 else: nil
               ),
             "sha256" => String.duplicate("a", 64),
             "sample_ids_sha256" => String.duplicate("b", 64),
             "evaluated_keys" => keys,
             "evidence_in_dataset" => family == "browsecomp_plus"
           }}
        end
      )

    forged =
      for index <- 1..520 do
        %{
          "key" => "forged-#{index}",
          "example_id" => "s_niah-1",
          "query_id" => "q-1",
          "context_size" => nil,
          "family" => "s_niah",
          "model_family" => "gpt_5",
          "approach" => "direct",
          "runtime" => "imp",
          "status" => "ok",
          "answer" => "x",
          "score" => 1.0,
          "latency_ms" => 1.0,
          "usage" => %{"requests" => 0, "input_tokens" => 0, "output_tokens" => 0, "usd" => 0.0},
          "metric" => "exact_match",
          "scorer_evidence" => %{},
          "trace_shape" => ["forged"],
          "trace" => [],
          "call_semantics" => %{"provider_calls" => 0},
          "provenance" => %{},
          "error" => nil
        }
      end

    gate =
      RLMProtocol.evaluate(%{
        "evidence_tier" => "t3_paper_scale",
        "datasets" => datasets,
        "rows" => forged,
        "official_scorers" => %{
          "browsecomp_plus" => %{
            "answer" => "pinned_official_llm_judge",
            "retrieval" => "trec_eval_evidence_and_gold_qrels",
            "judge_model" => "forged-judge",
            "prompt_sha256" => String.duplicate("c", 64)
          },
          "oolong" => %{"contract" => "numeric_0.75_abs_error_else_exact"},
          "oolong_pairs" => %{"contract" => "normalized_unordered_pair_set_f1"}
        }
      })

    refute Enum.find(gate["checks"], &(&1["id"] == "dataset_key_sets"))["passing"]
    refute Enum.find(gate["checks"], &(&1["id"] == "row_outcomes"))["passing"]
    refute Enum.find(gate["checks"], &(&1["id"] == "official_scorers"))["passing"]
    refute Enum.find(gate["checks"], &(&1["id"] == "dataset_authority"))["passing"]
    refute Enum.find(gate["checks"], &(&1["id"] == "cost_accounting"))["passing"]
  end

  defp run!(fixture, runtime, opts \\ []) do
    defaults =
      [
        out: fixture.out,
        checkpoint_dir: fixture.checkpoints,
        runtime: "imp",
        runtime_modules: %{"imp" => runtime}
      ]

    RLMCampaign.run(fixture.manifest_path, Keyword.merge(defaults, opts))
  end

  defp fixture!(opts \\ []) do
    root = tmp_dir("campaign")
    source = Path.join(root, "authority.py")
    File.write!(source, "# pinned\n")

    rows =
      Map.new(dataset_rows(), fn {family, row} ->
        split = if(family in ~w(oolong oolong_pairs), do: "trec_coarse", else: "test")

        {family,
         Map.merge(row, %{
           "source" => "test source",
           "revision" => "test revision",
           "split" => split
         })}
      end)

    dataset_paths =
      Map.new(rows, fn {family, row} ->
        path = Path.join(root, "#{family}.jsonl")

        records =
          if family == "oolong_pairs" do
            context_row =
              row
              |> Map.take(~w(source revision split contexts))
              |> Map.put("id", "__contexts__")

            query_rows =
              Enum.map(1..20, fn index ->
                row
                |> Map.delete("contexts")
                |> Map.put("id", "oolong_pairs-#{index}")
              end)

            [context_row | query_rows]
          else
            [row]
          end

        File.write!(path, Enum.map_join(records, "\n", &Jason.encode!/1) <> "\n")
        {family, path}
      end)

    manifest = manifest(root, source, dataset_paths, Keyword.get(opts, :request_limit, 100))
    manifest_path = Path.join(root, "manifest.json")
    File.write!(manifest_path, Jason.encode!(manifest, pretty: true))

    %{
      manifest_path: manifest_path,
      dataset_paths: dataset_paths,
      out: Path.join(root, "out"),
      checkpoints: Path.join(root, "checkpoints")
    }
  end

  defp manifest(_root, source, paths, request_limit) do
    datasets =
      Map.new(paths, fn {family, path} ->
        spec = %{
          "path" => path,
          "sha256" => sha(path),
          "source" => "test source",
          "revision" => "test revision",
          "split" => if(family in ~w(oolong oolong_pairs), do: "trec_coarse", else: "test"),
          "sample_count" => 1,
          "sample_seed" => 17,
          "sample_ids" => ["#{family}-1"],
          "context_grid" =>
            if(family == "oolong_pairs",
              do: [
                1024,
                2048,
                4096,
                8192,
                16384,
                32768,
                65536,
                131_072,
                262_144,
                524_288,
                1_048_576
              ],
              else: []
            ),
          "docs_per_instance" => if(family == "browsecomp_plus", do: 2, else: nil),
          "metric" => "exact_match"
        }

        {family, spec}
      end)

    pricing = %{"input_per_million" => 1.0, "output_per_million" => 1.0}

    approaches =
      Map.new(~w(direct simple_retrieval compaction rlm), fn approach ->
        settings =
          case approach do
            "direct" ->
              %{"reservation_pricing" => pricing}

            "simple_retrieval" ->
              %{
                "k" => 1,
                "retriever" => "deterministic_lexical",
                "reservation_pricing" => pricing
              }

            "compaction" ->
              %{"chunk_chars" => 100, "max_chunks" => 2, "reservation_pricing" => pricing}

            "rlm" ->
              %{
                "max_iterations" => 2,
                "max_llm_calls" => 2,
                "recursion_depth" => 1,
                "reservation_pricing" => pricing
              }
          end

        {approach,
         %{
           "enabled" => true,
           "runtimes" => ["imp"],
           "budget" => %{
             "requests" => request_limit,
             "input_tokens" => 100_000,
             "output_tokens" => 100_000,
             "usd" => 100.0
           },
           "settings" => settings
         }}
      end)

    model = %{
      "logical" => "test",
      "imp" => %{
        "provider" => "test",
        "id" => "test",
        "base_url" => "https://example.test/v1",
        "api_key_env" => "IMP_RLM_TEST_API_KEY",
        "context_window" => 2_000_000
      },
      "dspy" => "test/test",
      "temperature" => 0.0,
      "reasoning" => "none",
      "max_output_tokens" => 10
    }

    %{
      "schema_version" => 1,
      "campaign_id" => "test-campaign",
      "evidence_tier" => "t2_live_sample",
      "authorities" => %{
        "paper" => %{"arxiv" => "2512.24601v3"},
        "rlm" => %{
          "repository" => "https://example.test/rlm",
          "commit" => "72d6940142ddfb84ee6be573dc999a37e633e671"
        },
        "dspy" => %{
          "repository" => "https://example.test/dspy",
          "version" => "3.3.0b1",
          "commit" => "b2829b7ae3b6e276ac6a8bef66a7ec519dbc923f"
        },
        "sources" => %{"authority" => %{"path" => source, "sha256" => sha(source)}}
      },
      "models" => %{"root" => model, "submodel" => model, "compaction" => model},
      "approaches" => approaches,
      "execution" => %{
        "seed" => 17,
        "concurrency" => 2,
        "row_timeout_ms" => 5000,
        "cancellation_grace_ms" => 100,
        "bootstrap_samples" => 100,
        "confidence" => 0.95
      },
      "datasets" => datasets,
      "deviations" => []
    }
  end

  defp dataset_rows do
    %{
      "s_niah" => %{
        "id" => "s_niah-1",
        "context" => "needle yes",
        "question" => "answer?",
        "answer" => "yes"
      },
      "browsecomp_plus" => %{
        "id" => "browsecomp_plus-1",
        "documents" => [%{"id" => "a", "text" => "yes"}, %{"id" => "b", "text" => "no"}],
        "evidence_document_ids" => ["a"],
        "question" => "answer?",
        "answer" => "yes"
      },
      "oolong" => %{
        "id" => "oolong-1",
        "context" => ["yes"],
        "question" => "answer?",
        "answer" => "yes"
      },
      "oolong_pairs" => %{
        "id" => "oolong_pairs-1",
        "contexts" =>
          Map.new(
            [1024, 2048, 4096, 8192, 16384, 32768, 65536, 131_072, 262_144, 524_288, 1_048_576],
            &{Integer.to_string(&1), "context #{&1}"}
          ),
        "question" => "answer?",
        "gold_by_context_size" => %{
          "1024" => ["(1, 2)"],
          "2048" => [],
          "4096" => ["(3, 4)"],
          "8192" => [],
          "16384" => ["(5, 6)"],
          "32768" => [],
          "65536" => ["(7, 8)"],
          "131072" => [],
          "262144" => ["(9, 10)"],
          "524288" => [],
          "1048576" => ["(11, 12)"]
        }
      },
      "longbench_v2_codeqa" => %{
        "id" => "longbench_v2_codeqa-1",
        "context" => "code",
        "question" => "answer?",
        "choices" => ["yes", "no"],
        "answer" => "yes"
      }
    }
  end

  defp sha(path),
    do: path |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

  defp canonical_manifest_with_fixture_oolong!(fixture) do
    canonical =
      "benchmarks/config/rlm-paper-protocol-v3.json"
      |> File.read!()
      |> Jason.decode!()

    fixture_manifest = fixture.manifest_path |> File.read!() |> Jason.decode!()
    fixture_spec = fixture_manifest["datasets"]["oolong"]
    [fixture_row] = fixture_spec["path"] |> File.stream!() |> Enum.map(&Jason.decode!/1)

    rows =
      Enum.map(1..50, fn index ->
        Map.put(fixture_row, "id", "oolong-#{index}")
      end)

    dataset_path = Path.join(Path.dirname(fixture.manifest_path), "paper-oolong.jsonl")
    File.write!(dataset_path, Enum.map_join(rows, "\n", &Jason.encode!/1) <> "\n")

    paper_spec =
      fixture_spec
      |> Map.put("path", dataset_path)
      |> Map.put("sha256", sha(dataset_path))
      |> Map.put("sample_count", 50)
      |> Map.put("sample_ids", Enum.map(rows, & &1["id"]))

    manifest = put_in(canonical, ["datasets", "oolong"], paper_spec)
    path = Path.join(Path.dirname(fixture.manifest_path), "paper-manifest.json")
    File.write!(path, Jason.encode!(manifest, pretty: true))
    path
  end

  defp tmp_dir(label) do
    path =
      Path.join(
        System.tmp_dir!(),
        "imp-rlm-#{label}-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end
end
