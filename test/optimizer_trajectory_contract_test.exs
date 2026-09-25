defmodule Imp.Optimizer.TrajectoryContractTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Imp.Adapter.Types.{ToolCall, ToolCallResults, ToolCalls, ToolResult}
  alias Imp.Optimizer.Trajectory
  alias Imp.Optimizer.Trajectory.{Cache, DecodeError, Event, Failure, Parameter, Timing, Usage}

  @fixture "test/fixtures/optimizer_trajectory_contract.json"

  test "all optimizer, agent, and evaluation families project into one typed contract" do
    fixture = @fixture |> File.read!() |> Jason.decode!()
    assert fixture["schema_version"] == Trajectory.schema_version()

    Enum.each(fixture["cases"], fn contract_case ->
      runtime = String.to_existing_atom(contract_case["runtime"])

      trajectory =
        Trajectory.project(runtime, %{
          index: 0,
          example: %{"question" => "France?"},
          prediction: %{"answer" => "Paris"},
          score: 1.0,
          trace: contract_case["trace"]
        })

      assert trajectory.runtime == runtime
      assert Enum.all?(trajectory.events, &match?(%Event{}, &1))
      assert Enum.map(trajectory.events, &to_string(&1.kind)) == contract_case["event_kinds"]
      assert {:ok, restored} = trajectory |> Trajectory.dump() |> Trajectory.load()
      assert Trajectory.dump(restored) == Trajectory.dump(trajectory)
    end)
  end

  test "wire envelope covers multimodal values, accounting, cache, failures, and parameters" do
    image = %Imp.Adapter.Types.Image{
      data: "aW1hZ2U=",
      mime_type: "image/png",
      metadata: %{alt: "map"}
    }

    trajectory =
      Trajectory.project(
        :gepa,
        %{
          index: 0,
          example: Imp.example(prompt: ["locate", image]) |> Imp.with_inputs(:prompt),
          prediction: Imp.Prediction.new(reasoning: "visual inspection", answer: "map"),
          score: 0.8,
          feedback: %{instruction: "be precise"},
          metric_metadata: %{objectives: %{accuracy: 0.8}},
          error: %Failure{kind: :provider, message: "retry recovered", retryable: true},
          program_id: "program-7",
          rollout_id: "rollout-2",
          trace: [
            %{predictor: :vision, inputs: %{prompt: ["locate", image]}, outputs: %{answer: "map"}}
          ]
        },
        usage: %Usage{
          input_tokens: 10,
          output_tokens: 4,
          total_tokens: 14,
          requests: 1,
          cost: 0.01,
          currency: "USD"
        },
        timing: %Timing{
          started_at: "2026-07-13T00:00:00Z",
          finished_at: "2026-07-13T00:00:00.025Z",
          duration_us: 25_000
        },
        cache: %Cache{key: "candidate-7/example-0", hit: true, namespace: "optimizer"},
        named_parameters: [
          %Parameter{name: :vision, kind: :instruction, value: "Inspect all supplied content"},
          %Parameter{name: :few_shot, kind: :demos, value: [%{answer: "map"}]}
        ],
        metadata: %{source_semantics: %{gepa: %{component: :vision}}}
      )

    wire = Trajectory.dump(trajectory)
    assert {:ok, json} = Jason.encode(wire)
    refute json =~ "Elixir."
    assert wire["usage"]["total_tokens"] == 14
    assert wire["cache"]["key"] == "candidate-7/example-0"

    assert {:ok, restored} = Trajectory.load(Jason.decode!(json))

    assert %Imp.Adapter.Types.Image{} =
             Imp.Example.get(restored.example, :prompt) |> List.last()

    assert %Failure{kind: :provider} = restored.error
    assert Enum.map(restored.named_parameters, & &1.name) == [:vision, :few_shot]
    assert Trajectory.dump(restored) == wire
  end

  test "native ReAct histories expand aligned calls and results without flattening history" do
    calls = ToolCalls.new([ToolCall.new(:lookup, %{city: "Paris"}, id: "call-native")])

    results =
      ToolCallResults.new([ToolResult.new(:lookup, "France", id: "call-native")])

    prediction =
      Imp.Prediction.new(%{answer: "France"},
        metadata: %{
          history: [
            %{tool: :lookup, arguments: %{city: "Paris"}, result: "France"},
            %{next_thought: "confirm", tool_calls: calls, tool_call_results: results}
          ]
        }
      )

    trajectory = Trajectory.project(:react, prediction)

    assert Enum.map(trajectory.events, & &1.kind) == [
             :tool_call,
             :tool_result,
             :tool_call,
             :tool_result
           ]

    assert Enum.map(trajectory.events, & &1.sequence) == [0, 1, 2, 3]
    assert trajectory.trace == prediction.metadata[:history]
    assert Trajectory.validate!(trajectory) == trajectory
  end

  test "serialization always redacts credential keys and secret-shaped values" do
    trajectory =
      Trajectory.project(:evaluation, %{
        index: 0,
        example: %{api_key: "sk-test-secret-1234567890", prompt: "Bearer abcdefghijklmnop"},
        prediction: %{answer: "ok"},
        score: 1.0,
        trace: []
      })

    encoded = trajectory |> Trajectory.dump() |> Jason.encode!()
    refute encoded =~ "sk-test-secret"
    refute encoded =~ "abcdefghijklmnop"
    assert encoded =~ "[REDACTED]"
  end

  test "serialization redacts credential tuple and keyword pairs without changing tuple shape" do
    authorization = "CANARY_TRAJECTORY_TUPLE_AUTHORIZATION_31b7c"
    session = "CANARY_TRAJECTORY_KEYWORD_SESSION_a024e"

    trajectory =
      Trajectory.project(:evaluation, %{
        index: 0,
        example: %{question: "pair boundaries"},
        prediction: %{answer: "ok"},
        score: 1.0,
        trace: [
          {"authorization", authorization},
          [session: session],
          {:status, {"request_id", "request-42"}},
          {:ordinary, 7, "retained"}
        ]
      })

    wire = Trajectory.dump(trajectory)
    encoded = Jason.encode!(wire)

    refute encoded =~ authorization
    refute encoded =~ session

    assert {:ok, restored} = Trajectory.load(wire)

    assert restored.trace == [
             {"authorization", "[REDACTED]"},
             [session: "[REDACTED]"],
             {:status, {"request_id", "request-42"}},
             {:ordinary, 7, "retained"}
           ]
  end

  test "accounting field names only bypass key redaction for valid numeric counts" do
    trajectory =
      Trajectory.project(:evaluation, %{
        index: 0,
        example: %{"input_tokens" => "sk-test-secret-1234567890"},
        prediction: %{},
        score: 0.0,
        trace: []
      })

    assert get_in(Trajectory.dump(trajectory), ["example", "input_tokens"]) == "[REDACTED]"
  end

  test "serialization preserves attachment payloads while redacting attachment metadata" do
    payload = Base.encode64(:crypto.strong_rand_bytes(96))

    trajectory =
      Trajectory.project(:evaluation, %{
        index: 0,
        example: %{
          image: %Imp.Adapter.Types.Image{
            data: payload,
            metadata: %{api_key: "sk-test-secret-1234567890"}
          }
        },
        prediction: %{answer: "ok"},
        score: 1.0,
        trace: []
      })

    wire = Trajectory.dump(trajectory)
    assert {:ok, restored} = wire |> Jason.encode!() |> Jason.decode!() |> Trajectory.load()

    assert %Imp.Adapter.Types.Image{
             data: ^payload,
             metadata: %{"api_key" => "[REDACTED]"}
           } = restored.example["image"]
  end

  test "serialization rejects atom and string keys that collide in JSON" do
    trajectory =
      Trajectory.project(:evaluation, %{
        index: 0,
        example: %{:prompt => "one", "prompt" => "two"},
        prediction: %{},
        score: 0.0,
        trace: []
      })

    assert_raise DecodeError, ~r/colliding key/, fn -> Trajectory.dump(trajectory) end

    assert_raise ArgumentError, ~r/contains both :score and "score"/, fn ->
      Trajectory.project(:evaluation, %{:score => 1.0, "score" => 0.0, index: 0})
    end
  end

  test "redaction preserves semantic credential-named schema descriptors" do
    trajectory =
      Trajectory.project(:evaluation, %{
        index: 0,
        example: %{schema: %{token: :string, api_key: :string}, token: "actual-secret"},
        prediction: %{},
        score: 0.0,
        trace: []
      })

    redacted = Trajectory.redact(trajectory)
    assert redacted.example.schema == %{token: :string, api_key: :string}
    assert redacted.example.token == "[REDACTED]"
  end

  test "serialization fails safe for mixed tagged credential keys and improper provider lists" do
    typed_key = %{"__imp_type__" => "atom", "value" => "api_key"}

    tagged = %{
      "__imp_type__" => :map,
      :entries => [[typed_key, "CANARY_TRAJECTORY_TAGGED_SECRET"]]
    }

    trajectory =
      Trajectory.project(:evaluation, %{
        index: 0,
        score: 0.0,
        trace: [],
        metadata: %{
          tagged: tagged,
          provider_error: [:provider_error, %{api_key: "CANARY_IMPROPER_SECRET"} | "messages"]
        }
      })

    wire = Trajectory.dump(trajectory)
    rendered = inspect(wire)

    refute rendered =~ "CANARY_TRAJECTORY_TAGGED_SECRET"
    refute rendered =~ "CANARY_IMPROPER_SECRET"
    assert rendered =~ "[REDACTED]"
    assert rendered =~ "provider_error"
    assert {:ok, _json} = Jason.encode(wire)
    assert {:ok, _restored} = Trajectory.load(wire)
  end

  test "typed payload tags reject extra keys" do
    wire =
      Trajectory.project(:evaluation, %{index: 0, score: 0.0, trace: []})
      |> Trajectory.dump()

    tagged = %{"__trajectory_type__" => "tuple", "value" => [], "extra" => true}
    assert {:error, %DecodeError{}} = wire |> Map.put("feedback", tagged) |> Trajectory.load()
  end

  test "saved trajectories cannot smuggle deferred host file reads" do
    path =
      Path.join(
        System.tmp_dir!(),
        "imp-trajectory-host-read-#{System.unique_integer([:positive])}"
      )

    File.write!(path, "CANARY")
    on_exit(fn -> File.rm(path) end)

    trajectory =
      Trajectory.project(:evaluation, %{
        index: 0,
        score: 0.0,
        trace: [],
        feedback: %Imp.Adapter.Types.File{data: Base.encode64("safe")}
      })

    wire = Trajectory.dump(trajectory)

    hostile_file = %{
      "__trajectory_type__" => "file",
      "value" => %{
        "path" => path,
        "url" => nil,
        "data" => nil,
        "mime_type" => nil,
        "metadata" => %{}
      }
    }

    assert {:error, %DecodeError{message: message}} =
             wire |> Map.put("feedback", hostile_file) |> Trajectory.load()

    assert message =~ "cannot carry deferred host paths"

    assert_raise DecodeError, ~r/cannot persist a deferred file path/, fn ->
      trajectory
      |> Map.put(:feedback, %Imp.Adapter.Types.File{path: path})
      |> Trajectory.dump()
    end

    assert {:ok, restored} = Trajectory.load(wire)
    assert restored.feedback == %Imp.Adapter.Types.File{data: Base.encode64("safe")}
  end

  test "ordinary maps resembling wire tags round-trip as ordinary maps" do
    feedback = %{"__trajectory_type__" => "atom", "value" => "not_an_atom", "note" => true}

    trajectory =
      Trajectory.project(:evaluation, %{
        index: 0,
        score: 0.0,
        trace: [],
        feedback: feedback
      })

    assert {:ok, restored} = trajectory |> Trajectory.dump() |> Trajectory.load()
    assert restored.feedback == feedback
  end

  test "map projection preserves supplied typed envelope fields" do
    trajectory =
      Trajectory.project(:agent, %{
        index: 0,
        score: 1.0,
        trace: [],
        events: [%{kind: :runtime, output: "ok"}],
        usage: %{input_tokens: 2, output_tokens: 1, total_tokens: 3, requests: 1},
        timing: %{duration_us: 20},
        cache: %{key: "run-1", hit: true},
        named_parameters: [%{name: :main, kind: :instruction, value: "answer"}],
        metadata: %{source: :agent}
      })

    assert [%Event{kind: :runtime}] = trajectory.events
    assert trajectory.usage.total_tokens == 3
    assert trajectory.timing.duration_us == 20
    assert trajectory.cache.hit
    assert [%Parameter{name: :main}] = trajectory.named_parameters
    assert trajectory.metadata == %{source: :agent}
  end

  test "nested wire structs require complete schemas and valid failures" do
    wire =
      Trajectory.project(:evaluation, %{index: 0, score: 0.0, trace: []}) |> Trajectory.dump()

    assert {:error, %DecodeError{}} = wire |> Map.put("usage", %{}) |> Trajectory.load()

    malformed_failure = %{
      "__trajectory_type__" => "failure",
      "value" => %{
        "kind" => %{"__trajectory_type__" => "atom", "value" => "provider"},
        "message" => 42,
        "details" => nil,
        "retryable" => false
      }
    }

    assert {:error, %DecodeError{}} =
             wire |> Map.put("error", malformed_failure) |> Trajectory.load()
  end

  test "tool results are one-to-one and must match the call name" do
    base = Trajectory.project(:agent, %{index: 0, score: 0.0, trace: []})

    duplicate_result =
      %{
        base
        | events: [
            %Event{sequence: 0, kind: :tool_call, tool_call_id: "1", tool_name: :lookup},
            %Event{sequence: 1, kind: :tool_result, tool_call_id: "1", tool_name: :lookup},
            %Event{sequence: 2, kind: :tool_result, tool_call_id: "1", tool_name: :lookup}
          ]
      }

    assert_raise ArgumentError, ~r/no preceding tool_call/, fn ->
      Trajectory.validate!(duplicate_result)
    end

    wrong_name = %{
      base
      | events: [
          %Event{sequence: 0, kind: :tool_call, tool_call_id: "1", tool_name: :lookup},
          %Event{sequence: 1, kind: :tool_result, tool_call_id: "1", tool_name: :search}
        ]
    }

    assert_raise ArgumentError, ~r/name does not match/, fn ->
      Trajectory.validate!(wrong_name)
    end
  end

  test "the general Imp persistence facade uses the canonical trajectory codec" do
    trajectory = Trajectory.project(:gepa, %{index: 0, score: 1.0, trace: []})
    assert %Trajectory{} = restored = trajectory |> Imp.dump() |> Imp.load()
    assert Trajectory.dump(restored) == Trajectory.dump(trajectory)
  end

  test "alignment and malformed payloads fail closed" do
    first = Trajectory.project(:evaluation, %{index: 0, score: 1.0, trace: []})
    third = Trajectory.project(:evaluation, %{index: 2, score: 1.0, trace: []})

    assert_raise ArgumentError, ~r/contiguous/, fn ->
      Trajectory.validate_aligned!([first, third])
    end

    unaligned_tool_result =
      Map.replace!(first, :events, [
        %Event{sequence: 0, kind: :tool_result, tool_call_id: "missing", output: "nope"}
      ])

    assert_raise ArgumentError, ~r/no preceding tool_call/, fn ->
      Trajectory.validate!(unaligned_tool_result)
    end

    wire = Trajectory.dump(first)
    assert {:error, %DecodeError{}} = wire |> Map.put("unknown", true) |> Trajectory.load()
    assert {:error, %DecodeError{}} = wire |> Map.put("schema_version", 99) |> Trajectory.load()

    assert {:error, %DecodeError{}} =
             wire |> put_in(["usage", "requests"], -1) |> Trajectory.load()
  end

  property "canonical wire maps round-trip deterministically" do
    check all(
            runtime <-
              member_of([
                :evaluation,
                :gepa,
                :mipro_v2,
                :simba,
                :rlm,
                :agent,
                :react,
                :optimize_anything
              ]),
            score <- float(min: -10.0, max: 10.0),
            prompt <- string(:alphanumeric, max_length: 40),
            answer <- string(:alphanumeric, max_length: 40),
            input_tokens <- non_negative_integer(),
            output_tokens <- non_negative_integer(),
            max_runs: 75
          ) do
      trajectory =
        Trajectory.project(
          runtime,
          %{
            index: 0,
            example: %{"prompt" => prompt},
            prediction: %{"answer" => answer},
            score: score,
            trace: []
          },
          usage: %{
            input_tokens: input_tokens,
            output_tokens: output_tokens,
            total_tokens: input_tokens + output_tokens,
            requests: 1
          },
          named_parameters: [%{name: "main", kind: "instruction", value: prompt}]
        )

      wire = Trajectory.dump(trajectory)
      assert {:ok, decoded} = wire |> Jason.encode!() |> Jason.decode!() |> Trajectory.load()
      assert Trajectory.dump(decoded) == wire
    end
  end
end
