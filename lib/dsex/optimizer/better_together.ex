defmodule DSEx.Optimizer.BetterTogether do
  @moduledoc "Meta-optimizer that applies named prompt/weight optimizers in sequence."

  defstruct [:metric, optimizers: %{}]

  def new(metric, optimizers \\ %{}) do
    optimizers =
      if map_size(Map.new(optimizers)) == 0 do
        %{
          p: DSEx.Optimizer.RandomSearch.new(metric),
          w: DSEx.Optimizer.BootstrapFinetune.new(metric)
        }
      else
        Map.new(optimizers)
      end

    %__MODULE__{metric: metric, optimizers: optimizers}
  end

  def compile(%__MODULE__{} = bt, student, trainset, valset, opts \\ []) do
    strategy = Keyword.get(opts, :strategy, "p")
    steps = strategy_steps(strategy)

    {compiled, step_reports, errors} =
      Enum.reduce(steps, {student, [], []}, fn key, {program, reports, errors} ->
        case fetch_optimizer(bt.optimizers, key) do
          {:ok, optimizer} ->
            case compile_step(optimizer, program, trainset, valset) do
              {:ok, next, metadata} ->
                {next, reports ++ [Map.merge(%{key: key, status: :ok}, metadata)], errors}

              {:error, reason} ->
                error = %{key: key, error: reason}

                {program, reports ++ [%{key: key, status: :error, error: reason}],
                 errors ++ [error]}
            end

          {:error, reason} ->
            error = %{key: key, error: reason}
            {program, reports ++ [%{key: key, status: :error, error: reason}], errors ++ [error]}
        end
      end)

    DSEx.Optimizer.Report.attach(
      compiled,
      DSEx.Optimizer.Report.new(%{
        optimizer: :better_together,
        candidate_count: length(step_reports),
        candidates: step_reports,
        errors: errors,
        metadata: %{strategy: strategy, steps: steps}
      })
    )
  end

  defp strategy_steps(strategy) when is_binary(strategy) do
    strategy
    |> String.split("->")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp strategy_steps(strategy), do: List.wrap(strategy)

  defp compile_step(
         %DSEx.Optimizer.BootstrapFinetune{} = optimizer,
         program,
         trainset,
         _valset
       ) do
    case safe_call(fn ->
           DSEx.Optimizer.BootstrapFinetune.compile(optimizer, program, trainset)
         end) do
      {:ok, %{program: compiled} = result} ->
        metadata =
          result
          |> Map.take([:job, :error])
          |> Map.put(:optimizer, optimizer.__struct__)

        {:ok, compiled, metadata}

      {:ok, other} ->
        {:error, {:invalid_optimizer_result, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp compile_step(optimizer, program, trainset, valset) do
    cond do
      not is_map(optimizer) or not Map.has_key?(optimizer, :__struct__) ->
        {:error, {:invalid_optimizer, optimizer}}

      function_exported?(optimizer.__struct__, :compile, 4) ->
        optimizer
        |> safe_compile(fn ->
          optimizer.__struct__.compile(optimizer, program, trainset, valset)
        end)

      function_exported?(optimizer.__struct__, :compile, 3) ->
        optimizer
        |> safe_compile(fn -> optimizer.__struct__.compile(optimizer, program, trainset) end)

      true ->
        {:error, {:unsupported_optimizer, optimizer.__struct__}}
    end
  end

  defp safe_compile(optimizer, fun) do
    case safe_call(fun) do
      {:ok, compiled} -> {:ok, compiled, %{optimizer: optimizer.__struct__}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp safe_call(fun) do
    {:ok, fun.()}
  rescue
    exception -> {:error, Exception.message(exception)}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp fetch_optimizer(optimizers, key) do
    cond do
      Map.has_key?(optimizers, key) ->
        {:ok, Map.fetch!(optimizers, key)}

      is_atom(existing_atom_or_string(key)) and
          Map.has_key?(optimizers, existing_atom_or_string(key)) ->
        {:ok, Map.fetch!(optimizers, existing_atom_or_string(key))}

      true ->
        {:error, {:unknown_optimizer, key}}
    end
  end

  defp existing_atom_or_string(key) when is_atom(key), do: key

  defp existing_atom_or_string(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  defp existing_atom_or_string(key), do: key
end
