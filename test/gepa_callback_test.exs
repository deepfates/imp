defmodule Imp.Optimizer.GEPA.CallbackTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Imp.Optimizer.GEPA.{Adapter, Callback, Engine, Result}

  defmodule AdapterFixture do
    defstruct []
    @behaviour Adapter

    @impl true
    def evaluate(_adapter, batch, candidate, opts) do
      scores =
        Enum.map(batch, fn required ->
          if String.contains?(candidate.main, required), do: 1.0, else: 0.0
        end)

      trajectories =
        if Keyword.get(opts, :capture_traces, false),
          do: %{main: List.duplicate(nil, length(batch))},
          else: %{}

      Result.new(scores, scores,
        trajectories: trajectories,
        side_information: %{main: Enum.reject(batch, &String.contains?(candidate.main, &1))},
        metadata: %{metric_calls: length(batch)}
      )
    end

    @impl true
    def make_reflective_dataset(_adapter, _candidate, result, components) do
      Map.new(components, fn component ->
        {component, Enum.map(result.side_information[component], &%{feedback: &1})}
      end)
    end
  end

  defmodule Recorder do
    @behaviour Callback

    for event <- Callback.events() do
      def unquote(event)(payload, owner) do
        send(owner, {:gepa_callback, unquote(event), payload})
      end
    end
  end

  defmodule PartialRecorder do
    @behaviour Callback

    @impl true
    def on_optimization_end(payload, owner),
      do: send(owner, {:partial_callback, payload.total_iterations})
  end

  defmodule FailingCallback do
    @behaviour Callback

    @impl true
    def on_candidate_selected(_payload, _context) do
      raise "api_key=sk-callback-secret-must-not-leak"
    end
  end

  defmodule BareRecorder do
    @behaviour Callback

    @impl true
    def on_optimization_end(payload, context),
      do: send(payload.owner_for_test, {:bare_callback, context})
  end

  test "every hook takes (event, context); a bare module's context is nil" do
    assert :ok =
             Callback.notify([BareRecorder], :on_optimization_end, %{owner_for_test: self()})

    assert_received {:bare_callback, nil}

    assert :ok =
             Callback.notify([{BareRecorder, :ctx}], :on_optimization_end, %{
               owner_for_test: self()
             })

    assert_received {:bare_callback, :ctx}
  end

  test "emits the observational lifecycle synchronously in meaningful engine order" do
    state =
      Engine.run(
        %AdapterFixture{},
        %{main: "base"},
        ["alpha", "beta"],
        ["alpha", "beta"],
        fn candidate, :main, records, _iteration ->
          addition = Enum.map_join(records, " ", & &1.feedback)
          String.trim(candidate.main <> " " <> addition)
        end,
        max_iterations: 2,
        minibatch_size: 2,
        callbacks: [{Recorder, self()}, {PartialRecorder, self()}]
      )

    events = drain_events([])
    names = Enum.map(events, &elem(&1, 0))

    assert hd(names) == :on_optimization_start
    assert List.last(names) == :on_optimization_end
    assert Enum.count(names, &(&1 == :on_iteration_start)) == 2
    assert Enum.count(names, &(&1 == :on_iteration_end)) == 2
    assert :on_candidate_selected in names
    assert :on_minibatch_sampled in names
    assert :on_reflective_dataset_built in names
    assert :on_proposal_start in names
    assert :on_proposal_end in names
    assert :on_candidate_accepted in names
    assert :on_candidate_rejected in names
    assert :on_pareto_front_updated in names
    assert :on_valset_evaluated in names
    assert :on_state_saved in names
    assert :on_budget_updated in names

    assert before?(names, :on_optimization_start, :on_valset_evaluated)
    assert before?(names, :on_candidate_selected, :on_minibatch_sampled)
    assert before?(names, :on_reflective_dataset_built, :on_proposal_start)
    assert before?(names, :on_proposal_start, :on_proposal_end)
    assert before?(names, :on_pareto_front_updated, :on_candidate_accepted)

    accepted = event_payload(events, :on_candidate_accepted)
    assert accepted.new_candidate_idx == 1
    assert accepted.parent_ids == [0]

    ended = events |> Enum.filter(&(elem(&1, 0) == :on_iteration_end)) |> Enum.map(&elem(&1, 1))
    assert Enum.map(ended, & &1.proposal_accepted) == [true, false]
    assert_received {:partial_callback, 2}
    assert state.iteration == 2
  end

  @tag capture_log: true
  test "isolates callback failures and reports only redacted failure metadata" do
    telemetry_ref =
      Imp.Test.TelemetryHelpers.attach([[:imp, :optimizer, :gepa, :callback, :exception]])

    log =
      capture_log(fn ->
        state =
          Engine.run(
            %AdapterFixture{},
            %{main: "base"},
            ["alpha"],
            ["alpha"],
            fn candidate, :main, records, _iteration ->
              candidate.main <> Enum.map_join(records, "", & &1.feedback)
            end,
            max_iterations: 1,
            callbacks: [{FailingCallback, :ignored}, {Recorder, self()}]
          )

        assert state.iteration == 1
      end)

    assert_receive {:gepa_callback, :on_candidate_selected, %{candidate_idx: 0}}
    assert_receive {:gepa_callback, :on_evaluation_skipped, %{reason: :cache_hit}}

    assert_receive {
      ^telemetry_ref,
      [:imp, :optimizer, :gepa, :callback, :exception],
      %{count: 1},
      metadata
    }

    assert metadata.callback == FailingCallback
    assert metadata.callback_event == :on_candidate_selected
    assert metadata.error_class == RuntimeError
    refute Map.has_key?(metadata, :reason)
    refute log =~ "sk-callback-secret"
    assert log =~ "GEPA callback failed"
  end

  test "validates and stores the public callback option" do
    metric = fn _example, _prediction -> 1.0 end
    optimizer = Imp.Optimizer.GEPA.new(metric, callbacks: [{PartialRecorder, self()}])

    assert optimizer.callbacks == [{PartialRecorder, self()}]

    assert_raise ArgumentError, ~r/callback modules/, fn ->
      Imp.Optimizer.GEPA.new(metric, callbacks: [fn _event -> :ok end])
    end
  end

  defp drain_events(events) do
    receive do
      {:gepa_callback, name, payload} -> drain_events([{name, payload} | events])
    after
      0 -> Enum.reverse(events)
    end
  end

  defp before?(names, first, second),
    do: Enum.find_index(names, &(&1 == first)) < Enum.find_index(names, &(&1 == second))

  defp event_payload(events, name), do: events |> Enum.find(&(elem(&1, 0) == name)) |> elem(1)
end
