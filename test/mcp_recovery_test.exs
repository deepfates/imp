defmodule MCPRecoveryTest do
  use ExUnit.Case, async: true

  alias Imp.MCP

  defmodule ScriptedTransport do
    @behaviour Imp.HTTP

    @impl true
    def post(url, headers, body, opts) do
      request = Jason.decode!(body)
      method = request["method"]
      owner = Keyword.fetch!(opts, :test_pid)
      send(owner, {:mcp_attempt, self(), url, headers, request, opts})

      action =
        Agent.get_and_update(Keyword.fetch!(opts, :script), fn script ->
          case Map.get(script, method, []) do
            [action | rest] -> {action, Map.put(script, method, rest)}
            [] -> {:ok, script}
          end
        end)

      respond(action, method, request, owner)
    end

    defp respond(:ok, "tools/list", request, _owner) do
      # MCP spec, Tool definition: camelCase "inputSchema"; "description" is
      # optional and omitted here so recovery paths exercise the spec dialect.
      response = %{
        "jsonrpc" => "2.0",
        "id" => request["id"],
        "result" => %{
          "tools" => [
            %{
              "name" => "recoverable",
              "inputSchema" => %{"type" => "object"}
            }
          ]
        }
      }

      ok(response)
    end

    defp respond(:ok, "tools/call", request, _owner) do
      ok(%{"jsonrpc" => "2.0", "id" => request["id"], "result" => %{"ok" => true}})
    end

    defp respond(:ok, _method, request, _owner) do
      ok(%{"jsonrpc" => "2.0", "id" => request["id"], "result" => %{}})
    end

    defp respond({:http, status, headers}, _method, _request, _owner) do
      {:ok, %{status: status, headers: headers, body: "scripted fault"}}
    end

    defp respond({:error, reason}, _method, _request, _owner), do: {:error, reason}

    defp respond(:block, _method, _request, owner) do
      port = Port.open({:spawn_executable, "/bin/cat"}, [:binary])
      send(owner, {:blocking_transport, self(), port})

      receive do
        :release -> {:error, :closed}
      end
    end

    defp ok(body),
      do:
        {:ok,
         %{
           status: 200,
           headers: [{"content-type", "application/json"}],
           body: Jason.encode!(body)
         }}
  end

  test "safe requests retry bounded transient responses with one JSON-RPC id" do
    telemetry_ref =
      Imp.Test.TelemetryHelpers.attach([[:imp, :mcp, :streamable_http, :attempt]])

    client =
      client(
        %{
          "tools/list" => [
            {:http, 429, [{"retry-after", "1"}]},
            {:http, 503, [{"Retry-After", "0"}]},
            :ok
          ]
        },
        max_retry_after: 10
      )

    started = System.monotonic_time(:millisecond)
    assert [tool] = MCP.import_tools(client)
    elapsed = System.monotonic_time(:millisecond) - started
    assert tool.name == :recoverable
    assert elapsed >= 8
    assert elapsed < 500

    attempts = receive_method_attempts("tools/list", 3)
    assert Enum.map(attempts, & &1.request["id"]) |> Enum.uniq() |> length() == 1
    assert Enum.all?(attempts, &(Keyword.fetch!(&1.opts, :retry) == false))
    assert Enum.all?(attempts, &(Keyword.fetch!(&1.opts, :timeout) == 100))

    assert_receive {^telemetry_ref, [:imp, :mcp, :streamable_http, :attempt], _,
                    %{method: "tools/list"} = metadata}

    refute Map.has_key?(metadata, :url)
    refute Map.has_key?(metadata, :body)
    refute Map.has_key?(metadata, :headers)
    assert metadata.replay == :idempotent
    assert metadata.outcome in [{:http, 429}, {:http, 503}, {:http, 200}]
  end

  test "ambiguous tools/call failures are not replayed without an idempotency contract" do
    client = client(%{"tools/call" => [{:error, :closed}, :ok]})
    [tool] = MCP.import_tools(client)

    assert {:error, :closed} = Imp.Tool.call(tool, %{"secret_argument" => "do-not-emit"})
    assert [_attempt] = receive_method_attempts("tools/call", 1)
    refute_receive {:mcp_attempt, _, _, _, %{"method" => "tools/call"}, _}, 50
  end

  test "a stable idempotency key permits bounded tools/call replay" do
    client =
      client(%{"tools/call" => [{:error, :closed}, :ok]},
        idempotency_key: fn
          "tools/call", %{"name" => name} -> "tool:#{name}:request-1"
          _method, _params -> nil
        end
      )

    [tool] = MCP.import_tools(client)
    assert %{"ok" => true} = Imp.Tool.call(tool, %{})

    attempts = receive_method_attempts("tools/call", 2)
    assert Enum.map(attempts, & &1.request["id"]) |> Enum.uniq() |> length() == 1

    assert Enum.all?(attempts, fn attempt ->
             {"idempotency-key", "tool:recoverable:request-1"} in attempt.headers
           end)
  end

  test "attempt timeout closes its local port and terminates the attempt task" do
    parent = self()

    client =
      client(%{"initialize" => [:block, :ok]},
        max_attempts: 2,
        timeout: 20,
        idempotency_key: fn "initialize", _params -> "initialize-request-1" end
      )

    caller =
      spawn(fn ->
        result = MCP.import_tools(client)
        send(parent, {:import_result, result})
      end)

    caller_ref = Process.monitor(caller)
    assert_receive {:blocking_transport, attempt, port}, 1_000
    attempt_ref = Process.monitor(attempt)

    assert_receive {:import_result, [%Imp.Tool{name: :recoverable}]}, 500
    assert_receive {:DOWN, ^attempt_ref, :process, ^attempt, _reason}, 500
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :normal}, 500
    eventually(fn -> Port.info(port) == nil end)

    attempts = receive_method_attempts("initialize", 2)
    assert Enum.map(attempts, & &1.request["id"]) |> Enum.uniq() |> length() == 1
  end

  test "caller cancellation cascades to the active attempt task and port" do
    client = client(%{"initialize" => [:block]}, max_attempts: 1, timeout: 5_000)
    caller = spawn(fn -> MCP.import_tools(client) end)
    caller_ref = Process.monitor(caller)

    assert_receive {:blocking_transport, attempt, port}, 1_000
    attempt_ref = Process.monitor(attempt)
    Process.exit(caller, :kill)

    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :killed}, 500
    assert_receive {:DOWN, ^attempt_ref, :process, ^attempt, _reason}, 500
    eventually(fn -> Port.info(port) == nil end)
  end

  test "recovery options reject unbounded or malformed policies" do
    assert_raise ArgumentError, ~r/max_attempts.*positive integer/, fn ->
      MCP.HTTPClient.new("https://mcp.example", max_attempts: 0)
    end

    assert_raise ArgumentError, ~r/idempotency_key.*arity-2 function/, fn ->
      MCP.StreamableHTTPClient.new("https://mcp.example", idempotency_key: fn _ -> "key" end)
    end
  end

  defp client(script, opts \\ []) do
    script = start_supervised!({Agent, fn -> script end})

    MCP.StreamableHTTPClient.new(
      "https://user:password@mcp.example/stream?token=secret",
      Keyword.merge(
        [
          transport: ScriptedTransport,
          transport_opts: [test_pid: self(), script: script],
          max_attempts: 3,
          timeout: 100,
          retry_delay: 0,
          max_retry_after: 0
        ],
        opts
      )
    )
  end

  defp receive_method_attempts(method, count, attempts \\ [])

  defp receive_method_attempts(_method, 0, attempts), do: Enum.reverse(attempts)

  defp receive_method_attempts(method, count, attempts) do
    receive do
      {:mcp_attempt, pid, url, headers, %{"method" => ^method} = request, opts} ->
        attempt = %{pid: pid, url: url, headers: headers, request: request, opts: opts}
        receive_method_attempts(method, count - 1, [attempt | attempts])

      {:mcp_attempt, _pid, _url, _headers, _request, _opts} ->
        receive_method_attempts(method, count, attempts)
    after
      500 -> flunk("timed out waiting for #{count} #{method} attempt(s)")
    end
  end

  defp eventually(fun, attempts \\ 20)
  defp eventually(_fun, 0), do: flunk("condition did not become true")

  defp eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
