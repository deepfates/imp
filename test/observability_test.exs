defmodule ObservabilityTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Imp.Optimize.Anything
  alias Imp.Optimize.Anything.Config

  setup do
    Imp.enable_logging()
    on_exit(&Imp.enable_logging/0)
    :ok
  end

  test "inspect_history renders recent turns and redacts secrets by default" do
    history =
      Imp.history([
        %{question: "old", answer: "old answer"},
        %{question: "use sk-test-secret-1234567890", answer: "no", api_key: "secret"}
      ])

    rendered = Imp.inspect_history(history, limit: 1)

    assert rendered =~ "Turn 1"
    assert rendered =~ "[REDACTED]"
    refute rendered =~ "sk-test-secret"
    refute rendered =~ "old answer"

    assert Imp.inspect_history(history, limit: 1, redact: false) =~ "sk-test-secret"
  end

  test "inspect_history renders a ReActV2 history holding an unknown tool and a raising tool" do
    {:ok, script} =
      Agent.start_link(fn ->
        [
          %{tool_calls: [%{id: "m1", name: "missing", arguments: %{query: "beam"}}]},
          %{tool_calls: [%{id: "e1", name: "explode", arguments: %{}}]},
          "Paris"
        ]
      end)

    lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          Agent.get_and_update(script, fn [action | rest] -> {action, rest} end)
        end
      )

    explode = Imp.tool(:explode, "explode", fn _arguments -> raise "tool exploded" end)

    assert {:ok, prediction} =
             Imp.react("question -> answer", [explode], lm: lm)
             |> Imp.call(%{question: "Capital of France?"})

    history = prediction.metadata[:history]

    assert [%{tool_call_results: [%{result: {:error, {:unknown_tool, "missing"}}}]}, raised, _] =
             Imp.History.messages(history)

    assert [%{result: {:error, {:tool_error, :explode, %RuntimeError{}}}}] =
             raised.tool_call_results

    assert [missing_turn, raised_turn, answer_turn] = rendered_turns(Imp.inspect_history(history))

    assert [%{"error" => true, "result" => ["error", ["unknown_tool", "missing"]]}] =
             missing_turn["tool_call_results"]

    assert [%{"result" => ["error", ["tool_error", "explode", %{"message" => "tool exploded"}]]}] =
             raised_turn["tool_call_results"]

    assert answer_turn["answer"] == "Paris"
  end

  test "inspect_history renders terms JSON cannot encode and redacts inside them" do
    ref = make_ref()

    history = [
      %{
        question: "mixed",
        result:
          {:error, {:tool_error, :lookup, %RuntimeError{message: "sk-test-secret-1234567890"}}},
        owner: self(),
        ref: ref,
        callback: &String.upcase/1,
        range: 1..3,
        bytes: <<0xFF, 0xFE>>,
        nested: [%{{:key, 1} => {:api_key, "plain-secret"}}, [:a | :b], <<1::3>>]
      }
    ]

    rendered = Imp.inspect_history(history)
    assert [turn] = rendered_turns(rendered)

    assert turn["owner"] == Kernel.inspect(self())
    assert turn["ref"] == Kernel.inspect(ref)
    assert turn["callback"] == Kernel.inspect(&String.upcase/1)
    assert turn["bytes"] == "<<255, 254>>"
    assert turn["range"] == %{"first" => 1, "last" => 3, "step" => 1}

    assert [
             %{"__imp_type__" => "map", "entries" => [[["key", 1], _entry]]},
             improper,
             "<<1::size(3)>>"
           ] =
             turn["nested"]

    assert improper == %{"__imp_type__" => "improper_list", "head" => "a", "tail" => "b"}
    assert rendered =~ "[REDACTED]"
    refute rendered =~ "sk-test-secret"
    refute rendered =~ "plain-secret"

    unredacted = Imp.inspect_history(history, redact: false)
    assert unredacted =~ "sk-test-secret-1234567890"
    assert unredacted =~ "plain-secret"
  end

  test "optimizer progress subscription receives GEPA baseline and generation events" do
    subscription = Imp.subscribe_optimizer_progress()

    Anything.run(
      "base",
      fn candidate, target -> if(String.contains?(candidate, target), do: 1.0, else: 0.0) end,
      dataset: ["target"],
      config:
        Config.new(
          engine: [max_candidate_proposals: 1, parallel: false],
          reflection: [
            custom_candidate_proposer: fn _candidate, _component, _records, _iteration ->
              "target"
            end
          ]
        )
    )

    assert_receive {:imp_optimizer_progress, [:imp, :optimizer, :progress],
                    %{completed_generations: 0, candidate_count: 1},
                    %{optimizer: :gepa, candidate_id: "baseline"}}

    assert_receive {:imp_optimizer_progress, [:imp, :optimizer, :progress],
                    %{completed_generations: 1, candidate_count: 2},
                    %{optimizer: :gepa, candidate_id: "gepa-1"}}

    assert Imp.unsubscribe_optimizer_progress(subscription) == :ok
  end

  test "trace captures ordered redacted telemetry with the operation result" do
    trace =
      Imp.trace(
        fn ->
          Imp.Telemetry.span(
            [:imp, :tool],
            %{tool: :lookup, api_key: "sk-test-secret-1234567890"},
            fn -> {:ok, "Paris"} end
          )
        end,
        events: [[:imp, :tool, :start], [:imp, :tool, :stop]]
      )

    assert %Imp.Observability.Trace{result: {:ok, "Paris"}, events: events} = trace
    assert Enum.map(events, &elem(&1, 0)) == [[:imp, :tool, :start], [:imp, :tool, :stop]]
    assert inspect(events) =~ "[REDACTED]"
    refute inspect(events) =~ "sk-test-secret"
  end

  test "logging controls suppress Imp logs and redact emitted metadata" do
    enabled =
      capture_log(fn ->
        Imp.Observability.log(:warning, "visible", api_key: "sk-test-secret-1234567890")
      end)

    assert enabled =~ "visible"
    refute enabled =~ "sk-test-secret"

    Imp.disable_logging()

    assert capture_log(fn ->
             Imp.Observability.log(:warning, "hidden")
           end) == ""
  end

  defp rendered_turns(rendered) do
    rendered
    |> String.split(~r/(?:\A|\n\n)Turn \d+\n/, trim: true)
    |> Enum.map(&Jason.decode!/1)
  end
end
