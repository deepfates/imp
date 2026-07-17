defmodule LearningPathContractTest do
  use ExUnit.Case, async: false

  # The reader-facing docs carry no test markers; this contract pins them by
  # position instead. `blocks` is the expected number of ```elixir blocks in
  # the file. `local` lists {index, expected_result} pairs for the blocks that
  # execute deterministically without provider credentials; every other block
  # is a live-provider block and is executed end to end by the :live test
  # below (run via `mix live.check` with OPENAI_API_KEY set).
  @contract %{
    "README.md" => %{blocks: 1, local: []},
    "docs/LEARNING_PATH.md" => %{
      blocks: 9,
      local: [
        {3, {"security", "high"}},
        {4, 0.5},
        {7, "security"},
        {8, {"Ines", [[:imp, :tool, :start], [:imp, :tool, :stop]]}}
      ]
    },
    "docs/TUTORIAL_TICKET_ROUTING.md" => %{blocks: 7, local: []}
  }

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
