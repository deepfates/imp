defmodule ToolSchemaRuntimeTest do
  use ExUnit.Case, async: false

  alias Imp.Predict.Avatar.ActionOutput

  test "ordinary and MCP tools share pre-handler JSON Schema validation" do
    parent = self()
    tool = schema_tool(parent)

    assert {:error, {:missing_required, ["query"]}} = Imp.Tool.call(tool, %{})

    assert {:error,
            {:schema_validation, [%{field: "query", rule: :type, message: "expected string"}]}} =
             Imp.Tool.call(tool, %{query: 7})

    assert {:error,
            {:schema_validation, [%{field: :input, rule: :type, message: "expected object"}]}} =
             Imp.Tool.call(tool, "not an argument object")

    refute_received {:schema_tool_called, _input}
    assert "found beam" = Imp.Tool.call(tool, %{query: "beam"})
    assert_received {:schema_tool_called, %{query: "beam"}}

    untyped = Imp.Tool.new(:untyped, "untyped", fn input -> input end)
    assert "unchanged" = Imp.Tool.call(untyped, "unchanged")

    [mcp_tool] =
      Imp.MCP.import_tools([
        %{
          name: :mcp_lookup,
          description: "lookup",
          inputSchema: schema(),
          run: fn input -> send(parent, {:mcp_tool_called, input}) end
        }
      ])

    assert {:error, {:missing_required, ["query"]}} = Imp.Tool.call(mcp_tool, %{})
    refute_received {:mcp_tool_called, _input}
  end

  test "ReAct surfaces validation errors without invoking the tool" do
    parent = self()

    lm =
      static_lm(fn _messages ->
        %{tool_calls: [%{name: "lookup", arguments: %{}}]}
      end)

    react = Imp.react("question -> answer", [schema_tool(parent)], lm: lm, max_iters: 1)

    assert {:error, {:missing_required, ["query"]}} = Imp.call(react, %{question: "q"})
    refute_received {:schema_tool_called, _input}
  end

  test "ReActV2 records validation errors and permits a later answer" do
    parent = self()
    {:ok, turns} = Agent.start_link(fn -> 0 end)

    lm =
      static_lm(fn _messages ->
        Agent.get_and_update(turns, fn
          0 -> {%{tool_calls: [%{name: "lookup", arguments: %{}}]}, 1}
          _ -> {"recovered", 2}
        end)
      end)

    react = Imp.react_v2("question -> answer", [schema_tool(parent)], lm: lm, max_iters: 2)

    assert {:ok, prediction} = Imp.call(react, %{question: "q"})
    assert Imp.get(prediction, :answer) == "recovered"
    assert %Imp.History{messages: [first, _second]} = prediction.metadata[:history]

    assert [%{error: true, result: {:error, {:missing_required, ["query"]}}}] =
             first.tool_call_results

    refute_received {:schema_tool_called, _input}
  end

  test "Avatar records validation errors as recoverable action observations" do
    parent = self()

    lm =
      static_lm(fn messages ->
        prompt = Enum.map_join(messages, "\n", & &1.content)

        cond do
          prompt =~ "Do not request another tool." -> %{answer: "recovered"}
          prompt =~ "missing_required" -> finish_action()
          true -> %{action: %{tool_name: "lookup", tool_input_query: %{}}}
        end
      end)

    avatar = Imp.avatar("question -> answer", [schema_tool(parent)], lm: lm, max_iters: 2)

    assert {:ok, prediction} = Imp.call(avatar, %{question: "q"})
    assert Imp.get(prediction, :answer) == "recovered"

    assert [
             %ActionOutput{
               tool_output: {:error, {:missing_required, ["query"]}},
               error?: true
             }
           ] = Imp.get(prediction, :actions)

    refute_received {:schema_tool_called, _input}
  end

  test "CodeAct returns its structured tool error for invalid arguments" do
    parent = self()

    lm = static_lm(fn _messages -> %{tool: "lookup", arguments: %{}} end)

    code_act =
      Imp.code_act("question -> answer", [schema_tool(parent)], lm: lm, max_iters: 1)

    assert {:error,
            {:code_act_tool_error, {:missing_required, ["query"]},
             [%{action: :tool, output: {:error, {:missing_required, ["query"]}}}]}} =
             Imp.call(code_act, %{question: "q"})

    refute_received {:schema_tool_called, _input}
  end

  test "RLM feeds invalid tool arguments back for controller repair" do
    parent = self()
    {:ok, turns} = Agent.start_link(fn -> 0 end)

    lm =
      static_lm(fn _messages ->
        Agent.get_and_update(turns, fn
          0 -> {%{code: ~S|lookup(%{})|}, 1}
          _ -> {%{code: ~S|submit(%{answer: "recovered"})|}, 2}
        end)
      end)

    rlm =
      Imp.rlm("question -> answer",
        lm: lm,
        tools: [schema_tool(parent)],
        max_iterations: 2
      )

    assert {:ok, prediction} = Imp.call(rlm, %{question: "q"})
    assert Imp.get(prediction, :answer) == "recovered"

    assert [
             %{
               action: :run_error,
               output: {:error, {:rlm_tool_error, {:missing_required, ["query"]}}}
             },
             %{action: :submit}
           ] = prediction.metadata.rlm_trace

    refute_received {:schema_tool_called, _input}
  end

  defp schema_tool(parent) do
    Imp.Tool.new(
      :lookup,
      "lookup",
      fn input ->
        send(parent, {:schema_tool_called, input})
        "found #{input[:query] || input["query"]}"
      end,
      schema: schema()
    )
  end

  defp schema do
    %{
      "type" => "object",
      "properties" => %{"query" => %{"type" => "string"}},
      "required" => ["query"]
    }
  end

  defp static_lm(handler) do
    %{
      module: Imp.LM.Static,
      opts: [handler: fn messages, _opts -> handler.(messages) end]
    }
  end

  defp finish_action, do: %{action: %{tool_name: "Finish", tool_input_query: %{}}}

  # A tool's name is the value it was given. A string that happens to name an
  # atom already loaded in the VM (`"ok"` always does) stays a string, so the
  # type of a name never depends on what else is running.
  test "a tool keeps the type of the name it was given" do
    assert Imp.Tool.new("ok", "d", fn _ -> :ok end).name == "ok"
    assert Imp.Tool.new(:ok, "d", fn _ -> :ok end).name == :ok
  end

  test "an imported MCP tool is named by the string the server published" do
    catalog = [
      %{
        name: "ok",
        description: "d",
        input_schema: %{"type" => "object"},
        run: fn _ -> :ok end
      },
      %{
        name: "never_an_atom_#{System.unique_integer([:positive])}",
        description: "d",
        input_schema: %{"type" => "object"},
        run: fn _ -> :ok end
      }
    ]

    assert Enum.all?(Imp.MCP.import_tools(catalog), &is_binary(&1.name))
  end
end
