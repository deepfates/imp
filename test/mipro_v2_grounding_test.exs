defmodule Imp.Optimizer.MIPROv2GroundingTest do
  use ExUnit.Case, async: true

  alias Imp.Optimizer.{InstructionProposer, MIPROv2, Report}

  defmodule TwoPredictorProgram do
    defstruct [:first, :second]

    def optimizer_predictors(program), do: [first: program.first, second: program.second]
    def update_optimizer_predictor(program, name, update), do: Map.update!(program, name, update)

    def call(_program, %{question: question}) do
      hint = "hint:#{question}"

      trace = [
        %{predictor: :first, inputs: %{question: question}, outputs: %{hint: hint}},
        %{predictor: :second, inputs: %{hint: hint}, outputs: %{answer: "yes"}}
      ]

      {:ok, Imp.Prediction.new(%{answer: "yes"}, metadata: %{optimizer_trace: trace})}
    end
  end

  test "source grounding rotates predictor-local sets, skips labels, and strips provenance" do
    augmented = fn id -> Imp.example(id: id, imp_augmented: true) end

    demo_sets = [
      [],
      [Imp.example(id: "label")],
      [augmented.("A1"), augmented.("A2")],
      [augmented.("B1"), augmented.("B2")]
    ]

    assert [] == InstructionProposer.grounded_augmented_demos(demo_sets, 0, 3)

    assert ["A1", "A2", "B1"] ==
             demo_sets
             |> InstructionProposer.grounded_augmented_demos(1, 3)
             |> Enum.map(&Imp.Example.fetch!(&1, :id))

    assert ["A1", "A2", "B1"] ==
             demo_sets
             |> InstructionProposer.grounded_augmented_demos(2, 3)
             |> Enum.map(&Imp.Example.fetch!(&1, :id))

    assert ["B1", "B2", "A1"] ==
             demo_sets
             |> InstructionProposer.grounded_augmented_demos(3, 3)
             |> Enum.map(&Imp.Example.fetch!(&1, :id))
  end

  test "ordinary MIPRO path keeps predictor-specific grounding and rollout identities" do
    owner = self()

    proposer_lm =
      Imp.LM.Static.new(
        handler: fn messages, opts ->
          payload = messages |> List.last() |> Map.fetch!(:content) |> Jason.decode!()
          send(owner, {:proposal, opts[:rollout_id], payload})

          %{
            "instructions" => [
              "#{payload["predictor_name"]}:#{payload["proposal_index"]}"
            ]
          }
        end
      )

    program = %TwoPredictorProgram{
      first: Imp.predict(Imp.signature("question -> hint", "first baseline")),
      second: Imp.predict(Imp.signature("hint -> answer", "second baseline"))
    }

    trainset =
      Enum.map(["train-a", "train-b"], fn question ->
        Imp.example(question: question, answer: "yes") |> Imp.with_inputs(:question)
      end)

    valset = [Imp.example(question: "validation", answer: "yes") |> Imp.with_inputs(:question)]

    metric = fn expected, prediction ->
      Imp.get(expected, :answer) == Imp.get(prediction, :answer)
    end

    selected =
      MIPROv2.new(metric,
        auto: nil,
        num_candidates: 4,
        num_trials: 1,
        minibatch: false,
        max_bootstrapped_demos: 1,
        max_labeled_demos: 1,
        prompt_lm: proposer_lm,
        seed: 17,
        startup_trials: 0
      )
      |> MIPROv2.compile(program, trainset, valset)

    report = Report.fetch(selected)
    first = report.metadata.proposals.first
    second = report.metadata.proposals.second

    assert Enum.map(first.slots, & &1.rollout_id) == [17, 18, 19, 20]
    assert Enum.map(second.slots, & &1.rollout_id) == [21, 22, 23, 24]
    assert Enum.map(first.slots, & &1.predictor_index) == [0, 0, 0, 0]
    assert Enum.map(second.slots, & &1.predictor_index) == [1, 1, 1, 1]
    assert Enum.map(first.slots, & &1.demo_set_index) == [0, 1, 2, 3]
    assert Enum.map(second.slots, & &1.demo_set_index) == [0, 1, 2, 3]

    calls = collect_proposals(8, [])
    assert Enum.map(calls, &elem(&1, 0)) == Enum.to_list(17..24)

    Enum.each(calls, fn {_rollout_id, payload} ->
      refute Enum.any?(payload["demonstrations"], fn demo ->
               Map.has_key?(demo, "augmented") or Map.has_key?(demo, "imp_augmented")
             end)
    end)

    first_payloads = calls |> Enum.take(4) |> Enum.map(&elem(&1, 1))
    second_payloads = calls |> Enum.drop(4) |> Enum.map(&elem(&1, 1))

    assert Enum.all?(first_payloads, &(&1["predictor_name"] == "first"))
    assert Enum.all?(second_payloads, &(&1["predictor_name"] == "second"))

    assert Enum.all?(first_payloads |> Enum.drop(1), fn payload ->
             Enum.all?(payload["demonstrations"], &Map.has_key?(&1, "hint"))
           end)

    assert Enum.all?(second_payloads |> Enum.drop(1), fn payload ->
             Enum.all?(payload["demonstrations"], &Map.has_key?(&1, "answer"))
           end)
  end

  defp collect_proposals(0, acc), do: Enum.reverse(acc)

  defp collect_proposals(remaining, acc) do
    receive do
      {:proposal, rollout_id, payload} ->
        collect_proposals(remaining - 1, [{rollout_id, payload} | acc])
    after
      1_000 -> flunk("missing #{remaining} MIPRO proposal calls")
    end
  end
end
