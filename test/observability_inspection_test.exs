defmodule Imp.ObservabilityInspectionTest do
  use ExUnit.Case, async: false

  alias Imp.Observability.{Inspection, Status}
  alias Imp.Optimizer.Report, as: OptimizerReport

  @secret "sk-test-secret-1234567890"

  test "prediction inspection combines provider, tool, RLM, and optimizer history" do
    report =
      OptimizerReport.new(%{
        optimizer: :gepa,
        best_score: 0.9,
        candidate_count: 1,
        candidates: [%{id: "candidate-1", prompt: @secret}]
      })

    prediction =
      Imp.Prediction.new(
        %{
          answer: "Paris",
          history: [%{tool: :lookup, input: %{token: @secret}, result: "Paris"}]
        },
        score: 1.0,
        metadata: %{
          trace: %{messages: [%{role: :user, content: @secret}], raw: "Paris"},
          rlm_trace: [%{iteration: 1, action: :tool, input: @secret, output: "Paris"}],
          optimizer_report: report
        }
      )

    assert %Inspection{kind: :prediction, status: :ok} =
             inspection = Imp.Observability.inspect_artifact(prediction)

    assert Enum.map(inspection.entries, & &1.source) == [
             :provider,
             :tool,
             :rlm,
             :optimizer_candidate
           ]

    assert inspection.summary.fields == ["answer", "history"]
    assert inspection.summary.entry_count == 4
    assert Kernel.inspect(inspection) =~ "[REDACTED]"
    refute Kernel.inspect(inspection) =~ @secret
  end

  # Each of these is a ReActV2 turn that ended with its answer; only the way it
  # ended differs. A turn that ran out of steps, time or context has none.
  test "a prediction that ended with its answer is complete however the turn ended" do
    for reason <- [:submit, :forced_submit, :answered, :last_text, :finished_by_tool] do
      prediction = Imp.Prediction.new(%{answer: "Paris", termination_reason: reason})

      assert %Inspection{status: :ok} = Imp.Observability.inspect_artifact(prediction),
             "#{reason} should be complete"

      assert %Status{state: :succeeded} = Imp.Observability.status(prediction)
    end

    for reason <- [:max_iters, :deadline_exceeded, :context_window_exceeded] do
      prediction = Imp.Prediction.new(%{termination_reason: reason})
      assert %Inspection{status: :incomplete} = Imp.Observability.inspect_artifact(prediction)
      assert %Status{state: :failed} = Imp.Observability.status(prediction)
    end
  end

  test "provider inspection mirrors recent prompt, messages, outputs, and timestamps" do
    history = [
      %{timestamp: "old", prompt: "old prompt", outputs: ["old output"]},
      %{
        timestamp: "new",
        messages: [%{role: :user, content: @secret}],
        outputs: [
          %{text: "answer", tool_calls: [%{name: "lookup", arguments: %{token: @secret}}]}
        ]
      }
    ]

    inspection = Imp.Observability.inspect_artifact({:provider, history}, limit: 1)

    assert %Inspection{kind: :provider, summary: %{call_count: 2}} = inspection
    assert [%{source: :provider, sequence: 1, payload: payload}] = inspection.entries
    assert payload.timestamp == "new"
    assert payload.messages == [%{role: :user, content: "[REDACTED]"}]
    refute Kernel.inspect(payload) =~ @secret

    rendered = Imp.inspect_history(history, limit: 1)
    assert rendered =~ ~s("kind": "provider")
    assert rendered =~ "new"
    refute rendered =~ "old prompt"
    refute rendered =~ @secret
  end

  test "streaming status messages are inspectable immutable artifacts" do
    message = %Imp.Streaming.Messages.StatusMessage{
      message: "calling provider",
      metadata: %{authorization: @secret}
    }

    assert %Inspection{kind: :status, summary: %{level: :info}} =
             inspection = Imp.Observability.inspect_artifact(message)

    assert [%{source: :status, payload: payload}] = inspection.entries
    assert payload.message == "calling provider"
    assert payload.metadata.authorization == "[REDACTED]"
  end

  test "tool and RLM inspections are explicit and size bounded" do
    tool = Imp.Observability.inspect_artifact({:tool, [%{tool: :search, result: "ok"}]})
    assert [%{source: :tool, payload: %{tool: :search}}] = tool.entries

    rlm =
      Imp.Observability.inspect_artifact(
        {:rlm, [%{iteration: 1, action: :load, output: String.duplicate("x ", 500)}]},
        max_bytes: 100
      )

    assert %{event_count: 1, actions: %{load: 1}} = rlm.summary
    assert [%{payload: %{truncated: true, bytes: bytes, fingerprint: fingerprint}}] = rlm.entries
    assert bytes > 100
    assert is_integer(fingerprint)
  end

  test "optimizer reports expose candidate and error status without internal parsing" do
    report =
      OptimizerReport.new(%{
        optimizer: :mipro_v2,
        best_score: 0.7,
        candidate_count: 2,
        candidates: [%{id: 1}],
        errors: [%{candidate_id: 2, reason: :timeout, authorization: @secret}]
      })

    inspection = Imp.Observability.inspect_artifact(report)
    assert inspection.status == :with_errors
    assert inspection.summary.error_count == 1
    refute Kernel.inspect(inspection) =~ @secret

    assert %Status{
             state: :failed,
             phase: :optimizer,
             completed: 2,
             total: 2,
             metadata: %{error_count: 1}
           } = Imp.Observability.status(report)
  end

  test "optimizer subscriptions emit both compatible telemetry and normalized status" do
    subscription = Imp.Observability.subscribe_optimizer()

    Imp.Telemetry.execute(
      [:imp, :optimizer, :progress],
      %{completed_generations: 2, total_generations: 5, candidate_count: 3},
      %{optimizer: :gepa, api_key: @secret}
    )

    assert_receive {:imp_optimizer_progress, [:imp, :optimizer, :progress], _, _}

    assert_receive {:imp_status,
                    %Status{
                      state: :running,
                      phase: "optimizer_progress",
                      completed: 2,
                      total: 5,
                      metadata: metadata
                    }}

    refute Kernel.inspect(metadata) =~ @secret
    assert Imp.Observability.unsubscribe_optimizer(subscription) == :ok
  end

  test "captured telemetry renders deterministically as redacted JSON" do
    trace =
      Imp.Observability.trace(
        fn ->
          Imp.Telemetry.span([:imp, :tool], %{tool: :lookup, password: @secret}, fn ->
            {:ok, "Paris"}
          end)
        end,
        events: [[:imp, :tool, :start], [:imp, :tool, :stop]]
      )

    first = Imp.Observability.render_inspection(trace)
    second = Imp.Observability.render_inspection(trace)

    assert first == second
    assert first =~ ~s("kind": "trace")
    assert first =~ "[REDACTED]"
    refute first =~ @secret
  end

  test "rendering remains fail-safe for typed map keys" do
    typed_key = %{"__imp_type__" => "atom", "value" => "api_key"}

    inspection =
      Imp.Observability.Inspection.new(
        :trace,
        :ok,
        %{},
        [
          {:telemetry,
           %{
             typed_key => @secret,
             provider_error: [:provider_error, %{api_key: @secret} | "tail"]
           }}
        ],
        limit: 10,
        max_bytes: 10_000,
        redact: true
      )

    rendered = Imp.Observability.render_inspection(inspection)
    assert rendered =~ "[REDACTED]"
    refute rendered =~ @secret
  end

  test "redaction can only be disabled explicitly" do
    inspection =
      Imp.Observability.inspect_artifact({:provider, [%{prompt: @secret, outputs: ["ok"]}]},
        redact: false
      )

    assert Kernel.inspect(inspection) =~ @secret
  end

  test "callbacks redact measurements even when telemetry bypasses Imp.Telemetry" do
    trace =
      Imp.Observability.trace(
        fn ->
          trace_id = Enum.find_value(Imp.Telemetry.context(), &Map.get(&1, :trace_id))

          :telemetry.execute([:imp, :tool, :stop], %{authorization: @secret}, %{
            trace_id: trace_id
          })
        end,
        events: [[:imp, :tool, :stop]]
      )

    assert [%{payload: %{measurements: %{authorization: "[REDACTED]"}}}] =
             Imp.Observability.inspect_artifact(trace).entries
  end

  test "unsupported artifact errors do not echo credentials" do
    assert_raise ArgumentError, fn ->
      Imp.Observability.inspect_artifact({:unknown, %{api_key: @secret}})
    end

    try do
      Imp.Observability.inspect_artifact({:unknown, %{api_key: @secret}})
    rescue
      error ->
        assert Exception.message(error) =~ "[REDACTED]"
        refute Exception.message(error) =~ @secret
    end
  end
end
