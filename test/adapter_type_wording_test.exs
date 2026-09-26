defmodule Imp.AdapterTypeWordingTest do
  use ExUnit.Case, async: true

  # Prompts name types in neutral words; no adapter shows a model a
  # programming language's type spelling (`decisions.md`).

  @router "ticket -> team: enum[atlas,harbor,beacon,quill]"

  @typed "question, tags: array[string] -> count: integer, ok: boolean, score: float, " <>
           "labels: array[string], grid: array[array[integer]], meta: object, when: datetime, answer"

  @python ~r/Python|Literal\[|\((str|int|float|bool)\)|list\[|dict\[|Code_|single (int|float) value|True or False/

  test "the router's enum is named as its members in every adapter" do
    signature = Imp.signature(@router, "Route the ticket.")
    inputs = %{ticket: "Refund attempts fail with a gateway timeout error."}

    for adapter <- [Imp.Adapter.Chat, Imp.Adapter.JSON, Imp.Adapter.XML, Imp.Adapter.TwoStep] do
      text = adapter |> apply(:format, [signature, inputs, []]) |> text()
      assert text =~ "1. `ticket` (string):", inspect(adapter)
      assert text =~ "1. `team` (one of: atlas, harbor, beacon, quill):", inspect(adapter)
      refute text =~ @python, inspect(adapter)
    end

    chat = signature |> Imp.Adapter.Chat.format(inputs, []) |> text()

    assert chat =~
             "{team}        # note: the value you produce must exactly match (no extra characters) one of: atlas; harbor; beacon; quill"

    assert chat =~
             "starting with the field `[[ ## team ## ]]` (must be formatted as one of: atlas, harbor, beacon, quill), and then"

    json = signature |> Imp.Adapter.JSON.format(inputs, []) |> text()

    assert json =~
             "Respond with a JSON object in the following order of fields: `team` (must be formatted as one of: atlas, harbor, beacon, quill)."

    single = signature |> Imp.Adapter.SingleField.format(inputs, []) |> text()
    assert single =~ "- ticket (string)"
    assert single =~ "Output value: team (one of: atlas, harbor, beacon, quill)"
  end

  test "every type is named in words, in the order the signature declares" do
    signature = Imp.signature(@typed, "Typed.")
    inputs = %{question: "q?", tags: ["a"]}

    for adapter <- [Imp.Adapter.Chat, Imp.Adapter.JSON, Imp.Adapter.XML, Imp.Adapter.TwoStep] do
      text = adapter |> apply(:format, [signature, inputs, []]) |> text()
      refute text =~ @python, inspect(adapter)

      assert text =~
               """
               1. `count` (integer):\s
               2. `ok` (true or false):\s
               3. `score` (number):\s
               4. `labels` (list of strings):\s
               5. `grid` (list of lists of integers):\s
               6. `meta` (object):\s
               7. `when` (ISO 8601 date and time):\s
               8. `answer` (string):
               """
               |> String.trim_trailing(),
             inspect(adapter)
    end

    chat = signature |> Imp.Adapter.Chat.format(inputs, []) |> text()
    assert chat =~ "{count}        # note: the value you produce must be a single integer"
    assert chat =~ "{ok}        # note: the value you produce must be true or false"
    assert chat =~ "{score}        # note: the value you produce must be a single number"

    assert chat =~
             "`[[ ## count ## ]]` (must be formatted as an integer), then `[[ ## ok ## ]]` (must be formatted as true or false), " <>
               "then `[[ ## score ## ]]` (must be formatted as a number), then `[[ ## labels ## ]]` (must be formatted as a list of strings), " <>
               "then `[[ ## grid ## ]]` (must be formatted as a list of lists of integers), then `[[ ## meta ## ]]` (must be formatted as an object), " <>
               "then `[[ ## when ## ]]` (must be formatted as an ISO 8601 date and time), then `[[ ## answer ## ]]`, and then"
  end

  test "a code field names its language, not a class" do
    signature =
      Imp.Signature.new(%{
        inputs: [:question],
        outputs: [%{name: :code, type: :code, language: "elixir"}]
      })

    for adapter <- [Imp.Adapter.Chat, Imp.Adapter.JSON, Imp.Adapter.XML] do
      text = adapter |> apply(:format, [signature, %{question: "q"}, []]) |> text()

      assert text =~
               "1. `code` (code in elixir): \n    Type description: Code represented in a string"

      refute text =~ @python
    end
  end

  test "ReAct's DSPy-shaped mode shows tool arguments as JSON" do
    tool =
      Imp.Tool.new(:lookup, "Look up.", fn _args -> "ok" end,
        schema: %{"type" => "object", "properties" => %{"id" => %{"type" => "string"}}}
      )

    me = self()

    lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          send(me, {:messages, messages})

          %{
            next_thought: "t",
            next_tool_name: "finish",
            next_tool_args: %{},
            reasoning: "r",
            team: "atlas"
          }
        end
      )

    agent = Imp.Predict.ReAct.new(Imp.signature(@router), [tool], mode: :dspy_3_2_1, lm: lm)
    _ = Imp.Predict.ReAct.call(agent, %{ticket: "t"})

    assert_received {:messages, messages}
    text = text(messages)
    assert text =~ ~s(It takes arguments {"id": {"type": "string"}}.)
    assert text =~ "`next_tool_name` (one of: lookup, finish)"
    assert text =~ "`next_tool_args` (object)"
    refute text =~ @python
  end

  test "the MIPROv2 dataset summary shows an example as JSON inputs and outputs" do
    example =
      Imp.example(%{
        "text" => "request-0",
        "route" => "K11",
        "ok" => true,
        "missing" => nil,
        "meta" => %Jason.OrderedObject{values: [{"z", [1, 2.5e-5]}, {"a", "can't \"say\""}]}
      })
      |> Imp.with_inputs("text")

    assert Imp.Optimizer.MIPROv2.UpstreamProposer.example_json(example) ==
             ~s({"inputs": {"text": "request-0"}, "outputs": {"meta": {"z": [1, 2.5e-05], "a": "can't \\"say\\""}, "missing": null, "ok": true, "route": "K11"}})
  end

  test "a non-string answer for a string field is kept as its JSON text" do
    signature = Imp.signature("question -> a, b")

    assert {:ok, prediction} =
             Imp.Adapter.JSON.parse(signature, ~s({"a": true, "b": ["x","y"]}), [])

    assert Imp.get(prediction, :a) == "true"
    assert Imp.get(prediction, :b) == ~s(["x", "y"])
  end

  defp text(messages) do
    Enum.map_join(messages, "\n", fn %{content: content} ->
      if is_binary(content), do: content, else: inspect(content)
    end)
  end
end
