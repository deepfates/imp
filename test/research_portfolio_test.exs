defmodule DSEx.ResearchPortfolioTest do
  use ExUnit.Case, async: true

  alias DSEx.ResearchPortfolio

  @portfolio "benchmarks/research_portfolio.json"
  @claims "benchmarks/claims.json"

  test "portfolio covers every active research claim and references resolve" do
    assert %{"lanes" => lanes} = ResearchPortfolio.load!(@portfolio, claims_path: @claims)
    assert length(lanes) >= 5
  end

  test "generated documentation agrees with the portfolio" do
    Mix.Task.reenable("dsex.research_portfolio")
    Mix.Tasks.Dsex.ResearchPortfolio.run(["--check"])
  end

  test "rejects missing claim ownership and weak decision contracts" do
    portfolio = read_json!(@portfolio)
    claims = read_json!(@claims)
    [first | rest] = portfolio["lanes"]

    missing =
      put_in(portfolio, ["lanes"], [Map.update!(first, "claim_ids", &Enum.drop(&1, 1)) | rest])

    assert_raise ArgumentError, ~r/research claim coverage differs/, fn ->
      ResearchPortfolio.validate!(missing, claims, File.cwd!())
    end

    weak = put_in(portfolio, ["lanes", Access.at(0), "decision_rules", "fail"], "")

    assert_raise ArgumentError, ~r/fail rule must be non-empty/, fn ->
      ResearchPortfolio.validate!(weak, claims, File.cwd!())
    end

    unknown_task =
      put_in(portfolio, ["lanes", Access.at(0), "preflight", "command"], "mix imp.not_real")

    assert_raise ArgumentError, ~r/preflight task does not resolve/, fn ->
      ResearchPortfolio.validate!(unknown_task, claims, File.cwd!())
    end
  end

  defp read_json!(path), do: path |> File.read!() |> Jason.decode!()
end
