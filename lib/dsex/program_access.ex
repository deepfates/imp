defmodule DSEx.ProgramAccess do
  @moduledoc false

  alias DSEx.Predict.{Assertions, ChainOfThought, CodeAct, Predict, ProgramOfThought, RAG, RLM}

  def predict(%Predict{} = predict), do: predict
  def predict(%ChainOfThought{predict: predict}), do: predict(predict)
  def predict(%ProgramOfThought{predict: predict}), do: predict(predict)
  def predict(%CodeAct{program_of_thought: pot}), do: predict(pot)
  def predict(%RAG{program: program}), do: predict(program)
  def predict(%Assertions{program: program}), do: predict(program)
  def predict(_program), do: nil

  def task_signature(%Predict{signature: signature}), do: signature
  def task_signature(%ChainOfThought{predict: predict}), do: task_signature(predict)
  def task_signature(%ProgramOfThought{signature: signature}), do: signature
  def task_signature(%CodeAct{program_of_thought: pot}), do: task_signature(pot)
  def task_signature(%RAG{program: program}), do: task_signature(program)
  def task_signature(%Assertions{program: program}), do: task_signature(program)
  def task_signature(%RLM{signature: signature}), do: signature
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
  def provider_stream_predict(%Assertions{program: program}), do: provider_stream_predict(program)
  def provider_stream_predict(_program), do: nil

  def internal_predictors(%RLM{} = rlm), do: RLM.internal_predictors(rlm)
  def internal_predictors(%Assertions{program: program}), do: internal_predictors(program)
  def internal_predictors(program), do: %{main: predict(program)}

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

  def get_metadata(program, key) do
    case predict(program) do
      %Predict{metadata: metadata} -> Map.get(metadata, key)
      nil -> nil
    end
  end

  def put_metadata(%Predict{metadata: metadata} = program, key, value) do
    %{program | metadata: Map.put(metadata, key, value)}
  end

  def put_metadata(%ChainOfThought{predict: predict} = program, key, value) do
    %{program | predict: put_metadata(predict, key, value)}
  end

  def put_metadata(%ProgramOfThought{predict: predict} = program, key, value) do
    %{program | predict: put_metadata(predict, key, value)}
  end

  def put_metadata(%CodeAct{program_of_thought: pot} = program, key, value) do
    %{program | program_of_thought: put_metadata(pot, key, value)}
  end

  def put_metadata(%RAG{program: inner} = program, key, value) do
    %{program | program: put_metadata(inner, key, value)}
  end

  def put_metadata(program, _key, _value), do: program

  def merge_metadata(%Predict{metadata: existing} = program, metadata) when is_map(metadata) do
    %{program | metadata: Map.merge(existing, metadata)}
  end

  def merge_metadata(%ChainOfThought{predict: predict} = program, metadata) do
    %{program | predict: merge_metadata(predict, metadata)}
  end

  def merge_metadata(%ProgramOfThought{predict: predict} = program, metadata) do
    %{program | predict: merge_metadata(predict, metadata)}
  end

  def merge_metadata(%CodeAct{program_of_thought: pot} = program, metadata) do
    %{program | program_of_thought: merge_metadata(pot, metadata)}
  end

  def merge_metadata(%RAG{program: inner} = program, metadata) do
    %{program | program: merge_metadata(inner, metadata)}
  end

  def merge_metadata(program, _metadata), do: program
end
