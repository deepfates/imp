defmodule Imp.Module do
  @moduledoc """
  Behaviour and safe dispatcher for executable Imp programs.

  An Imp program is any struct whose module implements `call/2` and returns
  either `{:ok, %Imp.Prediction{}}` or `{:error, reason}`. `Imp.Module.call/2`
  is the central boundary used by evaluators, composition modules, streaming,
  optimizers, and the public `Imp.call/2` facade. It catches callback crashes
  and normalizes malformed callback returns so composed workflows can report
  failures without losing the rest of the run.

  Consumer-defined multi-stage programs may expose named predictors to every
  program optimizer by implementing the paired optional callbacks
  `optimizer_predictors/1` and `update_optimizer_predictor/3`. Both callbacks
  are required together. Predictor names must be unique atoms or strings and
  each value must be an `Imp.Predict.Predict` struct. The update callback must
  return the same program struct after applying the supplied function to the
  named predictor. `Imp.ProgramParameters` validates this contract before an
  optimizer can use it.
  """

  @type optimizer_predictor_name :: atom() | String.t()
  @type optimizer_predictor :: %Imp.Predict.Predict{}
  @type optimizer_predictor_entry ::
          {optimizer_predictor_name(), optimizer_predictor()}
          | %{name: optimizer_predictor_name(), predictor: optimizer_predictor()}

  @callback call(struct(), map() | keyword()) ::
              {:ok, Imp.Prediction.t()} | {:error, term()}

  @callback optimizer_predictors(struct()) :: [optimizer_predictor_entry()]

  @callback update_optimizer_predictor(
              struct(),
              optimizer_predictor_name(),
              (optimizer_predictor() -> optimizer_predictor())
            ) :: struct()

  @optional_callbacks optimizer_predictors: 1, update_optimizer_predictor: 3

  @doc """
  Calls an Imp executable program and normalizes its result shape.

  Successful programs must return a `Imp.Prediction`:

      iex> lm = %{module: Imp.LM.Static, opts: [handler: fn _messages, _opts -> %{answer: "4"} end]}
      iex> program = Imp.Predict.Predict.new("question -> answer", lm: lm)
      iex> {:ok, prediction} = Imp.Module.call(program, %{question: "2+2?"})
      iex> Imp.Prediction.get(prediction, :answer)
      "4"

  Non-program values are reported as not callable:

      iex> Imp.Module.call(%{}, %{question: "q"})
      {:error, {:not_callable, %{}}}

  """
  def call(%module{} = program, inputs) do
    if Code.ensure_loaded?(module) and function_exported?(module, :call, 2) do
      safe_call(module, program, inputs)
    else
      {:error, {:not_callable, module}}
    end
  end

  def call(other, _inputs), do: {:error, {:not_callable, other}}

  defp safe_call(module, program, inputs) do
    case module.call(program, inputs) do
      {:ok, %Imp.Prediction{} = prediction} ->
        {:ok, prediction}

      {:ok, other} ->
        {:error, {:invalid_module_prediction, module, inspect(other)}}

      {:error, _reason} = error ->
        error

      other ->
        {:error, {:invalid_module_result, module, inspect(other)}}
    end
  rescue
    safety in Imp.OperationalSafetyError -> {:error, safety}
    error -> {:error, {:module_call_failed, module, error_message(error)}}
  catch
    kind, reason ->
      case Imp.OperationalSafetyError.find({kind, reason}) do
        %Imp.OperationalSafetyError{} = safety -> {:error, safety}
        nil -> {:error, {:module_call_failed, module, error_message({kind, reason})}}
      end
  end

  defp error_message(%_{} = exception), do: Exception.message(exception)
  defp error_message(error), do: inspect(error)
end
