defmodule ProgramOfThoughtFidelityTest do
  # async: false — this module mutates the global Imp.Settings Agent in setup;
  # running it concurrently would race that shared state with other async
  # modules (e.g. the BootstrapFewShot trajectory suite reads global defaults).
  # See dee-fqsr.
  use ExUnit.Case, async: false

  setup do
    Imp.configure(lm: nil, adapter: Imp.Adapter.Chat, retriever: nil)
    on_exit(&Imp.Settings.reset/0)
    :ok
  end

  test "ProgramOfThought regenerates failed code with the previous source and error" do
    owner = self()

    lm =
      static_sequence(owner, [
        %{program: "```elixir\nSystem.cmd(\"false\", [])\n```"},
        %{program: "x * 2"}
      ])

    program = Imp.program_of_thought("x: int -> answer: int", lm: lm, max_iters: 2)

    assert {:ok, prediction} = Imp.call(program, %{x: 21})
    assert Imp.Prediction.get(prediction, :answer) == 42

    assert [failed_messages, retry_messages] = collect_messages(2)
    refute rendered(failed_messages) =~ "previous program"
    assert rendered(retry_messages) =~ "previous_program"
    assert rendered(retry_messages) =~ "System.cmd"
    assert rendered(retry_messages) =~ "unsafe_ast"

    assert [failed, succeeded] = prediction.metadata.program_of_thought_trajectory
    assert failed.iteration == 1
    assert match?({:error, {:unsafe_ast, _}}, failed.output)
    assert succeeded == %{iteration: 2, action: :program, input: "x * 2", output: {:ok, 42}}
  end

  test "ProgramOfThought rejects malformed input pairs before calling the planner" do
    owner = self()
    lm = static_sequence(owner, [%{program: "1 + 1"}])
    program = Imp.program_of_thought("x -> answer", lm: lm)

    assert {:error, {:invalid_predict_inputs, "expected inputs as {key, value} pairs"}} =
             Imp.call(program, [:not_a_pair])

    refute_received {:lm_messages, _messages}
  end

  test "ProgramOfThought extracts declared outputs when code output is intermediate" do
    owner = self()

    lm =
      static_sequence(owner, [
        %{program: ~s(%{sum: x + y})},
        %{answer: 5, explanation: "computed in the sandbox"}
      ])

    program =
      Imp.program_of_thought("x: int, y: int -> answer: int, explanation: string", lm: lm)

    assert {:ok, prediction} = Imp.call(program, %{x: 2, y: 3})
    assert Imp.Prediction.get(prediction, :answer) == 5
    assert Imp.Prediction.get(prediction, :explanation) == "computed in the sandbox"

    assert [_generation, extraction] = collect_messages(2)
    extraction_prompt = rendered(extraction)
    assert extraction_prompt =~ "final_generated_program"
    assert extraction_prompt =~ "code_output"
    assert extraction_prompt =~ "sum"
  end

  test "ProgramOfThought extracts a type-invalid scalar instead of bypassing the signature" do
    owner = self()

    lm =
      static_sequence(owner, [
        %{program: ~s("forty-two")},
        %{answer: 42}
      ])

    program = Imp.program_of_thought("question -> answer: int", lm: lm)

    assert {:ok, prediction} = Imp.call(program, %{question: "value"})
    assert Imp.Prediction.get(prediction, :answer) == 42
    assert length(collect_messages(2)) == 2
  end

  test "ProgramOfThought exhausts exactly max_iters and preserves the sandbox error contract" do
    owner = self()
    lm = static_sequence(owner, List.duplicate(%{program: "missing + 1"}, 3))
    program = Imp.program_of_thought("x -> answer", lm: lm, max_iters: 3)

    assert {:error, {:unknown_variable, "missing"}} = Imp.call(program, %{x: 1})
    assert length(collect_messages(3)) == 3
    refute_received {:lm_messages, _messages}
  end

  test "ProgramOfThought regenerates malformed non-string planner output within the same budget" do
    owner = self()

    lm =
      static_sequence(owner, [
        %{program: %{not: "source"}},
        %{program: "x + 1"}
      ])

    program = Imp.program_of_thought("x -> answer", lm: lm, max_iters: 2)

    assert {:ok, prediction} = Imp.call(program, %{x: 1})
    assert Imp.Prediction.get(prediction, :answer) == 2

    [_initial, retry] = collect_messages(2)
    assert rendered(retry) =~ "invalid_generated_program"
    assert rendered(retry) =~ "%{not: \"source\"}"
  end

  test "ProgramOfThought keeps a custom regeneration budget through portable save and load" do
    owner = self()
    lm = static_sequence(owner, List.duplicate(%{program: "missing + 1"}, 2))

    loaded =
      "x -> answer"
      |> Imp.program_of_thought(lm: lm, max_iters: 2)
      |> Imp.dump()
      |> Imp.load()
      |> Imp.with_lm(lm)

    assert {:error, {:unknown_variable, "missing"}} = Imp.call(loaded, %{x: 1})
    assert length(collect_messages(2)) == 2
    refute_received {:lm_messages, _messages}
  end

  test "CodeAct feeds parse and execution failures back through its ordered trajectory" do
    owner = self()

    lm =
      static_sequence(owner, [
        %{program: ""},
        %{program: "observation + 1"},
        %{program: "1 + 1"}
      ])

    program = Imp.code_act("question -> answer", [], lm: lm, max_iters: 3)

    assert {:ok, prediction} = Imp.call(program, %{question: "recover"})

    assert Enum.map(prediction.metadata.code_act_trace, & &1.iteration) == [1, 2, 3]

    assert Enum.map(prediction.metadata.code_act_trace, & &1.action) == [
             :program,
             :program,
             :program
           ]

    assert match?(
             {:error, :missing_program},
             Enum.at(prediction.metadata.code_act_trace, 0).output
           )

    assert match?(
             {:error, {:program_runtime_error, "bad argument in arithmetic expression"}},
             Enum.at(prediction.metadata.code_act_trace, 1).output
           )

    [_first, second, third] = collect_messages(3)
    assert rendered(second) =~ "missing_program"
    assert rendered(third) =~ "program_runtime_error"
  end

  test "CodeAct honors finished and extracts signature outputs from the trajectory" do
    owner = self()

    lm =
      static_sequence(owner, [
        %{program: ~s(%{raw: x * 2}), finished: true},
        %{answer: 12}
      ])

    program = Imp.code_act("x: int -> answer: int", [], lm: lm, max_iters: 2)

    assert {:ok, prediction} = Imp.call(program, %{x: 6})
    assert Imp.Prediction.get(prediction, :answer) == 12

    assert [%{action: :program, output: {:ok, %{"raw" => 12}}}] =
             prediction.metadata.code_act_trace

    [_planner, extractor] = collect_messages(2)
    assert rendered(extractor) =~ "trajectory"
    assert rendered(extractor) =~ "raw"
  end

  test "CodeAct continues on finished false and extracts after its bounded final turn" do
    owner = self()

    lm =
      static_sequence(owner, [
        %{program: "x + 1", finished: false},
        %{program: "observation * 2", finished: false},
        %{answer: 8}
      ])

    program = Imp.code_act("x: int -> answer: int", [], lm: lm, max_iters: 2)

    assert {:ok, prediction} = Imp.call(program, %{x: 3})
    assert Imp.Prediction.get(prediction, :answer) == 8
    assert Enum.map(prediction.metadata.code_act_trace, & &1.output) == [{:ok, 4}, {:ok, 8}]
    assert length(collect_messages(3)) == 3
  end

  test "CodeAct honors an invocation-local max_iters budget and strips it from planner inputs" do
    owner = self()

    lm =
      static_sequence(owner, [
        %{program: "x + 1", finished: false},
        %{answer: 4}
      ])

    program = Imp.code_act("x: int -> answer: int", [], lm: lm, max_iters: 4)

    assert {:ok, prediction} = Imp.call(program, %{x: 3, max_iters: 1})
    assert Imp.Prediction.get(prediction, :answer) == 4

    [planner, _extractor] = collect_messages(2)
    refute rendered(planner) =~ "max_iters"
    refute_received {:lm_messages, _messages}
  end

  test "CodeAct validates an invocation-local max_iters budget before calling the planner" do
    owner = self()
    lm = static_sequence(owner, [%{program: "1 + 1"}])
    program = Imp.code_act("question -> answer", [], lm: lm)

    assert {:error, {:invalid_code_act_max_iters, -1}} =
             Imp.call(program, %{question: "q", max_iters: -1})

    refute_received {:lm_messages, _messages}
  end

  defp static_sequence(owner, outputs) do
    key = make_ref()
    Process.put(key, outputs)

    %{
      module: Imp.LM.Static,
      opts: [
        handler: fn messages, _opts ->
          send(owner, {:lm_messages, messages})
          [output | rest] = Process.get(key)
          Process.put(key, rest)
          output
        end
      ]
    }
  end

  defp collect_messages(count) do
    Enum.map(1..count, fn _ ->
      assert_receive {:lm_messages, messages}
      messages
    end)
  end

  defp rendered(messages) do
    messages
    |> Enum.map(&Map.get(&1, :content, ""))
    |> Enum.map(fn content -> if is_binary(content), do: content, else: inspect(content) end)
    |> Enum.join("\n")
  end
end
