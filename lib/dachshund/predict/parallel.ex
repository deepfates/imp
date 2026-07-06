defmodule Dachshund.Predict.Parallel do
  @moduledoc "Run a program across many inputs concurrently with `Task.async_stream/3`."

  def map(program, inputs, opts \\ []) do
    concurrency = Keyword.get(opts, :max_concurrency, System.schedulers_online())

    inputs
    |> Task.async_stream(&program.__struct__.call(program, &1),
      max_concurrency: concurrency,
      timeout: Keyword.get(opts, :timeout, 30_000)
    )
    |> Enum.map(fn
      {:ok, result} -> result
      {:exit, reason} -> {:error, reason}
    end)
  end
end
