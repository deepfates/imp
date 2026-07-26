defmodule Imp.Optimizer.Artifact.ParameterSnapshot do
  @moduledoc false

  alias Imp.Predict.Predict
  alias Imp.ProgramParameters

  @enforce_keys [:predictors]
  defstruct [:predictors]

  @type entry :: %{required(:name) => ProgramParameters.name(), required(:predictor) => struct()}
  @type t :: %__MODULE__{predictors: [entry()]}

  @spec from_program(struct()) :: t()
  def from_program(program) when is_struct(program) do
    entries =
      program
      |> ProgramParameters.predictors()
      |> Enum.map(fn %{name: name, predictor: predictor} ->
        %{name: name, predictor: portable_predictor(predictor)}
      end)

    new(entries)
  end

  @spec new([entry()]) :: t()
  def new(entries) when is_list(entries) do
    entries = Enum.map(entries, &validate_entry!/1)

    if entries == [] do
      raise ArgumentError,
            "optimizer parameter snapshots require at least one named predictor"
    end

    identities = Enum.map(entries, &name_identity(&1.name))

    if length(identities) != MapSet.size(MapSet.new(identities)) do
      raise ArgumentError, "optimizer parameter snapshot predictor names must be unique"
    end

    %__MODULE__{predictors: entries}
  end

  def new(other) do
    raise ArgumentError,
          "optimizer parameter snapshot predictors must be a list, got: #{inspect(other)}"
  end

  def optimizer_predictors(%__MODULE__{predictors: predictors}), do: predictors

  def update_optimizer_predictor(%__MODULE__{} = snapshot, name, update)
      when is_function(update, 1) do
    {updated, found?} =
      Enum.map_reduce(snapshot.predictors, false, fn
        %{name: ^name, predictor: predictor} = entry, _found? ->
          {%{entry | predictor: portable_predictor(update.(predictor))}, true}

        entry, found? ->
          {entry, found?}
      end)

    if found?,
      do: %{snapshot | predictors: updated},
      else: raise(ArgumentError, "optimizer parameter snapshot has no predictor #{inspect(name)}")
  end

  defp portable_predictor(%Predict{} = predictor) do
    Predict.new(predictor.signature,
      demos: predictor.demos,
      config: predictor.config
    )
  end

  defp portable_predictor(other) do
    raise ArgumentError,
          "optimizer parameter snapshots accept only Imp predictors, got: #{inspect(other)}"
  end

  defp validate_entry!(%{name: name, predictor: %Predict{} = predictor})
       when is_atom(name) or is_binary(name),
       do: %{name: name, predictor: portable_predictor(predictor)}

  defp validate_entry!(other) do
    raise ArgumentError,
          "invalid optimizer parameter snapshot entry: #{inspect(other)}"
  end

  defp name_identity(name) when is_atom(name), do: {:atom, Atom.to_string(name)}
  defp name_identity(name) when is_binary(name), do: {:string, name}
end
