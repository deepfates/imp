defmodule Imp.ParallelExecutionTest do
  use ExUnit.Case, async: true

  alias Imp.Predict.Parallel

  defmodule ParentProgram do
    @behaviour Imp.Module
    defstruct [:pairs]

    @impl true
    def call(%__MODULE__{pairs: pairs}, _inputs) do
      {:ok, Imp.Prediction.new(results: Parallel.run(pairs, num_threads: 2))}
    end
  end

  test "runs heterogeneous and nested program/input pairs without losing shape" do
    question = static_program("question -> answer", "question")
    topic = static_program("topic -> answer", "topic")

    assert [question_result, [topic_result, second_question_result]] =
             Imp.parallel(
               [
                 {question, %{question: "one"}},
                 [
                   {topic, %{topic: "two"}},
                   {question, %{question: "three"}}
                 ]
               ],
               num_threads: 2
             )

    assert {:ok, question_prediction} = question_result
    assert {:ok, topic_prediction} = topic_result
    assert {:ok, second_question_prediction} = second_question_result
    assert Imp.get(question_prediction, :answer) == "question:one"
    assert Imp.get(topic_prediction, :answer) == "topic:two"
    assert Imp.get(second_question_prediction, :answer) == "question:three"
  end

  test "keeps one invalid program local to its result slot" do
    program = static_program("question -> answer", "question")

    assert [{:ok, prediction}, {:error, {:not_callable, %{}}}, {:ok, second_prediction}] =
             Parallel.run([
               {program, %{question: "one"}},
               {%{}, %{question: "bad"}},
               {program, %{question: "three"}}
             ])

    assert Imp.get(prediction, :answer) == "question:one"
    assert Imp.get(second_prediction, :answer) == "question:three"
  end

  test "rejects malformed pair trees before starting work" do
    assert_raise ArgumentError, ~r/expected \{program, inputs\}.*\[1, 0\]/, fn ->
      Parallel.run([{static_program("question -> answer", "question"), %{}}, [123]])
    end
  end

  test "parallel children inherit the enclosing module call lineage" do
    caller = self()
    handler_id = "parallel-lineage-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:imp, :module, :start],
        fn _event, _measurements, metadata, pid -> send(pid, {:module_start, metadata}) end,
        caller
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    parent = %ParentProgram{
      pairs: [
        {static_program("question -> answer", "question"), %{question: "one"}},
        {static_program("topic -> answer", "topic"), %{topic: "two"}}
      ]
    }

    assert {:ok, %Imp.Prediction{}} = Imp.call(parent, %{})

    # Telemetry handlers are global. Collect the events already delivered by
    # this completed call, then correlate by its parent call ID so unrelated
    # async tests cannot be mistaken for one of these children.
    metadata = collect_module_starts([])
    parent_metadata = Enum.find(metadata, &(&1.module == ParentProgram))

    assert is_binary(parent_metadata.call_id)
    assert parent_metadata.parent_call_id == nil

    child_metadata =
      Enum.filter(
        metadata,
        &(&1.module == Imp.Predict and
            &1.parent_call_id == parent_metadata.call_id)
      )

    assert length(child_metadata) == 2
    assert child_metadata |> Enum.map(& &1.call_id) |> Enum.uniq() |> length() == 2
  end

  defp static_program(signature, input_name) do
    Imp.predict(signature,
      lm:
        Imp.LM.Static.new(
          handler: fn messages, _opts ->
            prompt = Enum.map_join(messages, "\n", &Map.fetch!(&1, :content))

            [value] =
              ~r/\[\[ ## #{input_name} ## \]\]\n([^\n]+)/
              |> Regex.scan(prompt, capture: :all_but_first)
              |> List.last()

            %{answer: "#{input_name}:#{value}"}
          end
        )
    )
  end

  defp collect_module_starts(acc) do
    receive do
      {:module_start, metadata} -> collect_module_starts([metadata | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
