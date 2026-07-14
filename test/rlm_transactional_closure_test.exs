defmodule Imp.Predict.RLM.TransactionalClosureTest do
  use ExUnit.Case, async: true

  alias Imp.Predict.RLM.Interpreter
  alias Imp.Predict.RLM.Trace

  test "completed effects replay by occurrence after a failed turn" do
    interpreter = Interpreter.new(%{}, %{"effect" => :effect}, nil)
    failed_source = ~S|[effect("same"), effect("same"), missing()]|

    assert {:effect, request, continuation} = Interpreter.execute(interpreter, failed_source)
    assert request.arguments == ["same"]

    assert {:effect, request, continuation} = Interpreter.resume(continuation, {:ok, "first"})
    assert request.arguments == ["same"]

    assert {:error, {:function_not_allowed, :missing}, interpreter} =
             Interpreter.resume(continuation, {:ok, "second"})

    repair_source = ~S|[effect("same"), effect("same")]|

    assert {:ok, ["first", "second"], interpreter} =
             Interpreter.execute(interpreter, repair_source)

    assert interpreter.effect_journal == []

    assert {:effect, _request, _continuation} =
             Interpreter.execute(interpreter, ~S|effect("same")|)
  end

  test "an effect executed before a repair error runs at most once" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    tool =
      Imp.tool(:once, "count one externally visible call", fn _arguments ->
        Agent.get_and_update(calls, fn count -> {count + 1, count + 1} end)
      end)

    actions = [
      %{code: ~S|value = once(%{})
missing()|},
      %{code: ~S|submit(%{wrong: once(%{})})|},
      %{code: ~S|submit(%{answer: once(%{})})|}
    ]

    rlm = rlm_with_actions(actions, tools: [tool], max_iterations: 3)

    assert {:ok, prediction} = Imp.Predict.RLM.call(rlm, %{question: "q"})
    assert Imp.Prediction.get(prediction, :answer) == "1"
    assert Agent.get(calls, & &1) == 1

    assert Enum.map(prediction.metadata.rlm_trace, & &1.action) == [
             :run_error,
             :submit_error,
             :submit
           ]
  end

  test "loaded values replace lazy handles in the synchronized namespace" do
    {:ok, loads} = Agent.start_link(fn -> 0 end)

    context =
      Imp.rlm_serializable(:context, fn ->
        Agent.update(loads, &(&1 + 1))
        "authoritative"
      end)

    actions = [
      %{code: ~S|context = load("context")
missing()|},
      %{code: ~S|submit(%{answer: context})|}
    ]

    rlm =
      rlm_with_actions(actions,
        signature: "question, context -> answer",
        max_iterations: 2
      )

    assert {:ok, prediction} =
             Imp.Predict.RLM.call(rlm, %{question: "q", context: context})

    assert Imp.Prediction.get(prediction, :answer) == "authoritative"
    assert Agent.get(loads, & &1) == 1
    assert Enum.map(prediction.metadata.rlm_trace, & &1.action) == [:run_error, :submit]
  end

  test "oversized trace terms compact deterministically without term serialization" do
    oversized = Enum.map(1..20_000, &%{index: &1, value: String.duplicate("x", 32)})

    compacted = Trace.compact(oversized, 256)

    assert compacted == Trace.compact(oversized, 256)
    assert compacted.type == :list
    assert compacted.truncated
    assert byte_size(compacted.sha256) == 64
    assert :erlang.external_size(compacted) < 256

    trace_source =
      Path.expand("../lib/imp/predict/rlm/trace.ex", __DIR__)
      |> File.read!()

    refute trace_source =~ "term_" <> "to_binary"
  end

  defp rlm_with_actions(actions, opts) do
    {:ok, actions} = Agent.start_link(fn -> actions end)
    {signature, opts} = Keyword.pop(opts, :signature, "question -> answer")

    lm = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn _messages, _opts ->
          Agent.get_and_update(actions, fn [action | rest] -> {action, rest} end)
        end
      ]
    }

    Imp.Predict.RLM.new(signature, Keyword.put(opts, :lm, lm))
  end
end
