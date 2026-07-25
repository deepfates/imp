defmodule Imp.Optimize.Anything.StructuredArtifactTest do
  use ExUnit.Case, async: true

  alias Imp.Optimize.Anything
  alias Imp.Optimize.Anything.{Config, Result}
  alias Imp.Optimizer.Report

  test "optimizes a native mixed-type artifact without exposing the text-engine codec" do
    receiver = self()

    seed = %{
      enabled: false,
      name: "baseline",
      policy: %{route: "slow", weights: [1.0, 0.0], note: nil},
      retries: 1
    }

    target = %{
      enabled: true,
      name: "selected",
      policy: %{route: "fast", weights: [0.25, 0.75], note: nil},
      retries: 3
    }

    train = [%{id: :train_one, split: :train}, %{id: :train_two, split: :train}]
    selection = [%{id: :select_one, split: :selection}, %{id: :select_two, split: :selection}]
    untouched_test = [%{id: :test_one, split: :test}]

    evaluator = fn artifact, example ->
      send(receiver, {:evaluated, artifact, example.split})
      score = matching_components(artifact, target)
      {score, %{feedback: "match every typed component", scores: %{quality: score}}}
    end

    proposer = fn artifact, component, _records, _iteration ->
      send(receiver, {:proposed, artifact, component})
      Map.fetch!(target, component)
    end

    result =
      Anything.run(seed, evaluator,
        dataset: train,
        valset: selection,
        objective: "Select the typed routing policy",
        config:
          Config.new(
            engine: [max_candidate_proposals: 4, seed: 17],
            reflection: [module_selector: :all]
          ),
        fallback_proposer: proposer
      )

    assert seed == %{
             enabled: false,
             name: "baseline",
             policy: %{route: "slow", weights: [1.0, 0.0], note: nil},
             retries: 1
           }

    assert Result.best_candidate(result) == target
    assert result.validation_scores == [0.0, 1.0]
    assert result.objective_scores == [%{quality: 0.0}, %{quality: 1.0}]
    assert Enum.all?(result.candidates, &native_artifact?/1)
    assert native_artifact?(Result.best_candidate(result))
    refute inspect(result.history) =~ "imp_optimize_anything_structured_component"
    refute inspect(result.rejected) =~ "imp_optimize_anything_structured_component"
    assert Jason.encode!(result.checkpoint) =~ "imp_optimize_anything_structured_component"

    for component <- Map.keys(seed) do
      assert_receive {:proposed, ^seed, ^component}
    end

    assert_receive {:evaluated, ^seed, :train}
    assert_receive {:evaluated, ^seed, :selection}
    assert_receive {:evaluated, ^target, :selection}
    refute_receive {:evaluated, _artifact, :test}

    assert Enum.all?(untouched_test, fn example ->
             evaluator.(target, example) ==
               {1.0, %{feedback: "match every typed component", scores: %{quality: 1.0}}}
           end)

    assert_receive {:evaluated, ^target, :test}

    restored =
      result |> Result.to_map() |> Jason.encode!() |> Jason.decode!() |> Result.from_map()

    assert Result.best_candidate(restored) == target
    assert restored.candidates == result.candidates
  end

  test "strict reflection decoding rejects malformed, partial, type-drift, and no-op values" do
    seed = %{policy: %{route: "safe", retries: 1}}

    failures = [
      {"{\"route\":", "invalid_structured_proposal"},
      {~s({"route":"fast"}), "expected exact keys"},
      {~s({"route":"fast","retries":"2"}), "expected integer"},
      {~s({"route":"safe","retries":1}), "no_op_structured_proposal"}
    ]

    Enum.each(failures, fn {response, expected_reason} ->
      receiver = self()

      lm =
        Imp.LM.Static.new(
          handler: fn messages, _opts ->
            send(receiver, {:reflection, response, messages})
            response
          end
        )

      result =
        Anything.run(
          seed,
          fn artifact, _example ->
            send(receiver, {:evaluated, response, artifact})
            {0.0, %{feedback: "change the policy"}}
          end,
          dataset: [:train],
          valset: [:selection],
          config:
            Config.new(
              engine: [max_candidate_proposals: 1, raise_on_exception: false],
              reflection: [reflection_lm: lm]
            )
        )

      assert result.candidates == [seed]
      assert result.reflection_calls == 1
      assert inspect(result.rejected) =~ expected_reason
      refute inspect(result.rejected) =~ "imp_optimize_anything_structured_component"
      assert_receive {:reflection, ^response, [%{content: prompt}]}
      assert prompt =~ "complete replacement value"
      assert prompt =~ ~s("retries": 1)
      assert_receive {:evaluated, ^response, ^seed}
    end)
  end

  test "strict reflection decoding applies a complete typed JSON component" do
    seed = %{policy: %{route: "slow", retries: 1}}
    target = %{policy: %{route: "fast", retries: 3}}

    lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          """
          ```json
          {"route":"fast","retries":3}
          ```
          """
        end
      )

    result =
      Anything.run(
        seed,
        fn artifact, _example ->
          if artifact == target, do: 1.0, else: 0.0
        end,
        dataset: [:train],
        valset: [:selection],
        config:
          Config.new(
            engine: [max_candidate_proposals: 1],
            reflection: [reflection_lm: lm]
          )
      )

    assert result.candidates == [seed, target]
    assert result.validation_scores == [0.0, 1.0]
    assert Result.best_candidate(result) == target
  end

  test "evaluator failures retain the native artifact when exceptions are configured as scores" do
    seed = %{enabled: true, retries: 2}

    result =
      Anything.run(
        seed,
        fn artifact ->
          assert artifact == seed
          raise "structured evaluator failed"
        end,
        config: Config.new(engine: [max_candidate_proposals: 0, raise_on_exception: false]),
        fallback_proposer: &same_component/4
      )

    assert result.candidates == [seed]
    assert result.validation_scores == [0.0]
    assert inspect(result.candidate_side_information) =~ "structured evaluator failed"
  end

  test "structured checkpoints resume exactly and reject tampered component identity first" do
    seed = %{enabled: false, retries: 1}
    target = %{enabled: true, retries: 3}

    evaluator = fn artifact, _example -> matching_components(artifact, target) end
    proposer = fn _artifact, component, _records, _iteration -> Map.fetch!(target, component) end

    {:checkpoint, captured} =
      catch_throw(
        Anything.run(seed, evaluator,
          dataset: [:train],
          valset: [:selection],
          config: Config.new(engine: [max_candidate_proposals: 2, seed: 9]),
          fallback_proposer: proposer,
          checkpoint_fn: fn checkpoint ->
            if checkpoint["iteration"] == 1,
              do: throw({:checkpoint, checkpoint}),
              else: :ok
          end
        )
      )

    persisted = captured |> Jason.encode!() |> Jason.decode!()

    resumed =
      Anything.run(seed, evaluator,
        dataset: [:train],
        valset: [:selection],
        config: Config.new(engine: [max_candidate_proposals: 2, seed: 9]),
        fallback_proposer: proposer,
        resume_state: persisted
      )

    uninterrupted =
      Anything.run(seed, evaluator,
        dataset: [:train],
        valset: [:selection],
        config: Config.new(engine: [max_candidate_proposals: 2, seed: 9]),
        fallback_proposer: proposer
      )

    assert resumed.candidates == uninterrupted.candidates
    assert resumed.parents == uninterrupted.parents
    assert resumed.validation_scores == uninterrupted.validation_scores
    assert resumed.total_metric_calls == uninterrupted.total_metric_calls
    assert Result.best_candidate(resumed) == target

    tampered = tamper_first_component_identity(persisted)
    receiver = self()

    assert_raise ArgumentError,
                 ~r/structured Optimize Anything resume checkpoint is invalid/,
                 fn ->
                   Anything.run(
                     seed,
                     fn artifact, example ->
                       send(receiver, {:unexpected_evaluation, artifact, example})
                       0.0
                     end,
                     dataset: [:train],
                     valset: [:selection],
                     config: Config.new(engine: [max_candidate_proposals: 2, seed: 9]),
                     fallback_proposer: proposer,
                     resume_state: tampered
                   )
                 end

    refute_receive {:unexpected_evaluation, _artifact, _example}
  end

  test "text-only extensions fail before execution for structured artifacts" do
    seed = %{enabled: false, retries: 1}

    custom_selector = fn _state, _trajectories, _scores, _candidate_id, _candidate ->
      [:enabled]
    end

    assert_raise ArgumentError, ~r/custom_module_selector/, fn ->
      Anything.run(seed, fn _artifact -> 0.0 end,
        config:
          Config.new(
            engine: [max_candidate_proposals: 0],
            reflection: [module_selector: custom_selector]
          ),
        fallback_proposer: &same_component/4
      )
    end
  end

  test "reserved persistence tag keys fail before evaluator execution" do
    receiver = self()

    assert_raise ArgumentError, ~r/__imp_type__.*reserved/, fn ->
      Anything.run(
        %{metadata: %{"__imp_type__" => "user_value"}, retries: 1},
        fn artifact ->
          send(receiver, {:unexpected_evaluation, artifact})
          0.0
        end,
        config: Config.new(engine: [max_candidate_proposals: 0]),
        fallback_proposer: &same_component/4
      )
    end

    refute_receive {:unexpected_evaluation, _artifact}
  end

  defp matching_components(artifact, target) do
    matches = Enum.count(target, fn {key, value} -> Map.fetch!(artifact, key) == value end)
    matches / map_size(target)
  end

  defp native_artifact?(artifact) do
    artifact.enabled in [true, false] and is_binary(artifact.name) and
      is_integer(artifact.retries) and is_map(artifact.policy) and
      is_list(artifact.policy.weights)
  end

  defp same_component(candidate, component, _records, _iteration),
    do: Map.fetch!(candidate, component)

  defp tamper_first_component_identity(checkpoint) do
    [first | rest] = checkpoint["candidates"]
    candidate = first["candidate"] |> Report.decode_term()
    [component | _] = Map.keys(candidate)

    payload =
      candidate
      |> Map.fetch!(component)
      |> Jason.decode!()
      |> Map.put("artifact_schema_sha256", "tampered")
      |> Jason.encode!()

    tampered_candidate = Map.put(candidate, component, payload)
    tampered_first = Map.put(first, "candidate", Report.encode_term(tampered_candidate))
    Map.put(checkpoint, "candidates", [tampered_first | rest])
  end
end
