defmodule Imp.Predict.Parallel do
  @moduledoc """
  Run a program across many inputs concurrently through a supervised BEAM task
  boundary.

  `map/3` is the homogeneous batch primitive. `run/2` accepts a tree of
  `{program, inputs}` pairs when one workflow needs to execute different
  programs concurrently. Both run through the supervised Imp task boundary
  and preserve input order and nesting.

  Successful calls return `{:ok, %Imp.Prediction{}}`. Program crashes, throws,
  invalid return shapes, and task exits are returned as per-input
  `{:error, reason}` tuples so one bad input does not bring down the whole
  batch.

      iex> lm = %{
      ...>   module: Imp.LM.Static,
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
      iex> program = Imp.Predict.Predict.new("question -> answer", lm: lm)
      iex> results = Imp.Predict.Parallel.map(program, [%{question: "alpha"}, %{question: "beta"}])
      iex> Enum.map(results, fn {:ok, prediction} -> Imp.Prediction.get(prediction, :answer) end)
      ["A", "B"]

  Bad inputs remain local to their result slot:

      iex> lm = %{
      ...>   module: Imp.LM.Static,
      ...>   opts: [
      ...>     handler: fn messages, _opts ->
      ...>       prompt = Enum.map_join(messages, "\\n", &Map.fetch!(&1, :content))
      ...>       if prompt =~ "bad", do: raise("boom"), else: %{answer: "ok"}
      ...>     end
      ...>   ]
      ...> }
      iex> program = Imp.Predict.Predict.new("question -> answer", lm: lm)
      iex> results = Imp.Predict.Parallel.map(program, [%{question: "ok"}, %{question: "bad"}])
      iex> match?([{:ok, %Imp.Prediction{}}, {:error, {:lm_failed, Imp.LM.Static, "boom"}}], results)
      true
      iex> [{:ok, prediction}, _error] = results; Imp.Prediction.get(prediction, :answer)
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
    opts = Imp.Options.validate!(opts, @option_schema, "Imp.Predict.Parallel.map/3")
    inputs = validate_inputs!(inputs)

    inputs
    |> Enum.map(&{program, &1})
    |> run_pairs(opts)
  end

  @doc """
  Runs heterogeneous `{program, inputs}` pairs concurrently.

  Nested lists preserve their shape while every leaf shares one bounded task
  pool. This avoids nested task-pool deadlocks and makes diverse composed work
  as cheap to supervise as a homogeneous batch:

      iex> first = Imp.predict("question -> answer", lm: Imp.LM.Static.new(handler: fn _, _ -> %{answer: "first"} end))
      iex> second = Imp.predict("topic -> answer", lm: Imp.LM.Static.new(handler: fn _, _ -> %{answer: "second"} end))
      iex> [first_result, [second_result]] = Imp.Predict.Parallel.run([
      ...>   {first, %{question: "q"}},
      ...>   [{second, %{topic: "t"}}]
      ...> ])
      iex> {:ok, first_prediction} = first_result
      iex> {:ok, second_prediction} = second_result
      iex> {Imp.get(first_prediction, :answer), Imp.get(second_prediction, :answer)}
      {"first", "second"}

  The options are the same as `map/3`.
  """
  def run(exec_pairs, opts \\ []) do
    opts = Imp.Options.validate!(opts, @option_schema, "Imp.Predict.Parallel.run/2")
    exec_pairs = validate_exec_pairs!(exec_pairs)
    {shape, leaves} = flatten(exec_pairs)
    results = run_pairs(leaves, opts) |> List.to_tuple()
    rebuild(shape, results)
  end

  defp run_pairs(pairs, opts) do
    pairs
    |> Imp.Tasks.async_stream(fn {program, input} -> call_program(program, input) end,
      max_concurrency: opts[:max_concurrency],
      timeout: opts[:timeout],
      on_timeout: opts[:on_timeout]
    )
    |> Enum.map(fn
      {:ok, result} -> result
      {:exit, reason} -> {:error, reason}
    end)
  end

  defp flatten(nodes) do
    {shape, leaves, _next_index} = flatten_nodes(nodes, [], 0)
    {shape, Enum.reverse(leaves)}
  end

  defp flatten_nodes(nodes, leaves, next_index) do
    Enum.reduce(nodes, {[], leaves, next_index}, fn node, {shape, leaves, next_index} ->
      case node do
        {program, inputs} ->
          {[{:leaf, next_index} | shape], [{program, inputs} | leaves], next_index + 1}

        nested when is_list(nested) ->
          {nested_shape, leaves, next_index} = flatten_nodes(nested, leaves, next_index)
          {[{:branch, nested_shape} | shape], leaves, next_index}
      end
    end)
    |> then(fn {shape, leaves, next_index} -> {Enum.reverse(shape), leaves, next_index} end)
  end

  defp rebuild(shape, results) do
    Enum.map(shape, fn
      {:leaf, index} -> elem(results, index)
      {:branch, nested} -> rebuild(nested, results)
    end)
  end

  defp call_program(program, input) do
    case Imp.Module.call(program, input) do
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
            "Imp.Predict.Parallel.map/3 expects inputs to be an enumerable batch; got: #{inspect(inputs)}"
    end
  end

  defp validate_exec_pairs!(exec_pairs) when is_list(exec_pairs) do
    validate_exec_pair_nodes!(exec_pairs, [])
    exec_pairs
  end

  defp validate_exec_pairs!(exec_pairs) do
    raise ArgumentError,
          "Imp.Predict.Parallel.run/2 expects a list of {program, inputs} pairs or nested pair lists; got: #{inspect(exec_pairs)}"
  end

  defp validate_exec_pair_nodes!(nodes, path) do
    Enum.with_index(nodes)
    |> Enum.each(fn
      {{_program, _inputs}, _index} ->
        :ok

      {nested, index} when is_list(nested) ->
        validate_exec_pair_nodes!(nested, path ++ [index])

      {node, index} ->
        raise ArgumentError,
              "Imp.Predict.Parallel.run/2 expected {program, inputs} or a nested list at #{inspect(path ++ [index])}; got: #{inspect(node)}"
    end)
  end

  defp error_message(%_{} = exception), do: Exception.message(exception)
  defp error_message(error), do: inspect(error)
end
