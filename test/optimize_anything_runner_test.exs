defmodule Imp.Optimize.Anything.RunnerTest do
  use ExUnit.Case, async: true

  alias Imp.Adapters.Types.Image
  alias Imp.Optimize.Anything
  alias Imp.Optimize.Anything.{Config, Result}

  test "single-task mode evaluates a string candidate without an example" do
    receiver = self()

    result =
      Anything.run(
        "baseline",
        fn candidate ->
          send(receiver, {:evaluated, candidate})
          0.75
        end,
        runner_options(0)
      )

    assert %Result{mode: :single_task} = result
    assert Result.best_candidate(result) == "baseline"
    assert result.validation_scores == [0.75]
    assert result.total_metric_calls == 1
    assert_receive {:evaluated, "baseline"}
    refute_receive {:evaluated, _}
  end

  test "multi-task mode uses the dataset for baseline validation" do
    receiver = self()
    dataset = [%{id: :first, target: "alpha"}, %{id: :second, target: "beta"}]

    result =
      Anything.run(
        "alpha only",
        fn candidate, example ->
          send(receiver, {:evaluated, candidate, example.id})
          if String.contains?(candidate, example.target), do: 1.0, else: 0.0
        end,
        runner_options(0, dataset: dataset)
      )

    assert %Result{mode: :multi_task} = result
    assert Result.best_candidate(result) == "alpha only"
    assert result.validation_scores == [0.5]
    assert result.total_metric_calls == 2
    assert_receive {:evaluated, "alpha only", :first}
    assert_receive {:evaluated, "alpha only", :second}
  end

  test "generalization mode validates on the valset rather than the training dataset" do
    receiver = self()
    dataset = [%{split: :train, score: 0.0}]
    valset = [%{split: :validation, score: 0.25}, %{split: :validation, score: 0.75}]

    result =
      Anything.run(
        "baseline",
        fn candidate, example ->
          send(receiver, {:evaluated, candidate, example.split, example.score})
          example.score
        end,
        runner_options(0, dataset: dataset, valset: valset)
      )

    assert %Result{mode: :generalization} = result
    assert result.validation_scores == [0.5]
    assert result.total_metric_calls == 2
    assert_receive {:evaluated, "baseline", :validation, 0.25}
    assert_receive {:evaluated, "baseline", :validation, 0.75}
    refute_receive {:evaluated, "baseline", :train, _}
  end

  test "named candidates are passed to the evaluator and returned without string unwrapping" do
    receiver = self()
    candidate = %{planner: "plan carefully", writer: "answer briefly"}

    result =
      Anything.run(
        candidate,
        fn evaluated ->
          send(receiver, {:evaluated, evaluated})
          1.0
        end,
        runner_options(0)
      )

    assert result.candidates == [candidate]
    assert Result.best_candidate(result) == candidate
    assert result.string_candidate_key == nil
    assert_receive {:evaluated, ^candidate}
  end

  test "seedless mode generates one fenced seed from the objective and at most three samples" do
    receiver = self()

    lm = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn messages, _opts ->
          send(receiver, {:seed_prompt, messages})

          %{
            __imp_lm_output__: "```text\ngenerated seed\n```",
            __imp_lm_metadata__: %{provider: "test"}
          }
        end
      ]
    }

    dataset = Enum.map(1..4, &%{sample: &1})

    result =
      Anything.run(
        nil,
        fn candidate, _example -> if(candidate == "generated seed", do: 1.0, else: 0.0) end,
        dataset: dataset,
        objective: "Produce a useful artifact",
        background: "Stay concise",
        config:
          Config.new(
            engine: [max_candidate_proposals: 0],
            reflection: [reflection_lm: lm]
          )
      )

    assert Result.best_candidate(result) == "generated seed"

    assert_receive {:seed_prompt, [%{content: prompt}]}
    assert prompt =~ "Produce a useful artifact"
    assert prompt =~ "Stay concise"
    assert prompt =~ "%{sample: 3}"
    refute prompt =~ "%{sample: 4}"
  end

  test "structured objective scores populate the public objective frontier" do
    result =
      Anything.run(
        %{prompt: "answer"},
        fn _candidate -> {0.75, %{scores: %{quality: 0.9, safety: 1.0}}} end,
        runner_options(0)
      )

    assert result.objective_scores == [%{quality: 0.9, safety: 1.0}]

    assert result.objective_frontier == %{
             {:objective, :quality} => [0],
             {:objective, :safety} => [0]
           }
  end

  test "reflection sends nested ASI images to the LM in deterministic depth-first order" do
    receiver = self()
    first = %Image{url: "https://example.test/first.png"}
    second = %Image{data: "c2Vjb25k", mime_type: "image/png"}

    reflection_lm = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn [%{content: content}], _opts ->
          send(receiver, {:reflection_content, content})
          "```text\nbase\n```"
        end
      ]
    }

    result =
      Anything.run(
        "base",
        fn _candidate, _example ->
          {0.0, %{a: %{visual: first}, z: [second]}}
        end,
        dataset: [:task],
        config:
          Config.new(
            engine: [max_candidate_proposals: 1],
            reflection: [reflection_lm: reflection_lm]
          )
      )

    assert %Result{} = result
    assert_receive {:reflection_content, [prompt, ^first, ^second]}
    assert prompt =~ "Iteration: 1"
    assert prompt =~ "[IMAGE-1 - see visual content]"
    assert prompt =~ "[IMAGE-2 - see visual content]"
  end

  test "capture_stdio preserves evaluator output as actionable side information" do
    result =
      Anything.run(
        "base",
        fn _candidate ->
          IO.write("diagnostic output")
          1.0
        end,
        config: Config.new(engine: [max_candidate_proposals: 0, capture_stdio: true]),
        fallback_proposer: fn candidate, component, _records, _iteration ->
          Map.fetch!(candidate, component)
        end
      )

    assert [%{current_candidate: [%{"stdout" => "diagnostic output"}]}] =
             result.candidate_side_information
  end

  test "refiner boosts evaluation and exposes co-evolved prompt history" do
    refiner_lm = %{
      module: Imp.LM.Static,
      opts: [handler: fn _messages, _opts -> ~s({"current_candidate":"better"}) end]
    }

    result =
      Anything.run(
        "base",
        fn candidate -> if(candidate == "better", do: 1.0, else: 0.0) end,
        objective: "Produce the better candidate",
        background: "Use exact words",
        config:
          Config.new(
            engine: [max_candidate_proposals: 0, track_best_outputs: true],
            refiner: [refiner_lm: refiner_lm, max_refinements: 1]
          ),
        fallback_proposer: fn candidate, component, _records, _iteration ->
          Map.fetch!(candidate, component)
        end
      )

    assert result.validation_scores == [1.0]
    assert Result.best_candidate(result) == "base"
    assert Result.best_refiner_prompt(result) =~ "Produce the better candidate"

    assert [%{refiner_prompt: [%{"Attempts" => attempts}]}] =
             result.candidate_side_information

    assert Enum.map(attempts, & &1["score"]) == [0.0, 1.0]
    assert [{0, {1.0, refined_candidate, _side_info}}] = result.best_outputs_valset[0]
    assert refined_candidate.current_candidate == "better"
  end

  test "rejects dataset and valset combinations outside the three public modes" do
    evaluator = fn _candidate, _example -> 1.0 end

    assert_raise ArgumentError, ~r/requires :dataset when :valset is provided/, fn ->
      Anything.run("baseline", evaluator, runner_options(0, valset: [:held_out]))
    end

    for options <- [
          [dataset: []],
          [dataset: :not_a_list],
          [dataset: [:train], valset: []],
          [dataset: [:train], valset: :not_a_list]
        ] do
      assert_raise ArgumentError,
                   ~r/:dataset and :valset must be non-empty lists or nil/,
                   fn ->
                     Anything.run("baseline", evaluator, runner_options(0, options))
                   end
    end
  end

  test "rejects unknown and malformed runner options before execution" do
    assert_raise ArgumentError, ~r/unknown Optimize Anything options: \[:datset\]/, fn ->
      Anything.run("baseline", fn _candidate -> 1.0 end,
        datset: [:misspelled],
        config: Config.new(engine: [max_candidate_proposals: 0])
      )
    end

    assert_raise ArgumentError, ~r/:checkpoint_fn must be nil or an arity-1 function/, fn ->
      Anything.run("baseline", fn _candidate -> 1.0 end,
        checkpoint_fn: :invalid,
        config: Config.new(engine: [max_candidate_proposals: 0])
      )
    end

    assert_raise ArgumentError, ~r/:fallback_max_iterations must be a non-negative integer/, fn ->
      Anything.run("baseline", fn _candidate -> 1.0 end,
        fallback_max_iterations: -1,
        fallback_proposer: fn candidate, component, _, _ -> Map.fetch!(candidate, component) end
      )
    end
  end

  test "a result checkpoint resumes to the same result as an uninterrupted run" do
    dataset = [%{target: 2}]

    evaluator = fn candidate, example ->
      candidate |> String.to_integer() |> min(example.target)
    end

    proposer = fn _candidate, _component, _records, iteration -> Integer.to_string(iteration) end

    {:checkpoint, first_checkpoint} =
      catch_throw(
        Anything.run(
          "0",
          evaluator,
          runner_options(2,
            dataset: dataset,
            fallback_proposer: proposer,
            checkpoint_fn: fn checkpoint ->
              if checkpoint["iteration"] == 1,
                do: throw({:checkpoint, checkpoint}),
                else: :ok
            end
          )
        )
      )

    resumed =
      Anything.run(
        "0",
        evaluator,
        runner_options(2,
          dataset: dataset,
          fallback_proposer: proposer,
          resume_state: first_checkpoint
        )
      )

    uninterrupted =
      Anything.run(
        "0",
        evaluator,
        runner_options(2, dataset: dataset, fallback_proposer: proposer)
      )

    assert first_checkpoint["iteration"] == 1
    assert resumed.checkpoint["iteration"] == 2
    assert resumed.candidates == uninterrupted.candidates
    assert resumed.parents == uninterrupted.parents
    assert resumed.validation_scores == uninterrupted.validation_scores
    assert resumed.total_metric_calls == uninterrupted.total_metric_calls
    assert Result.best_candidate(resumed) == "2"
  end

  test "run directories receive seed validation output artifacts" do
    run_dir =
      Path.join(
        System.tmp_dir!(),
        "imp-best-outputs-#{System.unique_integer([:positive, :monotonic])}"
      )

    on_exit(fn -> File.rm_rf!(run_dir) end)

    result =
      Anything.run(
        "baseline",
        fn _candidate -> {0.75, %{explanation: "seed evidence"}} end,
        config:
          Config.new(
            engine: [
              max_candidate_proposals: 0,
              run_dir: run_dir,
              track_best_outputs: false
            ]
          ),
        fallback_proposer: fn candidate, component, _records, _iteration ->
          Map.fetch!(candidate, component)
        end
      )

    assert %Result{run_dir: ^run_dir} = result

    [artifact] =
      Path.wildcard(Path.join(run_dir, "generated_best_outputs_valset/task_0/iter_0_prog_0.json"))

    decoded = artifact |> File.read!() |> Jason.decode!()
    assert decoded["score"] == 0.75

    assert decoded["output"] == %{
             "__imp_type__" => "tuple",
             "items" => [
               0.75,
               %{"current_candidate" => "baseline"},
               %{"explanation" => "seed evidence"}
             ]
           }
  end

  test "disk evaluation caches survive independent runs" do
    run_dir =
      Path.join(
        System.tmp_dir!(),
        "imp-disk-cache-#{System.unique_integer([:positive, :monotonic])}"
      )

    on_exit(fn -> File.rm_rf!(run_dir) end)
    receiver = self()

    evaluator = fn candidate ->
      send(receiver, {:evaluated, candidate})
      0.9
    end

    options =
      runner_options(0,
        config:
          Config.new(
            engine: [run_dir: run_dir, cache_evaluation: true, max_candidate_proposals: 0]
          )
      )

    first = Anything.run("cached", evaluator, options)
    assert_receive {:evaluated, "cached"}
    assert first.total_metric_calls == 1

    File.rm!(Path.join(run_dir, "gepa_state.json"))

    second = Anything.run("cached", evaluator, options)
    refute_receive {:evaluated, "cached"}
    assert second.total_metric_calls == 0
    assert second.validation_scores == [0.9]
  end

  defp runner_options(max_candidate_proposals, overrides \\ []) do
    defaults = [
      config: Config.new(engine: [max_candidate_proposals: max_candidate_proposals]),
      fallback_proposer: fn candidate, component, _records, _iteration ->
        Map.fetch!(candidate, component)
      end
    ]

    Keyword.merge(defaults, overrides)
  end
end
