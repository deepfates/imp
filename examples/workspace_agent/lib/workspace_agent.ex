defmodule WorkspaceAgent do
  @moduledoc """
  A consumer-owned Imp program exposed through the private Imp ACP adapter.
  """

  alias WorkspaceAgent.Tools

  @default_model "qwen/qwen3.6-35b-a3b"
  @default_base_url "http://127.0.0.1:1234/v1"
  @default_receive_timeout_ms 300_000
  @default_rlm_max_time_ms 600_000

  @spec run() :: :ok | {:error, term()}
  def run do
    mounted_root = System.fetch_env!("WORKSPACE_AGENT_ROOT")
    program_kind = program_kind()

    Imp.ACP.run(
      program_factory: fn session ->
        program(session,
          mounted_root: mounted_root,
          program: program_kind,
          mcp_authorize: mcp_authorizer()
        )
      end,
      permission_policy: &permission_policy/2,
      session_store: durable_session_store(program_kind),
      agent_info: %{"name" => "imp-workspace-agent", "version" => "0.1.0"}
    )
  end

  @doc "Returns the local durable ACP session directory."
  @spec session_store() :: Path.t()
  def session_store do
    System.get_env("WORKSPACE_AGENT_SESSION_STORE") ||
      Path.join([state_home(), "imp_acp", "workspace_agent", "sessions"])
  end

  # ReAct history has a stable serialized representation. A persistent RLM's
  # interpreter namespace is intentionally process-local today, so advertising
  # session/load for that mode would promise continuity the program cannot keep.
  defp durable_session_store(:react), do: session_store()
  defp durable_session_store(:rlm), do: nil

  @doc "Preauthorizes bounded reads and asks the ACP client before mutations."
  def permission_policy(request, _session) do
    case request.tool_name do
      name when name in [:list_files, "list_files", :read_file, "read_file"] -> :allow
      name when name in [:search_text, "search_text"] -> :allow
      _mutating_or_external -> :client
    end
  end

  @spec model() :: String.t()
  def model, do: System.get_env("WORKSPACE_AGENT_MODEL", @default_model)

  @spec base_url() :: String.t()
  def base_url, do: System.get_env("WORKSPACE_AGENT_BASE_URL", @default_base_url)

  @doc "Returns the LM Studio transport inactivity timeout in milliseconds."
  @spec receive_timeout_ms() :: pos_integer()
  def receive_timeout_ms do
    positive_env_ms("WORKSPACE_AGENT_RECEIVE_TIMEOUT_MS", @default_receive_timeout_ms)
  end

  @doc "Returns the whole-call persistent RLM budget in milliseconds."
  @spec rlm_max_time_ms() :: pos_integer()
  def rlm_max_time_ms do
    positive_env_ms("WORKSPACE_AGENT_RLM_MAX_TIME_MS", @default_rlm_max_time_ms)
  end

  @spec provider() :: :lmstudio | :static
  def provider do
    case System.get_env("WORKSPACE_AGENT_PROVIDER", "lmstudio") do
      "lmstudio" -> :lmstudio
      "static" -> :static
      other -> raise "WORKSPACE_AGENT_PROVIDER must be lmstudio or static, got: #{other}"
    end
  end

  @spec program_kind() :: :react | :rlm
  def program_kind do
    case System.get_env("WORKSPACE_AGENT_PROGRAM", "rlm") do
      "react" -> :react
      "rlm" -> :rlm
      other -> raise "WORKSPACE_AGENT_PROGRAM must be react or rlm, got: #{other}"
    end
  end

  @doc "Returns the explicit authority granted to host-attached MCP descriptors."
  @spec mcp_authority() :: :deny | :host
  def mcp_authority do
    case System.get_env("WORKSPACE_AGENT_MCP_AUTHORITY", "deny") do
      "deny" -> :deny
      "host" -> :host
      other -> raise "WORKSPACE_AGENT_MCP_AUTHORITY must be deny or host, got: #{other}"
    end
  end

  @doc "Builds one workspace-rooted program for an ACP session."
  @spec program(%{required(:cwd) => Path.t()}, keyword()) ::
          {:ok, term(), (-> term())} | {:error, term()}
  def program(session, opts \\ [])

  def program(%{cwd: cwd} = session, opts) do
    with :ok <- validate_mount(cwd, Keyword.get(opts, :mounted_root)),
         workspace_tools <- Tools.for_workspace(cwd),
         {:ok, mcp} <- import_mcp_tools(session, opts, workspace_tools) do
      tools = workspace_tools ++ mcp.tools
      program_kind = Keyword.get(opts, :program, program_kind())
      provider = Keyword.get(opts, :provider, provider())

      {program_kind, provider}
      |> build_program(tools)
      |> attach_cleanup(mcp.cleanup, Imp.ACP.ToolKind.derive_all(mcp.annotations))
    end
  end

  defp build_program({:react, :lmstudio}, tools), do: react(tools, lm(:react))
  defp build_program({:rlm, :lmstudio}, tools), do: rlm(tools, lm(:rlm))
  defp build_program({:react, :static}, tools), do: static_react(tools)
  defp build_program({:rlm, :static}, tools), do: static_rlm(tools)

  defp import_mcp_tools(session, opts, workspace_tools) do
    servers = Map.get(session, :mcp_servers, [])
    authorize = Keyword.get(opts, :mcp_authorize, mcp_authorizer())

    Imp.MCP.connect(servers,
      cwd: session.cwd,
      authorize: authorize,
      result_mode: :text,
      reserved_tool_names: Enum.map(workspace_tools, & &1.name)
    )
  end

  defp mcp_authorizer do
    case mcp_authority() do
      :host -> fn _server, _context -> true end
      :deny -> nil
    end
  end

  # The kinds derived from the MCP servers this session connected travel back to
  # Imp.ACP with the program, because they are not knowable when the adapter's
  # options are built.
  defp attach_cleanup({:ok, program, cleanup}, mcp_cleanup, tool_kinds)
       when is_function(cleanup, 0) and is_function(mcp_cleanup, 0) do
    {:ok, program, %{cleanup: combine_cleanup(cleanup, mcp_cleanup), tool_kinds: tool_kinds}}
  end

  defp attach_cleanup({:error, _reason} = error, mcp_cleanup, _tool_kinds) do
    mcp_cleanup.()
    error
  end

  defp attach_cleanup(program, mcp_cleanup, tool_kinds) when is_function(mcp_cleanup, 0),
    do: {:ok, program, %{cleanup: mcp_cleanup, tool_kinds: tool_kinds}}

  defp combine_cleanup(first, second) do
    fn ->
      _ = first.()
      second.()
    end
  end

  defp validate_mount(_cwd, nil), do: :ok

  defp validate_mount(cwd, mounted_root) when is_binary(cwd) and is_binary(mounted_root) do
    if same_directory?(cwd, mounted_root),
      do: :ok,
      else: {:error, :workspace_not_mounted}
  end

  defp validate_mount(_cwd, _mounted_root), do: {:error, :workspace_not_mounted}

  # A process launcher may report the physical spelling of a mounted path
  # (`/private/tmp/...` on macOS) while ACP preserves the path selected by the
  # host (`/tmp/...`). Keep the boundary fail-closed, but recognize two names
  # for the same directory by filesystem identity instead of string spelling.
  defp same_directory?(left, right) do
    if Path.expand(left) == Path.expand(right) do
      File.dir?(left)
    else
      with {:ok, left_stat} <- File.stat(left),
           {:ok, right_stat} <- File.stat(right) do
        left_stat.type == :directory and
          right_stat.type == :directory and
          left_stat.inode > 0 and
          {left_stat.major_device, left_stat.minor_device, left_stat.inode} ==
            {right_stat.major_device, right_stat.minor_device, right_stat.inode}
      else
        _error -> false
      end
    end
  end

  defp react(tools, lm) do
    signature =
      Imp.signature(
        "question -> answer",
        "Inspect the selected workspace with the workspace tools. Ground the answer in " <>
          "observed files and cite relative file paths. You may create files, replace exact " <>
          "text, and run argument-vector commands when the task requires it; those effects " <>
          "require explicit client approval. Start with the README, inspect only what is needed, " <>
          "make the smallest coherent change, run the relevant check, then write the answer " <>
          "as plain text without calling a tool. Use the provider's named function calls rather than serializing a tool call " <>
          "as response text, and pass a JSON object matching the selected tool schema. For " <>
          "commands, pass the executable once, for example run_command with " <>
          "{\"command\":\"cat\",\"args\":[\"README.md\"]}; never repeat the executable inside " <>
          "args. Treat a failed tool result as a failure, not evidence that the check " <>
          "passed. Do not claim facts you did not observe. Prefer the mounted project's root " <>
          "documentation and source over files belonging to this example application."
      )

    Imp.react(signature, tools,
      lm: lm,
      max_iters: 12,
      config: [max_tokens: 1_600, temperature: 0.0]
    )
  end

  defp rlm(tools, lm) do
    signature =
      Imp.signature(
        "question -> answer",
        "Use the constrained Elixir controller and the workspace tools to answer " <>
          "the question or make the requested change. Mutating tools and commands require " <>
          "explicit client approval. Cite relative file paths and call submit(%{answer: answer}) " <>
          "only after grounding the answer in tool results and running the relevant check. " <>
          "Prefer the mounted project's root documentation and source over files belonging to " <>
          "this example application. Tool " <>
          "arguments must be maps, for example list_files(%{path: \".\"}), " <>
          "read_file(%{path: \"README.md\"}), and search_text(%{query: \"term\", path: \".\"}); " <>
          "for commands use run_command(%{command: \"cat\", args: [\"README.md\"]}) and do not " <>
          "repeat the executable inside args. Never pass a keyword list or claim a failed check " <>
          "passed. Read the root README before searching for exact phrases."
      )

    Imp.rlm(signature,
      lm: lm,
      adapter: Imp.Adapter.JSON,
      tools: tools,
      max_iterations: 10,
      max_time_ms: rlm_max_time_ms(),
      persistent: true
    )
  end

  defp lm(kind) do
    capabilities =
      case kind do
        :react -> %{chat: true, tools: %{enabled: true}}
        :rlm -> %{chat: true}
      end

    model = model()

    Imp.req_llm(
      %{
        provider: :openai,
        id: model,
        model: model,
        provider_model_id: model,
        capabilities: capabilities,
        extra: %{wire: %{protocol: "openai_chat"}}
      },
      api_key: "lm-studio",
      base_url: base_url(),
      cache: false,
      receive_timeout: receive_timeout_ms(),
      max_retries: 0,
      req_http_options: [retry: false, max_retries: 0]
    )
  end

  defp positive_env_ms(name, default) do
    case Integer.parse(System.get_env(name, Integer.to_string(default))) do
      {timeout, ""} when timeout > 0 -> timeout
      _invalid -> raise "#{name} must be a positive integer"
    end
  end

  defp static_react(tools) do
    {:ok, step} = Agent.start_link(fn -> 0 end)

    lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          case Agent.get_and_update(step, &{&1, &1 + 1}) do
            0 ->
              tool_turn("List the workspace first.", "list_files", "smoke-list", %{path: "."})

            1 ->
              tool_turn("Read its entry document.", "read_file", "smoke-read", %{
                path: "README.md"
              })

            _ ->
              answer =
                case Imp.ACP.DemoMessages.current_tool_result(messages) do
                  {:ok, content} -> "Observed README first line: #{observed_first_line(content)}"
                  {:error, reason} -> "Workspace read was denied or failed: #{inspect(reason)}"
                  :none -> "No workspace content was observed."
                end

              answer
          end
        end
      )

    {:ok, react(tools, lm), fn -> if Process.alive?(step), do: Agent.stop(step) end}
  end

  defp static_rlm(tools) do
    lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          %{
            reasoning: "Read the workspace entry document and submit its first line.",
            code: ~S"""
            content = read_file(%{path: "README.md", line_count: 1})
            first = content |> String.split("\n") |> Enum.at(-1)
            submit(%{answer: "Observed README first line: " <> first})
            """
          }
        end
      )

    rlm(tools, lm)
  end

  defp tool_turn(thought, name, id, arguments) do
    %{next_thought: thought, tool_calls: [%{id: id, name: name, arguments: arguments}]}
  end

  defp observed_first_line(content) do
    case String.split(content, "\n", parts: 3) do
      ["[README.md lines " <> _range, first_line | _rest] -> first_line
      [first_line | _rest] -> first_line
    end
  end

  defp state_home do
    System.get_env("XDG_STATE_HOME") || Path.join(System.user_home!(), ".local/state")
  end
end
