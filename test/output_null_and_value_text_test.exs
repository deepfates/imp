defmodule Imp.OutputNullAndValueTextTest do
  use ExUnit.Case, async: true

  # A null answer is no value: a declared default fills it, an optional field
  # is nil, and a required field is reported missing. Values a model reads
  # take their JSON text.

  defp signature do
    Imp.Signature.new(%{
      inputs: [:question],
      outputs: [
        %{name: :answer, type: :string},
        %{name: :note, type: :string, default: "No note"},
        %{name: :count, type: :integer, default: 0},
        %{name: :tags, type: :array, default: []},
        %{name: :maybe, type: :string, optional: true}
      ]
    })
  end

  test "a null for a field with a default takes the default, for every type" do
    completion = ~s({"answer": "a", "note": null, "count": null, "tags": null, "maybe": null})

    # The JSON adapter reads the completion text; Chat reads the same values
    # as a structured (provider-parsed) output.
    for {adapter, raw} <- [
          {Imp.Adapter.JSON, completion},
          {Imp.Adapter.Chat, Jason.decode!(completion)}
        ] do
      assert {:ok, prediction} = adapter.parse(signature(), raw, [])

      assert Imp.to_map(prediction) == %{
               answer: "a",
               note: "No note",
               count: 0,
               tags: [],
               maybe: nil
             },
             inspect(adapter)
    end
  end

  test "a null for a required field is reported missing, not invalid" do
    completion = ~s({"answer": null})

    assert {:error, %Imp.AdapterParseError{kind: :missing_fields}} =
             Imp.Adapter.JSON.parse(signature(), completion, [])
  end

  test "a present non-null value still wins over the default" do
    completion = ~s({"answer": "a", "note": "", "count": 3, "tags": []})

    assert {:ok, prediction} = Imp.Adapter.JSON.parse(signature(), completion, [])
    assert Imp.get(prediction, :note) == ""
    assert Imp.get(prediction, :count) == 3
  end

  test "an ordered JSON object renders as JSON in its own order" do
    value = %Jason.OrderedObject{values: [{"z", 1}, {"a", %{"b" => nil}}]}

    assert Imp.Adapter.Chat.format_value(value) == ~s({"z": 1, "a": {"b": null}})
    assert Imp.Adapter.Chat.format_value([value]) == ~s([{"z": 1, "a": {"b": null}}])
  end

  test "a ReAct observation of an ordered JSON object is JSON" do
    tool =
      Imp.Tool.new(
        :lookup,
        "Look up.",
        fn _args -> %Jason.OrderedObject{values: [{"z", true}, {"a", nil}]} end,
        schema: %{"type" => "object", "properties" => %{}}
      )

    owner = self()
    calls = :counters.new(1, [])

    lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          :counters.add(calls, 1, 1)
          send(owner, {:messages, messages})

          if :counters.get(calls, 1) == 1,
            do: %{next_thought: "look", next_tool_name: "lookup", next_tool_args: %{}},
            else: %{
              next_thought: "done",
              next_tool_name: "finish",
              next_tool_args: %{},
              reasoning: "r",
              answer: "x"
            }
        end
      )

    agent =
      Imp.Predict.ReAct.new(Imp.signature("question -> answer"), [tool],
        mode: :dspy,
        lm: lm
      )

    _ = Imp.Predict.ReAct.call(agent, %{question: "q"})

    assert_received {:messages, _first}
    assert_received {:messages, second}
    text = Enum.map_join(second, "\n", & &1.content)
    assert text =~ ~s({"z": true, "a": null})
    refute text =~ "OrderedObject"
  end

  defmodule CapturingRuleLM do
    defstruct [:owner]

    def generate(%__MODULE__{owner: owner}, messages, _opts) do
      send(owner, {:rule_prompt, Enum.map_join(messages, "\n", & &1.content)})
      {:ok, %{reasoning: "r", natural_language_rules: "Answer exactly."}}
    end
  end

  test "InferRules shows the rule model each example's values as JSON text" do
    task_lm =
      Imp.LM.Static.new(handler: fn _messages, _opts -> %{answer: "yes", score: 1.5e6} end)

    program = Imp.predict("question, context: object -> answer, score: float", lm: task_lm)

    trainset = [
      Imp.example(question: "q", context: %{"k" => nil}, answer: "yes", score: 1.5e6)
      |> Imp.with_inputs([:question, :context])
    ]

    Imp.Optimizer.InferRules.new(fn _example, _prediction -> 1.0 end,
      rule_lm: %CapturingRuleLM{owner: self()},
      num_candidates: 1,
      num_rules: 1,
      max_bootstrapped_demos: 0,
      max_labeled_demos: 0
    )
    |> Imp.Optimizer.InferRules.compile(program, trainset, trainset)

    assert_receive {:rule_prompt, prompt}
    assert prompt =~ ~s(context: {"k": null})
    assert prompt =~ "score: 1500000.0"
    refute prompt =~ "%{"
  end
end
