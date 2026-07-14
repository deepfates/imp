defmodule Imp.Optimizer.TrainingResult do
  @moduledoc "Result of a training optimizer executed through `Imp.train/4`."

  @enforce_keys [:program, :status]
  defstruct [:program, :job, :status, metadata: %{}]

  @type status :: :job_created | :completed
  @type t :: %__MODULE__{
          program: struct(),
          job: term() | nil,
          status: status(),
          metadata: map()
        }
end

defmodule Imp.Optimizer do
  @moduledoc """
  Canonical execution contract for program and training optimizers.

  Optimizer modules declare what they produce and which dataset splits they
  consume. `run/3` dispatches only through this behaviour; callback arity is
  never used to infer argument meaning.
  """

  alias Imp.Optimizer.TrainingResult

  @type kind :: :program | :training | :constructor | :workflow
  @type requirement :: :required | :optional | :unsupported
  @type capabilities :: %{
          required(:kind) => kind(),
          required(:datasets) => %{required(atom()) => requirement()},
          required(:result) =>
            :program
            | :training_result
            | :constructed_program
            | {:workflow_result, module()}
        }

  @callback __optimizer__() :: capabilities()
  @callback run(struct(), program :: term(), keyword()) :: {:ok, term()} | {:error, term()}

  @doc "Returns validated capability metadata for an optimizer value."
  @spec capabilities(struct()) :: {:ok, capabilities()} | {:error, term()}
  def capabilities(%module{} = _optimizer) do
    try do
      with true <- function_exported?(module, :__optimizer__, 0),
           true <- function_exported?(module, :run, 3),
           capabilities <- module.__optimizer__(),
           :ok <- validate_capabilities(capabilities) do
        {:ok, capabilities}
      else
        false -> {:error, {:not_an_optimizer, module}}
        {:error, _reason} = error -> error
      end
    rescue
      error -> {:error, {:optimizer_capabilities_failed, module, Exception.message(error)}}
    catch
      kind, reason -> {:error, {:optimizer_capabilities_failed, module, {kind, reason}}}
    end
  end

  def capabilities(value), do: {:error, {:not_an_optimizer, value}}

  @doc "Runs an optimizer through its declared behaviour."
  @spec run(struct(), term(), keyword()) :: {:ok, term()} | {:error, term()}
  def run(optimizer, program, opts), do: run(optimizer, program, opts, :any)

  @spec run(struct(), term(), keyword(), kind() | :any) :: {:ok, term()} | {:error, term()}
  def run(optimizer, program, opts, expected_kind) when is_list(opts) do
    if Keyword.keyword?(opts) do
      with {:ok, capabilities} <- capabilities(optimizer),
           :ok <- validate_kind(capabilities.kind, expected_kind) do
        execute(optimizer, program, opts, capabilities)
      end
    else
      {:error, {:invalid_optimizer_options, opts}}
    end
  end

  def run(_optimizer, _program, opts, _expected_kind),
    do: {:error, {:invalid_optimizer_options, opts}}

  @doc "Runs an optimizer once against the named datasets available to a composed workflow."
  @spec run_with_datasets(struct(), term(), map(), [kind()] | :any) ::
          {:ok, capabilities(), term()} | {:error, term()}
  def run_with_datasets(optimizer, program, available_datasets, allowed_kinds \\ :any)

  def run_with_datasets(optimizer, program, available_datasets, allowed_kinds)
      when is_map(available_datasets) do
    with {:ok, capabilities} <- capabilities(optimizer),
         :ok <- validate_allowed_kind(capabilities.kind, allowed_kinds),
         opts <- select_available_datasets(capabilities.datasets, available_datasets),
         {:ok, result} <- execute(optimizer, program, opts, capabilities) do
      {:ok, capabilities, result}
    end
  end

  def run_with_datasets(_optimizer, _program, available_datasets, _allowed_kinds),
    do: {:error, {:invalid_available_datasets, available_datasets}}

  @doc false
  def fetch_dataset!(opts, key), do: Keyword.fetch!(opts, key)

  @doc false
  def invocation_options(opts), do: Keyword.drop(opts, [:trainset, :validation])

  @doc false
  def reject_options([]), do: :ok
  def reject_options(opts), do: {:error, {:unsupported_optimizer_options, Keyword.keys(opts)}}

  defp invoke(%module{} = optimizer, program, opts) do
    module.run(optimizer, program, opts)
  rescue
    error -> {:error, {:optimizer_failed, module, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:optimizer_failed, module, {kind, reason}}}
  end

  defp execute(optimizer, program, opts, capabilities) do
    with :ok <- validate_datasets(capabilities, opts),
         result <- invoke(optimizer, program, opts),
         :ok <- validate_result(capabilities, result) do
      result
    end
  end

  defp validate_capabilities(%{
         kind: kind,
         datasets: datasets,
         result: result
       })
       when is_map(datasets) do
    expected = %{
      program: :program,
      training: :training_result,
      constructor: :constructed_program
    }

    cond do
      map_size(datasets) == 0 ->
        {:error, {:invalid_optimizer_capabilities, %{datasets: datasets}}}

      Enum.any?(datasets, fn {name, requirement} ->
        not is_atom(name) or requirement not in [:required, :optional, :unsupported]
      end) ->
        {:error, {:invalid_optimizer_capabilities, %{datasets: datasets}}}

      kind == :workflow and not valid_workflow_result_contract?(result) ->
        {:error, {:invalid_optimizer_capabilities, %{kind: kind, result: result}}}

      kind != :workflow and Map.get(expected, kind) != result ->
        {:error, {:invalid_optimizer_capabilities, %{kind: kind, result: result}}}

      true ->
        :ok
    end
  end

  defp validate_capabilities(value), do: {:error, {:invalid_optimizer_capabilities, value}}

  defp validate_datasets(capabilities, opts) do
    Enum.reduce_while(capabilities.datasets, :ok, fn {name, requirement}, :ok ->
      case validate_dataset(name, requirement, opts) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_kind(_actual, :any), do: :ok
  defp validate_kind(kind, kind), do: :ok

  defp validate_kind(actual, expected),
    do: {:error, {:optimizer_kind_mismatch, expected, actual}}

  defp validate_allowed_kind(_actual, :any), do: :ok

  defp validate_allowed_kind(actual, allowed) when is_list(allowed) do
    if actual in allowed,
      do: :ok,
      else: {:error, {:optimizer_kind_mismatch, allowed, actual}}
  end

  defp validate_allowed_kind(actual, allowed), do: validate_kind(actual, allowed)

  defp select_available_datasets(requirements, available) do
    Enum.reduce(requirements, [], fn {name, requirement}, opts ->
      if requirement != :unsupported and Map.has_key?(available, name),
        do: Keyword.put(opts, name, Map.fetch!(available, name)),
        else: opts
    end)
  end

  defp validate_dataset(key, :required, opts) do
    case Keyword.fetch(opts, key) do
      {:ok, dataset} -> validate_dataset_value(key, dataset)
      :error -> {:error, {:missing_dataset, key}}
    end
  end

  defp validate_dataset(key, :unsupported, opts) do
    if Keyword.has_key?(opts, key), do: {:error, {:unsupported_dataset, key}}, else: :ok
  end

  defp validate_dataset(key, :optional, opts) do
    case Keyword.fetch(opts, key) do
      {:ok, dataset} -> validate_dataset_value(key, dataset)
      :error -> :ok
    end
  end

  defp validate_dataset_value(key, nil), do: {:error, {:invalid_dataset, key, nil}}

  defp validate_dataset_value(key, dataset) do
    if Enumerable.impl_for(dataset), do: :ok, else: {:error, {:invalid_dataset, key, dataset}}
  end

  defp validate_result(
         %{result: :training_result},
         {:ok, %TrainingResult{program: program, status: status, job: job, metadata: metadata}}
       ) do
    cond do
      not executable_program?(program) ->
        {:error, {:invalid_optimizer_program, program}}

      status not in [:job_created, :completed] ->
        {:error, {:invalid_training_status, status}}

      not is_map(metadata) ->
        {:error, {:invalid_training_metadata, metadata}}

      status == :job_created and is_nil(job) ->
        {:error, :training_job_required}

      true ->
        :ok
    end
  end

  defp validate_result(%{result: result}, {:ok, program})
       when result in [:program, :constructed_program] do
    if executable_program?(program),
      do: :ok,
      else: {:error, {:invalid_optimizer_program, program}}
  end

  defp validate_result(%{result: {:workflow_result, module}}, {:ok, result}) do
    if is_struct(result, module),
      do: :ok,
      else: {:error, {:invalid_workflow_result, module, result}}
  end

  defp validate_result(_capabilities, {:error, _reason}), do: :ok

  defp validate_result(capabilities, result),
    do: {:error, {:invalid_optimizer_result, capabilities.result, result}}

  defp executable_program?(%module{}),
    do: Code.ensure_loaded?(module) and function_exported?(module, :call, 2)

  defp executable_program?(_value), do: false

  defp valid_workflow_result_contract?({:workflow_result, module}) when is_atom(module),
    do: Code.ensure_loaded?(module) and function_exported?(module, :__struct__, 0)

  defp valid_workflow_result_contract?(_result), do: false
end
