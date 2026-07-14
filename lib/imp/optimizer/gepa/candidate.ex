defmodule Imp.Optimizer.GEPA.Candidate do
  @moduledoc """
  Named textual components evaluated by a GEPA adapter.

  Component names use the same identity rules as `Imp.ProgramParameters`.
  The helpers in this module provide the bridge between an Imp program and the
  source-shaped GEPA candidate map without owning or duplicating predictor data.
  """

  alias Imp.ProgramParameters

  @type component_name :: ProgramParameters.name()
  @type t :: %{optional(component_name()) => String.t()}

  @doc "Returns the current instruction of every optimizer-visible program component."
  @spec from_program(struct()) :: t()
  def from_program(program) do
    case ProgramParameters.predictors(program) do
      [] ->
        case Imp.Optimizer.InstructionSearch.current_instruction(program) do
          instruction when is_binary(instruction) -> %{main: instruction}
          _other -> %{}
        end

      predictors ->
        Map.new(predictors, fn %{name: name, predictor: predictor} ->
          {name, predictor.signature.instructions}
        end)
    end
  end

  @doc "Applies a complete named candidate to a program through `Imp.ProgramParameters`."
  @spec apply_to_program(struct(), t()) :: struct()
  def apply_to_program(program, candidate) when is_map(candidate) do
    case ProgramParameters.predictors(program) do
      [] -> apply_instruction_program(program, candidate)
      predictors -> apply_predictor_program(program, predictors, candidate)
    end
  end

  defp apply_predictor_program(program, predictors, candidate) do
    expected_names = predictors |> Enum.map(& &1.name) |> MapSet.new()

    candidate_names = candidate |> validate!() |> Map.keys() |> MapSet.new()

    if candidate_names != expected_names do
      raise ArgumentError,
            "candidate components must match program components; expected " <>
              "#{inspect(MapSet.to_list(expected_names))}, got " <>
              inspect(MapSet.to_list(candidate_names))
    end

    Enum.reduce(candidate, program, fn {name, text}, updated_program ->
      ProgramParameters.put_instruction(updated_program, name, text)
    end)
  end

  defp apply_instruction_program(program, candidate) do
    candidate = validate!(candidate)

    case candidate do
      %{main: instruction} when map_size(candidate) == 1 ->
        Imp.Optimizer.InstructionSearch.put_instruction(program, instruction)

      %{"main" => instruction} when map_size(candidate) == 1 ->
        Imp.Optimizer.InstructionSearch.put_instruction(program, instruction)

      _other ->
        raise ArgumentError,
              "candidate components must match the program's single instruction component"
    end
  end

  @doc false
  @spec validate!(term()) :: t()
  def validate!(candidate) when is_map(candidate) do
    Enum.each(candidate, fn
      {name, text} when (is_atom(name) or is_binary(name)) and is_binary(text) ->
        :ok

      entry ->
        raise ArgumentError,
              "GEPA candidate entries must be named text components, got: #{inspect(entry)}"
    end)

    candidate
  end

  def validate!(candidate) do
    raise ArgumentError, "GEPA candidate must be a map, got: #{inspect(candidate)}"
  end
end
