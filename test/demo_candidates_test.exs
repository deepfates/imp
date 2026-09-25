defmodule Imp.Optimizer.DemoCandidatesTest do
  use ExUnit.Case, async: true

  alias Imp.Optimizer.DemoCandidates

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

      {:ok, Imp.Prediction.new(%{answer: "yes"}, metadata: %{optimizer_trace: trace})}
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
    lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          if inspect(messages) =~ "good", do: %{answer: "yes"}, else: %{answer: "no"}
        end
      )

    program = Imp.predict("question -> answer", lm: lm)

    trainset = [
      Imp.example(question: "good", answer: "yes") |> Imp.with_inputs(:question),
      Imp.example(question: "bad", answer: "yes") |> Imp.with_inputs(:question)
    ]

    metric = Imp.Metrics.exact_match(:answer)

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
    assert Imp.Example.to_map(labeled).answer == "yes"
    assert Imp.Example.to_map(bootstrapped).answer == "yes"
    assert Imp.Example.get(bootstrapped, :imp_augmented)
    refute :imp_augmented in Imp.Example.keys(bootstrapped)
    refute true in Imp.Example.values(bootstrapped)
    refute Enum.any?(Imp.Example.items(bootstrapped), &(elem(&1, 0) == "imp_augmented"))

    rendered =
      program.signature
      |> Imp.Adapter.Chat.format(%{question: "next"}, demos: [bootstrapped])
      |> inspect()

    refute rendered =~ "imp_augmented"
  end

  test "zero-shot candidate building still produces grounding demos for proposal" do
    lm = Imp.LM.Static.new(handler: fn _, _ -> %{answer: "yes"} end)
    program = Imp.predict("question -> answer", lm: lm)
    example = Imp.example(question: "q", answer: "yes") |> Imp.with_inputs(:question)

    {candidates, _metadata} =
      DemoCandidates.build(program, [example], Imp.Metrics.exact_match(:answer),
        candidate_count: 3,
        max_bootstrapped_demos: 3,
        max_labeled_demos: 0
      )

    assert [[], [first_demo], [second_demo]] = candidates.main
    assert Map.new(Imp.Example.items(first_demo)) == %{question: "q", answer: "yes"}
    assert Map.new(Imp.Example.items(second_demo)) == %{question: "q", answer: "yes"}
  end

  test "keeps the canonical third candidate in source trainset order" do
    lm = Imp.LM.Static.new(handler: fn _, _ -> %{answer: "yes"} end)
    program = Imp.predict("question -> answer", lm: lm)

    trainset =
      Enum.map(["first", "second", "third"], fn question ->
        Imp.example(question: question, answer: "yes") |> Imp.with_inputs(:question)
      end)

    {candidates, metadata} =
      DemoCandidates.build(program, trainset, Imp.Metrics.exact_match(:answer),
        candidate_count: 3,
        max_bootstrapped_demos: 3,
        max_labeled_demos: 0,
        seed: 9
      )

    assert [[], [_ | _], demos] = candidates.main
    assert Enum.map(demos, &Imp.Example.to_map(&1).question) == ["first", "second", "third"]
    assert Enum.map(metadata.rounds, &{&1.index, &1.bootstrap_size}) == [{1, 3}, {2, 3}]
  end

  test "keeps the final repeated call per predictor without cross-stage fallback" do
    program = %TracedProgram{
      first: Imp.predict("question -> hint"),
      second: Imp.predict("hint -> answer")
    }

    example = Imp.example(question: "q", answer: "yes") |> Imp.with_inputs(:question)

    {candidates, _metadata} =
      DemoCandidates.build(program, [example], Imp.Metrics.exact_match(:answer),
        candidate_count: 3,
        max_bootstrapped_demos: 4,
        max_labeled_demos: 0
      )

    assert [[], [first_demo], [second_first_demo]] = candidates.first
    assert Map.new(Imp.Example.items(first_demo)) == %{question: "q again", hint: "two"}
    assert Map.new(Imp.Example.items(second_first_demo)) == %{question: "q again", hint: "two"}

    assert [[], [second_demo], [second_second_demo]] = candidates.second
    assert Map.new(Imp.Example.items(second_demo)) == %{hint: "two", answer: "yes"}
    assert Map.new(Imp.Example.items(second_second_demo)) == %{hint: "two", answer: "yes"}
  end

  test "aborts bootstrapping when the configured error budget is exhausted" do
    program = %FailingProgram{predict: Imp.predict("question -> answer")}
    example = Imp.example(question: "q", answer: "a") |> Imp.with_inputs(:question)

    assert_raise RuntimeError, ~r/bootstrap error budget exhausted/, fn ->
      DemoCandidates.build(program, [example], Imp.Metrics.exact_match(:answer),
        candidate_count: 2,
        max_bootstrapped_demos: 1,
        max_labeled_demos: 0,
        max_errors: 1
      )
    end
  end
end
