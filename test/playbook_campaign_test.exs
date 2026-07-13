defmodule DSEx.Optimizer.Playbook.CampaignTest do
  use ExUnit.Case, async: true

  alias DSEx.Optimizer.Playbook.Campaign

  test "accepts all 250 pinned references with exact rational precedence" do
    rows =
      "benchmarks/data/playbook/math-equation-balancer.jsonl"
      |> File.stream!()
      |> Enum.map(&Jason.decode!/1)

    assert length(rows) == 250

    assert Enum.all?(rows, fn row ->
             Campaign.validate_equation(row["input"], row["expected"], row["target_value"]) == :ok
           end)
  end

  test "accepts alternate valid assignments and rejects malformed or reordered answers" do
    assert :ok = Campaign.validate_equation("2 ? 3 ? 4 = 14", "2 + 3 * 4 = 14", 14)
    assert :ok = Campaign.validate_equation("8 ? 4 ? 2 = 1", "8 / 4 / 2 = 1", 1)
    assert {:error, _} = Campaign.validate_equation("2 ? 3 ? 4 = 14", "4 * 3 + 2 = 14", 14)
    assert {:error, _} = Campaign.validate_equation("2 ? 3 ? 4 = 14", "2 + (3 * 4) = 14", 14)
    assert {:error, _} = Campaign.validate_equation("2 ? 3 = 5", "2 / 0 = 5", 5)
  end
end
