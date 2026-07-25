defmodule Imp.Optimize.Anything.BatchSamplerTest do
  use ExUnit.Case, async: true

  alias Imp.Optimize.Anything
  alias Imp.Optimize.Anything.{Config, Result}
  alias Imp.Optimizer.GEPA.BatchSampler

  defmodule PlannedSampler do
    @behaviour BatchSampler

    defstruct plan: [[1], [0]], cursor: 0, identity_tag: :consumer_plan

    @impl true
    def minibatch_size(_sampler), do: 1

    @impl true
    def identity(sampler), do: {sampler.identity_tag, sampler.plan}

    @impl true
    def next_minibatch_ids(sampler, _trainset, context, rng_state) do
      plan_index = rem(sampler.cursor, length(sampler.plan))

      unless context.iteration == sampler.cursor and context.call_index == 0 do
        raise "custom sampler state or iteration context did not resume"
      end

      ids = Enum.at(sampler.plan, plan_index)
      {ids, %{sampler | cursor: sampler.cursor + 1}, rng_state}
    end

    @impl true
    def dump_state(sampler), do: %{cursor: sampler.cursor}

    @impl true
    def load_state(sampler, %{cursor: cursor}) when is_integer(cursor) and cursor >= 0,
      do: %{sampler | cursor: cursor}
  end

  test "public config executes a custom sampler and keeps its exact state across JSON resume" do
    trainset = [%{split: :train, id: :first}, %{split: :train, id: :second}]
    valset = [%{split: :selection, id: :held_out}]
    proposer = fn _candidate, _component, _records, iteration -> Integer.to_string(iteration) end

    resumed_log = start_supervised!({Agent, fn -> [] end}, id: :custom_sampler_resumed_log)
    full_log = start_supervised!({Agent, fn -> [] end}, id: :custom_sampler_full_log)

    {:checkpoint, checkpoint} =
      catch_throw(
        Anything.run(
          "0",
          evaluator(resumed_log),
          options(trainset, valset, proposer,
            checkpoint_fn: fn checkpoint ->
              if checkpoint["iteration"] == 1,
                do: throw({:checkpoint, checkpoint}),
                else: :ok
            end
          )
        )
      )

    persisted = checkpoint |> Jason.encode!() |> Jason.decode!()

    resumed =
      Anything.run(
        "0",
        evaluator(resumed_log),
        options(trainset, valset, proposer, resume_state: persisted)
      )

    uninterrupted =
      Anything.run("0", evaluator(full_log), options(trainset, valset, proposer))

    resumed_calls = Agent.get(resumed_log, & &1)
    uninterrupted_calls = Agent.get(full_log, & &1)

    assert resumed_calls == uninterrupted_calls
    assert resumed.candidates == uninterrupted.candidates
    assert resumed.validation_scores == uninterrupted.validation_scores
    assert Result.best_candidate(resumed) == Result.best_candidate(uninterrupted)

    assert for({_candidate, %{split: :train, id: id}} <- uninterrupted_calls, do: id) ==
             [:second, :second, :first, :first]

    assert persisted["batch_sampler"]["strategy"] == "custom"
    assert persisted["batch_sampler"]["module"] == Atom.to_string(PlannedSampler)
  end

  test "custom sampler identity tampering is rejected before evaluator calls" do
    trainset = [%{split: :train, id: :first}, %{split: :train, id: :second}]
    valset = [%{split: :selection, id: :held_out}]
    proposer = fn _candidate, _component, _records, iteration -> Integer.to_string(iteration) end
    log = start_supervised!({Agent, fn -> [] end}, id: :custom_sampler_tamper_log)

    {:checkpoint, checkpoint} =
      catch_throw(
        Anything.run(
          "0",
          evaluator(log),
          options(trainset, valset, proposer,
            checkpoint_fn: fn checkpoint ->
              if checkpoint["iteration"] == 1,
                do: throw({:checkpoint, checkpoint}),
                else: :ok
            end
          )
        )
      )

    calls_before_resume = Agent.get(log, & &1)

    tampered =
      put_in(
        checkpoint,
        ["batch_sampler", "identity"],
        Imp.Optimizer.Report.encode_term(:different_sampler)
      )

    assert_raise ArgumentError, ~r/batch sampler identity does not match/, fn ->
      Anything.run(
        "0",
        evaluator(log),
        options(trainset, valset, proposer, resume_state: tampered)
      )
    end

    assert Agent.get(log, & &1) == calls_before_resume

    tampered_state =
      put_in(
        checkpoint,
        ["batch_sampler", "state"],
        Imp.Optimizer.Report.encode_term(%{wrong: 1})
      )

    assert_raise ArgumentError, ~r/load_state\/2 failed/, fn ->
      Anything.run(
        "0",
        evaluator(log),
        options(trainset, valset, proposer, resume_state: tampered_state)
      )
    end

    assert Agent.get(log, & &1) == calls_before_resume
  end

  test "public config rejects ignored and contradictory batch sampler settings" do
    assert_raise ArgumentError, ~r/must be :epoch_shuffled or a strategy struct/, fn ->
      Config.new(reflection: [batch_sampler: :consumer_sampler])
    end

    assert_raise ArgumentError, ~r/must implement/, fn ->
      Config.new(reflection: [batch_sampler: URI.parse("https://example.test")])
    end

    assert_raise ArgumentError, ~r/cannot be combined with a custom batch sampler/, fn ->
      Config.new(reflection: [batch_sampler: %PlannedSampler{}, reflection_minibatch_size: 1])
    end

    config = Config.new(reflection: [batch_sampler: %PlannedSampler{}])
    engine_options = Config.to_engine_options(config)

    assert engine_options[:batch_sampler] == %PlannedSampler{}
    refute Keyword.has_key?(engine_options, :minibatch_size)

    assert_raise ArgumentError, ~r/runtime-only value/, fn -> Config.to_map(config) end
  end

  defp evaluator(log) do
    fn candidate, example ->
      Agent.update(log, &(&1 ++ [{candidate, example}]))
      String.to_integer(candidate) / 2
    end
  end

  defp options(trainset, valset, proposer, overrides \\ []) do
    base = [
      dataset: trainset,
      valset: valset,
      fallback_proposer: proposer,
      config:
        Config.new(
          engine: [max_candidate_proposals: 2],
          reflection: [batch_sampler: %PlannedSampler{}]
        )
    ]

    Keyword.merge(base, overrides)
  end
end
