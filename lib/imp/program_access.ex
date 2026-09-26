defmodule Imp.ProgramAccess do
  @moduledoc """
  Internal. Uniform structural access to program structs: reaches through
  wrapper programs (ChainOfThought, RAG, Assertions, and friends) to the
  underlying `Imp.Predict`, its signature, demos, LM, and metadata,
  and writes those back via `put_lm/2` and the metadata helpers. Knowledge of
  each program type's internal shape is centralized here so callers like
  `Imp.with_lm/2` and the optimizers never pattern-match on it themselves.
  """

  alias Imp.Predict

  alias Imp.Predict.{
    Assertions,
    Avatar,
    BestOfN,
    ChainOfThought,
    CodeAct,
    MultiChainComparison,
    ProgramOfThought,
    RAG,
    ReAct,
    ReActV2,
    Refine,
    RLM
  }

  def predict(%Predict{} = predict), do: predict
  def predict(%ChainOfThought{predict: predict}), do: predict(predict)
  def predict(%ProgramOfThought{predict: predict}), do: predict(predict)
  def predict(%CodeAct{program_of_thought: pot}), do: predict(pot)
  def predict(%RAG{program: program}), do: predict(program)
  def predict(%Assertions{program: program}), do: predict(program)
  def predict(%ReAct{react: predict}), do: predict
  def predict(%ReActV2{react: predict}), do: predict
  def predict(%Avatar{actor: predict}), do: predict
  def predict(%BestOfN{program: program}), do: predict(program)
  def predict(%Refine{program: program}), do: predict(program)
  def predict(%MultiChainComparison{predict: predict}), do: predict(predict)
  def predict(%Imp.Optimizer.KNNFewShot.Program{student: student}), do: predict(student)
  def predict(%Imp.Playbook.WithContext{program: program}), do: predict(program)
  def predict(_program), do: nil

  def task_signature(%Predict{signature: signature}), do: signature
  def task_signature(%ChainOfThought{predict: predict}), do: task_signature(predict)
  def task_signature(%ProgramOfThought{signature: signature}), do: signature
  def task_signature(%CodeAct{program_of_thought: pot}), do: task_signature(pot)
  def task_signature(%RAG{program: program}), do: task_signature(program)
  def task_signature(%Assertions{program: program}), do: task_signature(program)
  def task_signature(%ReAct{signature: signature}), do: signature
  def task_signature(%ReActV2{signature: signature}), do: signature
  def task_signature(%Avatar{signature: signature}), do: signature
  def task_signature(%RLM{signature: signature}), do: signature

  def task_signature(%Imp.Optimizer.KNNFewShot.Program{student: student}),
    do: task_signature(student)

  def task_signature(%Imp.Playbook.WithContext{program: program}), do: task_signature(program)

  def task_signature(_program), do: nil

  def lm_signature(program) do
    case predict(program) do
      %Predict{signature: signature} -> signature
      nil -> nil
    end
  end

  def output_names(program) do
    case task_signature(program) do
      %Imp.Signature{} = signature -> Imp.Signature.output_names(signature)
      nil -> []
    end
  end

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

  def put_demos(%Predict{} = program, demos), do: Predict.with_demos(program, demos)

  def put_demos(%ChainOfThought{predict: predict} = program, demos),
    do: %{program | predict: put_demos(predict, demos)}

  def put_demos(%ProgramOfThought{predict: predict} = program, demos),
    do: %{program | predict: put_demos(predict, demos)}

  def put_demos(%CodeAct{program_of_thought: pot} = program, demos),
    do: %{program | program_of_thought: put_demos(pot, demos)}

  def put_demos(%RAG{program: inner} = program, demos),
    do: %{program | program: put_demos(inner, demos)}

  def put_demos(%Assertions{program: inner} = program, demos),
    do: %{program | program: put_demos(inner, demos)}

  def put_demos(%BestOfN{program: inner} = program, demos),
    do: %{program | program: put_demos(inner, demos)}

  def put_demos(%Refine{program: inner} = program, demos),
    do: %{program | program: put_demos(inner, demos)}

  def put_demos(%MultiChainComparison{predict: predict} = program, demos),
    do: %{program | predict: put_demos(predict, demos)}

  def put_demos(%ReAct{react: predict} = program, demos),
    do: %{program | react: put_demos(predict, demos)}

  def put_demos(%ReActV2{react: predict} = program, demos),
    do: %{program | react: put_demos(predict, demos)}

  def put_demos(%Imp.Playbook.WithContext{} = program, demos),
    do: Imp.Playbook.WithContext.with_demos(program, demos)

  def put_demos(%Imp.Optimizer.KNNFewShot.Program{} = program, demos) do
    %{
      program
      | student: put_demos(program.student, demos),
        teacher: maybe_put_demos(program.teacher, demos)
    }
  end

  def put_demos(%Imp.Optimizer.Ensemble.Program{programs: programs} = program, demos),
    do: %{program | programs: Enum.map(programs, &put_demos(&1, demos))}

  def put_demos(program, _demos) do
    raise ArgumentError,
          "Imp.with_demos/2 supports Predict and other demo-bearing Imp programs, " <>
            "and Imp.Example; " <>
            "got: #{inspect(program)}"
  end

  def put_lm(%Predict{} = program, lm), do: Predict.with_lm(program, lm)

  def put_lm(%ChainOfThought{predict: predict} = program, lm),
    do: %{program | predict: put_lm(predict, lm)}

  def put_lm(%ProgramOfThought{predict: predict} = program, lm),
    do: %{program | predict: put_lm(predict, lm)}

  def put_lm(%CodeAct{program_of_thought: pot} = program, lm),
    do: %{program | program_of_thought: put_lm(pot, lm)}

  def put_lm(%RAG{program: inner} = program, lm),
    do: %{program | program: put_lm(inner, lm)}

  def put_lm(%Assertions{program: inner} = program, lm),
    do: %{program | program: put_lm(inner, lm)}

  def put_lm(%BestOfN{program: inner} = program, lm),
    do: %{program | program: put_lm(inner, lm)}

  def put_lm(%Refine{program: inner} = program, lm),
    do: %{program | program: put_lm(inner, lm)}

  def put_lm(%MultiChainComparison{predict: predict} = program, lm),
    do: %{program | predict: put_lm(predict, lm)}

  def put_lm(%ReAct{react: predict} = program, lm),
    do: %{program | react: put_lm(predict, lm)}

  def put_lm(%ReActV2{react: predict} = program, lm),
    do: %{program | react: put_lm(predict, lm)}

  def put_lm(%Avatar{} = program, lm), do: Avatar.with_lm(program, lm)

  def put_lm(%RLM{} = program, lm),
    do: %{program | lm: lm, sub_lm: lm, dynamic_lm?: false, dynamic_sub_lm?: false}

  def put_lm(%Imp.Optimizer.KNNFewShot.Program{} = program, lm) do
    %{
      program
      | student: put_lm(program.student, lm),
        teacher: maybe_put_lm(program.teacher, lm)
    }
  end

  def put_lm(%Imp.Optimizer.Ensemble.Program{programs: programs} = program, lm),
    do: %{program | programs: Enum.map(programs, &put_lm(&1, lm))}

  def put_lm(%Imp.Evaluate.SemanticF1{predict: predict} = program, lm),
    do: %{program | predict: put_lm(predict, lm)}

  def put_lm(%Imp.Evaluate.CompleteAndGrounded{} = program, lm) do
    %{
      program
      | predict: maybe_put_lm(program.predict, lm),
        completeness: maybe_put_lm(program.completeness, lm),
        groundedness: maybe_put_lm(program.groundedness, lm)
    }
  end

  def put_lm(%Imp.Playbook.WithContext{} = program, lm),
    do: Imp.Playbook.WithContext.with_lm(program, lm)

  def put_lm(program, _lm) do
    raise ArgumentError,
          "Imp.with_lm/2 does not support #{inspect(program_type(program))}"
  end

  defp program_type(%module{}), do: module
  defp program_type(program), do: program

  defp maybe_put_lm(nil, _lm), do: nil
  defp maybe_put_lm(program, lm), do: put_lm(program, lm)

  defp maybe_put_demos(nil, _demos), do: nil
  defp maybe_put_demos(program, demos), do: put_demos(program, demos)

  def get_metadata(%Avatar{metadata: metadata}, key), do: Map.get(metadata, key)

  def get_metadata(%{__struct__: _module, metadata: metadata}, key) when is_map(metadata),
    do: Map.get(metadata, key)

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

  def put_metadata(%Assertions{program: inner} = program, key, value) do
    %{program | program: put_metadata(inner, key, value)}
  end

  def put_metadata(%BestOfN{program: inner} = program, key, value) do
    %{program | program: put_metadata(inner, key, value)}
  end

  def put_metadata(%Refine{program: inner} = program, key, value) do
    %{program | program: put_metadata(inner, key, value)}
  end

  def put_metadata(%MultiChainComparison{predict: predict} = program, key, value) do
    %{program | predict: put_metadata(predict, key, value)}
  end

  def put_metadata(%ReAct{react: predict} = program, key, value),
    do: %{program | react: put_metadata(predict, key, value)}

  def put_metadata(%ReActV2{react: predict} = program, key, value),
    do: %{program | react: put_metadata(predict, key, value)}

  def put_metadata(%Avatar{metadata: metadata} = program, key, value),
    do: %{program | metadata: Map.put(metadata, key, value)}

  def put_metadata(%Imp.Optimizer.KNNFewShot.Program{student: student} = program, key, value),
    do: %{program | student: put_metadata(student, key, value)}

  def put_metadata(%Imp.Playbook.WithContext{program: inner} = program, key, value),
    do: %{program | program: put_metadata(inner, key, value)}

  def put_metadata(%{__struct__: _module, metadata: metadata} = program, key, value)
      when is_map(metadata),
      do: %{program | metadata: Map.put(metadata, key, value)}

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

  def merge_metadata(%Assertions{program: inner} = program, metadata),
    do: %{program | program: merge_metadata(inner, metadata)}

  def merge_metadata(%BestOfN{program: inner} = program, metadata),
    do: %{program | program: merge_metadata(inner, metadata)}

  def merge_metadata(%Refine{program: inner} = program, metadata),
    do: %{program | program: merge_metadata(inner, metadata)}

  def merge_metadata(%MultiChainComparison{predict: predict} = program, metadata),
    do: %{program | predict: merge_metadata(predict, metadata)}

  def merge_metadata(%ReAct{react: predict} = program, metadata),
    do: %{program | react: merge_metadata(predict, metadata)}

  def merge_metadata(%ReActV2{react: predict} = program, metadata),
    do: %{program | react: merge_metadata(predict, metadata)}

  def merge_metadata(%Avatar{metadata: existing} = program, metadata),
    do: %{program | metadata: Map.merge(existing, metadata)}

  def merge_metadata(%Imp.Optimizer.KNNFewShot.Program{student: student} = program, metadata),
    do: %{program | student: merge_metadata(student, metadata)}

  def merge_metadata(%Imp.Playbook.WithContext{program: inner} = program, metadata),
    do: %{program | program: merge_metadata(inner, metadata)}

  def merge_metadata(program, _metadata), do: program
end
