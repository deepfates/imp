defmodule ObservabilityTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias DSEx.Optimize.Anything
  alias DSEx.Optimize.GEPA

  setup do
    DSEx.enable_logging()
    on_exit(&DSEx.enable_logging/0)
    :ok
  end

  test "inspect_history renders recent turns and redacts secrets by default" do
    history =
      DSEx.history([
        %{question: "old", answer: "old answer"},
        %{question: "use sk-test-secret-1234567890", answer: "no", api_key: "secret"}
      ])

    rendered = DSEx.inspect_history(history, limit: 1)

    assert rendered =~ "Turn 1"
    assert rendered =~ "[REDACTED]"
    refute rendered =~ "sk-test-secret"
    refute rendered =~ "old answer"

    assert DSEx.inspect_history(history, limit: 1, redact: false) =~ "sk-test-secret"
  end

  test "optimizer progress subscription receives GEPA baseline and generation events" do
    subscription = DSEx.subscribe_optimizer_progress()
    artifact = Anything.new_artifact(:prompt, "base")

    GEPA.optimize(
      artifact,
      fn candidate, examples ->
        %{
          per_example_scores:
            Enum.map(examples, &if(String.contains?(candidate.text, &1), do: 1.0, else: 0.0)),
          asi: Enum.reject(examples, &String.contains?(candidate.text, &1))
        }
      end,
      examples: ["target"],
      generations: 1,
      mutation_fn: fn _artifact, _asi, _generation -> "target" end
    )

    assert_receive {:dsex_optimizer_progress, [:dsex, :optimizer, :progress],
                    %{completed_generations: 0, candidate_count: 1},
                    %{optimizer: :gepa, candidate_id: "baseline"}}

    assert_receive {:dsex_optimizer_progress, [:dsex, :optimizer, :progress],
                    %{completed_generations: 1, candidate_count: 2},
                    %{optimizer: :gepa, candidate_id: "gepa-1"}}

    assert DSEx.unsubscribe_optimizer_progress(subscription) == :ok

    GEPA.optimize(artifact, fn _candidate, _examples -> %{per_example_scores: [1.0]} end,
      examples: [:one],
      generations: 0
    )

    refute_receive {:dsex_optimizer_progress, _, _, _}
  end

  test "trace captures ordered redacted telemetry with the operation result" do
    trace =
      DSEx.trace(
        fn ->
          DSEx.Telemetry.span(
            [:dsex, :tool],
            %{tool: :lookup, api_key: "sk-test-secret-1234567890"},
            fn -> {:ok, "Paris"} end
          )
        end,
        events: [[:dsex, :tool, :start], [:dsex, :tool, :stop]]
      )

    assert %DSEx.Observability.Trace{result: {:ok, "Paris"}, events: events} = trace
    assert Enum.map(events, &elem(&1, 0)) == [[:dsex, :tool, :start], [:dsex, :tool, :stop]]
    assert inspect(events) =~ "[REDACTED]"
    refute inspect(events) =~ "sk-test-secret"
  end

  test "logging controls suppress DSEx logs and redact emitted metadata" do
    enabled =
      capture_log(fn ->
        DSEx.Observability.log(:warning, "visible", api_key: "sk-test-secret-1234567890")
      end)

    assert enabled =~ "visible"
    refute enabled =~ "sk-test-secret"

    DSEx.disable_logging()

    assert capture_log(fn ->
             DSEx.Observability.log(:warning, "hidden")
           end) == ""
  end
end
