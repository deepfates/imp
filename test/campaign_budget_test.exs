defmodule DSEx.BenchmarkTruth.CampaignBudgetTest do
  use ExUnit.Case, async: true

  alias DSEx.BenchmarkTruth.{BudgetedLM, CampaignBudget}

  defmodule CountingLM do
    @behaviour DSEx.LM
    defstruct [:owner]

    @impl true
    def generate(_messages, _opts), do: {:error, :counting_lm_instance_required}

    def generate(%__MODULE__{owner: owner}, _messages, _opts) do
      send(owner, :provider_called)
      {:ok, %{answer: "ok"}}
    end
  end

  test "reserves strict request and conservative token and USD ceilings before calls" do
    {:ok, budget} =
      CampaignBudget.start_link(
        limits: %{requests: 1, input_tokens: 10_000, output_tokens: 20, usd: 1.0},
        pricing: %{"input_per_million" => 1.0, "output_per_million" => 2.0},
        default_max_output_tokens: 20
      )

    lm = %BudgetedLM{inner: %CountingLM{owner: self()}, budget: budget}

    assert {:ok, %{answer: "ok"}} = DSEx.LM.generate(lm, [%{content: "first"}], max_tokens: 20)
    assert_received :provider_called

    assert {:error, {:campaign_budget_exhausted, :requests}} =
             DSEx.LM.generate(lm, [%{content: "second"}], max_tokens: 20)

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

  test "restores observed usage and request counts without restoring active reservations" do
    {:ok, budget} =
      CampaignBudget.start_link(
        limits: %{requests: 3, input_tokens: 100_000, output_tokens: 100, usd: 2.0},
        pricing: %{"input_per_million" => 1.0, "output_per_million" => 1.0},
        default_max_output_tokens: 10,
        initial: %{
          "requests" => 2,
          "usage" => %{"input_tokens" => 7, "output_tokens" => 3, "usd" => 0.25},
          "active_reservations" => 9
        }
      )

    snapshot = CampaignBudget.snapshot(budget)
    assert snapshot["requests"] == 2
    assert snapshot["usage"]["input_tokens"] == 7
    assert snapshot["active_reservations"] == 0
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
end
