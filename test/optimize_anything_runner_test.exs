defmodule DSEx.Optimize.Anything.RunnerTest do
  use ExUnit.Case, async: true

  alias DSEx.Optimize.Anything
  alias DSEx.Optimize.Anything.{Config, Result}

  test "single-task mode evaluates a string candidate without an example" do
    receiver = self()

    result =
      Anything.optimize(
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
      Anything.optimize(
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
      Anything.optimize(
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
      Anything.optimize(
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
      module: DSEx.LM.Static,
      opts: [
        handler: fn messages, _opts ->
          send(receiver, {:seed_prompt, messages})
          "```text\ngenerated seed\n```"
        end
      ]
    }

    dataset = Enum.map(1..4, &%{sample: &1})

    result =
      Anything.optimize(
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
      Anything.optimize(
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

  test "rejects dataset and valset combinations outside the three public modes" do
    evaluator = fn _candidate, _example -> 1.0 end

    assert_raise ArgumentError, ~r/requires :dataset when :valset is provided/, fn ->
      Anything.optimize("baseline", evaluator, runner_options(0, valset: [:held_out]))
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
                     Anything.optimize("baseline", evaluator, runner_options(0, options))
                   end
    end
  end

  test "rejects unknown and malformed runner options before execution" do
    assert_raise ArgumentError, ~r/unknown Optimize Anything options: \[:datset\]/, fn ->
      Anything.optimize("baseline", fn _candidate -> 1.0 end,
        datset: [:misspelled],
        config: Config.new(engine: [max_candidate_proposals: 0])
      )
    end

    assert_raise ArgumentError, ~r/:checkpoint_fn must be nil or an arity-1 function/, fn ->
      Anything.optimize("baseline", fn _candidate -> 1.0 end,
        checkpoint_fn: :invalid,
        config: Config.new(engine: [max_candidate_proposals: 0])
      )
    end

    assert_raise ArgumentError, ~r/:fallback_max_iterations must be a non-negative integer/, fn ->
      Anything.optimize("baseline", fn _candidate -> 1.0 end,
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

    first =
      Anything.optimize(
        "0",
        evaluator,
        runner_options(1, dataset: dataset, fallback_proposer: proposer)
      )

    resumed =
      Anything.optimize(
        "0",
        evaluator,
        runner_options(2,
          dataset: dataset,
          fallback_proposer: proposer,
          resume_state: first.checkpoint
        )
      )

    uninterrupted =
      Anything.optimize(
        "0",
        evaluator,
        runner_options(2, dataset: dataset, fallback_proposer: proposer)
      )

    assert first.checkpoint["iteration"] == 1
    assert resumed.checkpoint["iteration"] == 2
    assert resumed.candidates == uninterrupted.candidates
    assert resumed.parents == uninterrupted.parents
    assert resumed.validation_scores == uninterrupted.validation_scores
    assert resumed.total_metric_calls == uninterrupted.total_metric_calls
    assert Result.best_candidate(resumed) == "2"
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
