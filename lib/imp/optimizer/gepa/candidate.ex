defmodule Imp.Optimizer.GEPA.Candidate do
  @moduledoc """
  Named textual components evaluated by a GEPA adapter.

  Component names use the same identity rules as `Imp.ProgramParameters`.
  The helpers in this module provide the bridge between an Imp program and the
  source-shaped GEPA candidate map without owning or duplicating predictor data.
  """

  alias Imp.ProgramParameters
  alias Imp.Optimizer.Parameter.Change

  @type component_name :: ProgramParameters.name()
  @type t :: %{optional(component_name()) => String.t()}

  @doc "Returns the current instruction of every optimizer-visible program component."
  @spec from_program(struct()) :: t()
  def from_program(program) do
    case ProgramParameters.instruction_components(program) do
      [] ->
        case Imp.Optimizer.InstructionSearch.current_instruction(program) do
          instruction when is_binary(instruction) -> %{main: instruction}
          _other -> %{}
        end

      components ->
        Map.new(components, fn %{name: name, component: component} ->
          {name, component.parameter.value}
        end)
    end
  end

  @doc "Applies a complete named candidate to a program through `Imp.ProgramParameters`."
  @spec apply_to_program(struct(), t()) :: struct()
  def apply_to_program(program, candidate) when is_map(candidate) do
    case ProgramParameters.instruction_components(program) do
      [] -> apply_instruction_program(program, candidate)
      components -> apply_component_program(program, components, candidate)
    end
  end

  defp apply_component_program(program, components, candidate) do
    expected_names = components |> Enum.map(& &1.name) |> MapSet.new()

    candidate_names = candidate |> validate!() |> Map.keys() |> MapSet.new()

    if candidate_names != expected_names do
      raise ArgumentError,
            "candidate components must match program components; expected " <>
              "#{inspect(MapSet.to_list(expected_names))}, got " <>
              inspect(MapSet.to_list(candidate_names))
    end

    by_name = Map.new(components, &{&1.name, &1.component.parameter})

    changes =
      Enum.map(candidate, fn {name, text} ->
        parameter = Map.fetch!(by_name, name)
        Change.new(parameter.id, parameter.kind, text, base_digest: parameter.digest)
      end)

    case ProgramParameters.apply_changes(program, changes) do
      {:ok, updated} -> updated
      {:error, reason} -> raise ArgumentError, "cannot apply GEPA candidate: #{inspect(reason)}"
    end
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
