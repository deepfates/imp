defmodule GuidePagesTest do
  # Runs the examples in the production guide and the Diving deeper pages.
  #
  # Each page's ```elixir blocks run in order, sharing bindings, the way a
  # reader would paste them into one IEx session. A `#=> value` line checks
  # the value of the code above it. Blocks fenced with ~~~elixir call a model
  # or belong in a config file; they are parsed, not run, and their output
  # comes from a live run.
  use ExUnit.Case, async: false

  @pages [
    "docs/production.md",
    "docs/diving-deeper/choosing-an-optimizer.md",
    "docs/diving-deeper/metrics-and-evaluation.md",
    "docs/diving-deeper/saving-and-artifacts.md",
    "docs/diving-deeper/runs-and-supervision.md",
    "docs/diving-deeper/settings-and-context.md"
  ]

  for page <- @pages do
    test "#{page} parses" do
      for {_fence, code, index} <- blocks(unquote(page)) do
        Code.string_to_quoted!(code, file: "#{unquote(page)}##{index}")
      end
    end

    test "#{page} runs and shows what it returns" do
      run_page(unquote(page))
    end
  end

  defp run_page(page) do
    # Blocks that only build a provider client read OPENAI_API_KEY; building
    # one sends nothing.
    previous_key = System.get_env("OPENAI_API_KEY")
    if is_nil(previous_key), do: System.put_env("OPENAI_API_KEY", "sk-doc-test-unused")

    try do
      page
      |> blocks()
      |> Enum.filter(fn {fence, _code, _index} -> fence == :run end)
      |> Enum.reduce([], fn {_fence, code, index}, binding ->
        run_block(code, binding, "#{page}##{index}")
      end)
    after
      if is_nil(previous_key), do: System.delete_env("OPENAI_API_KEY")
      Imp.Settings.reset()
    end
  end

  # Evaluates the code before each `#=>` line and compares its value.
  defp run_block(code, binding, file) do
    {segments, rest} =
      code
      |> String.split("\n")
      |> Enum.reduce({[], []}, fn line, {segments, lines} ->
        case line do
          "#=> " <> expected -> {[{Enum.reverse(lines), expected} | segments], []}
          _ -> {segments, [line | lines]}
        end
      end)

    binding =
      segments
      |> Enum.reverse()
      |> Enum.reduce(binding, fn {lines, expected}, binding ->
        {value, binding} = Code.eval_string(Enum.join(lines, "\n"), binding, file: file)
        assert_shown(value, expected, file)
        binding
      end)

    {_value, binding} = Code.eval_string(Enum.join(Enum.reverse(rest), "\n"), binding, file: file)
    binding
  end

  defp assert_shown(value, expected, file) do
    shown =
      try do
        {shown, _} = Code.eval_string(expected)
        shown
      rescue
        _ -> {:inspected, expected}
      end

    case shown do
      {:inspected, text} ->
        assert inspect(value) == text, "#{file} shows #{text}, got #{inspect(value)}"

      shown ->
        assert value == shown, "#{file} shows #{expected}, got #{inspect(value)}"
    end
  end

  defp blocks(page) do
    ~r/^(```|~~~)elixir\n(.*?)\n\1$/ms
    |> Regex.scan(File.read!(page), capture: :all_but_first)
    |> Enum.with_index()
    |> Enum.map(fn {[fence, code], index} ->
      {if(fence == "```", do: :run, else: :parse), code, index}
    end)
  end
end
