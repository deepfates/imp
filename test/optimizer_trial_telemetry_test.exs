defmodule OptimizerTrialTelemetryTest do
  # `Imp.subscribe_optimizer_progress/1` attaches a global telemetry handler, so
  # these tests run non-async to keep other optimizer runs out of the mailbox.
  use ExUnit.Case, async: false

  alias Imp.Optimizer.BootstrapFewShotWithRandomSearch

  defp program do
    Imp.predict("question -> answer",
      lm: Imp.LM.Static.new(handler: fn _messages, _opts -> %{answer: "constant"} end)
    )
  end

  defp trainset do
    Enum.map(1..4, fn index ->
      Imp.example(question: "question-#{index}", answer: "constant")
      |> Imp.with_inputs(:question)
    end)
  end

  defp run_random_search do
    BootstrapFewShotWithRandomSearch.new(
      Imp.Metrics.exact_match(:answer),
      num_candidate_programs: 1,
      max_bootstrapped_demos: 1,
      max_labeled_demos: 1
    )
    |> BootstrapFewShotWithRandomSearch.compile(program(), trainset(), trainset())
  end

  test "subscribe_optimizer_progress delivers trial events for a BootstrapFewShotWithRandomSearch run" do
    subscription = Imp.subscribe_optimizer_progress()
    on_exit(fn -> Imp.unsubscribe_optimizer_progress(subscription) end)

    run_random_search()

    # The ticket's acceptance bar: at least one event arrives for a subscribed
    # optimizer run. Trial spans identify the optimizer and the candidate seed.
    assert_receive {:imp_optimizer_progress, [:imp, :optimizer, :trial, :start],
                    %{system_time: _}, %{optimizer: :random_search, seed: -3, trial: 0}}

    assert_receive {:imp_optimizer_progress, [:imp, :optimizer, :trial, :stop], %{duration: _},
                    %{optimizer: :random_search, seed: -3, trial: 0, result: :ok}}

    # Every candidate seed in the schedule (-3..0 for one candidate program)
    # gets its own trial span.
    for seed <- [-2, -1, 0] do
      assert_receive {:imp_optimizer_progress, [:imp, :optimizer, :trial, :stop], %{duration: _},
                      %{optimizer: :random_search, seed: ^seed, result: :ok}}
    end
  end

  test "trial events also arrive as normalized status messages" do
    subscription = Imp.subscribe_optimizer_progress()
    on_exit(fn -> Imp.unsubscribe_optimizer_progress(subscription) end)

    run_random_search()

    assert_receive {:imp_status,
                    %Imp.Observability.Status{state: :running, phase: "optimizer_trial_start"}}

    assert_receive {:imp_status,
                    %Imp.Observability.Status{state: :succeeded, phase: "optimizer_trial_stop"}}
  end

  test "Imp.trace captures trial spans emitted during optimization" do
    trace =
      Imp.trace(&run_random_search/0,
        events: [
          [:imp, :optimizer, :trial, :start],
          [:imp, :optimizer, :trial, :stop],
          [:imp, :optimizer, :trial, :exception]
        ]
      )

    events = Enum.map(trace.events, &elem(&1, 0))

    assert [:imp, :optimizer, :trial, :start] in events
    assert [:imp, :optimizer, :trial, :stop] in events
    refute [:imp, :optimizer, :trial, :exception] in events
    assert length(events) == 8
  end
end
