defmodule Imp.ACPTest do
  use ExUnit.Case, async: false

  setup_all do
    {:ok, _} = Application.ensure_all_started(:ex_mcp)
    :ok
  end

  alias ExMCP.ACP.Agent.Transport.Memory
  alias ExMCP.ACP.Client

  # One MCP server whose tools declare their own nature, so the import path can
  # be falsified against every branch of Imp.ACP.ToolKind rather than a stub.
  defmodule AnnotatedMCPServer do
    @moduledoc false

    use ExMCP.Server.Handler
    use ExMCP.Server.DSL, name: "imp-acp-annotated-mcp", version: "0.1.0"

    tool "annotated_read", "A read that reaches outside the process" do
      annotations(%{readOnlyHint: true, openWorldHint: true})
      run(fn _arguments, state -> {:ok, "read", state} end)
    end

    tool "annotated_local_read", "A read that touches nothing outside the process" do
      annotations(%{readOnlyHint: true, openWorldHint: false})
      run(fn _arguments, state -> {:ok, "local", state} end)
    end

    tool "annotated_write", "A write that is not destructive" do
      annotations(%{readOnlyHint: false, destructiveHint: false, openWorldHint: true})
      run(fn _arguments, state -> {:ok, "wrote", state} end)
    end

    tool "annotated_local_write", "A non-destructive write that stays local" do
      annotations(%{readOnlyHint: false, destructiveHint: false, openWorldHint: false})
      run(fn _arguments, state -> {:ok, "wrote locally", state} end)
    end

    tool "annotated_destructive", "A write that may destroy something" do
      annotations(%{readOnlyHint: false, destructiveHint: true, openWorldHint: true})
      run(fn _arguments, state -> {:ok, "destroyed", state} end)
    end

    tool "unannotated", "A tool that declares nothing about itself" do
      run(fn _arguments, state -> {:ok, "unknown", state} end)
    end
  end

  defmodule EchoProgram do
    @behaviour Imp.Module

    defstruct [:signature, :test_pid]

    @impl true
    def call(program, inputs) do
      send(program.test_pid, {:echo_inputs, inputs})
      {:ok, Imp.Prediction.new(%{answer: "echo: " <> inputs.question})}
    end
  end

  defmodule BlockingProgram do
    @behaviour Imp.Module

    defstruct [:signature, :test_pid]

    @impl true
    def call(program, _inputs) do
      send(program.test_pid, {:blocking_worker, self()})

      receive do
        :never -> :ok
      end

      {:ok, Imp.Prediction.new(%{answer: "too late"})}
    end
  end

  defmodule DelayedProgram do
    @behaviour Imp.Module

    defstruct [:signature, :test_pid]

    @impl true
    def call(program, _inputs) do
      send(program.test_pid, {:delayed_worker, self()})
      Process.sleep(150)
      {:ok, Imp.Prediction.new(%{answer: "late answer"})}
    end
  end

  defmodule CleanupProgram do
    @behaviour Imp.Module

    defstruct [:signature, :test_pid]

    @impl true
    def call(_program, _inputs), do: {:ok, Imp.Prediction.new(%{answer: "ok"})}

    def close(program) do
      send(program.test_pid, :program_closed)
      :ok
    end
  end

  defmodule ErrorProgram do
    @behaviour Imp.Module

    defstruct [:signature]

    @impl true
    def call(_program, _inputs) do
      {:error,
       {:module_call_failed, Imp.Predict.ReActV2,
        "tool call requires a name; got %{command: \"cat\"}"}}
    end
  end

  defmodule TimeoutProgram do
    @behaviour Imp.Module

    defstruct [:signature]

    @impl true
    def call(_program, _inputs) do
      {:error,
       {:rlm_extract_failed,
        %{cause: %{reason: :timeout, stacktrace: [{Secret.Module, :call, 1}]}, reason: "timeout"}}}
    end
  end

  defmodule ResultOnlyProgram do
    @behaviour Imp.Module

    defstruct [:signature]

    @impl true
    def call(_program, _inputs) do
      :ok =
        Imp.Run.emit(:tool_result,
          tool_call_id: "invalid-call",
          tool_name: :run_command,
          input: "invalid arguments",
          error: {:schema_validation, :invalid_arguments}
        )

      {:ok, Imp.Prediction.new(%{answer: "failed honestly"})}
    end
  end

  defmodule PermissionHandler do
    @behaviour ExMCP.ACP.Client.Handler

    @impl true
    def init(opts) do
      {:ok,
       %{
         parent: Keyword.fetch!(opts, :parent),
         decision: Keyword.fetch!(opts, :decision)
       }}
    end

    @impl true
    def handle_session_update(_session_id, _update, state), do: {:ok, state}

    @impl true
    def handle_permission_request(session_id, tool_call, options, state) do
      send(state.parent, {:permission_requested, self(), session_id, tool_call, options})

      outcome =
        case state.decision do
          :allow ->
            %{"outcome" => "selected", "optionId" => "allow"}

          :deny ->
            %{"outcome" => "selected", "optionId" => "deny"}

          :forged ->
            %{"outcome" => "selected", "optionId" => "not_offered"}

          :block ->
            receive do
              {:resolve_permission, outcome} -> outcome
            end
        end

      {:ok, outcome, state}
    end
  end

  defmodule HostCapabilityHandler do
    @behaviour ExMCP.ACP.Client.Handler

    @impl true
    def init(opts), do: {:ok, %{parent: Keyword.fetch!(opts, :parent)}}

    @impl true
    def handle_session_update(_session_id, _update, state), do: {:ok, state}

    @impl true
    def handle_permission_request(session_id, tool_call, options, state) do
      send(state.parent, {:host_permission, session_id, tool_call, options})
      {:ok, %{"outcome" => "selected", "optionId" => "allow"}, state}
    end

    @impl true
    def handle_file_read(session_id, path, opts, state) do
      send(state.parent, {:host_read, session_id, path, opts})
      {:ok, "# Hosted\n", state}
    end

    @impl true
    def handle_file_write(session_id, path, content, state) do
      send(state.parent, {:host_write, session_id, path, content})
      {:ok, state}
    end

    @impl true
    def handle_terminal_request(method, params, _id, state) do
      send(state.parent, {:host_terminal, method, params})

      response =
        case method do
          "terminal/create" -> %{"terminalId" => "host-terminal-1"}
          "terminal/wait_for_exit" -> %{"exitCode" => 0}
          "terminal/output" -> %{"output" => "checked\n", "truncated" => false}
          "terminal/kill" -> %{}
          "terminal/release" -> %{}
        end

      {:ok, response, state}
    end
  end

  test "maps a single signature input and emits the selected prediction before end_turn" do
    test_pid = self()

    {client, _agent} =
      start_pair(fn _session -> echo_program(test_pid) end,
        permission_policy: :unrestricted
      )

    {:ok, %{"sessionId" => session_id}} = Client.new_session(client, "/tmp/project")

    assert {:ok, %{"stopReason" => "end_turn", "text" => "echo: hello"}} =
             Client.prompt(client, session_id, "hello")

    assert_receive {:echo_inputs, %{question: "hello"}}
  end

  test "keeps program internals out of the conversation and classifies the refusal" do
    program = %ErrorProgram{signature: Imp.signature("question -> answer")}

    {client, _agent} =
      start_pair(fn _session -> program end, permission_policy: :unrestricted)

    {:ok, %{"sessionId" => session_id}} = Client.new_session(client, "/tmp/project")

    assert {:ok,
            %{
              "stopReason" => "refusal",
              "text" => "I couldn't finish this request.",
              "_meta" => %{
                "imp_acp" => %{
                  "failure" => %{
                    "kind" => "module_call_failed",
                    "category" => "program_error"
                  }
                }
              }
            }} =
             Client.prompt(client, session_id, "run it")
  end

  test "presents nested provider timeouts without exposing their internal shape" do
    program = %TimeoutProgram{signature: Imp.signature("question -> answer")}

    {client, _agent} =
      start_pair(fn _session -> program end, permission_policy: :unrestricted)

    {:ok, %{"sessionId" => session_id}} = Client.new_session(client, "/tmp/project")

    assert {:ok,
            %{
              "stopReason" => "refusal",
              "text" => "The model took too long to finish this request.",
              "_meta" => %{
                "imp_acp" => %{
                  "failure" => %{"kind" => "rlm_extract_failed", "category" => "timeout"}
                }
              }
            } = result} = Client.prompt(client, session_id, "run it")

    refute inspect(result) =~ "Secret.Module"
    refute inspect(result) =~ "stacktrace"
  end

  test "a validation result without a source start still gets an ordered ACP tool card" do
    program = %ResultOnlyProgram{signature: Imp.signature("question -> answer")}

    {client, _agent} =
      start_pair(fn _session -> program end, permission_policy: :unrestricted)

    {:ok, %{"sessionId" => session_id}} = Client.new_session(client, "/tmp/project")

    assert {:ok, %{"stopReason" => "end_turn"}} = Client.prompt(client, session_id, "run it")

    [started, failed] = session_id |> receive_updates([]) |> tool_updates()
    assert started["sessionUpdate"] == "tool_call"
    assert started["status"] == "in_progress"
    assert started["kind"] == "execute"
    assert started["title"] == "command"
    assert started["rawInput"] == %{"value" => "invalid arguments"}
    assert failed["sessionUpdate"] == "tool_call_update"
    assert failed["status"] == "failed"
    assert started["toolCallId"] == failed["toolCallId"]
  end

  test "demo policies use only the current turn's tool result" do
    old_tool = %{role: :tool, content: "stale"}
    current_question = %{role: :user, content: "[[ ## question ## ]]\nfresh"}
    format_request = %{role: :user, content: "[[ ## tools ## ]]"}

    assert :none ==
             Imp.ACP.DemoMessages.current_tool_result([
               old_tool,
               current_question,
               format_request
             ])

    assert {:ok, "fresh"} ==
             Imp.ACP.DemoMessages.current_tool_result([
               current_question,
               %{role: :assistant, content: "inspect"},
               %{role: :tool, content: "fresh"},
               format_request
             ])

    assert {:error, "{:error, :denied}"} ==
             Imp.ACP.DemoMessages.current_tool_result([
               current_question,
               %{role: :assistant, content: "inspect"},
               %{role: :tool, content: "{:error, :denied}"},
               format_request
             ])
  end

  test "authorization-aware mode fails closed for a module without execute/3" do
    test_pid = self()
    {client, _agent} = start_pair(fn _session -> echo_program(test_pid) end)
    {:ok, %{"sessionId" => session_id}} = Client.new_session(client, "/tmp/project")

    assert {:ok, %{"stopReason" => "refusal"}} =
             Client.prompt(client, session_id, "must not run")

    refute_receive {:echo_inputs, _inputs}
  end

  test "factory lifecycle acquires each turn privately and releases it after completion" do
    parent = self()

    lifecycle = %{
      before_turn: fn ->
        send(parent, :before_turn)
        :ok
      end,
      after_turn: fn ->
        send(parent, :after_turn)
        :ok
      end,
      cleanup: fn ->
        send(parent, :factory_cleaned)
        :ok
      end
    }

    {client, agent} =
      start_pair(fn _ -> {:ok, echo_program(parent), lifecycle} end,
        permission_policy: :unrestricted
      )

    {:ok, %{"sessionId" => session_id}} = Client.new_session(client, "/tmp/project")

    for text <- ["first", "second"] do
      assert {:ok, %{"text" => "echo: " <> ^text}} = Client.prompt(client, session_id, text)
      assert_receive :before_turn
      assert_receive {:echo_inputs, %{question: ^text}}
      assert_receive :after_turn
    end

    stop_if_alive(agent)
    assert_receive :factory_cleaned
  end

  # A host that knows what its user should do returns a JSON-RPC error triple.
  # Wrapping it as a lifecycle failure and answering "I couldn't finish this
  # request" discards the only part of the failure anyone can act on.
  test "a host's own refusal message survives turn acquisition" do
    parent = self()

    lifecycle = %{
      before_turn: fn ->
        {:error, {-32_000, "Attach an account before prompting.", %{"reason" => "no_account"}}}
      end,
      after_turn: fn -> :ok end
    }

    {client, _agent} =
      start_pair(fn _ -> {:ok, echo_program(parent), lifecycle} end,
        permission_policy: :unrestricted
      )

    {:ok, %{"sessionId" => session_id}} = Client.new_session(client, "/tmp/project")

    assert {:ok, %{"stopReason" => "refusal", "_meta" => meta}} =
             Client.prompt(client, session_id, "must not execute")

    assert get_in(meta, ["imp_acp", "failure", "kind"]) == "no_account"
    assert get_in(meta, ["imp_acp", "failure", "category"]) == "refusal"

    # The sentence the host wrote is what the person actually reads.
    assert_receive {:acp_session_update, ^session_id,
                    %{"sessionUpdate" => "agent_message_chunk", "content" => content}}

    assert content["text"] =~ "Attach an account before prompting."
    refute_receive {:echo_inputs, _}
  end

  test "failed turn acquisition never starts a program" do
    parent = self()

    lifecycle = %{
      before_turn: fn -> {:error, :host_unavailable} end,
      after_turn: fn ->
        send(parent, :failed_turn_released)
        :ok
      end
    }

    {client, _agent} =
      start_pair(fn _ -> {:ok, echo_program(parent), lifecycle} end,
        permission_policy: :unrestricted
      )

    {:ok, %{"sessionId" => session_id}} = Client.new_session(client, "/tmp/project")

    assert {:ok, %{"stopReason" => "refusal"}} =
             Client.prompt(client, session_id, "must not execute")

    assert_receive :failed_turn_released
    refute_receive {:echo_inputs, _}
  end

  test "cancellation releases the factory turn after stopping its program" do
    parent = self()

    lifecycle = %{
      after_turn: fn ->
        send(parent, :cancelled_turn_released)
        :ok
      end
    }

    program = %BlockingProgram{signature: Imp.signature("question -> answer"), test_pid: parent}

    {client, _agent} =
      start_pair(fn _ -> {:ok, program, lifecycle} end,
        permission_policy: :unrestricted
      )

    {:ok, %{"sessionId" => session_id}} = Client.new_session(client, "/tmp/project")
    prompt = Task.async(fn -> Client.prompt(client, session_id, "wait") end)
    assert_receive {:blocking_worker, worker}
    assert :ok = Client.cancel(client, session_id)
    assert_receive :cancelled_turn_released
    refute Process.alive?(worker)
    Task.await(prompt)
  end

  test "turn acquisition is cancellable before the program starts" do
    parent = self()

    lifecycle = %{
      before_turn: fn ->
        send(parent, {:acquiring_turn, self()})
        receive do: (:never -> :ok)
      end,
      after_turn: fn ->
        send(parent, :acquisition_cancelled)
        :ok
      end
    }

    {client, _agent} =
      start_pair(fn _ -> {:ok, echo_program(parent), lifecycle} end,
        permission_policy: :unrestricted
      )

    {:ok, %{"sessionId" => session_id}} = Client.new_session(client, "/tmp/project")
    task = Task.async(fn -> Client.prompt(client, session_id, "wait for host") end)
    assert_receive {:acquiring_turn, worker}
    assert :ok = Client.cancel(client, session_id)
    assert_receive :acquisition_cancelled
    refute Process.alive?(worker)
    refute_receive {:echo_inputs, _}
    Task.await(task)
  end

  test "client approval orders one stable card before the external effect result" do
    test_pid = self()

    tool =
      Imp.tool(:external, "external effect", fn args ->
        send(test_pid, {:effect, args})
        "ok"
      end)

    program = one_tool_program(tool, "approved")

    {client, _agent} =
      start_pair(fn _session -> program end,
        agent_opts: [tool_kinds: %{external: :execute}],
        handler: PermissionHandler,
        client_handler_opts: [parent: test_pid, decision: :allow]
      )

    {:ok, %{"sessionId" => session_id}} = Client.new_session(client, "/tmp/project")

    assert {:ok, %{"stopReason" => "end_turn", "text" => "approved"}} =
             Client.prompt(client, session_id, "run it")

    assert_receive {:permission_requested, _handler, ^session_id, permission_tool, options}

    assert Enum.map(options, & &1["optionId"]) == [
             "allow",
             "allow_always",
             "deny",
             "deny_always"
           ]

    assert get_in(permission_tool, ["_meta", "deepfates.com/imp-acp", "toolName"]) ==
             "external"

    refute Map.has_key?(permission_tool, "name")
    assert_receive {:effect, %{value: "x"}}

    updates = receive_updates(session_id, [])
    [pending, in_progress, completed] = tool_updates(updates)

    assert pending["status"] == "pending"
    assert in_progress["status"] == "in_progress"
    assert completed["status"] == "completed"
    assert pending["toolCallId"] == permission_tool["toolCallId"]
    assert pending["toolCallId"] == in_progress["toolCallId"]
    assert pending["toolCallId"] == completed["toolCallId"]
    assert permission_tool["rawInput"] == %{"value" => "x"}
    assert permission_tool["kind"] == "execute"
    assert pending["kind"] == "execute"
    refute Map.has_key?(pending, "name")
  end

  test "a per-effect policy preauthorizes bounded tools without a client request" do
    test_pid = self()

    tool =
      Imp.tool(:external, "bounded lookup", fn args ->
        send(test_pid, {:bounded_effect, args})
        "ok"
      end)

    program = one_tool_program(tool, "preauthorized")

    policy = fn request, %{cwd: cwd} ->
      send(test_pid, {:policy_checked, request.tool_name, cwd})
      if request.tool_name in [:external, "external"], do: :allow, else: :client
    end

    {client, _agent} =
      start_pair(fn _session -> program end,
        permission_policy: policy,
        handler: PermissionHandler,
        client_handler_opts: [parent: test_pid, decision: :block]
      )

    {:ok, %{"sessionId" => session_id}} = Client.new_session(client, "/tmp/project")

    assert {:ok, %{"stopReason" => "end_turn", "text" => "preauthorized"}} =
             Client.prompt(client, session_id, "run it")

    assert_receive {:policy_checked, :external, "/tmp/project"}
    assert_receive {:bounded_effect, %{value: "x"}}
    refute_receive {:permission_requested, _handler, ^session_id, _tool, _options}

    updates = receive_updates(session_id, [])
    [pending, in_progress, completed] = tool_updates(updates)
    assert pending["status"] == "pending"
    assert in_progress["status"] == "in_progress"
    assert completed["status"] == "completed"
    assert pending["toolCallId"] == in_progress["toolCallId"]
    assert in_progress["toolCallId"] == completed["toolCallId"]
  end

  test "host-backed tools use the ACP filesystem and terminal capabilities" do
    test_pid = self()

    factory = fn session ->
      send(test_pid, {:host_handle, session.host})
      host_program(session.host)
    end

    policy = fn request, _session ->
      if request.tool_name in [:read_file, "read_file"], do: :allow, else: :client
    end

    {client, _agent} =
      start_pair(factory,
        permission_policy: policy,
        handler: HostCapabilityHandler,
        client_handler_opts: [parent: test_pid]
      )

    {:ok, %{"sessionId" => session_id}} = Client.new_session(client, "/tmp/project")

    assert_receive {:host_handle, %Imp.ACP.Host{session_id: ^session_id, cwd: "/tmp/project"}}

    assert {:ok, %{"stopReason" => "end_turn", "text" => "host capabilities complete"}} =
             Client.prompt(client, session_id, "use the host")

    assert_receive {:host_read, ^session_id, "/tmp/project/README.md",
                    %{"line" => 1, "limit" => 2}}

    assert_receive {:host_write, ^session_id, "/tmp/project/notes.txt", "hello\n"}

    assert_receive {:host_terminal, "terminal/create",
                    %{
                      "sessionId" => ^session_id,
                      "command" => "mix",
                      "args" => ["test"],
                      "cwd" => "/tmp/project",
                      "outputByteLimit" => 32_000
                    }}

    assert_receive {:host_terminal, "terminal/wait_for_exit",
                    %{"terminalId" => "host-terminal-1"}}

    assert_receive {:host_terminal, "terminal/output", %{"terminalId" => "host-terminal-1"}}
    assert_receive {:host_terminal, "terminal/release", %{"terminalId" => "host-terminal-1"}}

    permissions = receive_host_permissions(session_id, [])
    assert Enum.map(permissions, & &1["kind"]) == ["edit", "execute"]

    [write_permission, _command_permission] = permissions
    assert write_permission["title"] == "Write notes.txt"

    assert write_permission["content"] == [
             %{
               "type" => "diff",
               "path" => "notes.txt",
               "oldText" => nil,
               "newText" => "hello\n"
             }
           ]
  end

  test "host-backed tools reject paths outside the mounted workspace before ACP" do
    host =
      Imp.ACP.Host.new(self(), "session", "/tmp/project", %{
        "fs" => %{"readTextFile" => true}
      })

    read = Enum.find(Imp.ACP.Host.tools(host), &(&1.name == :read_file))

    assert {:error, :path_outside_workspace} =
             Imp.Tool.call(read, %{path: "../outside.txt", line_start: 1, line_count: 1})
  end

  test "host permission policy delegates only host-tool names" do
    for name <- [:read_file, "read_file", :write_file, "write_file", :run_command, "run_command"] do
      request = %Imp.Execution.Authorization{
        run_id: "run",
        tool_call_id: "call",
        tool_name: name,
        arguments: %{}
      }

      assert Imp.ACP.Host.permission_policy(request, %{}) == :allow
    end

    request = %Imp.Execution.Authorization{
      run_id: "run",
      tool_call_id: "call",
      tool_name: :external_mcp,
      arguments: %{}
    }

    assert Imp.ACP.Host.permission_policy(request, %{}) == :client
  end

  test "host-backed catalog contains only negotiated ACP client capabilities" do
    host =
      Imp.ACP.Host.new(self(), "session", "/tmp/project", %{
        "fs" => %{"readTextFile" => true, "writeTextFile" => false},
        "terminal" => false
      })

    assert Enum.map(Imp.ACP.Host.tools(host), & &1.name) == [:read_file]
    assert Imp.ACP.Host.supported?(host, :read_file)
    refute Imp.ACP.Host.supported?(host, :write_file)
    refute Imp.ACP.Host.supported?(host, :run_command)
  end

  test "client denial and a forged option both fail closed before the effect" do
    for decision <- [:deny, :forged] do
      test_pid = self()
      tool = Imp.tool(:external, "external effect", fn _args -> send(test_pid, :effect) end)
      program = one_tool_program(tool, "safe")

      {client, _agent} =
        start_pair(fn _session -> program end,
          handler: PermissionHandler,
          client_handler_opts: [parent: test_pid, decision: decision]
        )

      {:ok, %{"sessionId" => session_id}} = Client.new_session(client, "/tmp/project")

      assert {:ok, %{"stopReason" => "end_turn", "text" => "safe"}} =
               Client.prompt(client, session_id, "do not run")

      assert_receive {:permission_requested, _handler, ^session_id, _tool, _options}
      refute_receive :effect

      updates = receive_updates(session_id, [])
      [pending, failed] = tool_updates(updates)
      assert pending["status"] == "pending"
      assert failed["status"] == "failed"
      assert pending["toolCallId"] == failed["toolCallId"]
    end
  end

  test "session cancellation while permission waits cannot execute or emit a late answer" do
    test_pid = self()
    tool = Imp.tool(:external, "external effect", fn _args -> send(test_pid, :effect) end)
    program = one_tool_program(tool, "too late")

    {client, _agent} =
      start_pair(fn _session -> program end,
        handler: PermissionHandler,
        client_handler_opts: [parent: test_pid, decision: :block]
      )

    {:ok, %{"sessionId" => session_id}} = Client.new_session(client, "/tmp/project")
    prompt = Task.async(fn -> Client.prompt(client, session_id, "wait") end)

    assert_receive {:permission_requested, handler, ^session_id, _tool, _options}
    assert :ok = Client.cancel(client, session_id)
    assert {:ok, %{"stopReason" => "cancelled"}} = Task.await(prompt, 2_000)
    refute_receive :effect

    send(handler, {:resolve_permission, %{"outcome" => "selected", "optionId" => "allow"}})

    refute_receive {:acp_session_update, ^session_id,
                    %{"sessionUpdate" => "agent_message_chunk"}},
                   200

    assert :sys.get_state(client).pending_agent_requests == %{}
  end

  test "authorization timeout retires the ACP request and cannot produce a late effect" do
    test_pid = self()
    tool = Imp.tool(:external, "external effect", fn _args -> send(test_pid, :effect) end)
    program = one_tool_program(tool, "timed out safely")

    {client, _agent} =
      start_pair(fn _session -> program end,
        authorization_timeout: 30,
        handler: PermissionHandler,
        client_handler_opts: [parent: test_pid, decision: :block]
      )

    {:ok, %{"sessionId" => session_id}} = Client.new_session(client, "/tmp/project")

    assert {:ok, %{"stopReason" => "end_turn", "text" => "timed out safely"}} =
             Client.prompt(client, session_id, "wait")

    assert_receive {:permission_requested, handler, ^session_id, _tool, _options}
    refute_receive :effect
    assert :sys.get_state(client).pending_agent_requests == %{}

    send(handler, {:resolve_permission, %{"outcome" => "selected", "optionId" => "allow"}})
    refute_receive :effect, 100
  end

  test "client disconnect while permission waits closes the session without a late effect" do
    test_pid = self()
    tool = Imp.tool(:external, "external effect", fn _args -> send(test_pid, :effect) end)
    program = one_tool_program(tool, "too late")

    {client, agent} =
      start_pair(fn _session -> program end,
        handler: PermissionHandler,
        client_handler_opts: [parent: test_pid, decision: :block]
      )

    {:ok, %{"sessionId" => session_id}} = Client.new_session(client, "/tmp/project")
    session_count = DynamicSupervisor.count_children(Imp.ACP.SessionSupervisor).active
    prompt = Task.async(fn -> Client.prompt(client, session_id, "wait") end)

    assert_receive {:permission_requested, handler, ^session_id, _tool, _options}
    agent_ref = Process.monitor(agent)
    assert :ok = Client.disconnect(client)
    assert_receive {:DOWN, ^agent_ref, :process, ^agent, :normal}, 2_000
    assert {:error, :disconnected} = Task.await(prompt, 2_000)

    assert_eventually(fn ->
      DynamicSupervisor.count_children(Imp.ACP.SessionSupervisor).active == session_count - 1
    end)

    send(handler, {:resolve_permission, %{"outcome" => "selected", "optionId" => "allow"}})
    refute_receive :effect, 100
  end

  test "cancellation terminates the owned Imp task before returning cancelled" do
    test_pid = self()

    {client, _agent} =
      start_pair(fn _session -> blocking_program(test_pid) end,
        permission_policy: :unrestricted
      )

    {:ok, %{"sessionId" => session_id}} = Client.new_session(client, "/tmp/project")

    prompt = Task.async(fn -> Client.prompt(client, session_id, "wait") end)
    assert_receive {:blocking_worker, worker}
    assert Process.alive?(worker)

    assert :ok = Client.cancel(client, session_id)
    assert {:ok, %{"stopReason" => "cancelled"}} = Task.await(prompt, 2_000)
    refute Process.alive?(worker)
  end

  test "a cancelled task cannot emit a late ACP update" do
    test_pid = self()

    {client, _agent} =
      start_pair(fn _session -> delayed_program(test_pid) end,
        permission_policy: :unrestricted
      )

    {:ok, %{"sessionId" => session_id}} = Client.new_session(client, "/tmp/project")

    prompt = Task.async(fn -> Client.prompt(client, session_id, "wait") end)
    assert_receive {:delayed_worker, worker}

    assert :ok = Client.cancel(client, session_id)
    assert {:ok, %{"stopReason" => "cancelled"}} = Task.await(prompt, 2_000)
    refute Process.alive?(worker)

    refute_receive {:acp_session_update, ^session_id,
                    %{"sessionUpdate" => "agent_message_chunk"}},
                   300
  end

  test "program factories receive ACP workspace metadata and create independent sessions" do
    test_pid = self()

    {client, _agent} =
      start_pair(fn metadata ->
        send(test_pid, {:factory_metadata, metadata})
        echo_program(test_pid)
      end)

    assert {:ok, %{"sessionId" => first}} = Client.new_session(client, "/tmp/one")
    assert {:ok, %{"sessionId" => second}} = Client.new_session(client, "/tmp/two")
    refute first == second

    assert_receive {:factory_metadata, %{cwd: "/tmp/one", session_id: ^first}}
    assert_receive {:factory_metadata, %{cwd: "/tmp/two", session_id: ^second}}
  end

  test "advertises live-session close without claiming restart restoration" do
    test_pid = self()
    {client, _agent} = start_pair(fn _session -> echo_program(test_pid) end)

    capabilities = :sys.get_state(client).agent_capabilities

    assert capabilities["sessionCapabilities"] == %{"close" => %{}}

    assert capabilities["_meta"] == %{
             "deepfates.com/imp-acp" => %{"permissionToolName" => true}
           }

    refute Map.has_key?(capabilities["sessionCapabilities"], "load")
    refute Map.has_key?(capabilities["sessionCapabilities"], "resume")
  end

  test "session close calls a program lifecycle callback" do
    test_pid = self()

    {client, _agent} =
      start_pair(fn _session ->
        %CleanupProgram{signature: Imp.signature("question -> answer"), test_pid: test_pid}
      end)

    {:ok, %{"sessionId" => session_id}} = Client.new_session(client, "/tmp/project")
    before_close = DynamicSupervisor.count_children(Imp.ACP.SessionSupervisor).active
    assert {:ok, %{}} = Client.close_session(client, session_id)
    assert_receive :program_closed

    assert_eventually(fn ->
      DynamicSupervisor.count_children(Imp.ACP.SessionSupervisor).active == before_close - 1
    end)
  end

  test "session close runs resources returned by the program factory" do
    test_pid = self()

    {client, _agent} =
      start_pair(fn _session ->
        {:ok, echo_program(test_pid), fn -> send(test_pid, :factory_resource_closed) end}
      end)

    {:ok, %{"sessionId" => session_id}} = Client.new_session(client, "/tmp/project")
    assert {:ok, %{}} = Client.close_session(client, session_id)
    assert_receive :factory_resource_closed
  end

  test "ACP MCP descriptors are denied unless the exact server is authorized" do
    server = %{
      "name" => "untrusted",
      "command" => "/definitely/not/an/executable",
      "args" => [],
      "env" => []
    }

    assert {:error, {:mcp_server_not_authorized, "untrusted"}} =
             Imp.ACP.MCP.import_tools([server], cwd: File.cwd!())
  end

  test "authorized stdio MCP tools cross ExMCP transport into Imp.Tool values" do
    server = demo_mcp_server()
    workspace_name = Path.basename(File.cwd!())

    assert {:ok, %Imp.ACP.MCP.Import{tools: [tool], cleanup: cleanup}} =
             Imp.ACP.MCP.import_tools([server],
               cwd: File.cwd!(),
               trusted_servers: [server]
             )

    on_exit(cleanup)
    assert to_string(tool.name) == "external_workspace_name"
    assert Imp.Tool.call(tool, %{}) == workspace_name
    assert :ok = cleanup.()
  end

  test "MCP tool annotations survive import and derive ACP tool kinds" do
    port = free_port()
    ref = {:imp_acp_annotated_mcp_test, port}

    assert {:ok, _server} =
             AnnotatedMCPServer.start_link(
               transport: :http,
               port: port,
               use_sse: false,
               ranch_ref: ref
             )

    on_exit(fn -> Plug.Cowboy.shutdown(ref) end)

    server = %{
      "name" => "imp-acp-annotated",
      "type" => "http",
      "url" => "http://127.0.0.1:#{port}",
      "headers" => []
    }

    assert {:ok, %Imp.ACP.MCP.Import{} = import} =
             Imp.ACP.MCP.import_tools([server],
               cwd: File.cwd!(),
               trusted_servers: [server]
             )

    on_exit(import.cleanup)

    # The declaration itself crosses the wire, unedited.
    assert import.annotations["annotated_read"] ==
             %{"readOnlyHint" => true, "openWorldHint" => true}

    assert import.annotations["annotated_destructive"] ==
             %{"readOnlyHint" => false, "destructiveHint" => true, "openWorldHint" => true}

    refute Map.has_key?(import.annotations, "unannotated")

    assert import.tool_kinds == %{
             "annotated_read" => "read",
             "annotated_local_read" => "think",
             "annotated_write" => "execute",
             "annotated_local_write" => "edit",
             "annotated_destructive" => "delete"
           }

    assert :ok = import.cleanup.()
  end

  test "annotations are keyed by the name the program will actually see" do
    port = free_port()
    ref = {:imp_acp_annotated_qualified_mcp_test, port}

    assert {:ok, _server} =
             AnnotatedMCPServer.start_link(
               transport: :http,
               port: port,
               use_sse: false,
               ranch_ref: ref
             )

    on_exit(fn -> Plug.Cowboy.shutdown(ref) end)

    server = %{
      "name" => "annotated",
      "type" => "http",
      "url" => "http://127.0.0.1:#{port}",
      "headers" => []
    }

    # A name the program has already taken refuses rather than being renamed,
    # so the declaration is what says to call this server's tools something else.
    assert {:error, {:mcp_tool_name_collision, "annotated_destructive", ["annotated"]}} =
             Imp.ACP.MCP.import_tools([server],
               cwd: File.cwd!(),
               trusted_servers: [server],
               reserved_tool_names: ["annotated_destructive"]
             )

    prefixed = Map.put(server, "tool_prefix", "note_")

    assert {:ok, %Imp.ACP.MCP.Import{} = import} =
             Imp.ACP.MCP.import_tools([prefixed],
               cwd: File.cwd!(),
               trusted_servers: [prefixed],
               reserved_tool_names: ["annotated_destructive"]
             )

    on_exit(import.cleanup)

    refute Map.has_key?(import.tool_kinds, "annotated_destructive")
    assert import.tool_kinds["note_annotated_destructive"] == "delete"
    assert import.tool_kinds["note_annotated_read"] == "read"
    assert :ok = import.cleanup.()
  end

  test "a tool kind is derived from the annotation hints, or from nothing at all" do
    assert Imp.ACP.ToolKind.derive(%{"readOnlyHint" => true}) == "read"
    assert Imp.ACP.ToolKind.derive(%{readOnlyHint: true, openWorldHint: false}) == "think"

    assert Imp.ACP.ToolKind.derive(%{"readOnlyHint" => false, "destructiveHint" => true}) ==
             "delete"

    assert Imp.ACP.ToolKind.derive(%{"readOnlyHint" => false, "destructiveHint" => false}) ==
             "execute"

    # MCP's own default for an absent destructiveHint on a write is true.
    assert Imp.ACP.ToolKind.derive(%{"readOnlyHint" => false}) == "delete"

    # Undeclared is not a classification. The caller falls back rather than
    # receiving a guess dressed as a declaration.
    assert Imp.ACP.ToolKind.derive(nil) == nil
    assert Imp.ACP.ToolKind.derive(%{}) == nil
    assert Imp.ACP.ToolKind.derive(%{"title" => "Pretty name"}) == nil
    assert Imp.ACP.ToolKind.derive("readOnlyHint") == nil

    assert Imp.ACP.ToolKind.derive_all(%{"a" => %{"readOnlyHint" => true}, "b" => %{}}) ==
             %{"a" => "read"}

    assert Imp.ACP.ToolKind.derive_all(nil) == %{}
  end

  test "a program factory's derived tool kinds classify a tool call card" do
    test_pid = self()

    tool =
      Imp.tool(:external, "external effect", fn _args ->
        send(test_pid, :derived_effect)
        "ok"
      end)

    program = one_tool_program(tool, "derived")

    {client, _agent} =
      start_pair(
        fn _session ->
          {:ok, program,
           %{tool_kinds: Imp.ACP.ToolKind.derive_all(%{"external" => %{"readOnlyHint" => true}})}}
        end,
        permission_policy: :unrestricted
      )

    {:ok, %{"sessionId" => session_id}} = Client.new_session(client, "/tmp/project")

    assert {:ok, %{"stopReason" => "end_turn", "text" => "derived"}} =
             Client.prompt(client, session_id, "run it")

    assert_receive :derived_effect

    updates = receive_updates(session_id, [])
    assert [%{"kind" => "read"} | _] = tool_updates(updates)
  end

  test "a tool kind declared by name outranks the kind derived from annotations" do
    test_pid = self()

    tool =
      Imp.tool(:external, "external effect", fn _args ->
        send(test_pid, :override_effect)
        "ok"
      end)

    program = one_tool_program(tool, "overridden")

    {client, _agent} =
      start_pair(
        fn _session ->
          {:ok, program, %{tool_kinds: %{"external" => "read"}}}
        end,
        permission_policy: :unrestricted,
        agent_opts: [tool_kinds: %{external: :search}]
      )

    {:ok, %{"sessionId" => session_id}} = Client.new_session(client, "/tmp/project")

    assert {:ok, %{"stopReason" => "end_turn", "text" => "overridden"}} =
             Client.prompt(client, session_id, "run it")

    assert_receive :override_effect

    updates = receive_updates(session_id, [])
    assert [%{"kind" => "search"} | _] = tool_updates(updates)
  end

  test "a factory lifecycle map rejects tool kinds that are not ACP kinds" do
    program = one_tool_program(Imp.tool(:external, "e", fn _ -> "ok" end), "unused")

    {client, _agent} =
      start_pair(fn _session -> {:ok, program, %{tool_kinds: %{"external" => "mutate"}}} end,
        permission_policy: :unrestricted
      )

    assert {:error, _reason} = Client.new_session(client, "/tmp/project")
  end

  test "authorized Streamable HTTP MCP tools cross ExMCP transport into Imp.Tool values" do
    workspace_name = Path.basename(File.cwd!())
    port = free_port()
    ref = {:imp_acp_http_mcp_test, port}

    assert {:ok, _server} =
             Imp.ACP.DemoMCPServer.start_link(
               transport: :http,
               port: port,
               use_sse: false,
               ranch_ref: ref
             )

    on_exit(fn -> Plug.Cowboy.shutdown(ref) end)

    server = %{
      "name" => "imp-acp-demo-http",
      "type" => "http",
      "url" => "http://127.0.0.1:#{port}",
      "headers" => []
    }

    assert {:ok, %Imp.ACP.MCP.Import{tools: [tool], cleanup: cleanup}} =
             Imp.ACP.MCP.import_tools([server],
               cwd: File.cwd!(),
               trusted_servers: [server]
             )

    on_exit(cleanup)
    assert to_string(tool.name) == "external_workspace_name"
    assert Imp.Tool.call(tool, %{}) == workspace_name
    assert :ok = cleanup.()

    # A name the program has already taken is refused, not renamed: the tool a
    # caller addresses must be the one its declaration named.
    assert {:error, {:mcp_tool_name_collision, "external_workspace_name", ["imp-acp-demo-http"]}} =
             Imp.ACP.MCP.import_tools([server],
               cwd: File.cwd!(),
               trusted_servers: [server],
               reserved_tool_names: ["external_workspace_name"]
             )

    # The declaration says what to call it instead.
    prefixed = Map.put(server, "tool_prefix", "demo_")

    assert {:ok, %Imp.ACP.MCP.Import{tools: [prefixed_tool], cleanup: prefixed_cleanup}} =
             Imp.ACP.MCP.import_tools([prefixed],
               cwd: File.cwd!(),
               trusted_servers: [prefixed],
               reserved_tool_names: ["external_workspace_name"]
             )

    on_exit(prefixed_cleanup)
    assert to_string(prefixed_tool.name) == "demo_external_workspace_name"
    assert Imp.Tool.call(prefixed_tool, %{}) == workspace_name
    assert :ok = prefixed_cleanup.()
  end

  test "authorized Streamable HTTP MCP credentials reach the server on every request" do
    workspace_name = Path.basename(File.cwd!())
    previous_security = Application.get_env(:ex_mcp, :security)

    Application.put_env(:ex_mcp, :security,
      trusted_origins: [],
      trusted_hosts: [],
      consent_handler: ExMCP.ConsentHandler.Deny,
      enable_token_passthrough_prevention: true,
      enable_user_consent_validation: true
    )

    on_exit(fn ->
      if is_nil(previous_security),
        do: Application.delete_env(:ex_mcp, :security),
        else: Application.put_env(:ex_mcp, :security, previous_security)
    end)

    port = free_port()
    ref = {:imp_acp_authenticated_http_mcp_test, port}
    token = "disposable-integration-token"

    assert {:ok, _server} =
             Plug.Cowboy.http(
               Imp.ACP.DemoMCPHTTPPlug,
               [expected_authorization: "Bearer " <> token, notify: self()],
               port: port,
               ip: {127, 0, 0, 1},
               ref: ref
             )

    on_exit(fn -> Plug.Cowboy.shutdown(ref) end)

    server = %{
      "name" => "imp-acp-authenticated-http",
      "type" => "http",
      "url" => "http://127.0.0.1:#{port}",
      "headers" => [%{"name" => "Authorization", "value" => "Bearer " <> token}]
    }

    assert {:ok, %Imp.ACP.MCP.Import{tools: [tool], cleanup: cleanup}} =
             Imp.ACP.MCP.import_tools([server],
               cwd: File.cwd!(),
               trusted_servers: [server]
             )

    on_exit(cleanup)
    assert_received {:mcp_http_auth, :accepted}
    assert Imp.Tool.call(tool, %{}) == workspace_name
    assert_received {:mcp_http_auth, :accepted}
    assert :ok = cleanup.()

    rejected = put_in(server, ["headers"], [])

    caller = self()

    {:ok, _task} =
      Task.start(fn ->
        Process.flag(:trap_exit, true)

        result =
          Imp.ACP.MCP.import_tools([rejected],
            cwd: File.cwd!(),
            trusted_servers: [rejected]
          )

        send(caller, {:rejected_mcp_import, result})
      end)

    assert_receive {:rejected_mcp_import, {:error, _reason}}

    assert_received {:mcp_http_auth, :rejected}
  end

  test "tools with the same name from independent MCP servers remain addressable" do
    workspace_name = Path.basename(File.cwd!())
    port_a = free_port()
    port_b = free_port()
    ref_a = {:imp_acp_http_mcp_collision_a, port_a}
    ref_b = {:imp_acp_http_mcp_collision_b, port_b}

    assert {:ok, _server_a} =
             Imp.ACP.DemoMCPServer.start_link(
               transport: :http,
               port: port_a,
               use_sse: false,
               ranch_ref: ref_a
             )

    assert {:ok, _server_b} =
             Imp.ACP.DemoMCPServer.start_link(
               transport: :http,
               port: port_b,
               use_sse: false,
               ranch_ref: ref_b
             )

    on_exit(fn -> Plug.Cowboy.shutdown(ref_a) end)
    on_exit(fn -> Plug.Cowboy.shutdown(ref_b) end)

    servers = [
      %{
        "name" => "alpha-tools",
        "type" => "http",
        "url" => "http://127.0.0.1:#{port_a}",
        "headers" => []
      },
      %{
        "name" => "beta.tools",
        "type" => "http",
        "url" => "http://127.0.0.1:#{port_b}",
        "headers" => []
      }
    ]

    # Undeclared, one name claimed twice is a defect in the declaration and
    # refuses, naming both servers and the tool rather than renaming either.
    assert {:error, {:mcp_tool_name_collision, "external_workspace_name", names}} =
             Imp.ACP.MCP.import_tools(servers, cwd: File.cwd!(), trusted_servers: servers)

    assert names == ["alpha-tools", "beta.tools"]

    servers =
      Enum.zip(servers, ["alpha_", "beta_"])
      |> Enum.map(fn {server, prefix} -> Map.put(server, "tool_prefix", prefix) end)

    assert {:ok, %Imp.ACP.MCP.Import{tools: tools, cleanup: cleanup}} =
             Imp.ACP.MCP.import_tools(servers,
               cwd: File.cwd!(),
               trusted_servers: servers
             )

    on_exit(cleanup)

    assert Enum.map(tools, &to_string(&1.name)) == [
             "alpha_external_workspace_name",
             "beta_external_workspace_name"
           ]

    assert Enum.map(tools, &Imp.Tool.call(&1, %{})) == [workspace_name, workspace_name]
    assert :ok = cleanup.()
  end

  # Ownership architecture: clients are adopted by a bridge that monitors
  # :owner. A transient importer may exit without killing tools — even without
  # depending on "remember to unlink" as the ownership story.
  test "MCP clients survive after a spawn_monitor importer exits" do
    workspace_name = Path.basename(File.cwd!())
    port = free_port()
    ref = {:imp_acp_importer_exit_mcp_test, port}

    assert {:ok, _server} =
             Imp.ACP.DemoMCPServer.start_link(
               transport: :http,
               port: port,
               use_sse: false,
               ranch_ref: ref
             )

    on_exit(fn -> Plug.Cowboy.shutdown(ref) end)

    server = %{
      "name" => "imp-acp-importer-exit",
      "type" => "http",
      "url" => "http://127.0.0.1:#{port}",
      "headers" => []
    }

    owner = self()
    parent = self()
    result_ref = make_ref()

    {importer, mon} =
      spawn_monitor(fn ->
        result =
          Imp.ACP.MCP.import_tools([server],
            cwd: File.cwd!(),
            trusted_servers: [server],
            owner: owner
          )

        send(parent, {result_ref, result})
      end)

    assert_receive {^result_ref, {:ok, %Imp.ACP.MCP.Import{tools: [tool], cleanup: cleanup}}},
                   30_000

    on_exit(cleanup)

    assert_receive {:DOWN, ^mon, :process, ^importer, :normal}, 1_000
    refute Process.alive?(importer)

    # Helper is gone; tool must still reach the live MCP client (not noproc).
    assert Imp.Tool.call(tool, %{}) == workspace_name
    assert :ok = cleanup.()
  end

  test "owner death disconnects MCP clients adopted by the session bridge" do
    workspace_name = Path.basename(File.cwd!())
    port = free_port()
    ref = {:imp_acp_owner_death_mcp_test, port}

    assert {:ok, _server} =
             Imp.ACP.DemoMCPServer.start_link(
               transport: :http,
               port: port,
               use_sse: false,
               ranch_ref: ref
             )

    on_exit(fn -> Plug.Cowboy.shutdown(ref) end)

    server = %{
      "name" => "imp-acp-owner-death",
      "type" => "http",
      "url" => "http://127.0.0.1:#{port}",
      "headers" => []
    }

    # Long-lived owner stands in for the ACP session process.
    {:ok, owner} = Agent.start(fn -> :ok end)
    owner_mon = Process.monitor(owner)

    assert {:ok, %Imp.ACP.MCP.Import{tools: [tool], cleanup: cleanup}} =
             Imp.ACP.MCP.import_tools([server],
               cwd: File.cwd!(),
               trusted_servers: [server],
               owner: owner
             )

    assert Imp.Tool.call(tool, %{}) == workspace_name

    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^owner_mon, :process, ^owner, :killed}, 1_000

    # Bridge monitors the owner; session death must drop the live MCP clients.
    assert Enum.any?(1..50, fn _ ->
             case Imp.Tool.call(tool, %{}) do
               {:error, {:mcp_connection_unavailable, _, _}} ->
                 true

               _ ->
                 Process.sleep(20)
                 false
             end
           end),
           "expected MCP clients to disconnect after owner death"

    assert {:error, {:mcp_connection_unavailable, _, _}} = Imp.Tool.call(tool, %{})
    assert :ok = cleanup.()
  end

  test "cleanup disconnects MCP clients while the owner stays alive" do
    workspace_name = Path.basename(File.cwd!())
    port = free_port()
    ref = {:imp_acp_cleanup_disconnect_mcp_test, port}

    assert {:ok, _server} =
             Imp.ACP.DemoMCPServer.start_link(
               transport: :http,
               port: port,
               use_sse: false,
               ranch_ref: ref
             )

    on_exit(fn -> Plug.Cowboy.shutdown(ref) end)

    server = %{
      "name" => "imp-acp-cleanup-disconnect",
      "type" => "http",
      "url" => "http://127.0.0.1:#{port}",
      "headers" => []
    }

    assert {:ok, %Imp.ACP.MCP.Import{tools: [tool], cleanup: cleanup}} =
             Imp.ACP.MCP.import_tools([server],
               cwd: File.cwd!(),
               trusted_servers: [server],
               owner: self()
             )

    assert Imp.Tool.call(tool, %{}) == workspace_name
    assert :ok = cleanup.()
    assert Process.alive?(self())
    assert {:error, {:mcp_connection_unavailable, _, _}} = Imp.Tool.call(tool, %{})
  end

  test "bad MCP connect stays isolated from the caller" do
    server = %{
      "name" => "imp-acp-bad-connect",
      "type" => "http",
      "url" => "http://127.0.0.1:9/mcp",
      "headers" => []
    }

    assert Process.alive?(self())

    assert {:error, _reason} =
             Imp.ACP.MCP.import_tools([server],
               cwd: File.cwd!(),
               trusted_servers: [server],
               timeout: 1_000,
               owner: self()
             )

    assert Process.alive?(self())
  end

  test "an exact ACP MCP descriptor composes through a full authorized agent turn" do
    server = demo_mcp_server()
    workspace_name = Path.basename(File.cwd!())

    factory = fn %{cwd: cwd, mcp_servers: servers} ->
      with {:ok, %Imp.ACP.MCP.Import{tools: tools, cleanup: cleanup}} <-
             Imp.ACP.MCP.import_tools(servers,
               cwd: cwd,
               trusted_servers: [server]
             ) do
        {:ok, mcp_program(tools), cleanup}
      end
    end

    {client, _agent} =
      start_pair(factory, client_handler_opts: [auto_approve_permissions: true])

    {:ok, %{"sessionId" => session_id}} =
      Client.new_session(client, File.cwd!(), mcp_servers: [server])

    expected = "mcp:" <> workspace_name

    assert {:ok, %{"stopReason" => "end_turn", "text" => ^expected}} =
             Client.prompt(client, session_id, "inspect")

    updates = receive_updates(session_id, [])
    [pending, in_progress, completed] = tool_updates(updates)
    assert pending["toolCallId"] == in_progress["toolCallId"]
    assert pending["toolCallId"] == completed["toolCallId"]
    assert {:ok, %{}} = Client.close_session(client, session_id)
  end

  test "ReActV2 history is retained by its ACP session" do
    test_pid = self()

    lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          send(test_pid, {:react_messages, messages})

          %{
            next_thought: "answer",
            tool_calls: [
              %{id: "submit", name: "submit", arguments: %{answer: "ok"}}
            ]
          }
        end
      )

    {client, _agent} =
      start_pair(fn _session ->
        Imp.react_v2("question -> answer", [], lm: lm, max_iters: 1)
      end)

    {:ok, %{"sessionId" => session_id}} = Client.new_session(client, "/tmp/project")
    assert {:ok, %{"stopReason" => "end_turn"}} = Client.prompt(client, session_id, "first")
    assert_receive {:react_messages, first_messages}
    refute inspect(first_messages) =~ "answer: \"ok\""

    assert {:ok, %{"stopReason" => "end_turn"}} = Client.prompt(client, session_id, "second")
    assert_receive {:react_messages, second_messages}
    assert inspect(second_messages) =~ "first"
    assert inspect(second_messages) =~ "answer: \"ok\""
  end

  test "durable ReAct sessions list, load, replay, continue, and delete across agent restart" do
    test_pid = self()

    root =
      Path.join(System.tmp_dir!(), "imp-acp-durable-#{System.unique_integer([:positive])}")

    workspace = Path.join(root, "workspace")
    store = Path.join(root, "sessions")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(root) end)

    lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          send(test_pid, {:durable_react_messages, messages})

          %{
            next_thought: "answer",
            tool_calls: [%{id: "submit", name: "submit", arguments: %{answer: "ok"}}]
          }
        end
      )

    factory = fn _session -> Imp.react_v2("question -> answer", [], lm: lm, max_iters: 1) end

    {first_client, first_agent} =
      start_pair(factory,
        permission_policy: :unrestricted,
        agent_opts: [session_store: store]
      )

    assert {:ok, %{"sessionId" => session_id}} = Client.new_session(first_client, workspace)

    assert {:ok, %{"stopReason" => "end_turn", "text" => "ok"}} =
             Client.prompt(first_client, session_id, "first")

    assert_receive {:durable_react_messages, first_messages}
    refute inspect(first_messages) =~ "answer: \"ok\""

    stop_if_alive(first_client)
    stop_if_alive(first_agent)

    {second_client, _second_agent} =
      start_pair(factory,
        permission_policy: :unrestricted,
        agent_opts: [session_store: store]
      )

    assert {:ok, %{"sessions" => [listed]}} =
             Client.list_sessions(second_client, cwd: workspace)

    assert listed["sessionId"] == session_id
    assert listed["cwd"] == workspace
    assert listed["title"] == "first"

    assert {:ok, %{"sessionId" => ^session_id}} =
             Client.load_session(second_client, session_id, workspace)

    replayed = receive_updates(session_id, [])

    assert Enum.any?(replayed, fn update ->
             update["sessionUpdate"] == "user_message_chunk" and
               get_in(update, ["content", "text"]) == "first"
           end)

    assert Enum.any?(replayed, fn update ->
             update["sessionUpdate"] == "agent_message_chunk" and
               get_in(update, ["content", "text"]) == "ok"
           end)

    assert {:ok, %{"stopReason" => "end_turn", "text" => "ok"}} =
             Client.prompt(second_client, session_id, "second")

    assert_receive {:durable_react_messages, second_messages}
    assert inspect(second_messages) =~ "first"
    assert inspect(second_messages) =~ "answer: \"ok\""

    assert {:ok, %{}} = Client.delete_session(second_client, session_id)
    assert {:ok, %{"sessions" => []}} = Client.list_sessions(second_client, cwd: workspace)
  end

  test "ReActV2 source events become correlated live ACP thought and tool updates" do
    lookup = Imp.tool(:lookup, "lookup", fn %{query: query} -> "found " <> query end)

    lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          %{
            next_thought: "checking the workspace",
            tool_calls: [
              %{id: "lookup-live-1", name: "lookup", arguments: %{query: "beam"}},
              %{id: "submit-live-1", name: "submit", arguments: %{answer: "BEAM"}}
            ]
          }
        end
      )

    {client, _agent} =
      start_pair(
        fn _session -> Imp.react_v2("question -> answer", [lookup], lm: lm) end,
        client_handler_opts: [auto_approve_permissions: true]
      )

    {:ok, %{"sessionId" => session_id}} = Client.new_session(client, "/tmp/project")

    assert {:ok, %{"stopReason" => "end_turn", "text" => "BEAM"}} =
             Client.prompt(client, session_id, "runtime?")

    updates = receive_updates(session_id, [])

    assert [
             %{
               "sessionUpdate" => "agent_thought_chunk",
               "content" => %{"text" => "checking the workspace"}
             },
             %{
               "sessionUpdate" => "tool_call",
               "toolCallId" => tool_call_id,
               "status" => "pending"
             },
             %{
               "sessionUpdate" => "tool_call_update",
               "toolCallId" => authorized_tool_call_id,
               "status" => "in_progress"
             },
             %{
               "sessionUpdate" => "tool_call_update",
               "toolCallId" => result_tool_call_id,
               "status" => "completed"
             },
             %{"sessionUpdate" => "agent_message_chunk", "content" => %{"text" => "BEAM"}}
           ] = updates

    assert tool_call_id == authorized_tool_call_id
    assert tool_call_id == result_tool_call_id
    assert String.ends_with?(tool_call_id, ":lookup-live-1")
    refute Enum.any?(updates, &String.ends_with?(&1["toolCallId"] || "", ":submit-live-1"))
  end

  test "ACP tool-call IDs remain unique when source IDs repeat across session turns" do
    lookup = Imp.tool(:lookup, "lookup", fn %{query: query} -> "found " <> query end)

    lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          %{
            next_thought: "checking",
            tool_calls: [
              %{id: "reused-source-id", name: "lookup", arguments: %{query: "beam"}},
              %{id: "reused-submit-id", name: "submit", arguments: %{answer: "BEAM"}}
            ]
          }
        end
      )

    {client, _agent} =
      start_pair(
        fn _session -> Imp.react_v2("question -> answer", [lookup], lm: lm) end,
        client_handler_opts: [auto_approve_permissions: true]
      )

    {:ok, %{"sessionId" => session_id}} = Client.new_session(client, "/tmp/project")

    assert {:ok, %{"stopReason" => "end_turn"}} = Client.prompt(client, session_id, "first")
    first_updates = receive_updates(session_id, [])

    assert {:ok, %{"stopReason" => "end_turn"}} = Client.prompt(client, session_id, "second")
    second_updates = receive_updates(session_id, [])

    first_call = Enum.find(first_updates, &(&1["sessionUpdate"] == "tool_call"))

    first_result =
      Enum.find(
        first_updates,
        &(&1["sessionUpdate"] == "tool_call_update" and &1["status"] == "completed")
      )

    second_call = Enum.find(second_updates, &(&1["sessionUpdate"] == "tool_call"))

    second_result =
      Enum.find(
        second_updates,
        &(&1["sessionUpdate"] == "tool_call_update" and &1["status"] == "completed")
      )

    assert first_call["toolCallId"] == first_result["toolCallId"]
    assert second_call["toolCallId"] == second_result["toolCallId"]
    refute first_call["toolCallId"] == second_call["toolCallId"]
    assert String.ends_with?(first_call["toolCallId"], ":reused-source-id")
    assert String.ends_with?(second_call["toolCallId"], ":reused-source-id")
  end

  test "a persistent RLM keeps session state and emits correlated live tool updates" do
    {:ok, actions} =
      Agent.start_link(fn ->
        [
          %{
            reasoning: "inspect with a tool",
            code: ~S|scratch = context <> "-derived"
observed = lookup(%{query: context})
submit(%{answer: observed <> ":" <> scratch})|
          },
          %{
            reasoning: "reuse the retained namespace",
            code: ~S|submit(%{answer: context_0 <> ":" <> context_1 <> ":" <> scratch})|
          }
        ]
      end)

    lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          Agent.get_and_update(actions, fn [action | rest] -> {action, rest} end)
        end
      )

    lookup = Imp.tool(:lookup, "lookup", fn %{query: query} -> "found-" <> query end)

    {client, _agent} =
      start_pair(
        fn _session ->
          Imp.rlm("context -> answer",
            lm: lm,
            tools: [lookup],
            persistent: true,
            max_iterations: 1
          )
        end,
        client_handler_opts: [auto_approve_permissions: true]
      )

    {:ok, %{"sessionId" => session_id}} = Client.new_session(client, "/tmp/project")

    assert {:ok, %{"text" => "found-first:first-derived"}} =
             Client.prompt(client, session_id, "first")

    first_updates = receive_updates(session_id, [])
    call = Enum.find(first_updates, &(&1["sessionUpdate"] == "tool_call"))

    result =
      Enum.find(
        first_updates,
        &(&1["sessionUpdate"] == "tool_call_update" and &1["status"] == "completed")
      )

    assert call["toolCallId"] == result["toolCallId"]
    assert call["title"] == "Run lookup"
    refute Map.has_key?(call, "name")
    assert result["status"] == "completed"

    assert {:ok, %{"text" => "first:second:first-derived"}} =
             Client.prompt(client, session_id, "second")

    assert {:ok, %{}} = Client.close_session(client, session_id)
  end

  test "cold stdio startup emits only ACP JSON on stdout" do
    input_path =
      Path.join(
        System.tmp_dir!(),
        "imp-acp-initialize-#{System.unique_integer([:positive])}.jsonl"
      )

    initialize = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{"protocolVersion" => 1, "clientCapabilities" => %{}}
    }

    File.write!(input_path, Jason.encode!(initialize) <> "\n")
    on_exit(fn -> File.rm(input_path) end)

    {stdout, 0} =
      System.cmd(
        "sh",
        ["-c", ~S|scripts/imp-acp-rich-demo < "$1"|, "imp-acp-cold-stdio", input_path],
        cd: File.cwd!(),
        env: [{"MIX_ENV", "test"}]
      )

    assert [line] = String.split(stdout, "\n", trim: true)

    assert %{
             "jsonrpc" => "2.0",
             "id" => 1,
             "result" => %{"protocolVersion" => 1}
           } = Jason.decode!(line)
  end

  # ACP's `_meta` is the extension point for per-session data the protocol does
  # not model, and the only thing in `session/new` a host can use to say which
  # of several configurations this session wants. Dropped, that choice has
  # nowhere to live but the launch environment, which means one process per
  # configuration whether or not the endpoint needs one.
  test "the session map carries `_meta` from session/new through to the factory" do
    test_pid = self()

    factory = fn session ->
      send(test_pid, {:factory_session, session})
      echo_program(test_pid)
    end

    {:ok, state} =
      Imp.ACP.Handler.init(
        program_factory: factory,
        input_key: :question,
        output_key: :answer,
        session_store: nil
      )

    context = %{agent: self(), client_capabilities: %{}}

    params = %{
      "cwd" => "/tmp/project",
      "mcpServers" => [],
      "_meta" => %{"example" => %{"choice" => "second"}}
    }

    assert {:reply, %{"sessionId" => _}, _state} =
             Imp.ACP.Handler.handle_new_session(params, context, state)

    assert_receive {:factory_session, session}
    assert session.meta == %{"example" => %{"choice" => "second"}}
    assert session.cwd == "/tmp/project"

    # A request without `_meta` still gets the key, with nothing in it, so a
    # factory reads one shape rather than matching on absence.
    assert {:reply, %{"sessionId" => _}, _state} =
             Imp.ACP.Handler.handle_new_session(
               %{"cwd" => "/tmp/project", "mcpServers" => []},
               context,
               state
             )

    assert_receive {:factory_session, %{meta: %{}}}
  end

  # A session's `_meta` is what it is, not what the request that resumed it says.
  # The history and transcript were produced under the stored one, so a resume
  # that redefines it would replay one configuration's conversation as another's
  # — a silent wrong answer. The stored value wins and the request's is handed
  # over separately, because only the factory knows which of its own keys are
  # identity-bearing and which may vary between connections.
  test "a restored session keeps the `_meta` it was created with" do
    store = Path.join(System.tmp_dir!(), "imp_acp_meta_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(store) end)
    workspace = Path.expand(System.tmp_dir!())

    test_pid = self()

    factory = fn session ->
      send(test_pid, {:factory_session, session})
      echo_program(test_pid)
    end

    opts = [
      program_factory: factory,
      input_key: :question,
      output_key: :answer,
      session_store: store
    ]

    context = %{agent: self(), client_capabilities: %{}}
    created = %{"first" => %{"choice" => "second"}}

    {:ok, state} = Imp.ACP.Handler.init(opts)

    assert {:reply, %{"sessionId" => session_id}, _state} =
             Imp.ACP.Handler.handle_new_session(
               %{"cwd" => workspace, "mcpServers" => [], "_meta" => created},
               context,
               state
             )

    assert_receive {:factory_session, %{meta: ^created, requested_meta: ^created}}

    # A fresh handler is the restart this store exists for.
    {:ok, restarted} = Imp.ACP.Handler.init(opts)
    contradiction = %{"first" => %{"choice" => "something else"}}

    assert {:reply, %{"sessionId" => ^session_id}, _state} =
             Imp.ACP.Handler.handle_load_session(
               %{"sessionId" => session_id, "cwd" => workspace, "_meta" => contradiction},
               context,
               restarted
             )

    assert_receive {:factory_session, restored}
    assert restored.meta == created
    assert restored.requested_meta == contradiction

    # The ordinary resume names nothing, and still gets what it was.
    {:ok, restarted} = Imp.ACP.Handler.init(opts)

    assert {:reply, %{"sessionId" => ^session_id}, _state} =
             Imp.ACP.Handler.handle_resume_session(
               %{"sessionId" => session_id, "cwd" => workspace},
               context,
               restarted
             )

    assert_receive {:factory_session, %{meta: ^created, requested_meta: %{}}}
  end

  # A record written before sessions carried `_meta` has no place to have stored
  # one. It must resume as it always did rather than be refused for a field it
  # could not have written.
  test "a session stored before `_meta` existed resumes with none" do
    store = Path.join(System.tmp_dir!(), "imp_acp_meta_old_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(store) end)
    workspace = Path.expand(System.tmp_dir!())

    test_pid = self()

    opts = [
      program_factory: fn session ->
        send(test_pid, {:factory_session, session})
        echo_program(test_pid)
      end,
      input_key: :question,
      output_key: :answer,
      session_store: store
    ]

    context = %{agent: self(), client_capabilities: %{}}
    {:ok, state} = Imp.ACP.Handler.init(opts)

    assert {:reply, %{"sessionId" => session_id}, _state} =
             Imp.ACP.Handler.handle_new_session(
               %{"cwd" => workspace, "mcpServers" => []},
               context,
               state
             )

    assert_receive {:factory_session, _}

    path = Path.join(store, session_id <> ".json")
    record = path |> File.read!() |> Jason.decode!() |> Map.delete("meta")
    File.write!(path, Jason.encode!(record))

    {:ok, restarted} = Imp.ACP.Handler.init(opts)

    assert {:reply, %{"sessionId" => ^session_id}, _state} =
             Imp.ACP.Handler.handle_resume_session(
               %{"sessionId" => session_id, "cwd" => workspace},
               context,
               restarted
             )

    assert_receive {:factory_session, %{meta: %{}}}
  end

  defp start_pair(factory, opts \\ []) do
    {:ok, peer} = Memory.new_pair()

    {permission_policy, opts} = Keyword.pop(opts, :permission_policy, :client)
    {authorization_timeout, opts} = Keyword.pop(opts, :authorization_timeout, 3_600_000)
    {agent_opts, opts} = Keyword.pop(opts, :agent_opts, [])
    {client_handler_opts, client_opts} = Keyword.pop(opts, :client_handler_opts, [])

    {:ok, agent} =
      Imp.ACP.start_link(
        agent_opts ++
          [
            program_factory: factory,
            permission_policy: permission_policy,
            authorization_timeout: authorization_timeout,
            transport: {:memory, peer},
            pending_request_timeout: 5_000
          ]
      )

    {:ok, client} =
      Client.start_link(
        [
          transport_mod: Memory,
          peer: peer,
          role: :client,
          event_listener: self(),
          handler_opts: client_handler_opts
        ] ++ client_opts
      )

    on_exit(fn ->
      stop_if_alive(client)
      stop_if_alive(agent)
    end)

    {client, agent}
  end

  defp echo_program(test_pid) do
    %EchoProgram{signature: Imp.signature("question -> answer"), test_pid: test_pid}
  end

  defp blocking_program(test_pid) do
    %BlockingProgram{signature: Imp.signature("question -> answer"), test_pid: test_pid}
  end

  defp delayed_program(test_pid) do
    %DelayedProgram{signature: Imp.signature("question -> answer"), test_pid: test_pid}
  end

  defp one_tool_program(tool, answer) do
    lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          %{
            next_thought: "request the effect",
            tool_calls: [
              %{id: "external-call", name: "external", arguments: %{value: "x"}},
              %{id: "submit-call", name: "submit", arguments: %{answer: answer}}
            ]
          }
        end
      )

    Imp.react_v2("question -> answer", [tool], lm: lm, max_iters: 1)
  end

  defp mcp_program(tools) do
    lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          case Enum.find(messages, &(Map.get(&1, :role) == :tool)) do
            nil ->
              %{
                next_thought: "ask MCP",
                tool_calls: [
                  %{id: "mcp-call", name: "external_workspace_name", arguments: %{}}
                ]
              }

            %{content: content} ->
              %{
                next_thought: "submit MCP observation",
                tool_calls: [
                  %{id: "mcp-submit", name: "submit", arguments: %{answer: "mcp:#{content}"}}
                ]
              }
          end
        end
      )

    Imp.react_v2("question -> answer", tools, lm: lm, max_iters: 2)
  end

  defp host_program(host) do
    {:ok, step} = Agent.start_link(fn -> 0 end)

    lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          case Agent.get_and_update(step, &{&1, &1 + 1}) do
            0 ->
              tool_turn("read through the host", "read_file", "host-read", %{
                path: "README.md",
                line_start: 1,
                line_count: 2
              })

            1 ->
              tool_turn("write through the host", "write_file", "host-write", %{
                path: "notes.txt",
                content: "hello\n"
              })

            2 ->
              tool_turn("check through the host", "run_command", "host-command", %{
                command: "mix",
                args: ["test"]
              })

            _ ->
              tool_turn("finish", "submit", "host-submit", %{
                answer: "host capabilities complete"
              })
          end
        end
      )

    program =
      Imp.react_v2("question -> answer", Imp.ACP.Host.tools(host), lm: lm, max_iters: 4)

    {:ok, program, fn -> if Process.alive?(step), do: Agent.stop(step) end}
  end

  defp tool_turn(thought, name, id, arguments) do
    %{next_thought: thought, tool_calls: [%{id: id, name: name, arguments: arguments}]}
  end

  defp demo_mcp_server do
    mix = System.find_executable("mix") || flunk("mix executable is required")
    env = [%{"name" => "MIX_ENV", "value" => "test"}]

    env =
      case System.get_env("IMP_PATH") do
        path when is_binary(path) and path != "" ->
          env ++ [%{"name" => "IMP_PATH", "value" => path}]

        _unset ->
          env
      end

    env =
      case System.get_env("EX_MCP_PATH") do
        path when is_binary(path) and path != "" ->
          env ++ [%{"name" => "EX_MCP_PATH", "value" => path}]

        _unset ->
          env
      end

    %{
      "name" => "demo-tools",
      "type" => "stdio",
      "command" => mix,
      "args" => ["imp_acp.demo_mcp_server"],
      "env" => env
    }
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp stop_if_alive(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end

  defp receive_updates(session_id, updates) do
    receive do
      {:acp_session_update, ^session_id, update} ->
        receive_updates(session_id, updates ++ [update])
    after
      0 -> updates
    end
  end

  defp tool_updates(updates) do
    Enum.filter(updates, &(&1["sessionUpdate"] in ["tool_call", "tool_call_update"]))
  end

  defp receive_host_permissions(session_id, permissions) do
    receive do
      {:host_permission, ^session_id, tool_call, _options} ->
        receive_host_permissions(session_id, permissions ++ [tool_call])
    after
      0 -> permissions
    end
  end

  defp assert_eventually(fun, attempts \\ 50)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition did not become true")
end
