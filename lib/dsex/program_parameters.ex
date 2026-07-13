defmodule DSEx.ProgramParameters do
  @moduledoc """
  Named predictor access and functional updates for optimizable programs.

  Built-in DSEx programs expose their primary predictor as `:main`. Custom
  programs can implement `optimizer_predictors/1` and
  `update_optimizer_predictor/3` to expose additional named predictors.
  """

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
  @type playbook_entry :: %{name: name(), playbook: DSEx.Playbook.t()}

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

  @doc "Returns named persistent playbook parameters exposed by a program."
  @spec playbooks(struct()) :: [playbook_entry()]
  def playbooks(%module{} = program) do
    if function_exported?(module, :optimizer_playbooks, 1) do
      program
      |> module.optimizer_playbooks()
      |> normalize_custom_playbooks!()
    else
      []
    end
  end

  @doc "Functionally updates one named persistent playbook parameter."
  @spec update_playbook(struct(), name(), (DSEx.Playbook.t() -> DSEx.Playbook.t())) :: struct()
  def update_playbook(%module{} = program, name, update) when is_function(update, 1) do
    if function_exported?(module, :update_optimizer_playbook, 3) do
      updated = module.update_optimizer_playbook(program, name, update)

      unless match?(%DSEx.Playbook{}, fetch_playbook!(updated, name)) do
        raise ArgumentError, "optimizer playbook update must return a DSEx.Playbook"
      end

      updated
    else
      raise ArgumentError,
            "program #{inspect(module)} has no optimizer playbook named #{inspect(name)}"
    end
  end

  @doc "Replaces one named persistent playbook parameter."
  @spec put_playbook(struct(), name(), DSEx.Playbook.t()) :: struct()
  def put_playbook(program, name, %DSEx.Playbook{} = playbook) do
    update_playbook(program, name, fn _current -> playbook end)
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

  defp normalize_custom_playbooks!(playbooks) when is_list(playbooks) do
    entries =
      Enum.map(playbooks, fn
        {name, %DSEx.Playbook{} = playbook} -> %{name: name, playbook: playbook}
        %{name: name, playbook: %DSEx.Playbook{} = playbook} -> %{name: name, playbook: playbook}
        other -> raise ArgumentError, "invalid optimizer playbook entry: #{inspect(other)}"
      end)

    names = Enum.map(entries, & &1.name)
    normalized_names = Enum.map(names, &{name_type(&1), to_string(&1)})

    if length(normalized_names) == MapSet.size(MapSet.new(normalized_names)),
      do: entries,
      else: raise(ArgumentError, "optimizer playbook names must be unique")
  end

  defp normalize_custom_playbooks!(other) do
    raise ArgumentError,
          "optimizer_playbooks/1 must return a list, got: #{inspect(other)}"
  end

  defp fetch_playbook!(program, name) do
    case Enum.find(playbooks(program), &(&1.name == name)) do
      %{playbook: playbook} -> playbook
      nil -> raise ArgumentError, "optimizer playbook update removed #{inspect(name)}"
    end
  end

  defp name_type(name) when is_atom(name), do: :atom
  defp name_type(name) when is_binary(name), do: :string
end
