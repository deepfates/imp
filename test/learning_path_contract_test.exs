defmodule LearningPathContractTest do
  use ExUnit.Case, async: false

  # The reader-facing docs carry no test markers; this contract pins them by
  # position instead. `blocks` is the expected number of ```elixir blocks in
  # the file. `local` lists {index, expected_result} pairs for the blocks that
  # execute deterministically without provider credentials; every other block
  # is a live-provider block and is executed end to end by the :live test
  # below (run via `mix live.check` with OPENAI_API_KEY set).
  @contract %{
    "README.md" => %{blocks: 2, local: []},
    "docs/LEARNING_PATH.md" => %{
      blocks: 10,
      local: [
        {3, {"security", "high"}},
        {4, 0.5},
        {7, "security"},
        {8, {"security", :labeled_few_shot}},
        {9, {"Ines", [[:imp, :tool, :start], [:imp, :tool, :stop]]}}
      ]
    },
    "docs/TUTORIAL_TICKET_ROUTING.md" => %{blocks: 7, local: []}
  }

  # docs/API_GUIDE.md is pinned separately (dee-qzv9): its blocks deliberately
  # continue one another, so the deterministic ones execute SEQUENTIALLY with
  # carried bindings rather than standalone. Blocks that cannot execute offline
  # are pinned below by index, first line, and reason; everything else must
  # eval. If the guide changes, both pins fail loudly and must be re-pinned
  # against the new block inventory — that is the point.
  @api_guide "docs/API_GUIDE.md"
  @api_guide_blocks 52
  @api_guide_skips %{
    1 => {"model = System.fetch_env!(\"OPENAI_MODEL\")", "live provider block (OPENAI_MODEL)"},
    18 => {"lm = Imp.req_llm(\"openai:gpt-5.4-mini\"", "live provider block (OPENAI_API_KEY)"},
    19 => {"def handle_event(\"ask\"", "LiveView module-context sketch, not a script"},
    31 => {"{selected, report, artifact} =", "application-specific GEPA reconstruction sketch"},
    33 => {"rule_lm =", "live provider block (OPENAI_API_KEY)"},
    38 => {"job = Imp.Clients.TrainingJob.load!", "existing trained-artifact adoption sketch"},
    39 => {"Imp.Optimizer.BetterTogether.compile(", "continuation of adoption sketch"},
    45 => {"client = Imp.MCP.HTTPClient.new(", "external MCP service sketch"},
    51 => {"lm =", "live provider block (OPENAI_MODEL)"}
  }

  test "API guide block inventory is pinned and every block parses" do
    blocks = elixir_blocks(@api_guide)

    assert length(blocks) == @api_guide_blocks,
           "#{@api_guide} has #{length(blocks)} elixir blocks, contract expects " <>
             "#{@api_guide_blocks}; update this contract when the guide changes"

    for {code, index} <- Enum.with_index(blocks) do
      Code.string_to_quoted!(code, file: "#{@api_guide}##{index}")
    end

    for {index, {first_line, _reason}} <- @api_guide_skips do
      block = Enum.at(blocks, index)

      assert String.starts_with?(block, first_line),
             "#{@api_guide} block #{index} no longer starts with #{inspect(first_line)}; " <>
               "the skip pin is stale — re-verify whether the block is executable"
    end
  end

  @tag timeout: 300_000
  test "API guide deterministic blocks execute sequentially with their documented results" do
    binding =
      @api_guide
      |> elixir_blocks()
      |> Enum.with_index()
      |> Enum.reduce([], fn {code, index}, binding ->
        if Map.has_key?(@api_guide_skips, index) do
          binding
        else
          {_result, binding} = Code.eval_string(code, binding, file: "#{@api_guide}##{index}")
          binding
        end
      end)

    # The flagship MIPROv2 checkpoint example (dee-qzv9): as previously
    # documented it raised "minibatch_size cannot exceed valset size 1"
    # before writing any checkpoint.
    paused = Keyword.fetch!(binding, :paused)
    resumed = Keyword.fetch!(binding, :resumed)
    assert Imp.Optimizer.Report.fetch(paused).metadata.run_status == :paused
    assert Imp.Optimizer.Report.fetch(resumed).metadata.run_status == :complete

    # The Avatar and Optimize Anything examples referenced never-bound
    # variables; bound, they must actually optimize.
    compiled_avatar = Keyword.fetch!(binding, :compiled_avatar)
    assert Imp.Optimizer.Report.fetch(compiled_avatar).best_score == 1.0

    result = Keyword.fetch!(binding, :result)
    assert hd(result.validation_scores) == 0.5
    assert Enum.max(result.validation_scores) == 1.0
  end

  test "every documented Elixir snippet parses and the block inventory is pinned" do
    for {path, %{blocks: expected_count}} <- @contract do
      blocks = elixir_blocks(path)

      assert length(blocks) == expected_count,
             "#{path} has #{length(blocks)} elixir blocks, contract expects #{expected_count}; " <>
               "update this contract when the docs change"

      for {code, index} <- Enum.with_index(blocks) do
        Code.string_to_quoted!(code, file: "#{path}##{index}")
      end
    end
  end

  test "deterministic snippets execute with their documented results" do
    for {path, %{local: local}} <- @contract, {index, expected} <- local do
      code = path |> elixir_blocks() |> Enum.at(index)
      {result, _binding} = Code.eval_string(code, [], file: "#{path}##{index}")
      assert result == expected, "#{path} block #{index}"
    end
  end

  test "live snippets declare the credential they need" do
    for {path, %{blocks: count, local: local}} <- @contract, count > length(local) do
      body = File.read!(path)
      assert body =~ "OPENAI_API_KEY", "#{path} has live blocks but never names OPENAI_API_KEY"
    end
  end

  @tag :live
  @tag timeout: 600_000
  test "live documentation paths execute end to end against the real provider" do
    tmp = Path.join(System.tmp_dir!(), "imp-docs-live-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    original = File.cwd!()

    try do
      File.cd!(tmp)

      for {path, _spec} <- @contract do
        blocks = elixir_blocks(Path.join(original, path))

        Enum.reduce(Enum.with_index(blocks), [], fn {code, index}, binding ->
          {_result, binding} = Code.eval_string(code, binding, file: "#{path}##{index}")
          binding
        end)
      end
    after
      File.cd!(original)
      File.rm_rf!(tmp)
    end
  end

  defp elixir_blocks(path) do
    ~r/```elixir\n(.*?)\n```/s
    |> Regex.scan(File.read!(path))
    |> Enum.map(fn [_, code] -> code end)
  end
end
