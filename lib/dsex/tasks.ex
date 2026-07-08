defmodule DSEx.Tasks do
  @moduledoc """
  Supervised task boundary for DSEx runtime fan-out.

  Production applications should start `:dsex`, which supervises linked and
  unlinked task supervisors. If a DSEx helper is called before the application
  is started, DSEx starts the application before running supervised work.
  """

  @supervisor DSEx.TaskSupervisor
  @unlinked_supervisor DSEx.UnlinkedTaskSupervisor

  @async_stream_option_schema [
    max_concurrency: [type: :pos_integer],
    ordered: [type: :boolean],
    timeout: [type: {:or, [:timeout, :pos_integer]}],
    on_timeout: [type: {:in, [:exit, :kill_task]}],
    zip_input_on_exit: [type: :boolean]
  ]

  @doc "Returns the linked task supervisor name used by DSEx async helpers."
  def supervisor, do: @supervisor

  @doc "Returns the unlinked task supervisor name used by DSEx fire-and-observe helpers."
  def unlinked_supervisor, do: @unlinked_supervisor

  @doc """
  Returns whether both DSEx task supervisors are currently running.
  """
  def supervised? do
    Process.whereis(@supervisor) != nil and Process.whereis(@unlinked_supervisor) != nil
  end

  @doc """
  Starts a linked supervised task and propagates DSEx settings context.

      iex> task = DSEx.context([task_marker: :inside], fn ->
      ...>   DSEx.Tasks.async(fn -> DSEx.Settings.fetch!(:task_marker) end)
      ...> end)
      iex> Task.await(task)
      :inside

  """
  def async(fun) when is_function(fun, 0) do
    fun = inherit_context(fun)

    case ensure_supervisor(@supervisor) do
      nil -> Task.async(fun)
      _pid -> Task.Supervisor.async(@supervisor, fun)
    end
  end

  def async(fun) do
    raise ArgumentError, "DSEx.Tasks.async/1 expects a zero-arity function, got: #{inspect(fun)}"
  end

  @doc """
  Starts an unlinked supervised task and propagates DSEx settings context.

  Use this when the caller should monitor or await a task explicitly instead of
  being linked to its failures.
  """
  def async_nolink(fun) when is_function(fun, 0) do
    fun = inherit_context(fun)

    case ensure_supervisor(@unlinked_supervisor) do
      nil ->
        {:ok, supervisor} = Task.Supervisor.start_link()
        Task.Supervisor.async_nolink(supervisor, fun)

      _pid ->
        Task.Supervisor.async_nolink(@unlinked_supervisor, fun)
    end
  end

  def async_nolink(fun) do
    raise ArgumentError,
          "DSEx.Tasks.async_nolink/1 expects a zero-arity function, got: #{inspect(fun)}"
  end

  @doc """
  Runs a function over an enumerable through DSEx's supervised task boundary.

  The current DSEx settings context is captured once and restored inside each
  worker task.

      iex> DSEx.context([task_marker: :streamed], fn ->
      ...>   [1, 2]
      ...>   |> DSEx.Tasks.async_stream(fn value -> {value, DSEx.Settings.fetch!(:task_marker)} end, ordered: true)
      ...>   |> Enum.to_list()
      ...> end)
      [ok: {1, :streamed}, ok: {2, :streamed}]

  """
  def async_stream(enumerable, fun, opts \\ [])

  def async_stream(enumerable, fun, opts) when is_function(fun, 1) do
    enumerable = validate_enumerable!(enumerable)
    opts = DSEx.Options.validate!(opts, @async_stream_option_schema, "DSEx.Tasks.async_stream/3")
    context_stack = DSEx.Settings.context_stack()
    fun = fn item -> DSEx.Settings.with_context_stack(context_stack, fn -> fun.(item) end) end

    case ensure_supervisor(@supervisor) do
      nil -> Task.async_stream(enumerable, fun, opts)
      _pid -> Task.Supervisor.async_stream(@supervisor, enumerable, fun, opts)
    end
  end

  def async_stream(_enumerable, fun, _opts) do
    raise ArgumentError,
          "DSEx.Tasks.async_stream/3 expects an arity-1 function, got: #{inspect(fun)}"
  end

  defp validate_enumerable!(enumerable) do
    if Enumerable.impl_for(enumerable) do
      enumerable
    else
      raise ArgumentError,
            "DSEx.Tasks.async_stream/3 expects enumerable input, got: #{inspect(enumerable)}"
    end
  end

  defp inherit_context(fun) do
    context_stack = DSEx.Settings.context_stack()
    fn -> DSEx.Settings.with_context_stack(context_stack, fun) end
  end

  defp ensure_supervisor(name) do
    case Process.whereis(name) do
      nil ->
        case Application.ensure_all_started(:dsex) do
          {:ok, _apps} ->
            Process.whereis(name)

          {:error, reason} ->
            if Application.spec(:dsex) do
              raise "failed to start :dsex application for #{inspect(name)}: #{inspect(reason)}"
            end

            nil
        end

      pid ->
        pid
    end
  end
end
