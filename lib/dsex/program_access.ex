defmodule DSEx.ProgramAccess do
  @moduledoc false

  alias DSEx.Predict.{ChainOfThought, CodeAct, Predict, ProgramOfThought, RAG}

  def predict(%Predict{} = predict), do: predict
  def predict(%ChainOfThought{predict: predict}), do: predict(predict)
  def predict(%ProgramOfThought{predict: predict}), do: predict(predict)
  def predict(%CodeAct{program_of_thought: pot}), do: predict(pot)
  def predict(%RAG{program: program}), do: predict(program)
  def predict(_program), do: nil

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
