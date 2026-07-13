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
        limits: %{requests: 3, input_tokens: 100, output_tokens: 100, usd: 2.0},
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
        limits: %{requests: 3, input_tokens: 100, output_tokens: 100, usd: 2.0},
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
end
