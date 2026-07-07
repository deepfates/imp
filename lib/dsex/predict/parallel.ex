defmodule DSEx.Predict.Parallel do
  @moduledoc """
  Run a program across many inputs concurrently through `DSEx.Tasks`.

  Results preserve input order. Program crashes, throws, invalid return shapes,
  and task exits are returned as per-input `{:error, reason}` tuples so one bad
  input does not bring down the whole batch.
  """

  def map(program, inputs, opts \\ []) do
    concurrency =
      positive_integer(Keyword.get(opts, :max_concurrency, System.schedulers_online()))

    inputs
    |> DSEx.Tasks.async_stream(&call_program(program, &1),
      max_concurrency: concurrency,
      timeout: Keyword.get(opts, :timeout, 30_000),
      on_timeout: Keyword.get(opts, :on_timeout, :kill_task)
    )
    |> Enum.map(fn
      {:ok, result} -> result
      {:exit, reason} -> {:error, reason}
    end)
  end

  defp call_program(program, input) do
    case DSEx.Module.call(program, input) do
      {:ok, _value} = ok -> ok
      {:error, _reason} = error -> error
      other -> {:error, {:invalid_parallel_result, inspect(other)}}
    end
  rescue
    error -> {:error, {:parallel_program_failed, error_message(error)}}
  catch
    kind, reason -> {:error, {:parallel_program_failed, error_message({kind, reason})}}
  end

  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value), do: 1

  defp error_message(%_{} = exception), do: Exception.message(exception)
  defp error_message(error), do: inspect(error)
end
