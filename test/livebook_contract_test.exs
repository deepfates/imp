defmodule LivebookContractTest do
  use ExUnit.Case, async: true

  @stale_terms [
    "not production" <> " ready",
    "in" <> "complete",
    "place" <> "holder",
    "TO" <> "DO",
    "FIX" <> "ME",
    "not_" <> "implemented",
    "Local" <> "Trainer"
  ]

  test "Livebooks use local repo setup and avoid stale release language" do
    livebooks = Path.wildcard("livebooks/*.livemd")
    assert length(livebooks) == 4

    for path <- livebooks do
      body = File.read!(path)

      assert body =~ "Mix.install([{:dsex, path: repo}])"

      for term <- @stale_terms do
        refute String.contains?(String.downcase(body), String.downcase(term))
      end
    end
  end

  test "production Livebook names the full local gate set" do
    body = File.read!("livebooks/04_production_and_live_provider.livemd")

    assert body =~ "mix production.check"
    refute body =~ "mix " <> "v2" <> ".check"
    assert body =~ "mix integration.check"
    assert body =~ "LIVE_PROVIDER=1 mix live.check"
  end
end
