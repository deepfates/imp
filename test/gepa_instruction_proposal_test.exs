defmodule Imp.Optimizer.GEPA.InstructionProposalTest do
  use ExUnit.Case, async: true

  alias Imp.Optimizer.GEPA.InstructionProposal

  test "optimizer exposes the pinned record mode without accepting global feedback drift" do
    metric = fn _example, _prediction -> 1.0 end

    optimizer = Imp.Optimizer.GEPA.new(metric, reflection_record_mode: :gepa_v0_1_4)
    assert optimizer.reflection_record_mode == :gepa_v0_1_4

    assert_raise ArgumentError, ~r/non-upstream global reflection record/, fn ->
      Imp.Optimizer.GEPA.new(metric,
        reflection_record_mode: :gepa_v0_1_4,
        feedback_fn: fn _rows -> "global" end
      )
    end
  end

  test "renders current instructions and reflective records in the pinned GEPA prompt shape" do
    [%{role: :user, content: prompt}] =
      InstructionProposal.messages(
        "Route the ticket.",
        [
          %{
            "Inputs" => %{"ticket" => "invoice leak"},
            "Generated Outputs" => %{"team" => "billing"},
            "Feedback" => "This is a security incident."
          }
        ],
        "Prefer the owner of the underlying risk."
      )

    assert prompt =~ "I provided an assistant with the following instructions"
    assert prompt =~ "```\nRoute the ticket.\n```"
    assert prompt =~ "# Example 1"
    assert prompt =~ "## Inputs"
    assert prompt =~ "### ticket\ninvoice leak"
    assert prompt =~ "## Feedback\nThis is a security incident."
    assert prompt =~ "# Example 2\n## GlobalFeedback"
    assert prompt =~ "Provide the new instructions within ``` blocks."
  end

  test "extracts the same plain and fenced instruction spellings as GEPA v0.1.4" do
    cases = [
      {"Use exact labels.", "Use exact labels."},
      {"analysis\n```\nUse exact labels.\n```\ntrailing", "Use exact labels."},
      {"```text\nUse exact labels.", "Use exact labels."},
      {"Use exact labels.```", "Use exact labels."},
      {"```foo```", "foo"}
    ]

    for {response, expected} <- cases do
      assert InstructionProposal.extract_instruction(response) == expected
      assert InstructionProposal.normalize(response) == {:ok, expected}
    end
  end

  test "pinned v0.1.4 mode renders exact ordered prompt bytes" do
    record = %{
      "Feedback" => "Use the expected opaque route.",
      "Generated Outputs" => %{"route" => "K47"},
      "Inputs" => %{"text" => "What kind of thing is a narwhal?"}
    }

    [%{role: :user, content: actual}] =
      InstructionProposal.messages("Choose one route.", [record], nil, :gepa_v0_1_4)

    expected =
      """
      I provided an assistant with the following instructions to perform a task for me:
      ```
      Choose one route.
      ```

      The following are examples of different task inputs provided to the assistant along with the assistant's response for each of them, and some feedback on how the assistant's response could be better:
      ```
      # Example 1
      ## Inputs
      ### text
      What kind of thing is a narwhal?

      ## Generated Outputs
      ### route
      K47

      ## Feedback
      Use the expected opaque route.


      ```

      Your task is to write a new instruction for the assistant.

      Read the inputs carefully and identify the input format and infer detailed task description about the task I wish to solve with the assistant.

      Read all the assistant responses and the corresponding feedback. Identify all niche and domain specific factual information about the task and include it in the instruction, as a lot of it may not be available to the assistant in the future. The assistant may have utilized a generalizable strategy to solve the task, if so, include that in the instruction as well.

      Provide the new instructions within ``` blocks.
      """
      |> String.trim_trailing("\n")

    assert actual == expected
    refute String.ends_with?(actual, "\n")
  end

  test "normalizes typed and textual JSON adapter responses without installing the envelope" do
    assert InstructionProposal.normalize(%{"instruction" => "Use exact labels."}) ==
             {:ok, "Use exact labels."}

    assert InstructionProposal.normalize(~s({"instruction":"Use exact labels."})) ==
             {:ok, "Use exact labels."}

    assert InstructionProposal.normalize(
             "```json\n{\"new_instruction\":\"Use exact labels.\"}\n```"
           ) ==
             {:ok, "Use exact labels."}

    assert {:error, {:invalid_reflection_lm_response, %{answer: "missing"}}} =
             InstructionProposal.normalize(%{answer: "missing"})
  end
end
