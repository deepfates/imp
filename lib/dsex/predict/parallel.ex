defmodule DSEx.Predict.Parallel do
  @moduledoc "Run a program across many inputs concurrently through `DSEx.Tasks`."

  def map(program, inputs, opts \\ []) do
    concurrency = Keyword.get(opts, :max_concurrency, System.schedulers_online())

    inputs
    |> DSEx.Tasks.async_stream(&program.__struct__.call(program, &1),
      max_concurrency: concurrency,
      timeout: Keyword.get(opts, :timeout, 30_000)
    )
    |> Enum.map(fn
      {:ok, result} -> result
      {:exit, reason} -> {:error, reason}
    end)
  end
end
