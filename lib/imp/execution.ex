defmodule Imp.Execution do
  @moduledoc """
  Explicit, protocol-neutral capabilities for one program execution.

  `Imp.call/2` remains the final-result contract. Hosts that need a per-run
  security decision use `Imp.start_run/3` with `:authorize`; `Imp.Run` then
  passes this value through `Imp.Module.execute/3` to runtimes that support the
  capability. Authority is never recovered from telemetry or the ambient run
  event context.
  """

  @enforce_keys [:run_id]
  defstruct [:run_id, :authorize, :decision_owner, authorization_timeout: 30_000]

  @type decision :: :allow | {:deny, term()} | {:cancel, term()}
  @type t :: %__MODULE__{
          run_id: String.t(),
          authorize: (Imp.Execution.Authorization.t() -> decision()) | nil,
          decision_owner: pid() | nil,
          authorization_timeout: pos_integer()
        }

  @doc false
  def new(opts \\ []) when is_list(opts) do
    run_id = Keyword.get_lazy(opts, :run_id, &local_run_id/0)
    authorize = Keyword.get(opts, :authorize)
    owner = Keyword.get(opts, :decision_owner)
    timeout = Keyword.get(opts, :authorization_timeout, 30_000)

    if not is_nil(authorize) and not is_function(authorize, 1),
      do: raise(ArgumentError, ":authorize must be an arity-1 function")

    if not is_nil(owner) and not is_pid(owner),
      do: raise(ArgumentError, ":decision_owner must be a pid")

    unless is_integer(timeout) and timeout > 0,
      do: raise(ArgumentError, ":authorization_timeout must be a positive integer")

    %__MODULE__{
      run_id: run_id,
      authorize: authorize,
      decision_owner: owner,
      authorization_timeout: timeout
    }
  end

  @doc false
  def unrestricted, do: new()

  @doc false
  def bounded_description(description) when is_binary(description),
    do: String.slice(description, 0, 1_000)

  def bounded_description(_description), do: nil

  @doc "Returns whether this execution requires an authorization-aware module."
  def authorization_required?(%__MODULE__{authorize: authorize}), do: is_function(authorize, 1)

  @doc false
  def authorize(%__MODULE__{authorize: nil}, %{__struct__: Imp.Execution.Authorization}),
    do: :allow

  def authorize(
        %__MODULE__{} = execution,
        %{__struct__: Imp.Execution.Authorization} = request
      ) do
    owner = execution.decision_owner

    cond do
      is_pid(owner) and not Process.alive?(owner) ->
        {:deny, :authorization_owner_down}

      true ->
        previous_trap_exit = Process.flag(:trap_exit, true)

        try do
          task =
            Task.Supervisor.async(Imp.Tasks.supervisor(), fn ->
              invoke_authorizer(execution.authorize, request)
            end)

          cancellable =
            Imp.Run.register_cancellable(fn _reason ->
              if Process.alive?(task.pid), do: Process.exit(task.pid, :kill)
            end)

          try do
            task
            |> await_decision(owner, execution.authorization_timeout)
            |> normalize_decision()
          after
            Imp.Run.unregister_cancellable(cancellable)
            Process.unlink(task.pid)
            Task.shutdown(task, :brutal_kill)
            flush_link_exit(task.pid)
          end
        after
          Process.flag(:trap_exit, previous_trap_exit)
        end
    end
  end

  defp await_decision(task, owner, timeout) do
    owner_monitor = if is_pid(owner), do: Process.monitor(owner)
    task_ref = task.ref

    try do
      receive do
        {^task_ref, {:decision, decision}} ->
          decision

        {^task_ref, {:callback_error, reason}} ->
          {:authorization_callback_exit, reason}

        {:DOWN, ^task_ref, :process, _pid, reason} ->
          {:authorization_callback_exit, reason}

        {:DOWN, ^owner_monitor, :process, _pid, _reason} ->
          Task.shutdown(task, :brutal_kill)
          :authorization_owner_down
      after
        timeout ->
          Task.shutdown(task, :brutal_kill)
          :authorization_timeout
      end
    after
      if is_reference(owner_monitor), do: Process.demonitor(owner_monitor, [:flush])
    end
  end

  defp normalize_decision(:allow), do: :allow
  defp normalize_decision({:deny, reason}), do: {:deny, reason}
  defp normalize_decision({:cancel, reason}), do: {:cancel, reason}
  defp normalize_decision(:authorization_owner_down), do: {:deny, :authorization_owner_down}
  defp normalize_decision(:authorization_timeout), do: {:deny, :authorization_timeout}

  defp normalize_decision({:authorization_callback_exit, reason}),
    do: {:deny, {:authorization_callback_exit, reason}}

  defp normalize_decision(other), do: {:deny, {:invalid_authorization_decision, other}}

  defp invoke_authorizer(authorize, request) do
    {:decision, authorize.(request)}
  rescue
    error -> {:callback_error, {:error, Exception.message(error)}}
  catch
    kind, reason -> {:callback_error, {kind, Imp.Redaction.redact(reason)}}
  end

  defp flush_link_exit(pid) do
    receive do
      {:EXIT, ^pid, _reason} -> :ok
    after
      0 -> :ok
    end
  end

  defp local_run_id, do: Imp.Run.new_event_id("execution")
end

defmodule Imp.Execution.Authorization do
  @moduledoc "A protocol-neutral request to authorize one validated tool effect."

  @enforce_keys [:run_id, :tool_call_id, :tool_name, :arguments]
  defstruct [:run_id, :tool_call_id, :tool_name, :arguments, :description, metadata: %{}]

  @type t :: %__MODULE__{
          run_id: String.t(),
          tool_call_id: String.t(),
          tool_name: atom() | String.t(),
          arguments: map(),
          description: String.t() | nil,
          metadata: map()
        }
end
