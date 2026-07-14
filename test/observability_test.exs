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
end
