defmodule DSEx.ProgramAccess do
  @moduledoc false

  alias DSEx.Predict.{ChainOfThought, CodeAct, Predict, ProgramOfThought, RAG}

  def predict(%Predict{} = predict), do: predict
  def predict(%ChainOfThought{predict: predict}), do: predict(predict)
  def predict(%ProgramOfThought{predict: predict}), do: predict(predict)
  def predict(%CodeAct{program_of_thought: pot}), do: predict(pot)
  def predict(%RAG{program: program}), do: predict(program)
  def predict(_program), do: nil

  def task_signature(%Predict{signature: signature}), do: signature
  def task_signature(%ChainOfThought{predict: predict}), do: task_signature(predict)
  def task_signature(%ProgramOfThought{signature: signature}), do: signature
  def task_signature(%CodeAct{program_of_thought: pot}), do: task_signature(pot)
  def task_signature(%RAG{program: program}), do: task_signature(program)
  def task_signature(_program), do: nil

  def lm_signature(program) do
    case predict(program) do
      %Predict{signature: signature} -> signature
      nil -> nil
    end
  end

  def output_names(program) do
    case task_signature(program) do
      %DSEx.Signature{} = signature -> DSEx.Signature.output_names(signature)
      nil -> []
    end
  end

  def provider_stream_predict(%Predict{} = predict), do: predict
  def provider_stream_predict(%ChainOfThought{predict: predict}), do: predict
  def provider_stream_predict(_program), do: nil

  def demos(program) do
    case predict(program) do
      %Predict{demos: demos} -> demos
      nil -> []
    end
  end

  def lm(program) do
    case predict(program) do
      %Predict{lm: lm} -> lm
      nil -> nil
    end
  end
end
