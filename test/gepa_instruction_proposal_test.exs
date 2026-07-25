defmodule Imp.Optimizer.GEPA.InstructionProposalTest do
  use ExUnit.Case, async: true

  alias Imp.Optimizer.GEPA.InstructionProposal

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
