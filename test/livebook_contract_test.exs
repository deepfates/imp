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
    assert length(livebooks) == 5

    assert livebooks == [
             "livebooks/01_real_lm_front_door.livemd",
             "livebooks/02_programming_not_prompting.livemd",
             "livebooks/03_evaluate_and_optimize.livemd",
             "livebooks/04_tools_agents_mcp_rlm.livemd",
             "livebooks/05_operate_and_live_checks.livemd"
           ]

    for path <- livebooks do
      body = File.read!(path)

      assert body =~ "Mix.install([{:dsex, path: repo}])"

      for term <- @stale_terms do
        refute String.contains?(String.downcase(body), String.downcase(term))
      end
    end
  end

  test "operations Livebook names the full local gate set" do
    body = File.read!("livebooks/05_operate_and_live_checks.livemd")

    assert body =~ "Operate And Live Checks"
    assert body =~ "mix production.check"
    assert body =~ "mix livebook.execute.check"
    refute body =~ "mix " <> "v2" <> ".check"
    assert body =~ "mix integration.check"
    assert body =~ "LIVE_PROVIDER=1 mix live.check"
  end

  test "real LM Livebook teaches the front-door provider journey" do
    body = File.read!("livebooks/01_real_lm_front_door.livemd")

    assert body =~ "Real LM Front Door"
    assert body =~ "Program, Don't Prompt"
    assert body =~ "DSEx.req_llm"
    assert body =~ "DSEx.predict"
    assert body =~ "DSEx.chain_of_thought"
    assert body =~ "DSEx.react"
    assert body =~ "DSEx.optimize"
    assert body =~ "DSEx.dump"
    assert body =~ "OPENAI_API_KEY"
    assert body =~ "OPENAI_MODEL"
  end

  test "Livebooks teach the ReqLLM provider path only" do
    body = Path.wildcard("livebooks/*.livemd") |> Enum.map_join("\n", &File.read!/1)

    assert body =~ "DSEx.req_llm"
    assert body =~ "api_key: System.fetch_env!(\"OPENAI_API_KEY\")"
    refute body =~ "DSEx.openai"
    refute body =~ "DSEx.litellm"
    refute body =~ "DSEx.local_lm"
    refute body =~ "DSEx.databricks("
  end

  test "Livebooks do not retain the pre-cutover appended walkthrough names" do
    body = Path.wildcard("livebooks/*.livemd") |> Enum.map_join("\n", &File.read!/1)

    refute body =~ "DSEx 05: Real LM Wow Path"
    refute body =~ "05_real_lm_wow_path"
    refute body =~ "04_local_gates_and_live_provider_smoke"
    refute body =~ "03_agents_tools_mcp_rlm"
  end
end
