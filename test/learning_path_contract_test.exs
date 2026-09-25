defmodule LearningPathContractTest do
  use ExUnit.Case, async: false

  @reader_docs [
    "README.md",
    "docs/LEARNING_PATH.md",
    "docs/coming-from-dspy.md",
    "docs/production.md",
    "examples/deployment/README.md"
  ]

  test "every Elixir example in the reader path parses" do
    for path <- @reader_docs,
        {code, index} <- path |> elixir_blocks() |> Enum.with_index() do
      Code.string_to_quoted!(code, file: "#{path}##{index}")
    end
  end

  test "the learning path's provider-free examples retain their documented results" do
    expected = [
      {3, {"security", "high"}},
      {4, 0.5},
      {7, "security"},
      {8, {"security", :labeled_few_shot}},
      {9, {"Ines", [[:imp, :tool, :start], [:imp, :tool, :stop]]}}
    ]

    blocks = elixir_blocks("docs/LEARNING_PATH.md")

    for {index, expected_result} <- expected do
      {result, _binding} =
        blocks
        |> Enum.at(index)
        |> Code.eval_string([], file: "docs/LEARNING_PATH.md##{index}")

      assert result == expected_result
    end
  end

  test "live teaching pages say which credential they require" do
    for path <- ["README.md", "docs/LEARNING_PATH.md"] do
      assert File.read!(path) =~ "OPENAI_API_KEY"
    end
  end

  @tag :live
  @tag timeout: 600_000
  test "the continuous learning path runs against the configured provider" do
    tmp = Path.join(System.tmp_dir!(), "imp-docs-live-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    original = File.cwd!()

    try do
      File.cd!(tmp)

      for path <- ["README.md", "docs/LEARNING_PATH.md"] do
        path
        |> then(&Path.join(original, &1))
        |> elixir_blocks()
        |> Enum.reduce([], fn code, binding ->
          {_result, binding} = Code.eval_string(code, binding, file: path)
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
