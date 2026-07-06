defmodule OptimizerReportTest do
  use ExUnit.Case

  defp lm do
    %{
      module: DSEx.LM.Fake,
      opts: [
        handler: fn messages, _opts ->
          prompt = Enum.map_join(messages, "\n", & &1.content)

          if prompt =~ "answer: Paris" or prompt =~ "Always answer Paris",
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
end
