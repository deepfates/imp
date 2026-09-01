defmodule Imp.Predict.RLM.InterpreterTest do
  use ExUnit.Case, async: true

  alias Imp.Predict.RLM.Interpreter

  test "controller guide and interpreter agree on representative repair paths" do
    guide = Interpreter.controller_language_guide()
    interpreter = Interpreter.new(%{}, %{}, nil)

    source = ~S"""
    headings = for line <- ["body", "# Haven"], String.starts_with?(line, "#"), do: line
    heading = headings |> Enum.at(0)
    heading = if Enum.count(headings) > 0, do: heading, else: "missing"
    submit(%{answer: "README: " <> heading})
    """

    assert {:final, %{answer: "README: # Haven"}, _interpreter} =
             Interpreter.execute(interpreter, source)

    assert guide =~ "`if condition, do: value, else: value`"
    assert guide =~ "Enum.at/2"
    assert guide =~ "String.starts_with?/2"
    assert guide =~ "Pipelines with `|>` are supported"
    assert guide =~ "string concatenation with `<>`"

    for {source, named_trap} <- [
          {"case true do true -> 1 end", "`case`"},
          {"Enum.find([1, 2], 1)", "`Enum.find`"},
          {"hd([1])", "`hd`"},
          {~S|"value: #{1}"|, "binary `<<>>`"}
        ] do
      assert {:error, _reason, _interpreter} = Interpreter.execute(interpreter, source)
      assert guide =~ named_trap
    end
  end

  test "every advertised module call executes with representative valid arguments" do
    interpreter = Interpreter.new(%{}, %{}, nil)

    samples = %{
      {:String, :contains?, 2} => ~S|String.contains?("abc", "b")|,
      {:String, :downcase, 1} => ~S|String.downcase("ABC")|,
      {:String, :ends_with?, 2} => ~S|String.ends_with?("abc", "c")|,
      {:String, :length, 1} => ~S|String.length("abc")|,
      {:String, :replace, 3} => ~S|String.replace("abc", "b", "x")|,
      {:String, :slice, 2} => ~S|String.slice("abc", 1..2)|,
      {:String, :slice, 3} => ~S|String.slice("abc", 1, 2)|,
      {:String, :split, 1} => ~S|String.split("a b")|,
      {:String, :split, 2} => ~S|String.split("a,b", ",")|,
      {:String, :starts_with?, 2} => ~S|String.starts_with?("abc", "a")|,
      {:String, :trim, 1} => ~S|String.trim(" a ")|,
      {:String, :trim_leading, 1} => ~S|String.trim_leading(" a")|,
      {:String, :trim_trailing, 1} => ~S|String.trim_trailing("a ")|,
      {:String, :upcase, 1} => ~S|String.upcase("abc")|,
      {:Enum, :at, 2} => ~S|Enum.at([1, 2], 0)|,
      {:Enum, :at, 3} => ~S|Enum.at([], 0, "missing")|,
      {:Enum, :chunk_every, 2} => ~S|Enum.chunk_every([1, 2], 1)|,
      {:Enum, :chunk_every, 3} => ~S|Enum.chunk_every([1, 2, 3], 2, 1)|,
      {:Enum, :concat, 1} => ~S|Enum.concat([[1], [2]])|,
      {:Enum, :count, 1} => ~S|Enum.count([1, 2])|,
      {:Enum, :drop, 2} => ~S|Enum.drop([1, 2], 1)|,
      {:Enum, :join, 1} => ~S|Enum.join(["a", "b"])|,
      {:Enum, :join, 2} => ~S|Enum.join(["a", "b"], ",")|,
      {:Enum, :max, 1} => ~S|Enum.max([1, 2])|,
      {:Enum, :member?, 2} => ~S|Enum.member?([1, 2], 2)|,
      {:Enum, :min, 1} => ~S|Enum.min([1, 2])|,
      {:Enum, :product, 1} => ~S|Enum.product([2, 3])|,
      {:Enum, :reverse, 1} => ~S|Enum.reverse([1, 2])|,
      {:Enum, :slice, 2} => ~S|Enum.slice([1, 2, 3], 1..2)|,
      {:Enum, :sum, 1} => ~S|Enum.sum([1, 2])|,
      {:Enum, :take, 2} => ~S|Enum.take([1, 2], 1)|,
      {:Enum, :uniq, 1} => ~S|Enum.uniq([1, 1])|
    }

    capabilities = Interpreter.controller_language_capabilities()

    advertised =
      for {module, functions} <- [
            {:String, capabilities.string_functions},
            {:Enum, capabilities.enum_functions}
          ],
          {function, arities} <- functions,
          arity <- List.wrap(arities),
          into: MapSet.new(),
          do: {module, function, arity}

    assert advertised == samples |> Map.keys() |> MapSet.new()

    for {capability, source} <- samples do
      assert {:ok, _value, _interpreter} = Interpreter.execute(interpreter, source),
             "advertised call failed: #{inspect(capability)}"
    end

    assert {:ok, "b", _interpreter} =
             Interpreter.execute(interpreter, ~S|Access.get("abc", 1)|)

    novel_atom = ":imp_rlm_controller_atom_that_does_not_exist_4f52e7"

    assert {:ok, "imp_rlm_controller_atom_that_does_not_exist_4f52e7", _interpreter} =
             Interpreter.execute(interpreter, novel_atom)
  end

  test "Enum.sum and Enum.product are allowlisted aggregations" do
    interpreter = Interpreter.new(%{numbers: [1, 2, 3, 4, 5]}, %{}, nil)

    assert {:ok, 15, interpreter} = Interpreter.execute(interpreter, "Enum.sum(numbers)")
    assert {:ok, 120, interpreter} = Interpreter.execute(interpreter, "Enum.product(numbers)")

    # A lambda-taking Enum function stays out of the fn-less allowlist.
    assert {:error, {:function_not_allowed, :Enum, :reduce, 3}, _next} =
             Interpreter.execute(interpreter, "Enum.reduce(numbers, 0, fn x, acc -> x + acc end)")
  end

  test "assignments persist across executions" do
    interpreter = Interpreter.new(%{seed: 2}, %{}, nil)
    assert {:ok, 5, interpreter} = Interpreter.execute(interpreter, "total = seed + 3")
    assert interpreter.vars.total == 5
    assert {:ok, 10, interpreter} = Interpreter.execute(interpreter, "total * 2")
    assert interpreter.vars.total == 5
  end

  test "a failed cell rolls back ordinary assignments while retaining protected values" do
    interpreter = Interpreter.new(%{context: "original"}, %{}, nil)
    assert {:ok, interpreter} = Interpreter.put_protected(interpreter, "context", "protected")

    assert {:error, {:function_not_allowed, :missing}, next} =
             Interpreter.execute(
               interpreter,
               ~S|scratch = context <> "-saved"
missing()|
             )

    refute Map.has_key?(next.vars, :scratch)
    refute Map.has_key?(next.vars, "scratch")
    assert next.vars.context == "protected"

    assert {:ok, "protected", _next} = Interpreter.execute(next, "context")
  end

  test "effects in comprehensions yield and resume deterministically" do
    interpreter = Interpreter.new(%{}, %{"llm_query" => :llm_query}, nil)
    source = ~S|for prompt <- ["a", "b", "c"], do: llm_query(prompt)|

    assert {:effect, %{kind: :llm_query, arguments: ["a"]}, continuation} =
             Interpreter.execute(interpreter, source)

    assert {:effect, %{kind: :llm_query, arguments: ["b"]}, continuation} =
             Interpreter.resume(continuation, {:ok, "A"})

    assert {:effect, %{kind: :llm_query, arguments: ["c"]}, continuation} =
             Interpreter.resume(continuation, {:ok, "B"})

    assert {:ok, ["A", "B", "C"], interpreter} =
             Interpreter.resume(continuation, {:ok, "C"})

    assert interpreter.vars == %{}
  end

  test "submit stops a block immediately and accepts keyword arguments" do
    interpreter = Interpreter.new(%{}, %{}, :runtime)

    assert {:final, %{answer: 42}, interpreter} =
             Interpreter.execute(interpreter, "submit(answer: 42)\nnever = 1")

    refute Map.has_key?(interpreter.vars, :never)
  end

  test "print output is bounded and observable" do
    interpreter = Interpreter.new(%{}, %{}, nil, max_output_chars: 5)

    assert {:ok, "world", interpreter} =
             Interpreter.execute(interpreter, "print(\"hello\")\nprint(\"world\")")

    assert interpreter.output == "hello"

    assert {:ok, "next", interpreter} = Interpreter.execute(interpreter, ~S|print("next")|)
    assert interpreter.output == "next"
  end

  test "accepts elixir and bare markdown fences and rejects other languages" do
    interpreter = Interpreter.new(%{}, %{}, nil)
    assert {:ok, 3, _} = Interpreter.execute(interpreter, "```elixir\n1 + 2\n```")
    assert {:ok, 4, _} = Interpreter.execute(interpreter, "```\n2 + 2\n```")

    assert {:error, {:unsupported_markdown_language, "python"}, _} =
             Interpreter.execute(interpreter, "```python\n1 + 2\n```")
  end

  test "supports slicing and allowlisted transformations" do
    interpreter = Interpreter.new(%{context: "alpha beta gamma"}, %{}, nil)

    assert {:ok, ["alpha", "beta"], _} =
             Interpreter.execute(interpreter, "context |> String.split() |> Enum.take(2)")
  end

  test "rejects dangerous and arbitrary calls" do
    interpreter = Interpreter.new(%{}, %{}, nil)

    for source <- [
          "System.cmd(\"id\", [])",
          "File.read!(\"/etc/passwd\")",
          "spawn(fn -> :ok end)",
          "import String",
          "alias System",
          "String.to_atom(\"unsafe\")",
          "unknown_call()"
        ] do
      assert {:error, _reason, _} = Interpreter.execute(interpreter, source)
    end
  end

  test "controller identifiers do not create VM atoms" do
    identifier = "rlm_untrusted_identifier_#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(identifier) end

    interpreter = Interpreter.new(%{}, %{}, nil)
    assert {:ok, 1, interpreter} = Interpreter.execute(interpreter, "#{identifier} = 1")
    assert interpreter.vars[identifier] == 1
    assert_raise ArgumentError, fn -> String.to_existing_atom(identifier) end
  end

  test "enforces AST and execution step budgets" do
    interpreter = Interpreter.new(%{}, %{}, nil, max_steps: 6)

    assert {:error, :ast_step_limit_exceeded, _} =
             Interpreter.execute(interpreter, "[1, 2, 3, 4, 5, 6]")

    interpreter = Interpreter.new(%{}, %{}, nil, max_steps: 12)

    assert {:error, :step_limit_exceeded, _} =
             Interpreter.execute(interpreter, "for x <- 1..100, do: x")
  end

  test "rejects oversized source before parsing" do
    interpreter = Interpreter.new(%{}, %{}, nil, max_source_bytes: 8)

    assert {:error, {:source_too_large, 9, 8}, _} =
             Interpreter.execute(interpreter, "123456789")
  end

  test "bounds intermediate value growth without leaking a failed cell binding" do
    interpreter =
      Interpreter.new(%{}, %{}, nil,
        max_steps: 1_000,
        max_value_bytes: 1_000
      )

    source =
      ([~S|x = "0123456789"|] ++ List.duplicate("x = x <> x", 10))
      |> Enum.join("\n")

    assert {:error, {:value_budget_exceeded, bytes, 1_000}, interpreter} =
             Interpreter.execute(interpreter, source)

    assert bytes > 1_000
    refute Map.has_key?(interpreter.vars, :x)
  end

  test "bounds external effects per controller turn" do
    interpreter =
      Interpreter.new(%{}, %{"llm_query" => :llm_query}, nil, max_effects: 1)

    assert {:effect, %{arguments: ["a"]}, continuation} =
             Interpreter.execute(interpreter, ~S|[llm_query("a"), llm_query("b")]|)

    assert {:error, {:effect_limit_exceeded, 1}, _interpreter} =
             Interpreter.resume(continuation, {:ok, "A"})
  end

  test "cached effect requests and results share the value budget" do
    interpreter =
      Interpreter.new(%{}, %{"llm_query" => :llm_query}, nil,
        max_value_bytes: 1_000,
        max_effects: 2
      )

    source = ~S|[llm_query("a"), llm_query("b")]|
    assert {:effect, _request, continuation} = Interpreter.execute(interpreter, source)

    assert {:effect, _request, continuation} =
             Interpreter.resume(continuation, {:ok, String.duplicate("a", 400)})

    assert {:error, {:effect_result_budget_exceeded, {:value_budget_exceeded, bytes, 1_000}}, _} =
             Interpreter.resume(continuation, {:ok, String.duplicate("b", 700)})

    assert bytes > 1_000
  end
end
