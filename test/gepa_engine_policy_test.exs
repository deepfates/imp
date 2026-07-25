defmodule Imp.Optimizer.GEPA.EnginePolicyTest do
  use ExUnit.Case, async: true

  alias Imp.Optimizer.GEPA.{
    Adapter,
    Budget,
    CandidateSelector,
    CandidateSelector.TopKPareto,
    Engine,
    Result
  }

  defmodule FirstSelector do
    @behaviour CandidateSelector

    @impl true
    def select_candidate(state, rng_state), do: {hd(state.candidates).id, rng_state}
  end

  defmodule OffsetSelector do
    @behaviour CandidateSelector
    defstruct offset: 0

    @impl true
    def select_candidate(selector, state, rng_state) do
      {Enum.at(state.candidates, selector.offset).id, rng_state}
    end
  end

  defmodule UnknownSelector do
    @behaviour CandidateSelector

    @impl true
    def select_candidate(_state, rng_state), do: {:missing, rng_state}
  end

  defmodule MissingSelector do
  end

  defmodule RecordingCallback do
    @behaviour Imp.Optimizer.GEPA.Callback

    @impl true
    def on_evaluation_skipped(event, owner), do: send(owner, {:evaluation_skipped, event})
  end

  defmodule PerfectAdapter do
    @behaviour Adapter
    defstruct []

    @impl true
    def evaluate(_adapter, batch, candidate, opts) do
      trajectories =
        if Keyword.get(opts, :capture_traces, false),
          do: %{main: List.duplicate(nil, length(batch))},
          else: %{}

      Result.new(
        List.duplicate(candidate.main, length(batch)),
        List.duplicate(1.0, length(batch)),
        trajectories: trajectories,
        side_information: %{main: []},
        metadata: %{metric_calls: length(batch)}
      )
    end

    @impl true
    def make_reflective_dataset(_adapter, _candidate, _result, _components), do: %{}
  end

  defmodule OutputAdapter do
    @behaviour Adapter
    defstruct []

    @impl true
    def evaluate(_adapter, batch, candidate, opts) do
      {outputs, scores} =
        Enum.map(batch, &evaluation(&1, candidate.main))
        |> Enum.unzip()

      trajectories =
        if Keyword.get(opts, :capture_traces, false),
          do: %{main: List.duplicate(nil, length(batch))},
          else: %{}

      Result.new(outputs, scores,
        trajectories: trajectories,
        side_information: %{main: []},
        metadata: %{metric_calls: length(batch)}
      )
    end

    @impl true
    def make_reflective_dataset(_adapter, _candidate, _result, _components), do: %{}

    defp evaluation(:train, "base"), do: {"base-train", 0.0}
    defp evaluation(:train, "tie"), do: {"tie-train", 1.0}
    defp evaluation(:train, "better"), do: {"better-train", 2.0}
    defp evaluation(:a, "base"), do: {"base-a", 0.5}
    defp evaluation(:b, "base"), do: {"base-b", 0.5}
    defp evaluation(:a, "tie"), do: {"tie-a", 0.5}
    defp evaluation(:b, "tie"), do: {"tie-b", 0.5}
    defp evaluation(:a, "better"), do: {"better-a", 0.8}
    defp evaluation(:b, "better"), do: {"better-b", 0.4}
  end

  test "released selectors implement source selection policies" do
    state = selector_state()

    {pareto, pareto_rng} = CandidateSelector.select(:pareto, state)
    assert pareto.id in 0..2
    refute dump_rng(pareto_rng) == dump_rng(state.rng_state)

    {current_best, current_rng} = CandidateSelector.select(:current_best, state)
    assert current_best.id == 2
    assert dump_rng(current_rng) == dump_rng(state.rng_state)

    {draw, after_draw} = :rand.uniform_s(state.rng_state)
    assert draw < 0.1
    {position, expected_rng} = :rand.uniform_s(length(state.candidates), after_draw)
    {epsilon, epsilon_rng} = CandidateSelector.select(:epsilon_greedy, state)
    assert epsilon.id == Enum.at(state.candidates, position - 1).id
    assert dump_rng(epsilon_rng) == dump_rng(expected_rng)

    {top_k, _rng} = CandidateSelector.select(:top_k_pareto, top_k_state())
    assert top_k.id in 0..4

    {fallback, fallback_rng} =
      CandidateSelector.select(%TopKPareto{k: 1}, top_k_fallback_state())

    assert fallback.id == 0
    assert dump_rng(fallback_rng) == dump_rng(top_k_fallback_state().rng_state)
  end

  test "current best keeps the first candidate on aggregate-score ties" do
    state = selector_state([0.9, 0.4, 0.9])
    {candidate, _rng} = CandidateSelector.select(:current_best, state)
    assert candidate.id == 0
  end

  test "custom selector modules and structs are validated with checked results" do
    state = selector_state()

    assert {candidate, _rng} = CandidateSelector.select(FirstSelector, state)
    assert candidate.id == 0

    assert {candidate, _rng} = CandidateSelector.select(%OffsetSelector{offset: 1}, state)
    assert candidate.id == 1

    assert_raise ArgumentError, ~r/must implement select_candidate\/2/, fn ->
      CandidateSelector.validate!(MissingSelector)
    end

    assert_raise ArgumentError, ~r/unknown candidate ID/, fn ->
      CandidateSelector.select(UnknownSelector, state)
    end
  end

  test "epsilon-greedy continues from the JSON-persisted shared RNG" do
    state = selector_state()
    {_first, advanced_rng} = CandidateSelector.select(:epsilon_greedy, state)
    advanced = %{state | rng_state: advanced_rng}

    expected = CandidateSelector.select(:epsilon_greedy, advanced)

    checkpoint = advanced |> Engine.dump_state() |> Jason.encode!() |> Jason.decode!()

    resumed =
      Engine.run(
        %PerfectAdapter{},
        %{main: "candidate-0"},
        [:train],
        [:validation],
        fn _, _, _, _ -> "unused" end,
        max_iterations: 0,
        resume_state: checkpoint
      )

    actual = CandidateSelector.select(:epsilon_greedy, resumed)
    assert elem(actual, 0).id == elem(expected, 0).id
    assert dump_rng(elem(actual, 1)) == dump_rng(elem(expected, 1))
  end

  test "perfect parent minibatches skip reflection without refunding evaluation budget" do
    owner = self()

    state =
      Engine.run(
        %PerfectAdapter{},
        %{main: "perfect"},
        [:train],
        [:validation],
        fn _, _, _, _ -> flunk("perfect scores must skip the proposer") end,
        max_iterations: 2,
        skip_perfect_score: true,
        perfect_score: 1.0,
        callbacks: [{RecordingCallback, owner}]
      )

    assert state.iteration == 2
    assert state.budget.metric_calls == 3
    assert state.budget.full_evaluations == 1
    assert state.budget.reflection_calls == 0
    assert length(state.candidates) == 1

    for iteration <- 1..2 do
      assert_receive {:evaluation_skipped,
                      %{
                        iteration: ^iteration,
                        candidate_idx: 0,
                        reason: :all_scores_perfect,
                        scores: [1.0]
                      }}
    end

    assert_raise ArgumentError, ~r/perfect_score must be numeric/, fn ->
      Engine.run(
        %PerfectAdapter{},
        %{main: "perfect"},
        [:train],
        [:validation],
        fn _, _, _, _ -> "unused" end,
        max_iterations: 0,
        skip_perfect_score: true
      )
    end
  end

  test "best validation outputs append ties, replace strict improvements, and resume" do
    state =
      Engine.run(
        %OutputAdapter{},
        %{main: "base"},
        [:train],
        [:a, :b],
        fn _candidate, :main, _records, iteration ->
          if iteration == 1, do: "tie", else: "better"
        end,
        max_iterations: 2,
        candidate_selection_strategy: :current_best,
        acceptance_policy: :equal_or_better,
        track_best_outputs: true,
        cache_evaluation: false
      )

    assert state.best_outputs_valset == %{
             0 => [{2, "better-a"}],
             1 => [{0, "base-b"}, {1, "tie-b"}]
           }

    checkpoint = state |> Engine.dump_state() |> Jason.encode!() |> Jason.decode!()

    resumed =
      Engine.run(
        %OutputAdapter{},
        %{main: "base"},
        [:train],
        [:a, :b],
        fn _, _, _, _ -> "unused" end,
        max_iterations: 2,
        resume_state: checkpoint,
        acceptance_policy: :equal_or_better,
        cache_evaluation: false
      )

    assert resumed.best_outputs_valset == state.best_outputs_valset
  end

  defp selector_state(scores \\ [0.2, 0.5, 0.9]) do
    results = Enum.map(scores, &Result.new([&1], [&1], metadata: %{validation_ids: [0]}))
    entries = entries(results)

    %Engine.State{
      budget: Budget.new(),
      candidates: entries,
      rng_state: :rand.seed_s(:exsss, {6, 7, 8})
    }
  end

  defp top_k_state do
    results = [
      Result.new([], [0.9, 0.9, 0.9, 0.9, 0.9, 0.9]),
      Result.new([], [0.8, 0.8, 0.8, 0.8, 0.8, 0.8]),
      Result.new([], [0.7, 0.7, 0.7, 0.7, 0.7, 0.7]),
      Result.new([], [0.6, 0.6, 0.6, 0.6, 0.6, 0.6]),
      Result.new([], [0.5, 0.5, 0.5, 0.5, 0.5, 0.5]),
      Result.new([], [1.0, 0.0, 0.0, 0.0, 0.0, 0.0])
    ]

    %Engine.State{
      budget: Budget.new(),
      candidates: entries(results),
      rng_state: :rand.seed_s(:exsss, {2, 3, 4})
    }
  end

  defp top_k_fallback_state do
    results = [
      Result.new([], [0.8, 0.8, 0.8]),
      Result.new([], [1.0, 0.0, 0.0]),
      Result.new([], [0.0, 1.0, 0.0]),
      Result.new([], [0.0, 0.0, 1.0])
    ]

    %Engine.State{
      budget: Budget.new(),
      candidates: entries(results),
      rng_state: :rand.seed_s(:exsss, {10, 11, 12})
    }
  end

  defp entries(results) do
    results
    |> Enum.with_index()
    |> Enum.map(fn {result, id} ->
      %Engine.Entry{id: id, candidate: %{main: "candidate-#{id}"}, validation: result}
    end)
  end

  defp dump_rng(rng_state), do: :rand.export_seed_s(rng_state)
end
