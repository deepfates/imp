defmodule DSEx.Tasks do
  @moduledoc """
  Supervised task boundary for DSEx runtime fan-out.

  Production applications should start `:dsex`, which supervises linked and
  unlinked task supervisors. If a DSEx helper is called before the application
  is started, DSEx starts the application before running supervised work.
  """

  @supervisor DSEx.TaskSupervisor
  @unlinked_supervisor DSEx.UnlinkedTaskSupervisor

  def supervisor, do: @supervisor
  def unlinked_supervisor, do: @unlinked_supervisor

  def supervised? do
    Process.whereis(@supervisor) != nil and Process.whereis(@unlinked_supervisor) != nil
  end

  def async(fun) when is_function(fun, 0) do
    fun = inherit_context(fun)

    case ensure_supervisor(@supervisor) do
      nil -> Task.async(fun)
      _pid -> Task.Supervisor.async(@supervisor, fun)
    end
  end

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

  def async_stream(enumerable, fun, opts \\ []) when is_function(fun, 1) do
    context_stack = DSEx.Settings.context_stack()
    fun = fn item -> DSEx.Settings.with_context_stack(context_stack, fn -> fun.(item) end) end

    case ensure_supervisor(@supervisor) do
      nil -> Task.async_stream(enumerable, fun, opts)
      _pid -> Task.Supervisor.async_stream(@supervisor, enumerable, fun, opts)
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
