defmodule OptimizerReportTest do
  use ExUnit.Case

  defp lm do
    %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn messages, _opts ->
          prompt = Enum.map_join(messages, "\n", & &1.content)

          if prompt =~ "[[ ## answer ## ]]\nParis" or prompt =~ "Always answer Paris",
            do: %{answer: "Paris"},
            else: %{answer: "unknown"}
        end
      ]
    }
  end

  defp sets do
    train = [
      DSEx.example(question: "France capital?", answer: "Paris")
      |> DSEx.Example.with_inputs(:question)
    ]

    dev = [
      DSEx.example(question: "Capital of France?", answer: "Paris")
      |> DSEx.Example.with_inputs(:question)
    ]

    {train, dev}
  end

  test "random search attaches candidate history and best score" do
    {train, dev} = sets()
    metric = DSEx.Metrics.exact_match(:answer)
    program = DSEx.predict("question -> answer", lm: lm())

    compiled =
      metric
      |> DSEx.Optimizer.RandomSearch.new(candidates: 3, demos_per_candidate: 1)
      |> DSEx.Optimizer.RandomSearch.compile(program, train, dev)

    report = DSEx.Optimizer.Report.fetch(compiled)

    assert %DSEx.Optimizer.Report{
             optimizer: :random_search,
             best_score: 1.0,
             candidate_count: 3
           } =
             report

    assert Enum.all?(report.candidates, &Map.has_key?(&1, :score))
  end

  test "random search treats zero requested trials as a baseline-only compile" do
    {train, dev} = sets()
    metric = DSEx.Metrics.exact_match(:answer)
    program = DSEx.predict("question -> answer", lm: lm())

    compiled =
      metric
      |> DSEx.Optimizer.RandomSearch.new(candidates: 0, demos_per_candidate: 1)
      |> DSEx.Optimizer.RandomSearch.compile(program, train, dev)

    report = DSEx.Optimizer.Report.fetch(compiled)

    assert report.optimizer == :random_search
    assert report.best_score == 0.0
    assert report.candidate_count == 0
    assert report.errors == []
    assert report.metadata.baseline_score == 0.0
    assert Enum.map(report.candidates, & &1.index) == [:baseline]
  end

  test "random search returns the original program with diagnostics when all trials fail" do
    {train, _dev} = sets()
    metric = DSEx.Metrics.exact_match(:answer)
    program = DSEx.predict("question -> answer", lm: lm())

    compiled =
      metric
      |> DSEx.Optimizer.RandomSearch.new(candidates: 2, demos_per_candidate: 1)
      |> DSEx.Optimizer.RandomSearch.compile(program, train, :not_an_enumerable_devset)

    report = DSEx.Optimizer.Report.fetch(compiled)

    assert report.optimizer == :random_search
    assert report.best_score == nil
    assert report.candidate_count == 0
    assert report.candidates == []
    assert report.metadata.status == :all_candidates_failed
    assert length(report.errors) == 3
    assert Enum.map(report.errors, & &1.metadata.index) == [1, 2, :baseline]
    assert Enum.all?(report.errors, &String.contains?(&1.error, "Enumerable"))
  end

  test "instruction search attaches candidate score report" do
    {_train, dev} = sets()
    metric = DSEx.Metrics.exact_match(:answer)
    program = DSEx.predict("question -> answer", lm: lm())

    compiled =
      DSEx.Optimizer.InstructionSearch.compile(program, metric, [], dev, [
        "Answer unknown.",
        "Always answer Paris."
      ])

    report = DSEx.Optimizer.Report.fetch(compiled)
    assert report.optimizer == :instruction_search
    assert report.best_score == 1.0
    assert Enum.any?(report.candidates, &(&1.instruction == "Always answer Paris."))
  end

  test "instruction proposer accepts LM-generated scored candidates" do
    lm = %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn messages, _opts ->
          send(self(), {:proposer_messages, messages})
          ~s(["Always answer Paris.", "Mention evidence."])
        end
      ]
    }

    {train, _dev} = sets()
    program = DSEx.predict("question -> answer", lm: lm)

    assert ["Always answer Paris.", "Mention evidence."] =
             DSEx.Optimizer.InstructionSearch.candidate_instructions(program, train,
               lm: lm,
               scores: [%{score: 1.0}]
             )

    assert_received {:proposer_messages, messages}
    assert Enum.map_join(messages, "\n", & &1.content) =~ "scored_examples"
  end
end
