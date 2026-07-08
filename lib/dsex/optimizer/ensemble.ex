defmodule DSEx.Optimizer.Ensemble.Program do
  @moduledoc false
  @behaviour DSEx.Module

  defstruct [:ensemble, programs: []]

  @impl true
  def call(%__MODULE__{} = program, inputs) do
    programs =
      cond do
        program.ensemble.deterministic ->
          Enum.take(program.programs, program.ensemble.size || length(program.programs))

        program.ensemble.size ->
          program.programs |> Enum.shuffle() |> Enum.take(program.ensemble.size)

        true ->
          program.programs
      end

    outputs = Enum.map(programs, &safe_call(&1, inputs))

    if program.ensemble.reduce_fn do
      predictions =
        Enum.flat_map(outputs, fn
          {:ok, pred} -> [pred]
          _ -> []
        end)

      reduce(program.ensemble.reduce_fn, predictions, outputs)
    else
      {:ok, DSEx.Prediction.new(%{outputs: outputs})}
    end
  end

  defp safe_call(program, inputs) do
    case DSEx.Module.call(program, inputs) do
      {:ok, %DSEx.Prediction{} = prediction} ->
        {:ok, prediction}

      {:ok, other} ->
        {:error, {:invalid_ensemble_prediction, inspect(other)}}

      {:error, {:module_call_failed, _module, reason}} ->
        {:error, {:ensemble_program_failed, reason}}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:invalid_ensemble_result, inspect(other)}}
    end
  rescue
    error -> {:error, {:ensemble_program_failed, error_message(error)}}
  catch
    kind, reason -> {:error, {:ensemble_program_failed, error_message({kind, reason})}}
  end

  defp reduce(reduce_fn, predictions, outputs) do
    case reduce_fn.(predictions) do
      %DSEx.Prediction{} = prediction ->
        {:ok, prediction}

      %{} = fields ->
        {:ok, DSEx.Prediction.new(fields)}

      other ->
        {:error, {:invalid_ensemble_reduction, inspect(other), outputs}}
    end
  rescue
    error -> {:error, {:ensemble_reduce_failed, error_message(error), outputs}}
  catch
    kind, reason -> {:error, {:ensemble_reduce_failed, error_message({kind, reason}), outputs}}
  end

  defp error_message(%_{} = exception), do: Exception.message(exception)
  defp error_message(error), do: inspect(error)
end

defmodule DSEx.Optimizer.Ensemble do
  @moduledoc """
  Compile multiple programs into an ensemble program.

  Each child program is called independently. A failed child contributes an
  `{:error, reason}` entry to the ensemble outputs instead of crashing the whole
  ensemble. When a `:reduce_fn` is supplied, it receives only successful
  predictions; reducer exceptions or invalid reducer returns become structured
  `{:error, reason}` results.
  """

  defstruct reduce_fn: nil, size: nil, deterministic: false

  def new(opts \\ []) do
    %__MODULE__{
      reduce_fn: Keyword.get(opts, :reduce_fn),
      size: non_negative_integer_or_nil(Keyword.get(opts, :size)),
      deterministic: Keyword.get(opts, :deterministic, false)
    }
  end

  def compile(%__MODULE__{} = ensemble, programs),
    do: %DSEx.Optimizer.Ensemble.Program{programs: programs, ensemble: ensemble}

  defp non_negative_integer_or_nil(nil), do: nil
  defp non_negative_integer_or_nil(value) when is_integer(value) and value > 0, do: value
  defp non_negative_integer_or_nil(_value), do: 0
end
