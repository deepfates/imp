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
  `:host`, `:meta` and `:requested_meta`. `:meta` is ACP's `_meta`, the
  extension point for per-session data the protocol does not model; one endpoint
  can therefore answer for more than one configuration. Keys in `_meta` are
  namespaced by whoever defines them, so read your own and ignore the rest.

  On `session/new` both keys hold the request's `_meta`. On `session/load` and
  `session/resume` they may differ: `:meta` is the `_meta` the session was
  created with, stored beside its history and transcript, and `:requested_meta`
  is what this request asked for. The stored value is the one installed. Both
  are passed so a factory can compare them and refuse a resume whose requested
  configuration contradicts the stored one; only the factory knows which of its
  own keys are identity-bearing. A session stored without `_meta` resumes with
  `:meta` empty.

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

  # :on_cancel is distinct from :cleanup: an attachment closing must not imply
  # cancellation of independently owned application work.
  @adapter_keys Keyword.keys(Imp.ACP.Options.schema())

  # What Imp passes to `ExMCP.ACP.Agent`. `:handler` and `:handler_opts` are
  # Imp's own; a transport's options go in `:transport_options`, so every other
  # key is one this module knows.
  @agent_schema [
    name: [
      type: :any,
      doc: "A `GenServer` name for the agent process (`start_link/1` only)."
    ],
    agent_info: [
      type: {:map, :string, :any},
      doc: "The `agentInfo` announced at `initialize`; `imp` at Imp's version by default."
    ],
    agent_capabilities: [
      type: {:map, :string, :any},
      doc: "The `agentCapabilities` announced at `initialize`; `capabilities/1` by default."
    ],
    auth_methods: [
      type: {:list, :map},
      doc: "The `authMethods` announced at `initialize`; none by default."
    ],
    protocol_version: [
      type: :pos_integer,
      doc: "The ACP protocol version announced; ExMCP's by default."
    ],
    max_frame_bytes: [
      type: :pos_integer,
      doc: "Largest JSON-RPC frame read or written, in bytes; ExMCP's 1 MiB by default."
    ],
    max_pending_requests: [
      type: :pos_integer,
      doc: "Requests to the client awaiting an answer at once; ExMCP's by default."
    ],
    pending_request_timeout: [
      type: :pos_integer,
      default: 3_600_000,
      doc: "Milliseconds a request to the client (a permission request) may wait."
    ],
    handler_request_timeout: [
      type: :pos_integer,
      doc: "Milliseconds a client request may take in the adapter; ExMCP's by default."
    ],
    transport: [
      type: {:or, [{:in, [:stdio, :memory]}, {:tuple, [{:in, [:memory]}, :any]}, :atom]},
      doc:
        "`:stdio` (the default), `{:memory, peer}` for an in-VM client, or a " <>
          "transport module."
    ],
    transport_mod: [
      type: :atom,
      doc: "A transport module, in place of `:transport`."
    ],
    transport_options: [
      type: :keyword_list,
      default: [],
      doc:
        "Options for the transport, such as `ExMCP.ACP.Agent.Transport.Stdio`'s " <>
          "`:input` and `:output`."
    ]
  ]

  @schema Imp.ACP.Options.schema() ++ @agent_schema

  @doc false
  def adapter_keys, do: @adapter_keys

  @doc false
  # Validates a full option list without starting anything; `Imp.ACP.Local`
  # checks the options for the agents it will start this way before it listens.
  def validate_options!(opts, context, schema \\ @schema),
    do: Imp.Options.validate!(opts, schema, context)

  @doc false
  def schema, do: @schema

  @doc """
  Starts a linked ACP agent process.

  An option this function does not know raises `ArgumentError`.

  ## Options

  #{NimbleOptions.docs(@schema)}
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    opts = validate_options!(opts, "Imp.ACP.start_link/1")

    with :ok <- ensure_runtime() do
      opts |> agent_options() |> ExMCP.ACP.start_agent()
    end
  end

  @doc """
  Runs an ACP stdio agent until its connection exits.

  Takes the options `start_link/1` takes, and raises `ArgumentError` for one
  it does not know before anything is started.
  """
  @spec run(keyword()) :: :ok | {:error, term()}
  def run(opts) do
    opts = validate_options!(opts, "Imp.ACP.run/1")
    prepare_stdio_runtime()

    with :ok <- ensure_runtime() do
      opts |> agent_options() |> ExMCP.ACP.run_agent()
    end
  end

  defp agent_options(opts) do
    {adapter_opts, agent_opts} = Keyword.split(opts, @adapter_keys)
    {transport_opts, agent_opts} = Keyword.pop!(agent_opts, :transport_options)

    agent_opts
    |> Keyword.merge(transport_opts)
    |> Keyword.put(:handler, Imp.ACP.Handler)
    |> Keyword.put(:handler_opts, adapter_opts)
    |> Keyword.put_new(:agent_info, agent_info())
    |> Keyword.put_new(:agent_capabilities, capabilities(adapter_opts))
  end

  # What `initialize` answers when the host names no agent of its own.
  defp agent_info,
    do: %{"name" => "imp", "version" => to_string(Application.spec(:imp, :vsn))}

  # Stdio is the ACP wire. Silence logging before starting any dependency so
  # boot output cannot precede the first JSON-RPC frame. ExMCP does the same
  # when its stdio transport connects; doing it here also covers the window
  # during application start.
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

  @doc """
  Default adapter capabilities, for agents adding explicitly supported protocol features.

  Takes the adapter options `start_link/1` takes; `:session_store` decides
  whether sessions can be loaded, listed, resumed and deleted.
  """
  def capabilities(adapter_opts \\ []) do
    adapter_opts =
      Imp.Options.validate!(adapter_opts, Imp.ACP.Options.schema(), "Imp.ACP.capabilities/1")

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
