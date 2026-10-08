defmodule Imp.TrajectoryTest do
  use ExUnit.Case, async: true

  defmodule ScriptedLM do
    # Answers like a provider client: the visible text and tool calls are the
    # output, and its own reasoning, usage and charge are response metadata.
    defstruct [:owner, model: "test:model"]

    def generate(%__MODULE__{owner: owner}, messages, opts) do
      send(owner, {:request, messages, opts})
      step = Enum.count(messages, &(Map.get(&1, :role) in [:assistant, "assistant"]))

      output =
        case step do
          0 ->
            %{
              text: "Looking it up.",
              tool_calls: [%{id: "lookup-1", name: "lookup", arguments: %{query: "beam"}}]
            }

          _ ->
            %{
              text: "",
              tool_calls: [
                %{id: "submit-1", name: "submit", arguments: %{answer: "BEAM", confidence: 1.0}}
              ]
            }
        end

      {:ok,
       %{
         __imp_lm_output__: output,
         __imp_lm_metadata__: %{
           native_reasoning: "private thought #{step}",
           req_llm: %{usage: %{input_tokens: 100, output_tokens: 10, cached_tokens: 40}},
           cost: 0.25
         }
       }}
    end
  end

  test "a recorded multi-step run reads as the model saw it" do
    secret = "sk-test-secret-1234567890"
    long = String.duplicate("beam ", 50)
    lookup = Imp.tool(:lookup, "look up", fn _ -> %{found: long, api_key: secret} end)

    # The model is shown a shortened tool result, as a host may render it.
    program =
      Imp.react("question -> answer, confidence: float", [lookup],
        lm: %ScriptedLM{owner: self()},
        adapter_opts: [tool_result_renderer: fn _result, _call -> "found: beam (shortened)" end]
      )

    {:ok, run} = Imp.Run.start(program, %{question: "runtime?", api_key: secret})
    assert {:ok, _} = Task.await(run.task)
    events = Imp.Run.events(run)
    Imp.Run.stop(run)

    document =
      Imp.Trajectory.to_atif(events,
        agent: %{name: "fixture", version: "1", extra: %{api_key: secret}}
      )

    encoded = Jason.encode!(document)
    refute encoded =~ secret
    assert document["extra"]["terminal_event"] == "run_finished"

    agent = document["agent"]
    assert agent["name"] == "fixture"
    assert agent["model_name"] == "test:model"

    assert Enum.map(agent["tool_definitions"], &get_in(&1, ["function", "name"])) ==
             ["lookup", "submit"]

    steps = document["steps"]
    assert Enum.map(steps, & &1["step_id"]) == Enum.to_list(1..length(steps))
    responses = Enum.filter(steps, &(&1["llm_call_count"] == 1))
    assert length(responses) == 2
    refute Enum.any?(steps, &(&1["llm_call_count"] == 0))

    [first, second] = responses
    assert first["message"] == "Looking it up."
    assert first["reasoning_content"] == "private thought 0"
    assert first["model_name"] == "test:model"

    assert first["metrics"] == %{
             "prompt_tokens" => 100,
             "completion_tokens" => 10,
             "cached_tokens" => 40,
             "cost_usd" => 0.25
           }

    [call] = first["tool_calls"]
    assert call["function_name"] == "lookup"
    assert call["extra"]["native_tool_call_id"] == "lookup-1"
    [result] = first["observation"]["results"]
    assert result["source_call_id"] == call["tool_call_id"]
    assert result["content"] == "found: beam (shortened)"
    assert result["extra"]["seen_by_model"] == true
    assert result["extra"]["output"] =~ "beam beam"

    # What the model read is what the second request carried.
    assert_received {:request, _, _}
    assert_received {:request, second_request, _}
    assert Enum.any?(second_request, &(Map.get(&1, :content) == result["content"]))

    assert second["reasoning_content"] == "private thought 1"
    [submit] = second["observation"]["results"]
    assert submit["extra"]["seen_by_model"] == false

    assert document["final_metrics"] == %{
             "total_prompt_tokens" => 200,
             "total_completion_tokens" => 20,
             "total_cached_tokens" => 80,
             "total_cost_usd" => 0.5,
             "total_steps" => length(steps)
           }

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
    assert doc["extra"]["terminal_event"] == "run_cancelled"
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
        input: [
          %{role: :system, content: "instructions"},
          %{role: :user, content: "earlier question"},
          %{
            role: :assistant,
            content: "checking",
            reasoning_content: "earlier thought",
            tool_calls: [
              %{
                id: "old-1",
                type: "function",
                function: %{name: "lookup", arguments: ~s({"query":"q"})}
              }
            ]
          },
          %{role: :tool, content: "looked up", tool_calls: [%{id: "old-1"}]},
          %{role: :user, content: "question"}
        ]
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
    assert Enum.map(doc["steps"], & &1["source"]) == ["system", "user", "agent", "user", "agent"]

    assert Enum.map(doc["steps"], & &1["message"]) ==
             ["instructions", "earlier question", "checking", "question", "answer"]

    # A message replayed from history keeps its call, its reasoning and the
    # result it was shown, linked as ATIF requires.
    earlier = Enum.at(doc["steps"], 2)
    assert earlier["is_copied_context"]
    assert earlier["reasoning_content"] == "earlier thought"

    assert [%{"tool_call_id" => "old-1", "arguments" => %{"query" => "q"}}] =
             earlier["tool_calls"]

    assert earlier["observation"]["results"] == [
             %{"source_call_id" => "old-1", "content" => "looked up"}
           ]

    assert List.last(doc["steps"])["llm_call_count"] == 1
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

  test "a tool result's outcome is the one its loop recorded, and a stored kind Imp does not know is kept" do
    events = [
      %{
        "run_id" => "r",
        "sequence" => 0,
        "kind" => "tool_call",
        "tool_call_id" => "a",
        "tool_name" => "post",
        "input" => %{}
      },
      %{
        "run_id" => "r",
        "sequence" => 1,
        "kind" => "tool_result",
        "tool_call_id" => "a",
        "error" => %{"reason" => "denied"},
        "metadata" => %{"outcome" => "refused"}
      },
      %{
        "run_id" => "r",
        "sequence" => 2,
        "kind" => "tool_call",
        "tool_call_id" => "b",
        "tool_name" => "post",
        "input" => %{}
      },
      %{
        "run_id" => "r",
        "sequence" => 3,
        "kind" => "tool_result",
        "tool_call_id" => "b",
        "error" => %{"reason" => "timeout"},
        "metadata" => %{"outcome" => "unknown"}
      },
      %{"run_id" => "r", "sequence" => 4, "kind" => "would_post", "metadata" => %{}},
      %{"run_id" => "r", "sequence" => 5, "kind" => "run_finished"}
    ]

    doc = Imp.Trajectory.to_atif(events)
    [refused, unknown] = Enum.filter(doc["steps"], &Map.has_key?(&1, "tool_calls"))

    assert refused["extra"]["outcome"] == "refused"
    assert [%{"extra" => %{"outcome" => "refused"}}] = refused["observation"]["results"]
    assert unknown["extra"]["outcome"] == "unknown"
    assert Enum.any?(doc["extra"]["diagnostics"], &(&1["event_kind"] == "would_post"))
  end
end
