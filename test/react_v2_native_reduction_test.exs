defmodule ReActV2NativeReductionTest do
  use ExUnit.Case, async: true

  # Every request a native step makes is formatted from the step signature
  # without its `tools` input and `tool_calls` output: the n > 1 fallback, the
  # response-format schema built from the signature, and a program saved by
  # 0.5.0, whose step signature predates both.

  defmodule TextOnlyLM do
    @behaviour Imp.LM
    defstruct [:handler]

    @impl true
    def generate(%__MODULE__{handler: handler}, messages, opts),
      do: {:ok, handler.(messages, opts)}

    def tool_calling_capability(%__MODULE__{}), do: false
  end

  defp look, do: Imp.tool(:look, "Look at a thing", fn _ -> %{"seen" => [1]} end)

  defp handler(replies) do
    owner = self()
    counter = :counters.new(1, [])

    fn messages, opts ->
      :counters.add(counter, 1, 1)
      send(owner, {:request, messages, opts})
      Enum.at(replies, :counters.get(counter, 1) - 1, List.last(replies))
    end
  end

  defp requests(acc \\ []) do
    receive do
      {:request, messages, opts} -> requests([{messages, opts} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp text(messages), do: Enum.map_join(messages, "\n", &to_string(&1.content))

  test "the n > 1 JSON fallback of a native step describes no tool fields" do
    step = Imp.react("intent -> answer", [look()]).react

    lm =
      Imp.LM.Static.new(
        handler: handler(["[[ ## tool_calls ## ]]\nnot a list", ~s({"answer": "done."})])
      )

    step = %{step | lm: lm, dynamic_lm?: false, config: Keyword.put(step.config, :n, 2)}

    assert {:ok, _prediction} =
             Imp.Predict.call(step, %{
               intent: "what?",
               history: Imp.History.new([]),
               tools: ["look"]
             })

    sent = requests()
    assert length(sent) == 4
    [_, _, {fallback, opts}, _] = sent
    assert fallback |> hd() |> Map.get(:content) =~ "Outputs will be a JSON object"
    assert Enum.map(opts[:tools], & &1.function.name) == ["look"]
    refute text(fallback) =~ "tool_calls"
  end

  test "a JSON-schema response format is built from what the step describes" do
    for {adapter, replies} <- [
          {Imp.Adapter.JSON, [~s({"answer": "done."})]},
          {Imp.Adapter.Chat, ["[[ ## tool_calls ## ]]\nnot a list", ~s({"answer": "done."})]}
        ] do
      agent =
        Imp.react("intent -> answer", [look()],
          lm: Imp.LM.Static.new(handler: handler(replies)),
          adapter: adapter,
          config: [native_json_schema: true]
        )

      assert {:ok, _prediction} = Imp.call(agent, %{intent: "what?"})
      {_messages, opts} = List.last(requests())
      schema = opts[:response_format].json_schema.schema
      assert Map.keys(schema["properties"]) == ["answer"], inspect(adapter)
    end
  end

  describe "a ReActV2 saved by 0.5.0" do
    setup do
      registry = Imp.Saving.Registry.new(roster_runner: fn _args -> %{"ok" => true} end)

      program =
        "test/fixtures/react_v2_saved_0_5_0.json"
        |> File.read!()
        |> Jason.decode!()
        |> Imp.load!(registry: registry)

      %{program: program}
    end

    test "leaves the tool fields out for a native LM", %{program: program} do
      lm = Imp.LM.Static.new(handler: handler(["done."]))
      assert {:ok, _} = Imp.context([lm: lm], fn -> Imp.call(program, %{intent: "hi"}) end)
      [{messages, opts}] = requests()
      assert Enum.map(opts[:tools], & &1.function.name) == ["alpha_probe", "zeta_probe"]
      refute text(messages) =~ "tool_calls"
      refute text(messages) =~ "whose description is"
    end

    test "lists its tools for an LM that cannot call them", %{program: program} do
      lm = %TextOnlyLM{handler: handler(["done."])}
      assert {:ok, _} = Imp.context([lm: lm], fn -> Imp.call(program, %{intent: "hi"}) end)
      [{messages, opts}] = requests()
      assert opts[:tools] in [nil, []]
      assert text(messages) =~ "[[ ## tool_calls ## ]]"
      assert text(messages) =~ "alpha_probe, whose description is <desc>A</desc>."
      assert text(messages) =~ ~s(Example: [{"name": "search", "arguments": {"query": "cats"}}])
    end
  end

  @reserved "`tools` is reserved for the step's tool list; rename that field"

  test "a task field named tools is refused, on construction and on load" do
    assert_raise ArgumentError, "Imp.Predict.ReActV2.new/3: " <> @reserved, fn ->
      Imp.react("question, tools: array[str] -> answer", [look()])
    end

    assert_raise ArgumentError, "Imp.Predict.ReActV2.new/3: " <> @reserved, fn ->
      Imp.react("question -> answer, tools", [look()])
    end

    # A 0.5.0 save of an agent whose task has its own `tools` input.
    registry = Imp.Saving.Registry.new(roster_runner: fn _args -> %{"ok" => true} end)
    state = "test/fixtures/react_v2_saved_0_5_0.json" |> File.read!() |> Jason.decode!()

    field = %{
      "desc" => nil,
      "kind" => "input",
      "metadata" => %{},
      "name" => "tools",
      "prefix" => "Tools:",
      "type" => "array"
    }

    state =
      state
      |> update_in(["signature", "inputs"], &(&1 ++ [field]))
      |> update_in(["react", "signature", "inputs"], &(&1 ++ [field]))

    error = assert_raise ArgumentError, fn -> Imp.load!(state, registry: registry) end
    assert Exception.message(error) =~ "loading a ReActV2 program: " <> @reserved
  end
end
