defmodule Imp.TrajectoryTest do
  use ExUnit.Case, async: true

  test "real model and tool observations project with stable references and credential redaction" do
    secret = "sk-test-secret-1234567890"
    lookup = Imp.tool(:lookup, "look up", fn _ -> %{found: "beam", api_key: secret} end)

    lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          %{
            next_thought: "look it up",
            tool_calls: [
              %{id: "lookup-1", name: "lookup", arguments: %{query: "beam"}},
              %{id: "submit-1", name: "submit", arguments: %{answer: "BEAM", confidence: 1.0}}
            ]
          }
        end
      )

    {:ok, run} =
      Imp.Run.start(Imp.react_v2("question -> answer, confidence: float", [lookup], lm: lm), %{
        question: "runtime?",
        api_key: secret
      })

    assert {:ok, _} = Task.await(run.task)
    events = Imp.Run.events(run)
    Imp.Run.stop(run)
    assert Enum.count(events, &(&1.kind == :model_request)) == 1
    assert Enum.count(events, &(&1.kind == :model_response)) == 1

    document =
      Imp.Trajectory.to_atif(events,
        agent: %{name: "fixture", version: "1", extra: %{api_key: secret}}
      )

    encoded = Jason.encode!(document)
    refute encoded =~ secret
    assert encoded =~ "[REDACTED]"
    assert document["extra"]["outcome"] == "run_finished"

    assert Enum.map(document["steps"], & &1["step_id"]) ==
             Enum.to_list(1..length(document["steps"]))

    [call_step | _] = Enum.filter(document["steps"], &Map.has_key?(&1, "tool_calls"))
    [call] = call_step["tool_calls"]
    [observation] = call_step["observation"]["results"]
    assert call["tool_call_id"] == observation["source_call_id"]
    assert call["extra"]["native_tool_call_id"] == "lookup-1"
    assert call_step["llm_call_count"] == 0
    refute Enum.any?(document["steps"], &Map.has_key?(&1, "metrics"))

    if path = System.get_env("IMP_ATIF_FIXTURE_OUT"),
      do: File.write!(path, Jason.encode!(document, pretty: true))
  end

  test "cancelled unfinished calls remain unknown instead of inventing a result" do
    events = [
      %Imp.Run.Event{
        run_id: "r",
        sequence: 0,
        kind: :tool_call,
        tool_call_id: "p",
        tool_name: :post,
        input: %{text: "hello"}
      },
      %Imp.Run.Event{run_id: "r", sequence: 1, kind: :run_cancelled, error: :host_cancelled}
    ]

    doc = Imp.Trajectory.to_atif(events)
    [step | _] = doc["steps"]
    assert step["extra"]["outcome"] == "unknown"
    refute Map.has_key?(step, "observation")
    assert doc["extra"]["outcome"] == "run_cancelled"
    assert_raise ArgumentError, fn -> Imp.Trajectory.to_atif(Enum.reverse(events)) end

    assert_raise ArgumentError, fn ->
      Imp.Trajectory.to_atif([hd(events), %{List.last(events) | run_id: "other"}])
    end
  end

  test "projection keeps actual context roles, does not dump terminal predictions and accepts stored events" do
    events = [
      %Imp.Run.Event{run_id: "r", sequence: 0, kind: :run_started, input: %{question: "q"}},
      %Imp.Run.Event{
        run_id: "r",
        sequence: 1,
        kind: :model_request,
        input: [%{role: :system, content: "instructions"}, %{role: :user, content: "question"}]
      },
      %Imp.Run.Event{run_id: "r", sequence: 2, kind: :model_response, output: ["answer"]},
      %Imp.Run.Event{
        run_id: "r",
        sequence: 3,
        kind: :run_finished,
        output: %{fields: %{answer: "answer"}, internal: "prediction-dump"}
      }
    ]

    doc = events |> Enum.map(&Imp.Run.Event.to_map/1) |> Imp.Trajectory.to_atif()
    assert Enum.map(doc["steps"], & &1["source"]) == ["system", "user", "agent"]
    assert Enum.map(doc["steps"], & &1["message"]) == ["instructions", "question", "answer"]
    assert List.last(doc["steps"])["llm_call_count"] == nil
    refute Jason.encode!(doc) =~ "prediction-dump"
  end

  test "overlapping provider call IDs fail rather than attaching the wrong result" do
    call = %Imp.Run.Event{
      run_id: "r",
      sequence: 0,
      kind: :tool_call,
      tool_call_id: "same",
      tool_name: :lookup,
      input: %{}
    }

    assert_raise ArgumentError, ~r/overlapping/, fn ->
      Imp.Trajectory.to_atif([call, %{call | sequence: 1}])
    end

    events = [
      call,
      %Imp.Run.Event{
        run_id: "r",
        sequence: 1,
        kind: :tool_result,
        tool_call_id: "same",
        output: "first"
      },
      %{call | sequence: 2}
    ]

    [first, second] = Imp.Trajectory.to_atif(events)["steps"]
    refute hd(first["tool_calls"])["tool_call_id"] == hd(second["tool_calls"])["tool_call_id"]
    assert second["extra"]["outcome"] == "unknown"
  end
end
