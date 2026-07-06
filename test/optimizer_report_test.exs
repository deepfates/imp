defmodule OptimizerReportTest do
  use ExUnit.Case

  defp lm do
    %{
      module: Dachshund.LM.Fake,
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
      Dachshund.example(question: "France capital?", answer: "Paris")
      |> Dachshund.Example.with_inputs(:question)
    ]

    dev = [
      Dachshund.example(question: "Capital of France?", answer: "Paris")
      |> Dachshund.Example.with_inputs(:question)
    ]

    {train, dev}
  end

  test "random search attaches candidate history and best score" do
    {train, dev} = sets()
    metric = Dachshund.Metrics.exact_match(:answer)
    program = Dachshund.predict("question -> answer", lm: lm())

    compiled =
      metric
      |> Dachshund.Optimizer.RandomSearch.new(candidates: 3, demos_per_candidate: 1)
      |> Dachshund.Optimizer.RandomSearch.compile(program, train, dev)

    report = Dachshund.Optimizer.Report.fetch(compiled)

    assert %Dachshund.Optimizer.Report{
             optimizer: :random_search,
             best_score: 1.0,
             candidate_count: 3
           } =
             report

    assert Enum.all?(report.candidates, &Map.has_key?(&1, :score))
  end

  test "instruction search attaches candidate score report" do
    {_train, dev} = sets()
    metric = Dachshund.Metrics.exact_match(:answer)
    program = Dachshund.predict("question -> answer", lm: lm())

    compiled =
      Dachshund.Optimizer.InstructionSearch.compile(program, metric, [], dev, [
        "Answer unknown.",
        "Always answer Paris."
      ])

    report = Dachshund.Optimizer.Report.fetch(compiled)
    assert report.optimizer == :instruction_search
    assert report.best_score == 1.0
    assert Enum.any?(report.candidates, &(&1.instruction == "Always answer Paris."))
  end
end
