defmodule LearningPathContractTest do
  use ExUnit.Case, async: false

  @contract_paths ["README.md", "docs/LEARNING_PATH.md"]
  @expected_results %{
    "readme_predict" => "Paris",
    "predict" => "Paris",
    "evaluate" => 1.0,
    "optimize" => {0.0, 1.0},
    "react" => "Paris",
    "retrieval" => {"Paris", 1},
    "rlm" => {"Paris", [:submit]},
    "persistence" => "Paris",
    "observability" => {"Paris", [[:dsex, :tool, :start], [:dsex, :tool, :stop]]}
  }

  test "every local Elixir learning-path snippet executes with its documented result" do
    snippets = Enum.flat_map(@contract_paths, &local_snippets/1)

    assert MapSet.new(Enum.map(snippets, & &1.name)) == MapSet.new(Map.keys(@expected_results))

    Enum.each(snippets, fn snippet ->
      {result, _binding} = Code.eval_string(snippet.code, [], file: snippet.path)
      assert result == Map.fetch!(@expected_results, snippet.name), snippet.name
    end)
  end

  test "the only non-local Elixir snippet declares the required credentials" do
    docs = File.read!("docs/LEARNING_PATH.md")

    assert ["live_provider"] =
             Regex.scan(~r/# learning-path-credential-gated: ([a-z0-9_]+)/, docs)
             |> Enum.map(fn [_, name] -> name end)

    assert docs =~ "System.fetch_env!(\"OPENAI_API_KEY\")"
    assert docs =~ "System.fetch_env!(\"OPENAI_MODEL\")"
  end

  defp local_snippets(path) do
    docs = File.read!(path)

    all_elixir_blocks =
      Regex.scan(~r/```elixir\n(.*?)\n```/s, docs)
      |> Enum.reject(fn [_, code] ->
        String.starts_with?(code, "# learning-path-credential-gated:")
      end)

    snippets =
      Regex.scan(~r/```elixir\n# learning-path-contract: ([a-z0-9_]+)\n(.*?)\n```/s, docs)
      |> Enum.map(fn [_, name, code] -> %{name: name, code: code, path: path} end)

    assert length(all_elixir_blocks) == length(snippets),
           "every local Elixir snippet in #{path} must have a learning-path contract marker"

    snippets
  end
end
