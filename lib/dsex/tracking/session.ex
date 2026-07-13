defmodule DSEx.Tracking.Session do
  @moduledoc "Ordered, caller-owned fan-out across tracking backends."

  require Logger

  @enforce_keys [:owner, :backends]
  defstruct [:owner, :backends]

  @type backend_spec :: module() | {module(), keyword()}
  @type backend_entry :: {module(), term()}
  @type t :: %__MODULE__{owner: pid(), backends: [backend_entry()]}

  @doc "Starts each backend in declaration order. A start failure aborts the session."
  @spec start([backend_spec()], keyword()) :: {:ok, t()} | {:error, term()}
  def start(backends, opts \\ []) when is_list(backends) and is_list(opts) do
    owner = Keyword.get(opts, :owner, self())

    if is_pid(owner) do
      start_backends(backends, Keyword.delete(opts, :owner), owner, [])
    else
      {:error, {:invalid_owner, owner}}
    end
  end

  @doc "Logs an event to every backend in declaration order. Failures are warnings."
  @spec log(t(), DSEx.Tracking.Backend.event()) :: :ok | {:error, term()}
  def log(%__MODULE__{} = session, event) do
    with :ok <- ensure_owner(session) do
      fan_out(session.backends, :log, fn backend, state -> backend.log(state, event) end)
    end
  end

  @doc "Finishes every backend in declaration order. Failures are warnings."
  @spec finish(t(), DSEx.Tracking.Backend.status()) :: :ok | {:error, term()}
  def finish(%__MODULE__{} = session, status \\ :finished) do
    with :ok <- ensure_owner(session) do
      fan_out(session.backends, :finish, fn backend, state -> backend.finish(state, status) end)
    end
  end

  defp fan_out(backends, operation, callback) do
    Enum.each(backends, fn {backend, state} ->
      warn_on_failure(operation, backend, fn -> callback.(backend, state) end)
    end)

    :ok
  end

  defp start_backends([], _opts, owner, started) do
    {:ok, %__MODULE__{owner: owner, backends: Enum.reverse(started)}}
  end

  defp start_backends([spec | rest], opts, owner, started) do
    with {:ok, backend, backend_opts} <- normalize_backend(spec),
         :ok <- validate_backend(backend),
         {:ok, state} <- safe_call(fn -> backend.start(Keyword.merge(opts, backend_opts)) end) do
      start_backends(rest, opts, owner, [{backend, state} | started])
    else
      {:error, reason} ->
        rollback_started(started)
        {:error, {:backend_start_failed, backend_name(spec), reason}}

      other ->
        rollback_started(started)
        {:error, {:backend_start_failed, backend_name(spec), {:invalid_return, other}}}
    end
  end

  defp normalize_backend(backend) when is_atom(backend), do: {:ok, backend, []}

  defp normalize_backend({backend, opts}) when is_atom(backend) and is_list(opts) do
    if Keyword.keyword?(opts),
      do: {:ok, backend, opts},
      else: {:error, {:invalid_backend_options, opts}}
  end

  defp normalize_backend(spec), do: {:error, {:invalid_backend, spec}}

  defp validate_backend(backend) do
    if Code.ensure_loaded?(backend) and
         Enum.all?([start: 1, log: 2, finish: 2], fn {name, arity} ->
           function_exported?(backend, name, arity)
         end) do
      :ok
    else
      {:error, {:not_tracking_backend, backend}}
    end
  end

  defp rollback_started(started) do
    Enum.each(started, fn {backend, state} ->
      warn_on_failure(:rollback, backend, fn -> backend.finish(state, :failed) end)
    end)
  end

  defp ensure_owner(%__MODULE__{owner: owner}) do
    if self() == owner, do: :ok, else: {:error, {:not_session_owner, owner, self()}}
  end

  defp warn_on_failure(operation, backend, fun) do
    case safe_call(fun) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "tracking backend #{inspect(backend)} #{operation} failed: #{inspect(reason)}"
        )

      other ->
        Logger.warning(
          "tracking backend #{inspect(backend)} #{operation} returned #{inspect(other)}"
        )
    end
  end

  defp safe_call(fun) do
    fun.()
  rescue
    error -> {:error, {:exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp backend_name({backend, _opts}) when is_atom(backend), do: backend
  defp backend_name(backend) when is_atom(backend), do: backend
  defp backend_name(spec), do: spec
end
