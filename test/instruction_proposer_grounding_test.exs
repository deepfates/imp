defmodule Imp.Optimizer.InstructionProposerGroundingTest do
  use ExUnit.Case, async: true

  alias Imp.Optimizer.InstructionProposer

  test "grounded proposer independently controls program, data, demo, and tip context" do
    parent = self()

    lm = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn messages, _opts ->
          payload = messages |> List.last() |> Map.fetch!(:content) |> Jason.decode!()
          send(parent, {:proposal_payload, payload})
          %{"instructions" => ["Candidate instruction"]}
        end
      ]
    }

    program = Imp.predict("question -> answer")
    example = Imp.example(question: "q", answer: "a") |> Imp.with_inputs(:question)

    assert ["Candidate instruction"] =
             InstructionProposer.propose(program, [example],
               lm: lm,
               count: 1,
               demos: [example],
               seed: 4
             )

    assert_receive {:proposal_payload, payload}
    assert is_map(payload["program"])
    refute Map.has_key?(payload["program"], "source")
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

  test "program source grounding is explicit and bounded" do
    parent = self()

    lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          payload = messages |> List.last() |> Map.fetch!(:content) |> Jason.decode!()
          send(parent, {:program_context, payload["program"]})
          %{"instructions" => ["Candidate instruction"]}
        end
      )

    program = Imp.predict("question -> answer")
    example = Imp.example(question: "q", answer: "a") |> Imp.with_inputs(:question)

    assert ["Candidate instruction"] =
             InstructionProposer.propose(program, [example],
               lm: lm,
               count: 1,
               program_grounding: {:text, "Public program context."}
             )

    assert_receive {:program_context, %{"source" => "Public program context."}}
  end

  test "proposal reports preserve distinct rollout ids and fallback failures" do
    parent = self()

    lm = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn _messages, opts ->
          send(parent, {:proposal_rollout, opts[:rollout_id]})
          %{"instructions" => ["Instruction #{opts[:rollout_id]}"]}
        end
      ]
    }

    program = Imp.predict("question -> answer")
    example = Imp.example(question: "q", answer: "a") |> Imp.with_inputs(:question)

    {candidates, report} =
      InstructionProposer.propose_with_report(program, [example],
        lm: lm,
        count: 2,
        seed: 20
      )

    assert candidates == ["Instruction 20", "Instruction 21"]
    assert %{status: :ok, calls: 2, errors: [], slots: slots} = report
    assert Enum.map(slots, & &1.rollout_id) == [20, 21]
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

  test "provider envelopes produce proposals instead of silent fallbacks" do
    lm = fn _messages, _opts ->
      {:ok,
       %{
         __imp_lm_output__: %{"instructions" => ["Use the provider proposal."]},
         __imp_lm_metadata__: %{req_llm: %{provider: "test"}}
       }}
    end

    program = Imp.predict("question -> answer")
    example = Imp.example(question: "q", answer: "a") |> Imp.with_inputs(:question)

    assert ["Use the provider proposal."] =
             InstructionProposer.propose(program, [example], lm: lm, count: 1)

    assert {["Use the provider proposal."], %{status: :ok, calls: 1, errors: [], slots: [_]}} =
             InstructionProposer.propose_with_report(program, [example],
               lm: lm,
               count: 1
             )
  end

  test "operational safety failures never become fallback proposals" do
    safety =
      Imp.OperationalSafetyError.exception(
        kind: :route,
        message: "proposal route guard",
        reason: :provider_drift
      )

    lm = Imp.LM.Static.new(handler: fn _messages, _opts -> {:error, safety} end)
    program = Imp.predict("question -> answer")
    example = Imp.example(question: "q", answer: "a") |> Imp.with_inputs(:question)

    assert_raise Imp.OperationalSafetyError, "proposal route guard", fn ->
      InstructionProposer.propose(program, [example], lm: lm, count: 1)
    end

    assert_raise Imp.OperationalSafetyError, "proposal route guard", fn ->
      InstructionProposer.propose_with_report(program, [example], lm: lm, count: 1)
    end
  end

  test "proposal slots rotate only augmented demos and preserve repeated instructions" do
    parent = self()

    lm = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn messages, opts ->
          payload = messages |> List.last() |> Map.fetch!(:content) |> Jason.decode!()
          send(parent, {:proposal_demos, opts[:rollout_id], payload["demonstrations"]})
          %{"instructions" => ["same instruction"]}
        end
      ]
    }

    program = Imp.predict("question -> answer")

    labeled = Imp.example(question: "labeled", answer: "labeled") |> Imp.with_inputs(:question)

    augmented = fn question ->
      Imp.example(question: question, answer: question, imp_augmented: true)
      |> Imp.with_inputs(:question)
    end

    demos = [[], [labeled], [augmented.("a"), augmented.("b")], [augmented.("c")]]

    {candidates, report} =
      InstructionProposer.propose_with_report(program, List.flatten(demos),
        lm: lm,
        count: 4,
        seed: 10,
        demo_sets: demos,
        preserve_slots: true
      )

    assert candidates == List.duplicate("same instruction", 4)
    assert report.calls == 4
    assert_received {:proposal_demos, 10, []}
    assert_received {:proposal_demos, 11, [%{"answer" => "a", "question" => "a"} | _]}
    assert_received {:proposal_demos, 12, [%{"answer" => "a", "question" => "a"} | _]}
    assert_received {:proposal_demos, 13, [%{"answer" => "c", "question" => "c"} | _]}
    refute inspect(report.slots) =~ "imp_augmented"
  end

  test "required typed transport sends an exact schema and rejects narrative substitutes" do
    parent = self()

    typed =
      Imp.LM.Static.new(
        handler: fn _messages, opts ->
          send(parent, {:proposal_response_format, opts[:response_format]})
          %{"instructions" => ["Classify by the demonstrated route mapping."]}
        end
      )

    program = Imp.predict("question -> route")
    example = Imp.example(question: "q", route: "R17") |> Imp.with_inputs(:question)

    assert {[
              "Classify by the demonstrated route mapping."
            ], %{status: :ok, calls: 1, errors: [], slots: [_]}} =
             InstructionProposer.propose_with_report(program, [example],
               lm: typed,
               count: 1,
               proposal_response_format: :required
             )

    assert_received {:proposal_response_format,
                     %{
                       type: "json_schema",
                       json_schema: %{
                         name: "imp_instruction_proposal",
                         strict: true,
                         schema: %{
                           "additionalProperties" => false,
                           "required" => ["instructions"]
                         }
                       }
                     }}

    narrative =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          %{"comment" => "Here is a list of instructions in JSON format:"}
        end
      )

    {fallbacks, report} =
      InstructionProposer.propose_with_report(program, [example],
        lm: narrative,
        count: 1,
        proposal_response_format: :required
      )

    assert length(fallbacks) == 1
    assert report.status == :with_fallbacks
    assert report.errors == [{:invalid_proposal, 0}]
  end

  test "required typed transport rejects partial and extra proposal fields" do
    program = Imp.predict("question -> answer")
    example = Imp.example(question: "q", answer: "a") |> Imp.with_inputs(:question)

    for response <- [
          %{"instructions" => []},
          %{"instructions" => ["one", "two"]},
          %{"instructions" => ["one"], "comment" => "extra"},
          %{"instruction" => "one"}
        ] do
      {_fallbacks, report} =
        InstructionProposer.propose_with_report(program, [example],
          lm: Imp.LM.Static.new(handler: fn _messages, _opts -> response end),
          count: 1,
          proposal_response_format: :required
        )

      assert report.errors == [{:invalid_proposal, 0}]
    end
  end
end
