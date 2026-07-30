defmodule Imp.Playbook.WithContext do
  @moduledoc """
  Executes a program with active playbook guidance appended to every predictor.

  The wrapped program and playbook remain immutable. Optimizers operate on the
  underlying predictor instructions; playbook context is added only to the
  ephemeral program used for each call.
  """

  @behaviour Imp.Module

  alias Imp.{Playbook, ProgramParameters}
  alias Imp.Predict.Predict

  @enforce_keys [:program, :playbook]
  defstruct [:program, :playbook]

  @type t :: %__MODULE__{program: struct(), playbook: Playbook.t()}

  @spec new(struct(), Playbook.t()) :: t()
  def new(%module{} = program, %Playbook{} = playbook) do
    predictors = ProgramParameters.predictors(program)

    cond do
      not Code.ensure_loaded?(module) or not function_exported?(module, :call, 2) ->
        raise ArgumentError, "with_playbook expects an executable Imp program"

      predictors == [] ->
        raise ArgumentError, "with_playbook program must expose at least one optimizer predictor"

      true ->
        %__MODULE__{program: program, playbook: playbook}
    end
  end

  def new(program, playbook) do
    raise ArgumentError,
          "with_playbook expects an executable struct and Imp.Playbook, got: #{inspect({program, playbook})}"
  end

  @impl true
  def call(%__MODULE__{} = wrapper, inputs) do
    wrapper.program
    |> contextualize(wrapper.playbook)
    |> Imp.Module.call(inputs)
  end

  @doc false
  @impl true
  def optimizer_predictors(%__MODULE__{program: program}),
    do: ProgramParameters.predictors(program)

  @doc false
  @impl true
  def update_optimizer_predictor(%__MODULE__{} = wrapper, name, update) do
    %{wrapper | program: ProgramParameters.update_predictor(wrapper.program, name, update)}
  end

  @doc false
  def optimizer_playbooks(%__MODULE__{playbook: playbook}),
    do: [%{name: :playbook, playbook: playbook}]

  @doc false
  def update_optimizer_playbook(%__MODULE__{} = wrapper, :playbook, update) do
    case update.(wrapper.playbook) do
      %Playbook{} = playbook -> %{wrapper | playbook: playbook}
      other -> raise ArgumentError, "playbook update returned #{inspect(other)}"
    end
  end

  def update_optimizer_playbook(%__MODULE__{}, name, _update) do
    raise ArgumentError, "with_playbook has no optimizer playbook named #{inspect(name)}"
  end

  @doc false
  def with_lm(%__MODULE__{} = wrapper, lm) do
    update_predictors(wrapper, &Predict.with_lm(&1, lm))
  end

  @doc false
  def with_demos(%__MODULE__{} = wrapper, demos) do
    update_predictors(wrapper, &Predict.with_demos(&1, demos))
  end

  defp contextualize(program, playbook) do
    case Playbook.render(playbook) do
      "" ->
        program

      rendered ->
        Enum.reduce(ProgramParameters.predictors(program), program, fn %{name: name}, current ->
          ProgramParameters.update_predictor(current, name, fn %Predict{} = predictor ->
            instructions = predictor.signature.instructions
            block = "# Playbook\n\n" <> rendered
            updated = if instructions == "", do: block, else: instructions <> "\n\n" <> block
            Predict.with_signature(predictor, %{predictor.signature | instructions: updated})
          end)
        end)
    end
  end

  defp update_predictors(wrapper, update) do
    Enum.reduce(ProgramParameters.predictors(wrapper), wrapper, fn %{name: name}, current ->
      ProgramParameters.update_predictor(current, name, update)
    end)
  end
end
