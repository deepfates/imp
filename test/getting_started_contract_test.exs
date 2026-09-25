defmodule GettingStartedContractTest do
  use ExUnit.Case, async: false

  @reader_docs [
    "README.md",
    "docs/coming-from-dspy.md",
    "docs/production.md",
    "examples/deployment/README.md"
  ]

  # Pages whose every block runs with a scripted model. Their `#=>` results are
  # checked here; the other pages call a provider and run under the :live tag.
  @provider_free [
    "docs/getting-started/testing-without-a-provider.md",
    "docs/getting-started/running-in-your-application.md"
  ]

  test "every Elixir example in the reader docs and the getting-started path parses" do
    for path <- @reader_docs ++ pages(),
        {code, index} <- path |> elixir_blocks() |> Enum.with_index() do
      Code.string_to_quoted!(code, file: "#{path}##{index}")
    end
  end

  test "the getting-started pages chain in reading order" do
    [_ | rest] = pages = pages()

    for {page, next} <- Enum.zip(pages, rest) do
      assert File.read!(page) =~ "**Next:** [",
             "#{page} does not end with a Next link"

      assert File.read!(page) =~ "](#{Path.basename(next)})\n",
             "#{page} does not link to #{next}, the next page"
    end
  end

  test "provider-free pages produce the results they show" do
    for path <- @provider_free do
      refute File.read!(path) =~ "req_llm(\"",
             "#{path} is listed as provider-free but builds a provider client in a checked block"

      path
      |> elixir_blocks()
      |> Enum.with_index()
      |> Enum.reduce([], fn {code, index}, binding ->
        {result, binding} = Code.eval_string(code, binding, file: "#{path}##{index}")

        case shown_result(code) do
          nil -> :ok
          shown -> assert result == shown, "#{path}##{index} returned #{inspect(result)}"
        end

        binding
      end)
    end
  end

  test "the provider-free check compares against the shown result" do
    assert shown_result("1 + 1\n#=> 2") == 2
    assert shown_result("1 + 1") == nil
  end

  test "live teaching pages say which credential they require" do
    for path <- ["README.md", "docs/getting-started/setting-up.md"] do
      assert File.read!(path) =~ "OPENAI_API_KEY"
    end
  end

  @tag :live
  @tag timeout: 1_200_000
  test "the README and the getting-started path run against the configured provider" do
    tmp = Path.join(System.tmp_dir!(), "imp-docs-live-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    original = File.cwd!()

    try do
      File.cd!(tmp)

      for paths <- [["README.md"], pages()] do
        Enum.reduce(paths, [], fn path, binding ->
          path
          |> then(&Path.join(original, &1))
          |> elixir_blocks()
          |> Enum.reduce(binding, fn code, binding ->
            {_result, binding} = Code.eval_string(provider(code), binding, file: path)
            binding
          end)
        end)
      end
    after
      File.cd!(original)
      File.rm_rf!(tmp)
    end
  end

  # The pages show OpenAI, which most readers have. A maintainer with only an
  # OpenRouter key runs the same models through OpenRouter's OpenAI route.
  defp provider(code) do
    if System.get_env("OPENAI_API_KEY") || is_nil(System.get_env("OPENROUTER_API_KEY")) do
      code
    else
      code
      |> String.replace(~s|Imp.req_llm("openai:|, ~s|Imp.req_llm("openrouter:openai/|)
      |> String.replace(
        ~s|System.fetch_env!("OPENAI_API_KEY")|,
        ~s|System.fetch_env!("OPENROUTER_API_KEY")|
      )
    end
  end

  defp pages do
    Mix.Project.config()
    |> Keyword.fetch!(:docs)
    |> Keyword.fetch!(:groups_for_extras)
    |> Keyword.fetch!(:"Getting started")
  end

  defp shown_result(code) do
    case code |> String.split("\n") |> List.last() do
      "#=> " <> shown ->
        {value, _binding} = Code.eval_string(shown)
        value

      _other ->
        nil
    end
  end

  defp elixir_blocks(path) do
    ~r/```elixir\n(.*?)\n```/s
    |> Regex.scan(File.read!(path))
    |> Enum.map(fn [_, code] -> code end)
  end
end
