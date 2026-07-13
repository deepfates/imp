defmodule DSEx.Optimizer.InstructionProposerGroundingTest do
  use ExUnit.Case, async: true

  alias DSEx.Optimizer.InstructionProposer

  test "grounded proposer independently controls program, data, demo, and tip context" do
    parent = self()

    lm = %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn messages, _opts ->
          payload = messages |> List.last() |> Map.fetch!(:content) |> Jason.decode!()
          send(parent, {:proposal_payload, payload})
          %{"instructions" => ["Candidate instruction"]}
        end
      ]
    }

    program = DSEx.predict("question -> answer")
    example = DSEx.example(question: "q", answer: "a") |> DSEx.with_inputs(:question)

    assert ["Candidate instruction"] =
             InstructionProposer.propose(program, [example],
               lm: lm,
               count: 1,
               demos: [example],
               seed: 4
             )

    assert_receive {:proposal_payload, payload}
    assert is_map(payload["program"])
    assert payload["train_examples"] == [%{"answer" => "a", "question" => "q"}]
    assert payload["demonstrations"] == [%{"answer" => "a", "question" => "q"}]
    assert is_binary(payload["prompting_tip"])

    InstructionProposer.propose(program, [example],
      lm: lm,
      count: 1,
      program_aware: false,
      data_aware: false,
      fewshot_aware: false,
      tip_aware: false
    )

    assert_receive {:proposal_payload, sparse}
    refute Map.has_key?(sparse, "program")
    refute Map.has_key?(sparse, "train_examples")
    refute Map.has_key?(sparse, "demonstrations")
    refute Map.has_key?(sparse, "prompting_tip")
  end

  test "proposal reports preserve distinct rollout ids and fallback failures" do
    parent = self()

    lm = %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn _messages, opts ->
          send(parent, {:proposal_rollout, opts[:rollout_id]})
          %{"instructions" => ["Instruction #{opts[:rollout_id]}"]}
        end
      ]
    }

    program = DSEx.predict("question -> answer")
    example = DSEx.example(question: "q", answer: "a") |> DSEx.with_inputs(:question)

    {candidates, report} =
      InstructionProposer.propose_with_report(program, [example],
        lm: lm,
        count: 2,
        seed: 20
      )

    assert candidates == ["Instruction 20", "Instruction 21"]
    assert report == %{status: :ok, calls: 2, errors: []}
    assert_received {:proposal_rollout, 20}
    assert_received {:proposal_rollout, 21}

    failing = fn _messages, _opts -> {:error, :offline} end

    {_fallbacks, failed_report} =
      InstructionProposer.propose_with_report(program, [example],
        lm: failing,
        count: 2,
        seed: 20
      )

    assert failed_report.status == :with_fallbacks
    assert length(failed_report.errors) == 2
  end

  test "proposal slots rotate grounded demo sets and preserve repeated instructions" do
    parent = self()

    lm = %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn messages, opts ->
          payload = messages |> List.last() |> Map.fetch!(:content) |> Jason.decode!()
          send(parent, {:proposal_demos, opts[:rollout_id], payload["demonstrations"]})
          %{"instructions" => ["same instruction"]}
        end
      ]
    }

    program = DSEx.predict("question -> answer")

    demos =
      Enum.map(["a", "b", "c"], fn question ->
        [DSEx.example(question: question, answer: question) |> DSEx.with_inputs(:question)]
      end)

    {candidates, report} =
      InstructionProposer.propose_with_report(program, List.flatten(demos),
        lm: lm,
        count: 3,
        seed: 10,
        demo_sets: demos,
        preserve_slots: true
      )

    assert candidates == ["same instruction", "same instruction", "same instruction"]
    assert report.calls == 3
    assert_received {:proposal_demos, 10, []}
    assert_received {:proposal_demos, 11, [%{"answer" => "b", "question" => "b"} | _]}
    assert_received {:proposal_demos, 12, [%{"answer" => "c", "question" => "c"} | _]}
  end
end
