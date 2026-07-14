defmodule Imp.Optimize.Anything.AdapterTest do
  use ExUnit.Case, async: true

  alias Imp.Optimize.Anything
  alias Imp.Optimize.Anything.Adapter
  alias Imp.Optimize.Anything.Adapter.OptimizationState
  alias Imp.Optimizer.GEPA.{Evaluation, Result}

  test "uses explicit mode arities and unwraps only string candidates" do
    parent = self()

    single =
      Adapter.new(
        fn candidate ->
          send(parent, {:single, candidate})
          1
        end,
        :single_task,
        candidate_format: :string
      )

    assert %Result{scores: [1]} =
             Evaluation.evaluate(single, [:single_sentinel], %{current_candidate: "solution"})

    assert_receive {:single, "solution"}

    multi =
      Adapter.new(
        fn candidate, example ->
          send(parent, {:multi, candidate, example})
          {0.5, %{feedback: "improve"}}
        end,
        mode: :multi_task
      )

    assert %Result{scores: [0.5]} = Evaluation.evaluate(multi, [:example], %{prompt: "named"})
    assert_receive {:multi, %{prompt: "named"}, :example}

    generalization =
      Adapter.new(
        fn _candidate, example -> if example == :held_out, do: 1, else: 0 end,
        :generalization
      )

    assert Evaluation.evaluate(generalization, [:held_out], %{prompt: "skill"}).scores == [1]

    assert_raise ArgumentError, ~r/requires an explicit :mode/, fn ->
      Adapter.new(fn _candidate -> 1 end, [])
    end

    assert_raise ArgumentError, ~r/must have arity 1/, fn ->
      Adapter.new(fn _candidate, _example -> 1 end, :single_task)
    end
  end

  test "injects OptimizationState only through the explicit evaluator contract" do
    parent = self()
    state = %OptimizationState{best_example_evals: [%{score: 0.8, side_info: %{hint: "x"}}]}

    adapter =
      Adapter.new(
        fn candidate, example, received_state ->
          send(parent, {:called, candidate, example, received_state})
          1.0
        end,
        :multi_task,
        evaluator_contract: :with_optimization_state,
        optimization_state: state
      )

    assert Evaluation.evaluate(adapter, [:task], %{prompt: "solve"}).scores == [1.0]
    assert_receive {:called, %{prompt: "solve"}, :task, ^state}

    assert_raise ArgumentError, ~r/must have arity 2/, fn ->
      Adapter.new(fn _candidate, _example, _state -> 1 end, :multi_task)
    end
  end

  test "accumulates descending top-K evaluations independently per example" do
    parent = self()

    adapter =
      Adapter.new(
        fn candidate, example, state ->
          send(parent, {:state, example, state.best_example_evals})
          score = String.to_integer(candidate.score)
          {score, %{example: example, candidate: score}}
        end,
        :multi_task,
        evaluator_contract: :with_optimization_state,
        best_example_evals_k: 2
      )

    assert Evaluation.evaluate(adapter, [:a, :b], %{score: "1"}).scores == [1, 1]
    assert_receive {:state, :a, []}
    assert_receive {:state, :b, []}

    assert Evaluation.evaluate(adapter, [:a], %{score: "3"}).scores == [3]
    assert_receive {:state, :a, [%{score: 1, side_info: %{example: :a, candidate: 1}}]}

    assert Evaluation.evaluate(adapter, [:a], %{score: "2"}).scores == [2]

    assert_receive {:state, :a,
                    [
                      %{score: 3, side_info: %{example: :a, candidate: 3}},
                      %{score: 1, side_info: %{example: :a, candidate: 1}}
                    ]}

    assert Evaluation.evaluate(adapter, [:b], %{score: "4"}).scores == [4]
    assert_receive {:state, :b, [%{score: 1, side_info: %{example: :b, candidate: 1}}]}

    assert Evaluation.evaluate(adapter, [:a], %{score: "0"}).scores == [0]

    assert_receive {:state, :a,
                    [
                      %{score: 3, side_info: %{example: :a, candidate: 3}},
                      %{score: 2, side_info: %{example: :a, candidate: 2}}
                    ]}
  end

  test "serializes concurrent best-evaluation updates without losing records" do
    parent = self()
    counter = start_supervised!({Agent, fn -> 0 end})

    adapter =
      Adapter.new(
        fn _candidate, example, state ->
          send(parent, {:state, state.best_example_evals})
          score = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
          {score, %{example: example, score: score}}
        end,
        :multi_task,
        evaluator_contract: :with_optimization_state,
        best_example_evals_k: 3,
        max_concurrency: 8
      )

    examples = List.duplicate(:same, 12)

    assert Evaluation.evaluate(adapter, examples, %{main: "x"}).scores |> Enum.sort() ==
             Enum.to_list(1..12)

    for _index <- 1..12 do
      assert_receive {:state, _prior_evaluations}
    end

    assert Evaluation.evaluate(adapter, [:same], %{main: "x"}).scores == [13]

    assert_receive {:state,
                    [
                      %{score: 12, side_info: %{example: :same, score: 12}},
                      %{score: 11, side_info: %{example: :same, score: 11}},
                      %{score: 10, side_info: %{example: :same, score: 10}}
                    ]}
  end

  test "records only successful evaluations and supports disabling history" do
    parent = self()

    adapter =
      Adapter.new(
        fn candidate, _example, state ->
          send(parent, {:state, state.best_example_evals})

          if candidate.action == "fail" do
            raise "failed evaluation"
          else
            {1, %{kept: true}}
          end
        end,
        :multi_task,
        evaluator_contract: :with_optimization_state,
        best_example_evals_k: 0,
        raise_on_exception: false
      )

    assert Evaluation.evaluate(adapter, [:example], %{action: "fail"}).scores == [0.0]
    assert_receive {:state, []}

    assert Evaluation.evaluate(adapter, [:example], %{action: "pass"}).scores == [1]
    assert_receive {:state, []}

    assert Evaluation.evaluate(adapter, [:example], %{action: "pass"}).scores == [1]
    assert_receive {:state, []}

    assert_raise ArgumentError, ~r/best_example_evals_k must be a non-negative integer/, fn ->
      Adapter.new(fn _candidate -> 1 end, :single_task, best_example_evals_k: -1)
    end
  end

  test "uses unnamed state and stops it when the adapter owner exits normally" do
    parent = self()

    owner =
      spawn(fn ->
        adapter = Adapter.new(fn _candidate -> 1 end, :single_task)
        send(parent, {:store, adapter.optimization_state_store})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:store, store}
    assert Process.info(store, :registered_name) == {:registered_name, []}
    monitor = Process.monitor(store)

    send(owner, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^store, :shutdown}
  end

  test "normalizes evaluations and extracts global and parameter objectives" do
    adapter =
      Adapter.new(
        fn _candidate, example ->
          case example do
            :number ->
              0.25

            :tuple ->
              {0.5, %{scores: %{quality: 0.7}}}

            :evaluation ->
              %Anything.Evaluation{
                score: 0.75,
                diagnostics: ["close"],
                metadata: %{source: :judge}
              }

            :map ->
              %{
                score: 1.0,
                asi: %{
                  "scores" => %{"accuracy" => 0.9},
                  "prompt_specific_info" => %{
                    "scores" => %{"tone" => 0.8},
                    "Feedback" => "be concise"
                  },
                  "tool_specific_info" => %{"Feedback" => "use lookup"}
                }
              }
          end
        end,
        :multi_task
      )

    candidate = %{prompt: "answer", tool: "search"}

    result =
      Evaluation.evaluate(adapter, [:number, :tuple, :evaluation, :map], candidate,
        capture_traces: true
      )

    assert result.scores == [0.25, 0.5, 0.75, 1.0]

    assert result.objective_scores == [
             %{},
             %{quality: 0.7},
             %{},
             %{"accuracy" => 0.9, "prompt::tone" => 0.8}
           ]

    assert length(result.trajectories.prompt) == 4
    assert Enum.at(result.side_information.prompt, 3)["Feedback"] == "be concise"
    assert Enum.at(result.side_information.tool, 3)["Feedback"] == "use lookup"
    refute Map.has_key?(Enum.at(result.side_information.prompt, 3), "tool_specific_info")

    assert %{prompt: [_, _, _, prompt_record], tool: [_, _, _, tool_record]} =
             Adapter.make_reflective_dataset(adapter, candidate, result, [:prompt, :tool])

    assert prompt_record["Scores (Higher is Better)"] == %{"accuracy" => 0.9}
    assert prompt_record["scores"] == %{"tone" => 0.8}
    assert prompt_record["Feedback"] == "be concise"
    assert tool_record["Feedback"] == "use lookup"
  end

  test "rejects invalid scores and ASI shapes" do
    invalid_score = Adapter.new(fn _candidate -> {"high", %{}} end, :single_task)

    assert_raise ArgumentError, ~r/score must be numeric/, fn ->
      Evaluation.evaluate(invalid_score, [:sentinel], %{main: "x"})
    end

    invalid_asi = Adapter.new(fn _candidate -> {1.0, "feedback"} end, :single_task)

    assert_raise ArgumentError, ~r/side_info must be a map/, fn ->
      Evaluation.evaluate(invalid_asi, [:sentinel], %{main: "x"})
    end

    invalid_objective =
      Adapter.new(fn _candidate -> {1.0, %{scores: %{quality: "high"}}} end, :single_task)

    assert_raise ArgumentError, ~r/scores must be a map with numeric values/, fn ->
      Evaluation.evaluate(invalid_objective, [:sentinel], %{main: "x"})
    end
  end

  test "raises evaluator exceptions by default or returns redacted zero-score diagnostics" do
    raising = Adapter.new(fn _candidate -> raise "boom" end, :single_task)

    assert_raise RuntimeError, "boom", fn ->
      Evaluation.evaluate(raising, [:sentinel], %{main: "x"})
    end

    safe =
      Adapter.new(
        fn _candidate -> raise "request failed for sk-super-secret-1234567890" end,
        :single_task,
        raise_on_exception: false
      )

    result = Evaluation.evaluate(safe, [:sentinel], %{main: "x"}, capture_traces: true)

    assert result.scores == [0.0]
    assert result.outputs == [nil]
    assert result.metadata.failures == 1
    assert result.side_information.main == [%{"error" => "[REDACTED]"}]
    assert [%{error: "[REDACTED]"}] = result.trajectories.main
  end

  test "captures evaluator IO as stdout and preserves evaluator stdout collisions" do
    adapter =
      Adapter.new(
        fn _candidate, example ->
          IO.write("captured #{example}")

          case example do
            :plain -> {1.0, %{detail: "plain"}}
            :collision -> {1.0, %{"stdout" => "evaluator-owned"}}
            :atom_collision -> {1.0, %{stdout: "evaluator-owned atom"}}
          end
        end,
        :multi_task,
        capture_stdio: true
      )

    result =
      Evaluation.evaluate(adapter, [:plain, :collision, :atom_collision], %{main: "x"})

    assert [plain, collision, atom_collision] = result.side_information.main
    assert plain["stdout"] == "captured plain"
    assert collision["stdout"] == "evaluator-owned"
    assert collision["_gepa_stdout"] == "captured collision"
    assert atom_collision.stdout == "evaluator-owned atom"
    assert atom_collision["_gepa_stdout"] == "captured atom_collision"
  end

  test "preserves captured stdout when evaluator exceptions become diagnostics" do
    parent = self()

    adapter =
      Adapter.new(
        fn _candidate ->
          send(parent, {:capture_device, Process.group_leader()})
          IO.write("context before failure")
          raise "failed evaluation"
        end,
        :single_task,
        capture_stdio: true,
        raise_on_exception: false
      )

    result = Evaluation.evaluate(adapter, [:sentinel], %{main: "x"}, capture_traces: true)

    assert result.scores == [0.0]

    assert result.side_information.main == [
             %{"error" => "failed evaluation", "stdout" => "context before failure"}
           ]

    assert [%{feedback: %{"stdout" => "context before failure"}}] = result.trajectories.main
    assert_receive {:capture_device, capture_device}
    refute Process.alive?(capture_device)
  end

  test "isolates concurrent evaluator captures and closes each temporary group leader" do
    parent = self()

    adapter =
      Adapter.new(
        fn _candidate, example ->
          capture_device = Process.group_leader()
          send(parent, {:capture_device, capture_device})
          IO.write("start-#{example}|")
          Process.sleep((5 - example) * 5)
          IO.write("end-#{example}")
          {example, %{example: example}}
        end,
        :multi_task,
        capture_stdio: true,
        max_concurrency: 4
      )

    result = Evaluation.evaluate(adapter, [1, 2, 3, 4], %{main: "x"})

    assert Enum.map(result.side_information.main, & &1["stdout"]) == [
             "start-1|end-1",
             "start-2|end-2",
             "start-3|end-3",
             "start-4|end-4"
           ]

    capture_devices =
      for _index <- 1..4 do
        assert_receive {:capture_device, capture_device}
        capture_device
      end

    assert capture_devices |> Enum.uniq() |> length() == 4
    refute Enum.any?(capture_devices, &Process.alive?/1)
  end

  test "defaults capture_stdio to false and validates explicit values" do
    adapter = Adapter.new(fn _candidate -> 1 end, :single_task)
    refute adapter.capture_stdio

    assert_raise ArgumentError, ~r/capture_stdio must be a boolean/, fn ->
      Adapter.new(fn _candidate -> 1 end, :single_task, capture_stdio: :yes)
    end
  end

  test "bounds parallel evaluation while preserving batch order" do
    tracker = start_supervised!({Agent, fn -> %{active: 0, peak: 0} end})

    evaluator = fn _candidate, example ->
      Agent.update(tracker, fn state ->
        active = state.active + 1
        %{active: active, peak: max(state.peak, active)}
      end)

      Process.sleep(20)
      Agent.update(tracker, &%{&1 | active: &1.active - 1})
      {example / 10, %{example: example}}
    end

    adapter = Adapter.new(evaluator, :multi_task, max_concurrency: 2)
    result = Evaluation.evaluate(adapter, [1, 2, 3, 4], %{main: "x"})

    assert result.scores == [0.1, 0.2, 0.3, 0.4]
    assert Agent.get(tracker, & &1.peak) == 2
  end
end
