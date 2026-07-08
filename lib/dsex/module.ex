defmodule DSEx.Module do
  @moduledoc "Behaviour for executable DSEx programs."

  @callback call(struct(), map() | keyword()) ::
              {:ok, DSEx.Prediction.t()} | {:error, term()}

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
