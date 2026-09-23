defmodule WorkspaceAgentTest do
  use ExUnit.Case, async: false

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "workspace-agent-program-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    File.write!(Path.join(root, "README.md"), "# Example\nA useful project.\n")
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "provider-free ReAct factory reads and answers with workspace evidence", %{root: root} do
    assert {:ok, program, %{cleanup: cleanup}} =
             WorkspaceAgent.program(%{cwd: root}, provider: :static, program: :react)

    on_exit(cleanup)

    assert {:ok, prediction} = Imp.call(program, %{question: "Read the README"})
    assert Imp.get(prediction, :answer) == "Observed README first line: # Example"
  end

  test "provider-free RLM factory uses the constrained interpreter and submits", %{root: root} do
    assert {:ok, program, %{cleanup: cleanup}} =
             WorkspaceAgent.program(%{cwd: root}, provider: :static, program: :rlm)

    on_exit(fn ->
      cleanup.()
      Imp.Predict.RLM.close(program)
    end)

    assert {:ok, prediction} = Imp.call(program, %{question: "Read the README"})
    assert Imp.get(prediction, :answer) == "Observed README first line: # Example"
  end

  test "LM Studio profile passes its explicit receive timeout to ReqLLM", %{root: root} do
    original_receive_timeout = System.get_env("WORKSPACE_AGENT_RECEIVE_TIMEOUT_MS")
    original_max_time = System.get_env("WORKSPACE_AGENT_RLM_MAX_TIME_MS")
    System.put_env("WORKSPACE_AGENT_RECEIVE_TIMEOUT_MS", "42000")
    System.put_env("WORKSPACE_AGENT_RLM_MAX_TIME_MS", "84000")

    on_exit(fn ->
      if original_receive_timeout,
        do: System.put_env("WORKSPACE_AGENT_RECEIVE_TIMEOUT_MS", original_receive_timeout),
        else: System.delete_env("WORKSPACE_AGENT_RECEIVE_TIMEOUT_MS")

      if original_max_time,
        do: System.put_env("WORKSPACE_AGENT_RLM_MAX_TIME_MS", original_max_time),
        else: System.delete_env("WORKSPACE_AGENT_RLM_MAX_TIME_MS")
    end)

    assert {:ok, %Imp.Predict.RLM{lm: %Imp.Clients.ReqLLM{opts: opts}} = program,
            %{cleanup: cleanup}} =
             WorkspaceAgent.program(%{cwd: root}, provider: :lmstudio, program: :rlm)

    on_exit(fn ->
      cleanup.()
      Imp.Predict.RLM.close(program)
    end)

    assert Keyword.fetch!(opts, :receive_timeout) == 42_000
    assert Keyword.fetch!(opts, :max_retries) == 0
    assert Keyword.fetch!(opts, :req_http_options) == [retry: false, max_retries: 0]
    assert program.max_time_ms == 84_000
  end

  test "the launcher-owned mount must match the ACP session workspace", %{root: root} do
    assert {:error, :workspace_not_mounted} =
             WorkspaceAgent.program(%{cwd: System.tmp_dir!()},
               mounted_root: root,
               provider: :static,
               program: :react
             )

    assert {:ok, _program, %{cleanup: cleanup}} =
             WorkspaceAgent.program(%{cwd: root},
               mounted_root: root,
               provider: :static,
               program: :react
             )

    cleanup.()
  end

  test "the launcher accepts a filesystem alias for the same mounted workspace", %{root: root} do
    alias_root = root <> "-alias"
    File.ln_s!(root, alias_root)
    on_exit(fn -> File.rm(alias_root) end)

    assert {:ok, _program, %{cleanup: cleanup}} =
             WorkspaceAgent.program(%{cwd: root},
               mounted_root: alias_root,
               provider: :static,
               program: :react
             )

    cleanup.()
  end

  test "workspace policy preauthorizes reads and delegates mutations to the ACP client" do
    assert :allow = WorkspaceAgent.permission_policy(%{tool_name: :read_file}, %{})
    assert :allow = WorkspaceAgent.permission_policy(%{tool_name: "search_text"}, %{})
    assert :client = WorkspaceAgent.permission_policy(%{tool_name: :replace_text}, %{})
    assert :client = WorkspaceAgent.permission_policy(%{tool_name: "run_command"}, %{})
    assert :client = WorkspaceAgent.permission_policy(%{tool_name: :external_mcp}, %{})
  end

  test "host-authorized MCP descriptors become ordinary external tools", %{root: root} do
    adapter_name = "../../.." |> Path.expand(__DIR__) |> Path.basename()

    env =
      [%{"name" => "MIX_ENV", "value" => "test"}] ++
        Enum.flat_map(["EX_MCP_PATH", "IMP_PATH"], fn name ->
          case System.get_env(name) do
            path when is_binary(path) and path != "" ->
              [%{"name" => name, "value" => path}]

            _unset ->
              []
          end
        end)

    server = %{
      "name" => "imp-acp-demo",
      "type" => "stdio",
      "command" => Path.expand("../../../scripts/imp-acp-demo-mcp-server", __DIR__),
      "args" => [],
      "env" => env
    }

    assert {:error, {:mcp_server_not_authorized, "imp-acp-demo"}} =
             WorkspaceAgent.program(%{cwd: root, mcp_servers: [server]},
               provider: :static,
               program: :react,
               mcp_authorize: nil
             )

    assert {:ok, program, %{cleanup: cleanup, tool_kinds: tool_kinds}} =
             WorkspaceAgent.program(%{cwd: root, mcp_servers: [server]},
               provider: :static,
               program: :react,
               mcp_authorize: fn _server, _context -> true end
             )

    on_exit(cleanup)
    tool = Map.fetch!(program.tools, :external_workspace_name)
    assert Imp.Tool.call(tool, %{}) == adapter_name

    # The demo server declares readOnlyHint, so the kind the ACP host will apply
    # a permission mode to comes from the tool rather than from a table here.
    assert tool_kinds == %{"external_workspace_name" => "read"}
  end
end
