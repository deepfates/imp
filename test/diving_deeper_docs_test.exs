defmodule DivingDeeperDocsTest do
  # Evaluates the examples in the Diving deeper pages and the DSPy guide.
  #
  # Every ```elixir block must parse. A block that needs a provider key or an
  # external MCP server is only parsed; every other block runs, in page order,
  # sharing bindings with the blocks before it, and each `#=>` line must equal
  # what the code above it returned. Blocks fenced with ~~~ are fragments that
  # need something the page does not set up; they are parsed and not run.
  use ExUnit.Case, async: false

  @pages [
    "docs/coming-from-dspy.md",
    "docs/diving-deeper/signatures.md",
    "docs/diving-deeper/modules-and-composition.md",
    "docs/diving-deeper/adapters.md",
    "docs/diving-deeper/tools-and-mcp.md",
    "docs/diving-deeper/react.md"
  ]

  # A block containing one of these needs the network, a provider key, or an
  # MCP server process.
  @external ["System.fetch_env!", "Imp.MCP.connect", "imported."]

  test "every Elixir block on the pages parses" do
    for page <- @pages,
        {code, index} <- Enum.with_index(blocks(page, ~r/^(```|~~~)elixir\n(.*?)\n\1$/ms)) do
      Code.string_to_quoted!(code, file: "#{page}##{index}")
    end
  end

  for page <- @pages do
    test "the provider-free examples in #{page} return what the page shows" do
      page = unquote(page)

      page
      |> blocks(~r/^(```)elixir\n(.*?)\n\1$/ms)
      |> Enum.with_index()
      |> Enum.reject(fn {code, _index} -> Enum.any?(@external, &String.contains?(code, &1)) end)
      |> Enum.reduce([], fn {code, index}, binding ->
        run_block(code, binding, "#{page}##{index}")
      end)
    end
  end

  test "the evaluator catches an example whose shown result is wrong" do
    assert_raise ExUnit.AssertionError, fn -> run_block("1 + 1\n#=> 3", [], "guard") end
  end

  defp blocks(page, pattern) do
    pattern
    |> Regex.scan(File.read!(page))
    |> Enum.map(fn [_, _fence, code] -> code end)
  end

  # Splits a block at its `#=>` lines. The code before each one is evaluated
  # and its value compared with the expected expression.
  defp run_block(code, binding, file) do
    {binding, pending, expected} =
      code
      |> String.split("\n")
      |> Enum.reduce({binding, [], []}, fn line, {binding, pending, expected} ->
        case line do
          "#=> " <> value ->
            {binding, pending, expected ++ [value]}

          line when expected != [] ->
            binding = check(pending, expected, binding, file)
            {binding, [line], []}

          line ->
            {binding, pending ++ [line], expected}
        end
      end)

    if expected == [] do
      {_value, binding} = Code.eval_string(Enum.join(pending, "\n"), binding, file: file)
      binding
    else
      check(pending, expected, binding, file)
    end
  end

  defp check(pending, expected, binding, file) do
    {value, binding} = Code.eval_string(Enum.join(pending, "\n"), binding, file: file)
    {wanted, _binding} = Code.eval_string(Enum.join(expected, "\n"), [], file: file)
    assert value == wanted, "#{file} shows #{inspect(wanted)} but returned #{inspect(value)}"
    binding
  end
end
