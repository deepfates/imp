defmodule LivebookContractTest do
  use ExUnit.Case, async: false

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

      assert body =~ "File.regular?(Path.join(path, \"lib/imp.ex\"))"
      assert body =~ "[explicit_repo, Path.expand(\"..\", __DIR__), File.cwd!()]"
      assert body =~ "Mix.install([{:imp, path: repo}], install_opts)"
      assert body =~ "if File.regular?(Path.join(repo, \"mix.lock\"))"
      assert body =~ "IMP_PATH does not point to an Imp source checkout or unpacked package"

      for term <- @stale_terms do
        refute String.contains?(String.downcase(body), String.downcase(term))
      end
    end
  end

  @tag timeout: 180_000
  test "Livebook setup ignores an unrelated current Mix project" do
    root = File.cwd!()
    notebook = Path.join(root, "livebooks/02_programming_not_prompting.livemd")

    foreign =
      Path.join(
        System.tmp_dir!(),
        "imp-livebook-foreign-cwd-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(foreign)
    File.write!(Path.join(foreign, "mix.exs"), "# deliberately not an Imp project\n")
    on_exit(fn -> File.rm_rf(foreign) end)

    script = ~S'''
    notebook = System.fetch_env!("IMP_LIVEBOOK_CONTRACT_NOTEBOOK")
    body = File.read!(notebook)
    [_, setup | _] = Regex.run(~r/```elixir\n(.*?)\n```/s, body)
    {_value, binding} = Code.eval_string(setup, [], file: notebook)
    IO.puts("resolved_imp_repo=" <> Keyword.fetch!(binding, :repo))
    '''

    {output, status} =
      System.cmd("env", ["-u", "IMP_PATH", "elixir", "-e", script],
        cd: foreign,
        env: [{"IMP_LIVEBOOK_CONTRACT_NOTEBOOK", notebook}],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "resolved_imp_repo=#{root}"
    refute output =~ "resolved_imp_repo=#{foreign}"
  end

  test "operations Livebook teaches the consumer live boundary, not maintainer gates" do
    body = File.read!("livebooks/05_operate_and_live_checks.livemd")

    assert body =~ "Operate And Live Checks"
    assert body =~ "Operational boundaries"
    assert body =~ "Imp.req_llm"
    assert body =~ "LIVE_PROVIDER"
    assert body =~ "OPENAI_API_KEY"
    refute body =~ "mix production.check"
    refute body =~ "mix livebook.execute.check"
    refute body =~ "mix integration.check"
    refute body =~ "mix live.check"
  end

  test "real LM Livebook teaches the front-door provider journey" do
    body = File.read!("livebooks/01_real_lm_front_door.livemd")

    assert body =~ "Real LM Front Door"
    assert body =~ "Program, Don't Prompt"
    assert body =~ "Imp.req_llm"
    assert body =~ "Imp.predict"
    assert body =~ "Imp.chain_of_thought"
    assert body =~ "Imp.react"
    assert body =~ "Imp.optimize"
    assert body =~ "Imp.dump"
    assert body =~ "OPENAI_API_KEY"
    assert body =~ "OPENAI_MODEL"
  end

  test "the front-door Livebook runs real calls with a key and guides setup without one" do
    body = File.read!("livebooks/01_real_lm_front_door.livemd")

    # A key alone unlocks the payoff: no extra opt-in flag, no skip tuples,
    # and no raise-on-failure proof assertions in reader-facing cells.
    assert body =~ "OPENAI_API_KEY"
    refute body =~ "LIVE_PROVIDER"
    refute body =~ "{:skip"
    refute body =~ "proof failed"

    [_setup | reader_blocks] =
      Regex.scan(~r/```elixir\n(.*?)```/s, body, capture: :all_but_first)
      |> List.flatten()

    refute Enum.join(reader_blocks, "\n") =~ ~r/^\s*raise /m

    assert body =~
             ~s(raise "IMP_PATH does not point to an Imp source checkout or unpacked package")

    # Missing credentials produce friendly setup guidance, not a bare tuple.
    assert body =~ "setup_guidance"
    assert body =~ "Secrets panel"
    assert body =~ "Add OPENAI_API_KEY (see the setup cell) to watch this run."
  end

  test "each later Livebook has a live-provider proof path" do
    expected = %{
      "livebooks/02_programming_not_prompting.livemd" => [
        "## Live Provider Proof",
        "live provider returned an invalid typed prediction"
      ],
      "livebooks/03_evaluate_and_optimize.livemd" => [
        "## Live Evaluation Proof",
        "live provider failed the evaluation proof"
      ],
      "livebooks/04_tools_agents_mcp_rlm.livemd" => [
        "## Live ReAct Proof",
        "## Live RLM Submit Proof",
        "live ReAct proof failed",
        "live RLM proof failed"
      ],
      "livebooks/05_operate_and_live_checks.livemd" => [
        "## Live Operations Proof",
        "live operations proof failed"
      ]
    }

    for {path, snippets} <- expected do
      body = File.read!(path)

      assert body =~ "OPENAI_API_KEY"
      assert body =~ "OPENAI_MODEL"
      assert body =~ "System.get_env(\"LIVE_PROVIDER\") == \"1\""
      assert body =~ "live_provider_enabled? && System.get_env(\"OPENAI_API_KEY\")"

      ~r/```elixir\n(.*?)```/s
      |> Regex.scan(body, capture: :all_but_first)
      |> List.flatten()
      |> Enum.filter(fn block ->
        String.contains?(block, "Imp.req_llm") and
          String.contains?(block, "System.fetch_env!(\"OPENAI_API_KEY\")")
      end)
      |> Enum.each(fn provider_block ->
        assert provider_block =~
                 "live_provider_enabled? && System.get_env(\"OPENAI_API_KEY\")"
      end)

      for snippet <- snippets do
        assert body =~ snippet
      end
    end
  end

  test "Livebooks teach the ReqLLM provider path only" do
    body = Path.wildcard("livebooks/*.livemd") |> Enum.map_join("\n", &File.read!/1)

    assert body =~ "Imp.req_llm"
    assert body =~ "api_key: System.fetch_env!(\"OPENAI_API_KEY\")"
    refute body =~ "Imp.openai"
    refute body =~ "Imp.litellm"
    refute body =~ "Imp.local_lm"
    refute body =~ "Imp.databricks("
  end

  test "Livebooks do not retain the pre-cutover appended walkthrough names" do
    body = Path.wildcard("livebooks/*.livemd") |> Enum.map_join("\n", &File.read!/1)

    refute body =~ "Imp 05: Real LM Wow Path"
    refute body =~ "05_real_lm_wow_path"
    refute body =~ "04_local_gates_and_live_provider_smoke"
    refute body =~ "03_agents_tools_mcp_rlm"
  end

  test "Livebooks read as one cohesive manual path" do
    first = File.read!("livebooks/01_real_lm_front_door.livemd")
    second = File.read!("livebooks/02_programming_not_prompting.livemd")
    third = File.read!("livebooks/03_evaluate_and_optimize.livemd")
    fourth = File.read!("livebooks/04_tools_agents_mcp_rlm.livemd")
    fifth = File.read!("livebooks/05_operate_and_live_checks.livemd")

    assert first =~ "Manual path: real provider shape first"
    assert first =~ "Next: open `livebooks/02_programming_not_prompting.livemd`"
    assert second =~ "Livebook 01 showed the real-provider shape"
    assert second =~ "Next: open `livebooks/03_evaluate_and_optimize.livemd`"
    assert third =~ "Livebook 02 made the program inspectable"
    assert third =~ "Next: open `livebooks/04_tools_agents_mcp_rlm.livemd`"
    assert fourth =~ "Livebook 03 handled improvement loops"
    assert fourth =~ "Next: open `livebooks/05_operate_and_live_checks.livemd`"
    assert fifth =~ "The earlier notebooks built Imp programs"
  end
end
