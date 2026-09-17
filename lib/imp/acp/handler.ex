defmodule Imp.ACP.Handler do
  @moduledoc false

  @behaviour ExMCP.ACP.Agent.Handler

  @impl true
  def init(opts) do
    {:ok, %{options: Imp.ACP.Options.new(opts), sessions: %{}}}
  end

  @impl true
  def handle_new_session(params, context, state) do
    session_id = random_id()

    metadata = %{
      cwd: params["cwd"],
      host:
        Imp.ACP.Host.new(
          context.agent,
          session_id,
          params["cwd"],
          Map.get(context, :client_capabilities)
        ),
      mcp_servers: params["mcpServers"] || [],
      meta: params["_meta"] || %{},
      requested_meta: params["_meta"] || %{},
      session_id: session_id
    }

    case start_new_session(session_id, state.options, metadata) do
      {:ok, pid} ->
        sessions = Map.put(state.sessions, session_id, pid)
        {:reply, %{"sessionId" => session_id}, %{state | sessions: sessions}}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  @impl true
  def handle_load_session(params, context, state) do
    restore_session(params, context, state, true)
  end

  @impl true
  def handle_resume_session(params, context, state) do
    restore_session(params, context, state, false)
  end

  @impl true
  def handle_list_sessions(params, _context, state) do
    case Imp.ACP.SessionStore.list(state.options.session_store, params) do
      {:ok, sessions} -> {:reply, sessions, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  @impl true
  def handle_prompt(session_id, prompt, context, state) do
    with {:ok, pid} <- fetch_session(state, session_id),
         :ok <- Imp.ACP.Session.prompt(pid, prompt, context) do
      {:noreply, state}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  @impl true
  def handle_cancel(session_id, _context, state) do
    case fetch_session(state, session_id) do
      {:ok, pid} ->
        case Imp.ACP.Session.cancel(pid) do
          :ok ->
            {:reply, "cancelled", state}

          {:error, :cancel_callback_failed} ->
            # ExMCP translates cancel-handler errors into "cancelled". An
            # explicit refusal response preserves the unknown application state.
            {:reply,
             %{
               "stopReason" => "refusal",
               "_meta" => %{
                 "imp_acp" => %{
                   "failure" => %{"category" => "cancel_callback_failed", "operation" => "cancel"}
                 }
               }
             }, state}
        end

      {:error, _reason} ->
        {:reply, "cancelled", state}
    end
  end

  @impl true
  def handle_close_session(session_id, _context, state) do
    case Map.pop(state.sessions, session_id) do
      {nil, sessions} ->
        {:reply, %{}, %{state | sessions: sessions}}

      {pid, sessions} ->
        if Process.alive?(pid), do: Imp.ACP.Session.close(pid)
        {:reply, %{}, %{state | sessions: sessions}}
    end
  end

  @impl true
  def handle_delete_session(session_id, _context, state) do
    {pid, sessions} = Map.pop(state.sessions, session_id)
    if is_pid(pid) and Process.alive?(pid), do: Imp.ACP.Session.close(pid)

    case Imp.ACP.SessionStore.delete(state.options.session_store, session_id) do
      :ok -> {:reply, %{}, %{state | sessions: sessions}}
      {:error, reason} -> {:error, reason, %{state | sessions: sessions}}
    end
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.sessions, fn {_session_id, pid} ->
      if Process.alive?(pid), do: Imp.ACP.Session.close(pid)
    end)

    :ok
  end

  defp start_new_session(session_id, options, metadata) do
    case start_session(session_id, options, metadata, nil, []) do
      {:ok, pid} ->
        case Imp.ACP.SessionStore.create(options.session_store, session_id, metadata) do
          :ok ->
            {:ok, pid}

          {:error, reason} ->
            if Process.alive?(pid), do: Imp.ACP.Session.close(pid)
            {:error, {:session_persistence_failed, reason}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp start_session(session_id, options, metadata, history, transcript) do
    spec =
      {Imp.ACP.Session,
       session_id: session_id,
       options: options,
       metadata: metadata,
       history: history,
       transcript: transcript}

    DynamicSupervisor.start_child(Imp.ACP.SessionSupervisor, spec)
  end

  defp restore_session(params, context, state, replay?) do
    session_id = params["sessionId"]
    cwd = params["cwd"]

    cond do
      Map.has_key?(state.sessions, session_id) ->
        {:error, :session_already_active, state}

      true ->
        with {:ok, restored} <-
               Imp.ACP.SessionStore.load(state.options.session_store, session_id, cwd),
             metadata <- %{
               cwd: Path.expand(cwd),
               host:
                 Imp.ACP.Host.new(
                   context.agent,
                   session_id,
                   cwd,
                   Map.get(context, :client_capabilities)
                 ),
               mcp_servers: params["mcpServers"] || [],
               # A restored session keeps the `_meta` it was created with,
               # because the history and transcript below were produced under
               # it. The request's own `_meta` is passed separately as
               # :requested_meta so a factory can refuse a contradiction.
               meta: restored.meta,
               requested_meta: params["_meta"] || %{},
               session_id: session_id
             },
             {:ok, pid} <-
               start_session(
                 session_id,
                 state.options,
                 metadata,
                 restored.history,
                 restored.transcript
               ) do
          case maybe_replay(context.agent, session_id, restored.transcript, replay?) do
            :ok ->
              sessions = Map.put(state.sessions, session_id, pid)
              {:reply, %{"sessionId" => session_id}, %{state | sessions: sessions}}

            {:error, reason} ->
              if Process.alive?(pid), do: Imp.ACP.Session.close(pid)
              {:error, reason, state}
          end
        else
          {:error, reason} -> {:error, reason, state}
        end
    end
  end

  defp maybe_replay(_agent, _session_id, _transcript, false), do: :ok

  defp maybe_replay(agent, session_id, transcript, true) do
    Enum.reduce_while(transcript, :ok, fn turn, :ok ->
      user_update = %{
        "sessionUpdate" => "user_message_chunk",
        "content" => %{"type" => "text", "text" => turn["user"]}
      }

      with :ok <- ExMCP.ACP.Agent.session_update(agent, session_id, user_update),
           :ok <- ExMCP.ACP.Agent.agent_message(agent, session_id, turn["assistant"]) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, {:session_replay_failed, reason}}}
      end
    end)
  end

  defp fetch_session(state, session_id) do
    case Map.fetch(state.sessions, session_id) do
      {:ok, pid} when is_pid(pid) ->
        if Process.alive?(pid), do: {:ok, pid}, else: {:error, :session_unavailable}

      :error ->
        {:error, :unknown_session}
    end
  end

  defp random_id do
    "imp_" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
  end
end
