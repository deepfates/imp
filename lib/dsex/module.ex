defmodule DSEx.Module do
  @moduledoc """
  Behaviour and safe dispatcher for executable DSEx programs.

  A DSEx program is any struct whose module implements `call/2` and returns
  either `{:ok, %DSEx.Prediction{}}` or `{:error, reason}`. `DSEx.Module.call/2`
  is the central boundary used by evaluators, composition modules, streaming,
  optimizers, and the public `DSEx.call/2` facade. It catches callback crashes
  and normalizes malformed callback returns so composed workflows can report
  failures without losing the rest of the run.
  """

  @callback call(struct(), map() | keyword()) ::
              {:ok, DSEx.Prediction.t()} | {:error, term()}

  @doc """
  Calls a DSEx executable program and normalizes its result shape.

  Successful programs must return a `DSEx.Prediction`:

      iex> lm = %{module: DSEx.LM.Static, opts: [handler: fn _messages, _opts -> %{answer: "4"} end]}
      iex> program = DSEx.Predict.Predict.new("question -> answer", lm: lm)
      iex> {:ok, prediction} = DSEx.Module.call(program, %{question: "2+2?"})
      iex> DSEx.Prediction.get(prediction, :answer)
      "4"

  Non-program values are reported as not callable:

      iex> DSEx.Module.call(%{}, %{question: "q"})
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
      {:ok, %DSEx.Prediction{} = prediction} ->
        {:ok, prediction}

      {:ok, other} ->
        {:error, {:invalid_module_prediction, module, inspect(other)}}

      {:error, _reason} = error ->
        error

      other ->
        {:error, {:invalid_module_result, module, inspect(other)}}
    end
  rescue
    error -> {:error, {:module_call_failed, module, error_message(error)}}
  catch
    kind, reason -> {:error, {:module_call_failed, module, error_message({kind, reason})}}
  end

  defp error_message(%_{} = exception), do: Exception.message(exception)
  defp error_message(error), do: inspect(error)
end
