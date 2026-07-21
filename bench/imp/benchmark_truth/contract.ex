defmodule Imp.BenchmarkTruth.Contract do
  @moduledoc false

  @imp_prompt_contract "imp-chat-template-v7-canonical-answer"
  @dspy_prompt_contract "dspy-signature-chat-20260707-canonical-answer"

  @hotpotqa_instruction "Answer using the provided context. Return the canonical exact answer span from the context. For yes/no questions, answer exactly yes or no. Do not abbreviate locations, titles, names, dates, or quantities when the question asks for the full entity."

  def current_prompt_contract do
    %{
      "imp_req_llm" => @imp_prompt_contract,
      "python_dspy" => @dspy_prompt_contract
    }
  end

  def prompt_contract(:imp_req_llm), do: @imp_prompt_contract
  def prompt_contract(:python_dspy), do: @dspy_prompt_contract
  def prompt_contract("imp_req_llm"), do: @imp_prompt_contract
  def prompt_contract("python_dspy"), do: @dspy_prompt_contract

  def hotpotqa_instruction, do: @hotpotqa_instruction
end
