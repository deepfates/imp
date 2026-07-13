defmodule DSEx.Optimizer.GEPA.EvaluationCacheTest do
  use ExUnit.Case, async: true

  alias DSEx.Optimizer.GEPA.{Adapter, Engine, EvaluationCache, Result}

  defmodule TrackingAdapter do
    defstruct [:owner]
    @behaviour Adapter

    def evaluate(%__MODULE__{owner: owner}, batch, candidate, opts) do
      capture_traces = Keyword.get(opts, :capture_traces, false)
      send(owner, {:gepa_evaluation, batch, capture_traces})

      scores =
        Enum.map(batch, fn value ->
          if String.contains?(candidate.main, Atom.to_string(value)), do: 1.0, else: 0.0
        end)

      trajectories =
        if capture_traces, do: %{main: List.duplicate(nil, length(batch))}, else: %{}

      Result.new(batch, scores,
        trajectories: trajectories,
        side_information: %{
          main:
            Enum.map(batch, fn value ->
              if String.contains?(candidate.main, Atom.to_string(value)), do: nil, else: value
            end)
        },
        metadata: %{metric_calls: length(batch)}
      )
    end

    def make_reflective_dataset(_adapter, _candidate, result, components) do
      Map.new(components, fn component ->
        records =
          result.side_information
          |> Map.fetch!(component)
          |> Enum.reject(&is_nil/1)
          |> Enum.map(&%{feedback: &1})

        {component, records}
      end)
    end
  end

  test "reuses overlapping examples independently of batch shape and order" do
    candidate = %{main: "answer carefully"}

    cache =
      EvaluationCache.put(
        %{},
        candidate,
        [:alpha, :beta],
        Result.new(["A", "B"], [0.25, 0.75], objective_scores: [%{quality: 0.2}, %{quality: 0.8}])
      )

    {hits, missing} = EvaluationCache.lookup(cache, candidate, [:beta, :gamma, :alpha])

    assert missing == [1]
    assert hits[0].output == "B"
    assert hits[2].score == 0.25

    result =
      EvaluationCache.assemble(
        [:beta, :gamma, :alpha],
        hits,
        missing,
        Result.new(["C"], [1.0],
          objective_scores: [%{quality: 1.0}],
          side_information: %{main: ["fresh diagnostic"]},
          metadata: %{metric_calls: 1}
        )
      )

    assert result.outputs == ["B", "C", "A"]
    assert result.scores == [0.75, 1.0, 0.25]

    assert result.objective_scores == [
             %{quality: 0.8},
             %{quality: 1.0},
             %{quality: 0.2}
           ]

    assert result.metadata.cache_hits == 2
    assert result.metadata.cache_misses == 1
    assert result.metadata.metric_calls == 1
    assert result.side_information == %{main: ["fresh diagnostic"]}
  end

  test "a fully cached batch performs no metric calls" do
    candidate = %{main: "cached"}
    cached = Result.new([:ok], [1.0])
    cache = EvaluationCache.put(%{}, candidate, [%{id: 1}], cached)
    {hits, []} = EvaluationCache.lookup(cache, candidate, [%{id: 1}])

    result = EvaluationCache.assemble([%{id: 1}], hits, [], nil)

    assert result.outputs == [:ok]
    assert result.scores == [1.0]
    assert result.side_information == %{}
    assert result.metadata == %{cache_hits: 1, cache_misses: 0, metric_calls: 0}
  end

  test "candidate identity covers every named component" do
    example = %{id: 1}

    cache =
      EvaluationCache.put(
        %{},
        %{planner: "one", writer: "two"},
        [example],
        Result.new([:ok], [1.0])
      )

    assert {%{}, [0]} =
             EvaluationCache.lookup(cache, %{planner: "changed", writer: "two"}, [example])
  end

  test "rejects a missing result that is not aligned with misses" do
    assert_raise ArgumentError, ~r/must align with 2 missing examples/, fn ->
      EvaluationCache.assemble([:a, :b], %{}, [0, 1], Result.new([:a], [1.0]))
    end
  end

  test "rejects partial objective-score coverage" do
    candidate = %{main: "cached"}
    cache = EvaluationCache.put(%{}, candidate, [:cached], Result.new([:ok], [1.0]))
    {hits, [1]} = EvaluationCache.lookup(cache, candidate, [:cached, :fresh])

    assert_raise ArgumentError, ~r/inconsistent objective-score presence/, fn ->
      EvaluationCache.assemble(
        [:cached, :fresh],
        hits,
        [1],
        Result.new([:fresh], [0.5], objective_scores: [%{quality: 0.5}])
      )
    end
  end

  test "engine evaluates only per-example misses while trace capture stays fresh" do
    proposer = fn candidate, :main, records, _iteration ->
      additions = Enum.map_join(records, " ", &Atom.to_string(&1.feedback))
      String.trim(candidate.main <> " " <> additions)
    end

    state =
      Engine.run(
        %TrackingAdapter{owner: self()},
        %{main: "a"},
        [:a, :d],
        [:a, :b, :c],
        proposer,
        max_iterations: 1,
        minibatch_size: 2,
        seed: 0
      )

    assert_receive {:gepa_evaluation, [:a, :b, :c], false}
    assert_receive {:gepa_evaluation, trace_batch, true}
    assert MapSet.new(trace_batch) == MapSet.new([:a, :d])
    assert_receive {:gepa_evaluation, proposal_batch, false}
    assert MapSet.new(proposal_batch) == MapSet.new([:a, :d])
    assert_receive {:gepa_evaluation, [:b, :c], false}
    refute_receive {:gepa_evaluation, _, _}

    assert state.budget.metric_calls == 9
    assert List.last(state.candidates).candidate.main == "a d"
  end
end
