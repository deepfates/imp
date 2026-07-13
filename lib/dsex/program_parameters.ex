defmodule DSEx.ProgramParameters do
  @moduledoc false

  alias DSEx.Predict.{
    Assertions,
    BestOfN,
    ChainOfThought,
    CodeAct,
    MultiChainComparison,
    Predict,
    ProgramOfThought,
    RAG,
    ReAct,
    ReActV2,
    Refine
  }

  @type name :: atom() | String.t()
  @type entry :: %{name: name(), predictor: struct()}

  @spec predictors(struct()) :: [entry()]
  def predictors(%module{} = program) do
    cond do
      function_exported?(module, :optimizer_predictors, 1) ->
        program
        |> module.optimizer_predictors()
        |> normalize_custom_predictors!()

      true ->
        builtin_predictors(program)
    end
  end

  @spec update_predictor(struct(), name(), (struct() -> struct())) :: struct()
  def update_predictor(%module{} = program, name, update) when is_function(update, 1) do
    cond do
      function_exported?(module, :update_optimizer_predictor, 3) ->
        module.update_optimizer_predictor(program, name, update)

      name == :main ->
        update_builtin_predictor(program, update)

      true ->
        raise ArgumentError,
              "program #{inspect(module)} has no optimizer predictor named #{inspect(name)}"
    end
  end

  @spec put_instruction(struct(), name(), String.t()) :: struct()
  def put_instruction(program, name, instruction) when is_binary(instruction) do
    update_predictor(program, name, fn predictor ->
      Predict.with_signature(predictor, %{predictor.signature | instructions: instruction})
    end)
  end

  @spec put_demos(struct(), name(), [term()]) :: struct()
  def put_demos(program, name, demos) when is_list(demos) do
    update_predictor(program, name, &Predict.with_demos(&1, demos))
  end

  defp builtin_predictors(program) do
    case builtin_predictor(program) do
      %Predict{} = predictor -> [%{name: :main, predictor: predictor}]
      nil -> []
    end
  end

  defp builtin_predictor(%Predict{} = predictor), do: predictor
  defp builtin_predictor(%ChainOfThought{predict: predictor}), do: predictor
  defp builtin_predictor(%ProgramOfThought{predict: predictor}), do: predictor
  defp builtin_predictor(%CodeAct{program_of_thought: program}), do: builtin_predictor(program)
  defp builtin_predictor(%RAG{program: program}), do: builtin_predictor(program)
  defp builtin_predictor(%Assertions{program: program}), do: builtin_predictor(program)
  defp builtin_predictor(%ReAct{react: predictor}), do: predictor
  defp builtin_predictor(%ReActV2{react: predictor}), do: predictor
  defp builtin_predictor(%BestOfN{program: program}), do: builtin_predictor(program)
  defp builtin_predictor(%Refine{program: program}), do: builtin_predictor(program)
  defp builtin_predictor(%MultiChainComparison{predict: predictor}), do: predictor
  defp builtin_predictor(_program), do: nil

  defp update_builtin_predictor(%Predict{} = program, update), do: update.(program)

  defp update_builtin_predictor(%ChainOfThought{predict: predictor} = program, update),
    do: %{program | predict: update.(predictor)}

  defp update_builtin_predictor(%ProgramOfThought{predict: predictor} = program, update),
    do: %{program | predict: update.(predictor)}

  defp update_builtin_predictor(%CodeAct{program_of_thought: inner} = program, update),
    do: %{program | program_of_thought: update_builtin_predictor(inner, update)}

  defp update_builtin_predictor(%RAG{program: inner} = program, update),
    do: %{program | program: update_builtin_predictor(inner, update)}

  defp update_builtin_predictor(%Assertions{program: inner} = program, update),
    do: %{program | program: update_builtin_predictor(inner, update)}

  defp update_builtin_predictor(%ReAct{react: predictor} = program, update),
    do: %{program | react: update.(predictor)}

  defp update_builtin_predictor(%ReActV2{react: predictor} = program, update),
    do: %{program | react: update.(predictor)}

  defp update_builtin_predictor(%BestOfN{program: inner} = program, update),
    do: %{program | program: update_builtin_predictor(inner, update)}

  defp update_builtin_predictor(%Refine{program: inner} = program, update),
    do: %{program | program: update_builtin_predictor(inner, update)}

  defp update_builtin_predictor(%MultiChainComparison{predict: predictor} = program, update),
    do: %{program | predict: update.(predictor)}

  defp update_builtin_predictor(%module{}, _update) do
    raise ArgumentError,
          "program #{inspect(module)} does not expose optimizer predictors; implement optimizer_predictors/1 and update_optimizer_predictor/3"
  end

  defp normalize_custom_predictors!(predictors) when is_list(predictors) do
    entries =
      Enum.map(predictors, fn
        {name, %Predict{} = predictor} -> %{name: name, predictor: predictor}
        %{name: name, predictor: %Predict{} = predictor} -> %{name: name, predictor: predictor}
        other -> raise ArgumentError, "invalid optimizer predictor entry: #{inspect(other)}"
      end)

    names = Enum.map(entries, & &1.name)

    normalized_names = Enum.map(names, &{name_type(&1), to_string(&1)})

    if length(normalized_names) == MapSet.size(MapSet.new(normalized_names)),
      do: entries,
      else: raise(ArgumentError, "optimizer predictor names must be unique")
  end

  defp normalize_custom_predictors!(other) do
    raise ArgumentError,
          "optimizer_predictors/1 must return a list, got: #{inspect(other)}"
  end

  defp name_type(name) when is_atom(name), do: :atom
  defp name_type(name) when is_binary(name), do: :string
end
