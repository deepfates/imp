defmodule Imp.ACP do
  @moduledoc """
  Runs an `Imp.Module` program behind an Agent Client Protocol endpoint.

  `Imp.ACP` owns the ACP-to-Imp boundary. ExMCP owns the protocol and stdio
  connection; Imp owns program execution. One adapter session process owns each
  ACP session's program, retained history, active supervised task, cancellation,
  and final-response ordering.

  Prefer `:program_factory` so stateful programs such as persistent RLM receive
  a fresh instance for every ACP session:

      Imp.ACP.run(
        program_factory: fn %{cwd: cwd} -> MyAgents.build(cwd) end,
        input_key: :question,
        output_key: :answer
      )

  `:program` is convenient for immutable/stateless programs, but the same value
  is installed into every session.

  The session map a factory receives is `:cwd`, `:mcp_servers`, `:session_id`,
  `:host`, `:meta` and `:requested_meta`. `:meta` is ACP's `_meta` — the
  extension point for per-session data the protocol does not model. Carrying it
  is what lets one endpoint answer for more than one configuration without a
  separate process per configuration; an adapter that drops it forces the choice
  into the launch environment instead. Keys in `_meta` are namespaced by whoever
  defines them, so read your own and ignore the rest.

  On `session/new` both keys are the request's `_meta`. On `session/load` and
  `session/resume` they differ: `:meta` is the `_meta` the session was created
  with, stored beside the history and transcript it produced, and
  `:requested_meta` is what this request asked for. The stored one wins, because
  the history belongs to whatever produced it and a session that silently
  becomes something else replays one configuration's transcript as another's.
  `:requested_meta` exists so a factory can refuse that contradiction out loud:
  only the factory knows which of its own keys are identity-bearing and which
  may vary per connection, so this adapter carries both rather than guessing.

  A session stored before `_meta` was carried has none, and resumes with `:meta`
  empty — as it always did.

  Optional `:on_cancel` receives `(program, session_metadata)` only for an
  explicit active `session/cancel`, never on disconnect or close. It must return
  `:ok` to acknowledge application cancellation. `{:error, reason}`, invalid
  returns, or exceptions refuse cancellation with `:cancel_callback_failed` and
  leave the observer run active; the adapter does not claim the work stopped.
  Keep this callback bounded and idempotent.

  External ReActV2 and RLM tool effects require an ACP client permission by
  default. Set `permission_policy: :unrestricted` only when the endpoint is
  deliberately trusted and the program's own `Imp.ToolPolicy` is sufficient.
  """

  # :on_cancel is deliberately distinct from resource cleanup: an attachment
  # closing must not imply cancellation of independently owned application work.
  @adapter_keys [
    :program,
    :program_factory,
    :input_key,
    :input_mapper,
    :output_key,
    :output_renderer,
    :cleanup,
    :on_cancel,
    :session_store,
    :permission_policy,
    :authorization_timeout,
    :cancel_timeout,
    :tool_kinds
  ]

  @doc false
  def adapter_keys, do: @adapter_keys

  @default_pending_request_timeout 3_600_000

  @doc "Starts a linked ACP agent process."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    with :ok <- ensure_runtime() do
      {adapter_opts, agent_opts} = Keyword.split(opts, @adapter_keys)

      ExMCP.ACP.start_agent(
        agent_opts
        |> Keyword.put(:handler, Imp.ACP.Handler)
        |> Keyword.put(:handler_opts, adapter_opts)
        |> Keyword.put_new(:agent_info, %{"name" => "imp-acp", "version" => "0.1.0"})
        |> Keyword.put_new(:agent_capabilities, capabilities(adapter_opts))
        |> Keyword.put_new(:pending_request_timeout, @default_pending_request_timeout)
      )
    end
  end

  @doc "Runs an ACP stdio agent until its connection exits."
  @spec run(keyword()) :: :ok | {:error, term()}
  def run(opts) when is_list(opts) do
    prepare_stdio_runtime()

    with :ok <- ensure_runtime() do
      {adapter_opts, agent_opts} = Keyword.split(opts, @adapter_keys)

      ExMCP.ACP.run_agent(
        agent_opts
        |> Keyword.put(:handler, Imp.ACP.Handler)
        |> Keyword.put(:handler_opts, adapter_opts)
        |> Keyword.put_new(:agent_info, %{"name" => "imp-acp", "version" => "0.1.0"})
        |> Keyword.put_new(:agent_capabilities, capabilities(adapter_opts))
        |> Keyword.put_new(:pending_request_timeout, @default_pending_request_timeout)
      )
    end
  end

  # Stdio is the ACP wire. Configure it before starting any dependency so an
  # application's boot logs cannot precede the first JSON-RPC frame. ExMCP
  # repeats this when its stdio transport connects; doing it here closes the
  # earlier application-start window for ordinary `mix run --no-start`
  # launchers.
  defp prepare_stdio_runtime do
    Application.put_env(:ex_mcp, :stdio_mode, true)
    Application.put_env(:logger, :level, :emergency)
    Logger.configure(level: :emergency)
    :logger.set_primary_config(:level, :emergency)
  end

  defp ensure_runtime do
    with {:ok, _} <- Application.ensure_all_started(:imp),
         {:ok, _} <- Application.ensure_all_started(:ex_mcp) do
      :ok
    else
      {:error, reason} -> {:error, {:application_start_failed, reason}}
    end
  end

  @doc "Default adapter capabilities, for agents adding explicitly supported protocol features."
  def capabilities(adapter_opts \\ []) do
    capabilities = %{
      "_meta" => %{
        "deepfates.com/imp-acp" => %{"permissionToolName" => true}
      },
      "promptCapabilities" => %{
        "image" => false,
        "audio" => false,
        "embeddedContext" => false
      },
      "sessionCapabilities" => %{"close" => %{}}
    }

    if Imp.ACP.SessionStore.enabled?(Keyword.get(adapter_opts, :session_store)) do
      capabilities
      |> Map.put("loadSession", true)
      |> put_in(
        ["sessionCapabilities"],
        %{"close" => %{}, "list" => %{}, "resume" => %{}, "delete" => %{}}
      )
    else
      capabilities
    end
  end
end
