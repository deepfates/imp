defmodule DSEx.Predict.Parallel do
  @moduledoc """
  Run a program across many inputs concurrently through `DSEx.Tasks`.

  Results preserve input order. Program crashes, throws, invalid return shapes,
  and task exits are returned as per-input `{:error, reason}` tuples so one bad
  input does not bring down the whole batch.
  """

  @option_schema [
    max_concurrency: [type: :any, default: System.schedulers_online()],
    timeout: [type: :any, default: 30_000],
    on_timeout: [type: :any, default: :kill_task]
  ]

  def map(program, inputs, opts \\ []) do
    opts = DSEx.Options.validate!(opts, @option_schema, "DSEx.Predict.Parallel.map/3")
    inputs = validate_inputs!(inputs)
    concurrency = positive_integer(opts[:max_concurrency])

    inputs
    |> DSEx.Tasks.async_stream(&call_program(program, &1),
      max_concurrency: concurrency,
      timeout: opts[:timeout],
      on_timeout: opts[:on_timeout]
    )
    |> Enum.map(fn
      {:ok, result} -> result
      {:exit, reason} -> {:error, reason}
    end)
  end

  defp call_program(program, input) do
    case DSEx.Module.call(program, input) do
      {:ok, _value} = ok ->
        ok

      {:error, {:module_call_failed, _module, reason}} ->
        {:error, {:parallel_program_failed, reason}}

      {:error, _reason} = error ->
        error

      other ->
        {:error, {:invalid_parallel_result, inspect(other)}}
    end
  rescue
    error -> {:error, {:parallel_program_failed, error_message(error)}}
  catch
    kind, reason -> {:error, {:parallel_program_failed, error_message({kind, reason})}}
  end

  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value), do: 1

  defp validate_inputs!(inputs) do
    if Enumerable.impl_for(inputs) do
      inputs
    else
      raise ArgumentError,
            "DSEx.Predict.Parallel.map/3 expects inputs to be an enumerable batch; got: #{inspect(inputs)}"
    end
  end

  defp error_message(%_{} = exception), do: Exception.message(exception)
  defp error_message(error), do: inspect(error)
end
