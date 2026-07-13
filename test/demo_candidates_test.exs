defmodule DSEx.Optimizer.DemoCandidatesTest do
  use ExUnit.Case, async: true

  alias DSEx.Optimizer.DemoCandidates

  defmodule TracedProgram do
    defstruct [:first, :second]
    def optimizer_predictors(program), do: [first: program.first, second: program.second]

    def update_optimizer_predictor(program, :first, update),
      do: %{program | first: update.(program.first)}

    def update_optimizer_predictor(program, :second, update),
      do: %{program | second: update.(program.second)}

    def call(_program, %{question: question}) do
      trace = [
        %{predictor: :first, inputs: %{question: question}, outputs: %{hint: "one"}},
        %{predictor: :first, inputs: %{question: question <> " again"}, outputs: %{hint: "two"}},
        %{predictor: :second, inputs: %{hint: "two"}, outputs: %{answer: "yes"}}
      ]

      {:ok, DSEx.Prediction.new(%{answer: "yes"}, metadata: %{optimizer_trace: trace})}
    end
  end

  defmodule FailingProgram do
    defstruct [:predict]
    def optimizer_predictors(program), do: [main: program.predict]

    def update_optimizer_predictor(program, :main, update),
      do: %{program | predict: update.(program.predict)}

    def call(_program, _inputs), do: {:error, :boom}
  end

  test "bootstraps only metric-accepted predictions and preserves labeled capacity" do
    lm = %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn messages, _opts ->
          if inspect(messages) =~ "good", do: %{answer: "yes"}, else: %{answer: "no"}
        end
      ]
    }

    program = DSEx.predict("question -> answer", lm: lm)

    trainset = [
      DSEx.example(question: "good", answer: "yes") |> DSEx.with_inputs(:question),
      DSEx.example(question: "bad", answer: "yes") |> DSEx.with_inputs(:question)
    ]

    metric = DSEx.Metrics.exact_match(:answer)

    {candidates, metadata} =
      DemoCandidates.build(program, trainset, metric,
        candidate_count: 3,
        max_bootstrapped_demos: 1,
        max_labeled_demos: 1,
        seed: 9
      )

    assert metadata.accepted_count == 1
    assert metadata.rejected_count == 1
    assert length(candidates.main) == 3
    assert [[], [labeled], [bootstrapped | _]] = candidates.main
    assert DSEx.Example.to_map(labeled).answer == "yes"
    assert DSEx.Example.to_map(bootstrapped).answer == "yes"
  end

  test "zero-shot candidate building still produces grounding demos for proposal" do
    lm = %{module: DSEx.LM.Static, opts: [handler: fn _, _ -> %{answer: "yes"} end]}
    program = DSEx.predict("question -> answer", lm: lm)
    example = DSEx.example(question: "q", answer: "yes") |> DSEx.with_inputs(:question)

    {candidates, _metadata} =
      DemoCandidates.build(program, [example], DSEx.Metrics.exact_match(:answer),
        candidate_count: 3,
        max_bootstrapped_demos: 3,
        max_labeled_demos: 0
      )

    assert [[], [first_demo], [second_demo]] = candidates.main
    assert DSEx.Example.to_map(first_demo) == %{question: "q", answer: "yes"}
    assert DSEx.Example.to_map(second_demo) == %{question: "q", answer: "yes"}
  end

  test "keeps the canonical third candidate in source trainset order" do
    lm = %{module: DSEx.LM.Static, opts: [handler: fn _, _ -> %{answer: "yes"} end]}
    program = DSEx.predict("question -> answer", lm: lm)

    trainset =
      Enum.map(["first", "second", "third"], fn question ->
        DSEx.example(question: question, answer: "yes") |> DSEx.with_inputs(:question)
      end)

    {candidates, metadata} =
      DemoCandidates.build(program, trainset, DSEx.Metrics.exact_match(:answer),
        candidate_count: 3,
        max_bootstrapped_demos: 3,
        max_labeled_demos: 0,
        seed: 9
      )

    assert [[], [_ | _], demos] = candidates.main
    assert Enum.map(demos, &DSEx.Example.to_map(&1).question) == ["first", "second", "third"]
    assert Enum.map(metadata.rounds, &{&1.index, &1.bootstrap_size}) == [{1, 3}, {2, 3}]
  end

  test "keeps the final repeated call per predictor without cross-stage fallback" do
    program = %TracedProgram{
      first: DSEx.predict("question -> hint"),
      second: DSEx.predict("hint -> answer")
    }

    example = DSEx.example(question: "q", answer: "yes") |> DSEx.with_inputs(:question)

    {candidates, _metadata} =
      DemoCandidates.build(program, [example], DSEx.Metrics.exact_match(:answer),
        candidate_count: 3,
        max_bootstrapped_demos: 4,
        max_labeled_demos: 0
      )

    assert [[], [first_demo], [second_first_demo]] = candidates.first
    assert DSEx.Example.to_map(first_demo) == %{question: "q again", hint: "two"}
    assert DSEx.Example.to_map(second_first_demo) == %{question: "q again", hint: "two"}

    assert [[], [second_demo], [second_second_demo]] = candidates.second
    assert DSEx.Example.to_map(second_demo) == %{hint: "two", answer: "yes"}
    assert DSEx.Example.to_map(second_second_demo) == %{hint: "two", answer: "yes"}
  end

  test "aborts bootstrapping when the configured error budget is exhausted" do
    program = %FailingProgram{predict: DSEx.predict("question -> answer")}
    example = DSEx.example(question: "q", answer: "a") |> DSEx.with_inputs(:question)

    assert_raise RuntimeError, ~r/bootstrap error budget exhausted/, fn ->
      DemoCandidates.build(program, [example], DSEx.Metrics.exact_match(:answer),
        candidate_count: 2,
        max_bootstrapped_demos: 1,
        max_labeled_demos: 0,
        max_errors: 1
      )
    end
  end
end
