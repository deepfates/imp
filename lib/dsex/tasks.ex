defmodule DSEx.Tasks do
  @moduledoc """
  Supervised task boundary for DSEx runtime fan-out.

  Production applications should start `:dsex`, which supervises
  `DSEx.TaskSupervisor`. Script-style callers that use DSEx before the
  application is started fall back to `Task` for compatibility.
  """

  @supervisor DSEx.TaskSupervisor

  def supervisor, do: @supervisor

  def supervised? do
    Process.whereis(@supervisor) != nil
  end

  def async(fun) when is_function(fun, 0) do
    case Process.whereis(@supervisor) do
      nil -> Task.async(fun)
      _pid -> Task.Supervisor.async(@supervisor, fun)
    end
  end

  def async_nolink(fun) when is_function(fun, 0) do
    case Process.whereis(@supervisor) do
      nil ->
        {:ok, supervisor} = Task.Supervisor.start_link()
        Task.Supervisor.async_nolink(supervisor, fun)

      _pid ->
        Task.Supervisor.async_nolink(@supervisor, fun)
    end
  end

  def async_stream(enumerable, fun, opts \\ []) when is_function(fun, 1) do
    case Process.whereis(@supervisor) do
      nil -> Task.async_stream(enumerable, fun, opts)
      _pid -> Task.Supervisor.async_stream(@supervisor, enumerable, fun, opts)
    end
  end
end
