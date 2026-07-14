defmodule Imp.Optimizer.MIPROv2.SearchContractTest do
  use ExUnit.Case, async: true

  test "runs the exact objective budget and selects only from full evaluations" do
    task_lm = %{
      module: Imp.LM.Static,
      opts: [handler: fn _messages, _opts -> %{answer: "yes"} end]
    }

    prompt_lm = %{
      module: Imp.LM.Static,
      opts: [handler: fn _messages, _opts -> %{"instructions" => ["Answer consistently."]} end]
    }

    program = Imp.predict("question -> answer", lm: task_lm)

    trainset =
      for index <- 1..3 do
        Imp.example(question: "train #{index}", answer: "yes") |> Imp.with_inputs(:question)
      end

    valset =
      for index <- 1..2 do
        Imp.example(question: "val #{index}", answer: "yes") |> Imp.with_inputs(:question)
      end

    optimizer =
      Imp.Optimizer.MIPROv2.new(Imp.Metrics.exact_match(:answer),
        auto: nil,
        num_candidates: 2,
        num_trials: 4,
        max_bootstrapped_demos: 1,
        max_labeled_demos: 0,
        minibatch: true,
        minibatch_size: 1,
        minibatch_full_eval_steps: 2,
        prompt_lm: prompt_lm,
        startup_trials: 1,
        seed: 31
      )

    compiled = Imp.Optimizer.MIPROv2.compile(optimizer, program, trainset, valset)
    report = Imp.Optimizer.Report.fetch(compiled)

    assert report.candidate_count == 4
    assert Enum.map(report.candidates, & &1.trial) == [1, 2, 3, 4]
    assert Enum.map(report.candidates, & &1.upstream_trial_num) == [2, 3, 5, 6]
    assert Enum.all?(report.candidates, &(&1.kind == :minibatch and &1.example_count == 1))
    assert hd(report.metadata.full_evaluations).kind == :baseline
    assert Enum.all?(report.metadata.full_evaluations, &(&1.kind in [:baseline, :promoted_full]))
    assert report.best_score == Enum.max(Enum.map(report.metadata.full_evaluations, & &1.score))
    assert report.metadata.evaluation_calls >= 8
    assert report.metadata.upstream_commit == "b2829b7"
  end

  test "same seed reproduces parameter trials" do
    task_lm = %{module: Imp.LM.Static, opts: [handler: fn _, _ -> %{answer: "yes"} end]}
    prompt_lm = %{module: Imp.LM.Static, opts: [handler: fn _, _ -> ["A", "B", "C"] end]}
    program = Imp.predict("question -> answer", lm: task_lm)
    examples = [Imp.example(question: "q", answer: "yes") |> Imp.with_inputs(:question)]

    build = fn seed ->
      Imp.Optimizer.MIPROv2.new(Imp.Metrics.exact_match(:answer),
        auto: nil,
        num_candidates: 3,
        num_trials: 6,
        minibatch: false,
        max_bootstrapped_demos: 0,
        max_labeled_demos: 0,
        prompt_lm: prompt_lm,
        startup_trials: 2,
        seed: seed
      )
      |> Imp.Optimizer.MIPROv2.compile(program, examples, examples)
      |> Imp.Optimizer.Report.fetch()
      |> then(&Enum.map(&1.candidates, fn candidate -> candidate.params end))
    end

    assert build.(7) == build.(7)
    refute build.(7) == build.(8)
  end

  test "requires a proposal model and honors an explicit task model" do
    program = Imp.predict("question -> answer")
    example = Imp.example(question: "q", answer: "yes") |> Imp.with_inputs(:question)
    metric = Imp.Metrics.exact_match(:answer)

    optimizer =
      Imp.Optimizer.MIPROv2.new(metric,
        auto: nil,
        num_candidates: 1,
        num_trials: 0,
        minibatch: false
      )

    assert_raise ArgumentError, ~r/requires :prompt_lm/, fn ->
      Imp.Optimizer.MIPROv2.compile(optimizer, program, [example], [example])
    end

    lm = %{module: Imp.LM.Static, opts: [handler: fn _, _ -> %{answer: "yes"} end]}

    compiled =
      Imp.Optimizer.MIPROv2.new(metric,
        auto: nil,
        num_candidates: 1,
        num_trials: 0,
        minibatch: false,
        prompt_lm: lm,
        task_lm: lm
      )
      |> Imp.Optimizer.MIPROv2.compile(program, [example], [example])

    assert Imp.Optimizer.Report.fetch(compiled).best_score == 1.0
    assert Imp.ProgramAccess.lm(compiled) == lm
  end
end
