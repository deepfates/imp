defmodule DSEx.Predict.Parallel do
  @moduledoc """
  Run a program across many inputs concurrently through `DSEx.Tasks`.

  `map/3` is the DSEx batch prediction primitive. It accepts any executable
  DSEx program and an enumerable of input maps, runs the program through the
  supervised DSEx task boundary, and returns one result per input in the same
  order as the original batch.

  Successful calls return `{:ok, %DSEx.Prediction{}}`. Program crashes, throws,
  invalid return shapes, and task exits are returned as per-input
  `{:error, reason}` tuples so one bad input does not bring down the whole
  batch.

      iex> lm = %{
      ...>   module: DSEx.LM.Static,
      ...>   opts: [
      ...>     handler: fn messages, _opts ->
      ...>       prompt = Enum.map_join(messages, "\\n", &Map.fetch!(&1, :content))
      ...>
      ...>       cond do
      ...>         prompt =~ "alpha" -> %{answer: "A"}
      ...>         prompt =~ "beta" -> %{answer: "B"}
      ...>       end
      ...>     end
      ...>   ]
      ...> }
      iex> program = DSEx.Predict.Predict.new("question -> answer", lm: lm)
      iex> results = DSEx.Predict.Parallel.map(program, [%{question: "alpha"}, %{question: "beta"}])
      iex> Enum.map(results, fn {:ok, prediction} -> DSEx.Prediction.get(prediction, :answer) end)
      ["A", "B"]

  Bad inputs remain local to their result slot:

      iex> lm = %{
      ...>   module: DSEx.LM.Static,
      ...>   opts: [
      ...>     handler: fn messages, _opts ->
      ...>       prompt = Enum.map_join(messages, "\\n", &Map.fetch!(&1, :content))
      ...>       if prompt =~ "bad", do: raise("boom"), else: %{answer: "ok"}
      ...>     end
      ...>   ]
      ...> }
      iex> program = DSEx.Predict.Predict.new("question -> answer", lm: lm)
      iex> results = DSEx.Predict.Parallel.map(program, [%{question: "ok"}, %{question: "bad"}])
      iex> match?([{:ok, %DSEx.Prediction{}}, {:error, {:lm_failed, DSEx.LM.Static, "boom"}}], results)
      true
      iex> [{:ok, prediction}, _error] = results; DSEx.Prediction.get(prediction, :answer)
      "ok"
  """

  @option_schema [
    max_concurrency: [type: :pos_integer, default: System.schedulers_online()],
    timeout: [type: :timeout, default: 30_000],
    on_timeout: [type: {:in, [:exit, :kill_task]}, default: :kill_task]
  ]

  @doc """
  Maps `program` over `inputs` concurrently.

  Options:

    * `:max_concurrency` - positive integer task concurrency. Defaults to
      `System.schedulers_online/0`.
    * `:timeout` - task timeout accepted by `Task.async_stream/5`. Defaults to
      `30_000`.
    * `:on_timeout` - either `:kill_task` or `:exit`. Defaults to `:kill_task`.

  """
  def map(program, inputs, opts \\ []) do
    opts = DSEx.Options.validate!(opts, @option_schema, "DSEx.Predict.Parallel.map/3")
    inputs = validate_inputs!(inputs)

    inputs
    |> DSEx.Tasks.async_stream(&call_program(program, &1),
      max_concurrency: opts[:max_concurrency],
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
