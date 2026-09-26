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
    assert guide =~ "Every function of `Enum`, `Keyword`, `List`, `Map` and `String`"
    assert guide =~ "`String.to_atom`"
    assert guide =~ "Pipelines with `|>` are supported"
    assert guide =~ "string concatenation with `<>`"

    for {source, named_trap} <- [
          {"case true do true -> 1 end", "`case`"},
          {"f = fn x -> x end\nf.(1)", "calling a function stored in a variable"},
          {"hd([1])", "`hd`"},
          {~S|"value: #{1}"|, "binary `<<>>`"}
        ] do
      assert {:error, _reason, _interpreter} = Interpreter.execute(interpreter, source)
      assert guide =~ named_trap
    end
  end

  test "representative library calls execute and refused functions are not advertised" do
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
    assert capabilities.library_modules == [:Enum, :Keyword, :List, :Map, :String]

    for capability <- Map.keys(samples) do
      assert capability in capabilities.library_functions
    end

    for {{module, function}, _reason} <- capabilities.refused_functions do
      refute Enum.any?(capabilities.library_functions, &match?({^module, ^function, _}, &1))
    end

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

  test "a pinned pattern matches the variable's value" do
    interpreter = Interpreter.new(%{t: 3, xs: [3, 4, 3]}, %{}, nil)

    assert {:ok, [:hit, :miss, :hit], _next} =
             Interpreter.execute(interpreter, "Enum.map(xs, fn ^t -> :hit; _ -> :miss end)")
  end

  test "Enum.sum, Enum.product and Enum.reduce aggregate" do
    interpreter = Interpreter.new(%{numbers: [1, 2, 3, 4, 5]}, %{}, nil)

    assert {:ok, 15, interpreter} = Interpreter.execute(interpreter, "Enum.sum(numbers)")
    assert {:ok, 120, interpreter} = Interpreter.execute(interpreter, "Enum.product(numbers)")

    assert {:ok, 15, _next} =
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

  describe "forged structs" do
    # A map carrying `__struct__` is dispatched by every protocol as that
    # struct. Controller code must not be able to make one: a map shaped like
    # a File.Stream sent Enum.take into Enumerable.File.Stream and read a file.
    setup do
      path =
        Path.join(System.tmp_dir!(), "imp-rlm-forged-#{System.unique_integer([:positive])}")

      File.write!(path, "host secret\n")
      on_exit(fn -> File.rm(path) end)
      {:ok, path: path}
    end

    defp file_stream_literal(path) do
      ~s|%{__struct__: :"Elixir.File.Stream", path: #{inspect(path)}, modes: [:raw, :read_ahead, :binary], line_or_bytes: :line, raw: true, node: :nonode@nohost}|
    end

    test "a map literal cannot carry __struct__ into Enumerable, String.Chars or Inspect",
         %{path: path} do
      interpreter = Interpreter.new(%{}, %{}, nil)
      forged = file_stream_literal(path)

      for source <- [
            "Enum.join(#{forged})",
            "Enum.chunk_every(#{forged}, 1)",
            "Enum.count(#{forged})",
            "Enum.join([#{forged}])",
            "print(#{forged})",
            "forged = #{forged}",
            "key = :__struct__\nEnum.join(%{key => :\"Elixir.File.Stream\", path: #{inspect(path)}})",
            "%File.Stream{path: #{inspect(path)}}",
            "submit(__struct__: :\"Elixir.File.Stream\", path: #{inspect(path)})"
          ] do
        result = Interpreter.execute(interpreter, source)
        refute inspect(result) =~ "host secret", source
        assert {:error, _reason, next} = result, source
        refute Map.has_key?(next.vars, :forged)
      end
    end

    test "a string __struct__ key is ordinary data" do
      interpreter = Interpreter.new(%{}, %{}, nil)

      assert {:ok, 1, _next} =
               Interpreter.execute(interpreter, ~S|Enum.count(%{"__struct__" => "File.Stream"})|)
    end

    test "a module named as a value cannot reach a library call" do
      interpreter = Interpreter.new(%{}, %{}, nil)

      assert {:error, {:module_value_not_allowed, File.Stream}, _next} =
               Interpreter.execute(interpreter, ~S|Enum.join([:"Elixir.File.Stream"])|)
    end

    test "a library call cannot build one", %{path: path} do
      interpreter = Interpreter.new(%{}, %{}, nil)

      fields =
        ~s|path: #{inspect(path)}, modes: [:raw, :read_ahead, :binary], line_or_bytes: :line, raw: true, node: :nonode@nohost|

      stream = ~s|:"Elixir.File.Stream"|

      for source <- [
            "Enum.join(Map.put(%{#{fields}}, :__struct__, #{stream}))",
            "forged = Map.put(%{#{fields}}, :__struct__, #{stream})",
            "forged = Map.put_new(%{#{fields}}, :__struct__, #{stream})",
            "forged = Map.merge(%{#{fields}}, Map.new([{:__struct__, #{stream}}]))",
            "forged = Enum.into([__struct__: #{stream}, #{fields}], %{})",
            "forged = Map.new([__struct__: #{stream}, #{fields}])",
            "forged = Map.new(Enum.zip([:__struct__, :path], [#{stream}, #{inspect(path)}]))",
            "forged = Enum.frequencies_by([1], fn _ -> :__struct__ end)",
            "forged = Map.from_keys([:__struct__], #{stream})",
            "forged = Enum.map([1], fn _ -> Map.new([{:__struct__, #{stream}}]) end)",
            "forged = Enum.reduce([1], %{}, fn _, acc -> Map.put(acc, :__struct__, :\"Elixir.Range\") end)",
            "forged = Map.put(%{first: 1, last: :x, step: 1}, :__struct__, :\"Elixir.Range\")",
            "forged = Map.put(%{arity: 1, clauses: 1}, :__struct__, :\"Elixir.Imp.Predict.RLM.Interpreter.Fn\")",
            "forged = [Map.new([{:__struct__, #{stream}}])]"
          ] do
        result = Interpreter.execute(interpreter, source)
        refute inspect(result) =~ "host secret", source
        assert {:error, _reason, next} = result, source
        refute Map.has_key?(next.vars, :forged), source
      end
    end

    test "structs handed in by the host still reach library calls" do
      interpreter = Interpreter.new(%{ids: MapSet.new([1, 2]), span: 1..3}, %{}, nil)

      assert {:ok, [2, 3], _next} =
               Interpreter.execute(interpreter, "[Enum.count(ids), Enum.count(span)]")
    end
  end

  describe "modules and native functions" do
    # An Erlang module is an ordinary atom, so the struct and module-value
    # checks above do not see it. These two stand in for any module in the
    # VM with a `compare/2` or a `__struct__/0`.
    defmodule :imp_rlm_probe_sorter do
      def compare(_left, _right) do
        send(self(), :probe_compare_ran)
        :eq
      end

      def __struct__ do
        send(self(), :probe_struct_ran)
        %{}
      end
    end

    test "a module is never a value" do
      interpreter = Interpreter.new(%{}, %{}, nil)

      for source <- [
            "m = File",
            "Map.put(%{}, :__struct__, File.Stream)",
            "Enum.sort([2, 1], File)",
            "Access.get(File, :cwd)"
          ] do
        assert {:error, {:module_value_not_allowed, name}, next} =
                 Interpreter.execute(interpreter, source),
               source

        assert name in ["File", "File.Stream"]
        refute Map.has_key?(next.vars, :m)
      end
    end

    test "an Erlang module is not a sorter and not a struct name" do
      interpreter = Interpreter.new(%{}, %{}, nil)

      for {source, reason} <- [
            {"Enum.sort([2, 1], :imp_rlm_probe_sorter)",
             {:sorter_not_allowed, :imp_rlm_probe_sorter}},
            {"Enum.sort([2, 1], {:asc, :imp_rlm_probe_sorter})",
             {:sorter_not_allowed, {:asc, :imp_rlm_probe_sorter}}},
            {"Enum.sort_by([2, 1], fn x -> x end, :imp_rlm_probe_sorter)",
             {:sorter_not_allowed, :imp_rlm_probe_sorter}},
            {"Enum.max([2, 1], :imp_rlm_probe_sorter)",
             {:sorter_not_allowed, :imp_rlm_probe_sorter}},
            {"Enum.min_by([2, 1], fn x -> x end, :imp_rlm_probe_sorter)",
             {:sorter_not_allowed, :imp_rlm_probe_sorter}},
            {"List.keysort([{2}, {1}], 0, :imp_rlm_probe_sorter)",
             {:sorter_not_allowed, :imp_rlm_probe_sorter}},
            {"Map.from_struct(:imp_rlm_probe_sorter)",
             {:module_value_not_allowed, :imp_rlm_probe_sorter}}
          ] do
        assert {:error, ^reason, _next} = Interpreter.execute(interpreter, source), source
      end

      refute_received :probe_compare_ran
      refute_received :probe_struct_ran

      assert {:ok, [2, 1], _next} = Interpreter.execute(interpreter, "Enum.sort([1, 2], :desc)")

      assert {:ok, [1, 2], _next} =
               Interpreter.execute(interpreter, "Enum.sort([2, 1], &(&1 <= &2))")
    end

    test "a function handed to a library call does not come back as a native closure" do
      interpreter = Interpreter.new(%{}, %{}, nil)

      for source <- [
            "g = Map.get(%{}, :missing, fn x -> x end)",
            "g = Enum.reduce([], fn x -> x end, fn _x, acc -> acc end)",
            "g = List.first([], fn x -> x end)"
          ] do
        assert {:error, {:function_value_not_allowed, _message}, next} =
                 Interpreter.execute(interpreter, source),
               source

        refute Map.has_key?(next.vars, :g)
      end

      # Interpreter functions held in data are values like any other.
      assert {:ok, [%Interpreter.Fn{}], _next} =
               Interpreter.execute(interpreter, "Enum.map([1], fn _ -> fn y -> y end end)")
    end
  end

  describe "patterns" do
    test "assignment destructures tuples, lists and maps" do
      interpreter = Interpreter.new(%{row: %{"id" => 7}}, %{}, nil)

      source = ~S"""
      {a, b} = {1, 2}
      [first | rest] = ["x", "y", "z"]
      %{"id" => id} = row
      [a + b, first, rest, id]
      """

      assert {:ok, [3, "x", ["y", "z"], 7], _next} = Interpreter.execute(interpreter, source)

      assert {:error, {:no_match, "{a, b}"}, _next} =
               Interpreter.execute(interpreter, "{a, b} = [1, 2]")
    end

    test "a list is built with [item | list]" do
      interpreter = Interpreter.new(%{}, %{}, nil)

      assert {:ok, [3, 2, 1], _next} =
               Interpreter.execute(
                 interpreter,
                 "Enum.reduce([1, 2, 3], [], fn x, acc -> [x | acc] end)"
               )

      assert {:error, {:invalid_operands, :|}, _next} =
               Interpreter.execute(interpreter, "[1 | 2]")
    end

    test "a pin reads a variable the host named with a string" do
      interpreter = Interpreter.new(%{"target" => 3}, %{}, nil)

      assert {:ok, [:hit, :miss], _next} =
               Interpreter.execute(
                 interpreter,
                 "Enum.map([3, 4], fn ^target -> :hit; _ -> :miss end)"
               )
    end

    test "for takes patterns, maps, into: and uniq:, and refuses reduce:" do
      interpreter = Interpreter.new(%{counts: %{"a" => 1, "b" => 2}}, %{}, nil)

      assert {:ok, ["a", "b"], next} =
               Interpreter.execute(interpreter, "for {key, _n} <- counts, do: key")

      refute Map.has_key?(next.vars, :key)

      assert {:ok, [1], _next} =
               Interpreter.execute(interpreter, "for {:ok, v} <- [{:ok, 1}, {:error, 2}], do: v")

      assert {:ok, %{"a" => 2, "b" => 4}, _next} =
               Interpreter.execute(interpreter, "for {k, n} <- counts, into: %{}, do: {k, n * 2}")

      assert {:ok, [1, 2], _next} =
               Interpreter.execute(interpreter, "for x <- [1, 1, 2], uniq: true, do: x")

      assert {:error, {:unsupported_for_option, :reduce, _hint}, _next} =
               Interpreter.execute(
                 interpreter,
                 "for x <- [1, 2], reduce: 0 do\n acc -> acc + x\nend"
               )

      assert {:error, :struct_key_not_allowed, _next} =
               Interpreter.execute(
                 interpreter,
                 "for k <- [String.to_existing_atom(\"__struct__\")], into: %{}, do: {k, 1}"
               )
    end
  end

  describe "local calls" do
    test "the pure Kernel functions a model reaches for are allowed" do
      interpreter = Interpreter.new(%{row: %{"team" => "atlas"}, pair: {1, "b"}}, %{}, nil)

      source = ~S"""
      [elem(pair, 1), to_string(elem(pair, 0)), is_map(row), is_list(row), length([1, 2]),
       map_size(row), div(7, 2), rem(7, 2), max(3, 4), abs(-2), is_nil(nil)]
      """

      assert {:ok, ["b", "1", true, false, 2, 1, 3, 1, 4, 2, true], _next} =
               Interpreter.execute(interpreter, source)
    end

    test "calling a value that is not a function is an error the model can read" do
      interpreter = Interpreter.new(%{}, %{}, nil)

      # The name is not an atom in this VM, as a model's names usually are not.
      source = "zq_" <> "notfn = 1\nzq_" <> "notfn.(1)"
      assert {:error, reason, _next} = Interpreter.execute(interpreter, source)
      assert reason == {:not_a_function, "zq_notfn", 1}

      assert {:error, {:unsupported_expression, text}, _next} =
               Interpreter.execute(interpreter, "f = fn x -> x end\nf.(1)")

      assert text =~ "calling a function held in a variable"

      assert {:error, {:function_not_allowed, "zq_" <> "other", :call, 0}, _next} =
               Interpreter.execute(interpreter, "zq_" <> "other.call()")
    end

    test "effectful and atom-making Kernel functions stay refused" do
      interpreter = Interpreter.new(%{}, %{}, nil)

      for source <- [
            ~S|spawn(fn -> 1 end)|,
            ~S|send(1, 2)|,
            ~S|self()|,
            ~S|apply(1, 2, 3)|,
            ~S|binary_to_atom("rlm_new_atom")|,
            ~S|node()|
          ] do
        assert {:error, {:function_not_allowed, _name}, _next} =
                 Interpreter.execute(interpreter, source)
      end
    end
  end

  describe "library calls" do
    @tickets [
      %{"id" => 1, "squad" => "Billing", "priority" => "high"},
      %{"id" => 2, "squad" => "billing", "priority" => "low"},
      %{"id" => 3, "squad" => "Search", "priority" => "high"}
    ]

    test "controller code may call pure Enum, Map, List, String and Keyword functions with functions" do
      interpreter = Interpreter.new(%{tickets: @tickets}, %{}, nil)

      source = ~S"""
      high = Enum.filter(tickets, fn t -> t["priority"] == "high" end)
      pairs = Enum.zip(["a", "b"], [1, 2])
      per_squad = Enum.frequencies_by(tickets, fn t -> String.downcase(t["squad"]) end)
      ids = Enum.group_by(tickets, &String.downcase(&1["squad"]), fn %{"id" => id} -> id end)
      high_count = Enum.count(tickets, fn %{"priority" => p} -> p == "high" end)
      ranked = Enum.sort_by(per_squad, fn {_squad, n} -> n end, :desc)
      tally = Enum.reduce(tickets, %{}, fn t, acc -> Map.update(acc, t["squad"], 1, &(&1 + 1)) end)
      limit = Keyword.get([limit: 1], :limit)
      submit(%{
        high: Enum.map(high, & &1["id"]),
        pairs: pairs,
        per_squad: per_squad,
        ids: ids,
        high_count: high_count,
        top: List.first(ranked),
        tally: tally,
        limited: Enum.take(ranked, limit)
      })
      """

      assert {:final, result, _interpreter} = Interpreter.execute(interpreter, source)

      assert result == %{
               high: [1, 3],
               pairs: [{"a", 1}, {"b", 2}],
               per_squad: %{"billing" => 2, "search" => 1},
               ids: %{"billing" => [1, 2], "search" => [3]},
               high_count: 2,
               top: {"billing", 2},
               tally: %{"Billing" => 1, "billing" => 1, "Search" => 1},
               limited: [{"billing", 2}]
             }
    end

    test "functions match clauses in order, honour guards and may print" do
      interpreter = Interpreter.new(%{}, %{}, nil)

      source = ~S"""
      labels = Enum.map([1, -2, 0], fn
        n when n > 0 -> "positive"
        0 -> "zero"
        _ -> "negative"
      end)
      Enum.each(labels, fn label -> print(label <> ";") end)
      labels
      """

      assert {:ok, ["positive", "negative", "zero"], interpreter} =
               Interpreter.execute(interpreter, source)

      assert interpreter.output == "positive;negative;zero;"

      assert {:error, {:fn_clause_not_matched, [3]}, _} =
               Interpreter.execute(interpreter, "Enum.map([3], fn 0 -> 0 end)")
    end

    test "effectful, atom-creating and nondeterministic calls stay refused" do
      interpreter = Interpreter.new(%{}, %{"llm_query" => :llm_query}, nil)

      for {source, reason} <- [
            {~S|File.read("/etc/hosts")|, {:function_not_allowed, :File, :read, 1}},
            {~S|System.cmd("id", [])|, {:function_not_allowed, :System, :cmd, 2}},
            {~S|:os.cmd(~c"id")|, {:function_not_allowed, :os, :cmd, 1}},
            {~S|Process.put(:key, 1)|, {:function_not_allowed, :Process, :put, 2}},
            {~S|String.to_atom("rlm_new_atom")|, {:function_not_allowed, :String, :to_atom, 1}},
            {~S|List.to_atom([97])|, {:function_not_allowed, :List, :to_atom, 1}},
            {~S|Enum.random([1, 2])|, {:function_not_allowed, :Enum, :random, 1}},
            {~S|apply(File, :read, ["/etc/hosts"])|, {:function_not_allowed, :apply}},
            {~S|Enum.map(["a"], fn p -> llm_query(p) end)|, {:effect_inside_fn, "llm_query"}},
            {~S|Enum.map([1], fn x -> submit(%{x: x}) end)|, :submit_inside_fn}
          ] do
        assert {:error, ^reason, _} = Interpreter.execute(interpreter, source),
               "expected #{source} to be refused with #{inspect(reason)}"
      end
    end

    test "function calls, results and ranges share the step and value budgets" do
      interpreter = Interpreter.new(%{}, %{}, nil, max_steps: 50, max_value_bytes: 1_000)

      assert {:error, :step_limit_exceeded, _} =
               Interpreter.execute(interpreter, "Enum.map(1..100, fn x -> x end)")

      assert {:error, {:value_budget_exceeded, _bytes, 1_000}, _} =
               Interpreter.execute(
                 interpreter,
                 ~S|Enum.map(1..3, fn _ -> String.duplicate("a", 400) end)|
               )

      assert {:error, {:value_budget_exceeded, _bytes, 1_000}, _} =
               Interpreter.execute(interpreter, ~S|String.duplicate("a", 100_000_000)|)

      assert {:error, {:value_budget_exceeded, 1_000_000_000, 1_000}, _} =
               Interpreter.execute(interpreter, "Enum.to_list(1..1_000_000_000)")

      assert {:ok, %{"a" => [1, 2]}, _} =
               Interpreter.execute(
                 interpreter,
                 ~S|Enum.reduce([1, 2], %{}, fn x, acc -> Map.update(acc, "a", [x], &(&1 ++ [x])) end)|
               )
    end
  end
end
