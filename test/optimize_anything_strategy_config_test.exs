defmodule Imp.Optimize.Anything.StrategyConfigTest do
  use ExUnit.Case, async: true

  alias Imp.Optimize.Anything
  alias Imp.Optimize.Anything.{Config, Result}
  alias Imp.Optimizer.GEPA.{Acceptance, CandidateSelector}

  defmodule ReleasedReflectionStrategy do
    def reflect(_candidate, _dataset, [component]) do
      %{new_texts: %{component => "1.0"}}
    end
  end

  defmodule VersionedParentSelector do
    @behaviour CandidateSelector

    defstruct [:version]

    @impl true
    def select_candidate(_selector, state, rng_state) do
      {List.last(state.candidates).id, rng_state}
    end

    @impl true
    def identity(selector), do: %{"version" => selector.version}
  end

  test "released reflection strategy executes through the public API and resumes from JSON" do
    calls = start_supervised!({Agent, fn -> 0 end})

    evaluator = fn candidate, _example ->
      Agent.update(calls, &(&1 + 1))
      String.to_float(candidate)
    end

    config =
      Config.new(
        reflection: [
          reflection_strategy: ReleasedReflectionStrategy,
          reflection_minibatch_size: 1
        ],
        engine: [max_candidate_proposals: 1]
      )

    result =
      Anything.run("0.0", evaluator,
        dataset: [%{id: :train}],
        valset: [%{id: :selection}],
        config: config
      )

    assert Result.best_candidate(result) == "1.0"
    calls_before_resume = Agent.get(calls, & &1)
    checkpoint = result.checkpoint |> Jason.encode!() |> Jason.decode!()

    resumed =
      Anything.run("0.0", evaluator,
        dataset: [%{id: :train}],
        valset: [%{id: :selection}],
        config: config,
        resume_state: checkpoint
      )

    assert Result.best_candidate(resumed) == "1.0"
    assert resumed.candidates == result.candidates
    assert Agent.get(calls, & &1) == calls_before_resume
  end

  test "public sampling, selection, and acceptance strategies execute and return an applicable artifact" do
    receiver = self()
    proposals = start_supervised!({Agent, fn -> ["0.25", "0.75", "0.50"] end})

    acceptance =
      Acceptance.callback(fn context ->
        send(receiver, {:acceptance, context.before_score, context.after_score})
        context.after_score >= context.before_score
      end)

    selection =
      {:callback,
       fn candidates, _state, accepted? ->
         send(receiver, {:selection, Enum.map(candidates, & &1.margin)})

         candidates
         |> Enum.filter(accepted?)
         |> Enum.max_by(& &1.margin, fn -> nil end)
         |> List.wrap()
       end}

    evaluator = fn candidate, _example -> String.to_float(candidate) end

    proposer = fn _candidate, _component, _records, _iteration ->
      Agent.get_and_update(proposals, fn [next | rest] -> {next, rest} end)
    end

    config =
      Config.new(
        reflection: [reflection_minibatch_size: 1],
        engine: [
          max_candidate_proposals: 1,
          sampling_strategy: {:same_parent, 3},
          selection_strategy: selection,
          acceptance_criterion: acceptance
        ]
      )

    result =
      Anything.run(
        "0.0",
        evaluator,
        dataset: Enum.map(1..3, &%{id: &1}),
        valset: [%{id: :selection}],
        fallback_proposer: proposer,
        config: config
      )

    assert Result.best_candidate(result) == "0.75"
    assert result.candidates == [%{current_candidate: "0.0"}, %{current_candidate: "0.75"}]
    assert length(result.rejected) == 2

    assert_receive {:selection, margins}
    assert Enum.sort(margins) == [0.25, 0.5, 0.75]

    assert collect_acceptance([]) |> Enum.sort() == [0.25, 0.5, 0.75]

    resumed =
      Anything.run("0.0", evaluator,
        dataset: Enum.map(1..3, &%{id: &1}),
        valset: [%{id: :selection}],
        fallback_proposer: proposer,
        config: config,
        resume_state: result.checkpoint
      )

    assert resumed.candidates == result.candidates

    consumer = %{instruction: "old", execute: fn instruction -> String.to_float(instruction) end}
    applied = %{consumer | instruction: Anything.best_candidate(result)}

    assert Task.await(Task.async(fn -> applied.execute.(applied.instruction) end)) == 0.75
  end

  test "improvement-or-equal is mapped to the engine instead of being ignored" do
    run = fn criterion ->
      Anything.run(
        "base",
        fn _candidate -> 1.0 end,
        fallback_max_iterations: 1,
        fallback_proposer: fn _candidate, _component, _records, _iteration -> "equal" end,
        config: Config.new(engine: [acceptance_criterion: criterion])
      )
    end

    strict = run.(:strict_improvement)
    equal = run.(:improvement_or_equal)

    assert strict.candidates == [%{current_candidate: "base"}]

    assert equal.candidates == [
             %{current_candidate: "base"},
             %{current_candidate: "equal"}
           ]
  end

  test "checkpoint resume binds strategy semantics rather than only task width" do
    evaluator_calls = start_supervised!({Agent, fn -> 0 end})

    evaluator = fn candidate, _example ->
      Agent.update(evaluator_calls, &(&1 + 1))
      String.to_integer(candidate)
    end

    proposer = fn _candidate, _component, _records, iteration -> Integer.to_string(iteration) end

    {:checkpoint, checkpoint} =
      catch_throw(
        Anything.run(
          "0",
          evaluator,
          strategy_options({:same_parent, 2}, :best_improvement, :strict_improvement,
            fallback_proposer: proposer,
            checkpoint_fn: fn checkpoint ->
              if checkpoint["iteration"] == 1,
                do: throw({:checkpoint, checkpoint}),
                else: :ok
            end
          )
        )
      )

    checkpoint = checkpoint |> Jason.encode!() |> Jason.decode!()
    calls_before_resume = Agent.get(evaluator_calls, & &1)

    mismatches = [
      {{:independent, 2}, :best_improvement, :strict_improvement},
      {{:same_parent, 2}, :all_improvements, :strict_improvement},
      {{:same_parent, 2}, :best_improvement, :improvement_or_equal}
    ]

    for {sampling, selection, acceptance} <- mismatches do
      assert_raise ArgumentError, ~r/resume proposal policy mismatch/, fn ->
        Anything.run(
          "0",
          evaluator,
          strategy_options(sampling, selection, acceptance,
            fallback_proposer: proposer,
            resume_state: checkpoint
          )
        )
      end

      assert Agent.get(evaluator_calls, & &1) == calls_before_resume
    end

    resumed =
      Anything.run(
        "0",
        evaluator,
        strategy_options({:same_parent, 2}, :best_improvement, :strict_improvement,
          fallback_proposer: proposer,
          resume_state: checkpoint
        )
      )

    assert resumed.checkpoint["iteration"] == 2
    assert Result.best_candidate(resumed) == "2"
  end

  test "checkpoint resume rejects parent-candidate selector config drift before evaluation" do
    evaluator_calls = start_supervised!({Agent, fn -> 0 end})

    evaluator = fn candidate, _example ->
      Agent.update(evaluator_calls, &(&1 + 1))
      String.to_integer(candidate)
    end

    proposer = fn _candidate, _component, _records, iteration -> Integer.to_string(iteration) end

    run = fn selector, overrides ->
      Anything.run(
        "0",
        evaluator,
        Keyword.merge(
          [
            dataset: [%{id: :train}],
            valset: [%{id: :selection}],
            fallback_proposer: proposer,
            config:
              Config.new(
                engine: [
                  max_candidate_proposals: 2,
                  candidate_selection_strategy: selector
                ]
              )
          ],
          overrides
        )
      )
    end

    {:checkpoint, checkpoint} =
      catch_throw(
        run.(%VersionedParentSelector{version: "v1"},
          checkpoint_fn: fn checkpoint ->
            if checkpoint["iteration"] == 1,
              do: throw({:checkpoint, checkpoint}),
              else: :ok
          end
        )
      )

    calls_before_resume = Agent.get(evaluator_calls, & &1)

    assert_raise ArgumentError, ~r/candidate selection.*identity mismatch/, fn ->
      run.(%VersionedParentSelector{version: "v2"}, resume_state: checkpoint)
    end

    assert Agent.get(evaluator_calls, & &1) == calls_before_resume

    resumed =
      run.(%VersionedParentSelector{version: "v1"}, resume_state: checkpoint)

    assert Result.best_candidate(resumed) == "2"
  end

  test "config persists built-in strategies and rejects unsupported custom sampling objects" do
    config =
      Config.new(
        engine: [
          sampling_strategy: {:pxn, 2, 3},
          selection_strategy: {:top_k, 2},
          acceptance_criterion: :improvement_or_equal,
          max_reflection_cost: 0.0
        ]
      )

    persisted = config |> Config.to_map() |> Jason.encode!() |> Jason.decode!()
    assert Config.from_map(persisted) == config

    opts = Config.to_engine_options(config)
    assert opts[:sampling_strategy] == {:pxn, 2, 3}
    assert opts[:proposal_concurrency] == 6
    assert opts[:selection_strategy] == {:top_k, 2}
    assert opts[:acceptance_policy] == :equal_or_better
    assert opts[:max_reflection_cost] == 0.0

    assert_raise ArgumentError, ~r/custom upstream strategy objects are not supported/, fn ->
      Config.new(engine: [sampling_strategy: URI.parse("https://example.test")])
    end

    assert_raise ArgumentError, ~r/:selection_strategy must be/, fn ->
      Config.new(engine: [selection_strategy: URI.parse("https://example.test")])
    end

    assert_raise ArgumentError, ~r/custom upstream criterion objects are not supported/, fn ->
      Config.new(engine: [acceptance_criterion: URI.parse("https://example.test")])
    end

    assert_raise ArgumentError, ~r/unknown Optimize Anything options: \[:apply_best\]/, fn ->
      Anything.run("base", fn _candidate -> 1.0 end,
        apply_best: fn _candidate -> :ok end,
        config: Config.new(engine: [max_candidate_proposals: 0])
      )
    end
  end

  defp strategy_options(sampling, selection, acceptance, overrides) do
    base = [
      dataset: [%{id: 1}, %{id: 2}],
      valset: [%{id: :selection}],
      fallback_max_iterations: 2,
      config:
        Config.new(
          reflection: [reflection_minibatch_size: 1],
          engine: [
            sampling_strategy: sampling,
            selection_strategy: selection,
            acceptance_criterion: acceptance
          ]
        )
    ]

    Keyword.merge(base, overrides)
  end

  defp collect_acceptance(scores) do
    receive do
      {:acceptance, before_score, after_score} ->
        if before_score != 0.0, do: raise("unexpected acceptance baseline")
        collect_acceptance([after_score | scores])
    after
      0 -> scores
    end
  end
end
