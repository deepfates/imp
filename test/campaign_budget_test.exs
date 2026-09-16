defmodule Imp.BenchmarkTruth.CampaignBudgetTest do
  use ExUnit.Case, async: false

  alias Imp.BenchmarkTruth.{BudgetedLM, CampaignBudget}

  defmodule CountingLM do
    @behaviour Imp.LM
    defstruct [:owner]

    @impl true
    def generate(_messages, _opts), do: {:error, :counting_lm_instance_required}

    def generate(%__MODULE__{owner: owner}, _messages, _opts) do
      send(owner, :provider_called)
      {:ok, %{answer: "ok"}}
    end
  end

  defmodule TelemetryLM do
    @behaviour Imp.LM
    defstruct []

    @impl true
    def generate(_messages, _opts), do: {:error, :telemetry_lm_instance_required}

    def generate(%__MODULE__{}, _messages, _opts) do
      :telemetry.execute(
        [:req_llm, :token_usage],
        %{tokens: %{input_tokens: 7, output_tokens: 3}, total_cost: 0.02},
        %{}
      )

      {:ok, %{answer: "ok"}}
    end
  end

  defmodule TimeoutLM do
    @behaviour Imp.LM
    defstruct []

    @impl true
    def generate(_messages, _opts), do: {:error, :timeout}
  end

  test "public facade constructs the packaged budget and LM decorator" do
    assert {:ok, budget} =
             Imp.start_optimizer_budget(
               limits: %{requests: 1, input_tokens: 10_000, output_tokens: 20, usd: 1.0},
               pricing: %{"input_per_million" => 1.0, "output_per_million" => 2.0},
               default_max_output_tokens: 20
             )

    lm = Imp.budgeted_lm(%CountingLM{owner: self()}, budget, max_output_tokens: 20)
    assert %Imp.LM.Budgeted{} = lm
    assert {:ok, %{answer: "ok"}} = Imp.LM.generate(lm, [%{content: "first"}], [])
    assert_received :provider_called

    assert {:error, {:campaign_budget_exhausted, :requests}} =
             Imp.LM.generate(lm, [%{content: "second"}], [])

    refute_received :provider_called
    assert Imp.Optimizer.Budget.snapshot(budget)["requests"] == 1
  end

  test "concurrent public wrappers record only their own provider telemetry" do
    assert {:ok, budget} =
             Imp.start_optimizer_budget(
               limits: %{requests: 2, input_tokens: 10_000, output_tokens: 40, usd: 1.0},
               pricing: %{"input_per_million" => 1.0, "output_per_million" => 2.0},
               default_max_output_tokens: 20
             )

    lm = Imp.budgeted_lm(%TelemetryLM{}, budget, max_output_tokens: 20)

    results =
      ["one", "two"]
      |> Enum.map(fn content ->
        Task.async(fn -> Imp.LM.generate(lm, [%{content: content}], []) end)
      end)
      |> Enum.map(&Task.await/1)

    assert results == [{:ok, %{answer: "ok"}}, {:ok, %{answer: "ok"}}]

    snapshot = Imp.Optimizer.Budget.snapshot(budget)
    assert snapshot["requests"] == 2
    assert snapshot["usage"] == %{"input_tokens" => 14, "output_tokens" => 6, "usd" => 0.04}
    assert snapshot["active_reservations"] == 0
  end

  test "a timeout is returned and its completed call reservation is released" do
    assert {:ok, budget} =
             Imp.start_optimizer_budget(
               limits: %{requests: 1, input_tokens: 10_000, output_tokens: 20, usd: 1.0},
               pricing: %{"input_per_million" => 1.0, "output_per_million" => 2.0},
               default_max_output_tokens: 20
             )

    lm = Imp.budgeted_lm(%TimeoutLM{}, budget, max_output_tokens: 20)
    assert {:error, :timeout} = Imp.LM.generate(lm, [%{content: "first"}], [])

    snapshot = Imp.Optimizer.Budget.snapshot(budget)
    assert snapshot["requests"] == 1
    assert snapshot["active_reservations"] == 0
  end

  test "reserves strict request and conservative token and USD ceilings before calls" do
    {:ok, budget} =
      CampaignBudget.start_link(
        limits: %{requests: 1, input_tokens: 10_000, output_tokens: 20, usd: 1.0},
        pricing: %{"input_per_million" => 1.0, "output_per_million" => 2.0},
        default_max_output_tokens: 20
      )

    lm = %BudgetedLM{inner: %CountingLM{owner: self()}, budget: budget}

    assert {:ok, %{answer: "ok"}} = Imp.LM.generate(lm, [%{content: "first"}], max_tokens: 20)
    assert_received :provider_called

    assert {:error, {:campaign_budget_exhausted, :requests}} =
             Imp.LM.generate(lm, [%{content: "second"}], max_tokens: 20)

    refute_received :provider_called
    assert CampaignBudget.snapshot(budget)["exhausted"] == "requests"
  end

  test "active reservations prevent concurrent calls from overcommitting output tokens" do
    {:ok, budget} =
      CampaignBudget.start_link(
        limits: %{requests: 2, input_tokens: 10_000, output_tokens: 30, usd: 1.0},
        pricing: %{"input_per_million" => 1.0, "output_per_million" => 1.0},
        default_max_output_tokens: 20
      )

    assert {:ok, reservation} =
             CampaignBudget.reserve(budget, [%{content: "one"}], max_tokens: 20)

    assert {:error, :output_tokens} =
             CampaignBudget.reserve(budget, [%{content: "two"}], max_tokens: 20)

    assert :ok = CampaignBudget.release(budget, reservation)
  end

  test "observed provider usage is reconciled into the checkpointable snapshot" do
    {:ok, budget} =
      CampaignBudget.start_link(
        limits: %{requests: 3, input_tokens: 100_000, output_tokens: 100, usd: 2.0},
        pricing: %{"input_per_million" => 1.0, "output_per_million" => 1.0},
        default_max_output_tokens: 10
      )

    :ok = CampaignBudget.record_usage(budget, %{input_tokens: 7, output_tokens: 3, usd: 0.25})

    assert CampaignBudget.snapshot(budget)["usage"] == %{
             "input_tokens" => 7,
             "output_tokens" => 3,
             "usd" => 0.25
           }
  end

  test "restores observed usage and request counts from current checkpoint state" do
    {:ok, budget} =
      CampaignBudget.start_link(
        limits: %{requests: 3, input_tokens: 100_000, output_tokens: 100, usd: 2.0},
        pricing: %{"input_per_million" => 1.0, "output_per_million" => 1.0},
        default_max_output_tokens: 10,
        initial: %{
          "requests" => 2,
          "usage" => %{"input_tokens" => 7, "output_tokens" => 3, "usd" => 0.25},
          "reservations" => []
        }
      )

    snapshot = CampaignBudget.snapshot(budget)
    assert snapshot["requests"] == 2
    assert snapshot["usage"]["input_tokens"] == 7
    assert snapshot["active_reservations"] == 0
  end

  test "rejects pre-canonical checkpoint state without reservation identities" do
    previous = Process.flag(:trap_exit, true)

    try do
      assert {:error, {%ArgumentError{message: message}, _stacktrace}} =
               CampaignBudget.start_link(
                 limits: %{requests: 3, input_tokens: 100_000, output_tokens: 100, usd: 2.0},
                 pricing: %{"input_per_million" => 1.0, "output_per_million" => 1.0},
                 default_max_output_tokens: 10,
                 initial: %{
                   "requests" => 2,
                   "usage" => %{"input_tokens" => 7, "output_tokens" => 3, "usd" => 0.25},
                   "active_reservations" => 1,
                   "reserved" => %{
                     "input_tokens" => 1,
                     "output_tokens" => 1,
                     "usd" => 0.01
                   }
                 }
               )

      assert message =~ "initial campaign reservations must be a list"
    after
      Process.flag(:trap_exit, previous)
    end
  end

  test "marks an unexpected provider overrun as exhausted" do
    {:ok, budget} =
      CampaignBudget.start_link(
        limits: %{requests: 3, input_tokens: 10, output_tokens: 10, usd: 1.0},
        pricing: %{"input_per_million" => 1.0, "output_per_million" => 1.0},
        default_max_output_tokens: 1
      )

    :ok = CampaignBudget.record_usage(budget, %{input_tokens: 11, output_tokens: 1, usd: 0.1})
    assert CampaignBudget.snapshot(budget)["exhausted"] == "input_tokens"
  end

  test "rejects credential-bearing pricing URLs before any checkpoint callback" do
    previous = Process.flag(:trap_exit, true)
    owner = self()

    try do
      assert {:error, {%ArgumentError{message: message}, _stacktrace}} =
               CampaignBudget.start_link(
                 limits: %{requests: 3, input_tokens: 10, output_tokens: 10, usd: 1.0},
                 pricing: %{
                   "input_per_million" => 1.0,
                   "output_per_million" => 1.0,
                   "source_url" => "https://user:password@pricing.example/rates?api_key=CANARY"
                 },
                 default_max_output_tokens: 1,
                 on_change: fn _snapshot -> send(owner, :checkpoint_written) end
               )

      assert message =~ "ordinary credential-free HTTP(S) documentation URL"
      refute_receive :checkpoint_written
    after
      Process.flag(:trap_exit, previous)
    end
  end

  test "rejects credential markers in recursively decoded URL paths, queries, and fragments" do
    unsafe_urls = [
      "https://pricing.example/api_key/CANARY_OA",
      "https://pricing.example/sk-proj-abcdefghijklmnopqrstuvwxyz1234567890/rates",
      "https://pricing.example/rates?api%255fkey=CANARY_OA",
      "https://pricing.example/rates?api_key%3DCANARY_OA",
      "https://pricing.example/rates#token%253Dsecret"
    ]

    for url <- unsafe_urls do
      assert_raise ArgumentError, ~r/ordinary credential-free/, fn ->
        CampaignBudget.validate_pricing_source_url!(url)
      end
    end

    assert CampaignBudget.validate_pricing_source_url!(
             "https://developers.openai.com/api/docs/pricing"
           ) == "https://developers.openai.com/api/docs/pricing"
  end

  test "reconciles an unresolved reservation once when its checkpoint is resumed" do
    {:ok, first} =
      CampaignBudget.start_link(
        limits: %{requests: 3, input_tokens: 100_000, output_tokens: 100, usd: 2.0},
        pricing: %{"input_per_million" => 1.0, "output_per_million" => 1.0},
        default_max_output_tokens: 10
      )

    assert {:ok, reservation} =
             CampaignBudget.reserve(first, [%{content: "unresolved"}], max_tokens: 10)

    checkpoint = CampaignBudget.snapshot(first)
    assert checkpoint["active_reservations"] == 1
    assert Enum.all?(checkpoint["reservations"], &(&1["bounds"] == checkpoint["reserved"]))
    :ok = GenServer.stop(first)

    {:ok, resumed} =
      CampaignBudget.start_link(
        limits: %{requests: 3, input_tokens: 100_000, output_tokens: 100, usd: 2.0},
        pricing: %{"input_per_million" => 1.0, "output_per_million" => 1.0},
        default_max_output_tokens: 10,
        initial: checkpoint
      )

    resumed_snapshot = CampaignBudget.snapshot(resumed)
    assert resumed_snapshot["active_reservations"] == 0
    assert resumed_snapshot["requests"] == 1
    assert resumed_snapshot["usage"]["input_tokens"] == checkpoint["reserved"]["input_tokens"]

    :ok = GenServer.stop(resumed)

    {:ok, second_resume} =
      CampaignBudget.start_link(
        limits: %{requests: 3, input_tokens: 100_000, output_tokens: 100, usd: 2.0},
        pricing: %{"input_per_million" => 1.0, "output_per_million" => 1.0},
        default_max_output_tokens: 10,
        initial: resumed_snapshot
      )

    assert CampaignBudget.snapshot(second_resume)["usage"] == resumed_snapshot["usage"]
    assert :ok = CampaignBudget.release(second_resume, reservation)
  end

  test "conservatively reconciles aggregate usage without false reservation attribution" do
    {:ok, first} =
      CampaignBudget.start_link(
        limits: %{requests: 3, input_tokens: 100_000, output_tokens: 100, usd: 2.0},
        pricing: %{"input_per_million" => 1.0, "output_per_million" => 1.0},
        default_max_output_tokens: 10
      )

    assert {:ok, _reservation} =
             CampaignBudget.reserve(first, [%{content: "observed"}], max_tokens: 10)

    :ok = CampaignBudget.record_usage(first, %{input_tokens: 7, output_tokens: 3, usd: 0.25})
    checkpoint = CampaignBudget.snapshot(first)
    refute Enum.any?(checkpoint["reservations"], &Map.has_key?(&1, "usage_recorded"))
    :ok = GenServer.stop(first)

    {:ok, resumed} =
      CampaignBudget.start_link(
        limits: %{requests: 3, input_tokens: 100_000, output_tokens: 100, usd: 2.0},
        pricing: %{"input_per_million" => 1.0, "output_per_million" => 1.0},
        default_max_output_tokens: 10,
        initial: checkpoint
      )

    resumed_snapshot = CampaignBudget.snapshot(resumed)

    assert resumed_snapshot["usage"]["input_tokens"] ==
             checkpoint["usage"]["input_tokens"] + checkpoint["reserved"]["input_tokens"]

    assert resumed_snapshot["usage"]["output_tokens"] ==
             checkpoint["usage"]["output_tokens"] + checkpoint["reserved"]["output_tokens"]

    assert_in_delta resumed_snapshot["usage"]["usd"],
                    checkpoint["usage"]["usd"] + checkpoint["reserved"]["usd"],
                    1.0e-12
  end

  test "two concurrent reservations reconcile all bounds without guessing which call used telemetry" do
    {:ok, first} =
      CampaignBudget.start_link(
        limits: %{requests: 4, input_tokens: 100_000, output_tokens: 100, usd: 2.0},
        pricing: %{"input_per_million" => 1.0, "output_per_million" => 1.0},
        default_max_output_tokens: 10
      )

    reservations =
      ["call-a", "call-b"]
      |> Enum.map(fn label ->
        Task.async(fn -> CampaignBudget.reserve(first, [%{content: label}], max_tokens: 10) end)
      end)
      |> Enum.map(&Task.await(&1, 5_000))

    assert Enum.all?(reservations, &match?({:ok, _}, &1))
    :ok = CampaignBudget.record_usage(first, %{input_tokens: 4, output_tokens: 2, usd: 0.1})
    checkpoint = CampaignBudget.snapshot(first)
    assert length(checkpoint["reservations"]) == 2
    refute Enum.any?(checkpoint["reservations"], &Map.has_key?(&1, "usage_recorded"))
    :ok = GenServer.stop(first)

    {:ok, resumed} =
      CampaignBudget.start_link(
        limits: %{requests: 4, input_tokens: 100_000, output_tokens: 100, usd: 2.0},
        pricing: %{"input_per_million" => 1.0, "output_per_million" => 1.0},
        default_max_output_tokens: 10,
        initial: checkpoint
      )

    resumed_snapshot = CampaignBudget.snapshot(resumed)
    assert resumed_snapshot["active_reservations"] == 0

    assert resumed_snapshot["usage"]["input_tokens"] ==
             checkpoint["usage"]["input_tokens"] + checkpoint["reserved"]["input_tokens"]

    assert resumed_snapshot["usage"]["output_tokens"] ==
             checkpoint["usage"]["output_tokens"] + checkpoint["reserved"]["output_tokens"]

    assert_in_delta resumed_snapshot["usage"]["usd"],
                    checkpoint["usage"]["usd"] + checkpoint["reserved"]["usd"],
                    1.0e-12
  end

  test "ReqLLM transport guard defeats the dependency retry reset and counts one attempt" do
    parent = self()

    base_url =
      Imp.Test.LocalHTTP.start(fn _request ->
        send(parent, :http_attempt)
        {429, [{"retry-after", "0"}], %{error: %{message: "rate limited"}}}
      end)

    model = %{
      provider: :openrouter,
      id: "openai/gpt-oss-20b:free",
      base_url: base_url
    }

    {:ok, prepared} =
      ReqLLM.Providers.OpenRouter.prepare_request(
        :chat,
        model,
        "one local request",
        api_key: "local-test-key",
        max_retries: 0
      )

    # req_llm 1.17.1 overwrote the caller's zero with its default of 3;
    # 1.18.0 honours it. Pinned here so a dependency regression is loud,
    # while the guard below keeps the attempt count correct either way.
    assert prepared.options.max_retries == 0

    {:ok, budget} =
      CampaignBudget.start_link(
        limits: %{requests: 1, input_tokens: 10_000, output_tokens: 32, usd: 0.0},
        pricing: %{"input_per_million" => 0.0, "output_per_million" => 0.0},
        default_max_output_tokens: 32
      )

    lm =
      %BudgetedLM{
        inner: Imp.req_llm(model, api_key: "local-test-key"),
        budget: budget,
        max_output_tokens: 32
      }

    assert {:error, _reason} = Imp.LM.generate(lm, [%{role: :user, content: "hello"}], [])
    assert_received :http_attempt
    refute_received :http_attempt

    snapshot = CampaignBudget.snapshot(budget)
    assert snapshot["requests"] == 1
    assert snapshot["transport_attempts"] == 1
    assert snapshot["single_attempt_transport_enforced"]
  end
end
