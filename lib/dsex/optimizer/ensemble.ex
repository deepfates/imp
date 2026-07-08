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

  @option_schema [
    reduce_fn: [type: :any, default: nil],
    size: [type: :any, default: nil],
    deterministic: [type: :boolean, default: false]
  ]

  def new(opts \\ []) do
    opts = DSEx.Options.validate!(opts, @option_schema, "DSEx.Optimizer.Ensemble.new/1")
    validate_reduce_fn!(opts[:reduce_fn])

    %__MODULE__{
      reduce_fn: opts[:reduce_fn],
      size: non_negative_integer_or_nil(opts[:size]),
      deterministic: opts[:deterministic]
    }
  end

  def compile(%__MODULE__{} = ensemble, programs),
    do: %DSEx.Optimizer.Ensemble.Program{
      programs: validate_programs!(programs),
      ensemble: ensemble
    }

  defp validate_programs!(programs) do
    if Enumerable.impl_for(programs) do
      Enum.to_list(programs)
    else
      raise ArgumentError,
            "DSEx.Optimizer.Ensemble.compile/2 expects an enumerable of programs; got: #{inspect(programs)}"
    end
  end

  defp non_negative_integer_or_nil(nil), do: nil
  defp non_negative_integer_or_nil(value) when is_integer(value) and value > 0, do: value
  defp non_negative_integer_or_nil(_value), do: 0

  defp validate_reduce_fn!(nil), do: :ok
  defp validate_reduce_fn!(reduce_fn) when is_function(reduce_fn, 1), do: :ok

  defp validate_reduce_fn!(reduce_fn) do
    raise ArgumentError,
          "DSEx.Optimizer.Ensemble.new/1 expects :reduce_fn to be nil or an arity-1 function; got: #{inspect(reduce_fn)}"
  end
end
