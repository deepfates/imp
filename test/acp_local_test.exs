defmodule Imp.ACPLocalTest do
  use ExUnit.Case, async: false
  alias ExMCP.ACP.Client
  @moduletag capture_log: true
  @moduletag :tmp_dir

  defp listener(_tmp_dir, opts \\ []) do
    root = "/tmp/imp-local-#{System.unique_integer([:positive])}"
    path = Path.join([root, "private", "acp.sock"])
    lm = Imp.LM.Static.new(handler: fn _, _ -> %{answer: "hello 🌱"} end)

    {:ok, pid} =
      Imp.ACP.Local.start_link(
        Keyword.merge(
          [
            socket_path: path,
            agent_options: [
              program_factory: fn _ -> {:ok, Imp.predict("question -> answer", lm: lm)} end,
              permission_policy: :unrestricted
            ]
          ],
          opts
        )
      )

    on_exit(fn ->
      stop(pid)
      File.rm_rf(root)
    end)

    {pid, path}
  end

  defp stop(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
  catch
    :exit, _ -> :ok
  end

  defp client(path) do
    {:ok, pid} = Client.start_link(transport_mod: Imp.ACP.Local.Transport, socket_path: path)
    on_exit(fn -> stop(pid) end)
    pid
  end

  test "two ordinary ACP clients attach; disconnecting one preserves listener and other", %{
    tmp_dir: tmp
  } do
    {listener, path} = listener(tmp)
    first = client(path)
    second = client(path)
    assert {:ok, %{"sessionId" => s1}} = Client.new_session(first, tmp)
    assert {:ok, %{"sessionId" => s2}} = Client.new_session(second, tmp)
    assert {:ok, %{"text" => "hello 🌱"}} = Client.prompt(first, s1, "hi")
    GenServer.stop(first)
    assert Process.alive?(listener)
    assert {:ok, %{"text" => "hello 🌱"}} = Client.prompt(second, s2, "still here")
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    assert Bitwise.band(File.stat!(Path.dirname(path)).mode, 0o777) == 0o700
    GenServer.stop(listener)
    refute File.exists?(path)
  end

  test "standard stdio client reaches the service through a separate relay VM", %{tmp_dir: tmp} do
    {listener, path} = listener(tmp)
    elixir = System.find_executable("elixir")
    beams = Path.wildcard(Path.join(Mix.Project.build_path(), "lib/*/ebin"))
    code = "Imp.ACP.Local.relay(" <> inspect(path) <> ")"

    {:ok, relay_client} =
      Client.start_link(
        command: [elixir] ++ Enum.flat_map(beams, fn path -> ["-pa", path] end) ++ ["-e", code]
      )

    on_exit(fn -> stop(relay_client) end)
    assert {:ok, %{"sessionId" => session}} = Client.new_session(relay_client, tmp)
    assert {:ok, %{"text" => "hello 🌱"}} = Client.prompt(relay_client, session, "hello 🦆")
    GenServer.stop(relay_client)
    assert Process.alive?(listener)
  end

  test "failed application cancellation is a refusal on the ACP wire", %{tmp_dir: tmp} do
    parent = self()

    lm =
      Imp.LM.Static.new(
        handler: fn _, _ ->
          send(parent, {:active_worker, self()})

          receive do
            :finish -> %{answer: "done"}
          end
        end
      )

    {_listener, path} =
      listener(tmp,
        agent_options: [
          program: Imp.predict("question -> answer", lm: lm),
          permission_policy: :unrestricted,
          on_cancel: fn _, _ -> {:error, :unavailable} end
        ]
      )

    client = client(path)
    assert {:ok, %{"sessionId" => session}} = Client.new_session(client, tmp)
    prompt = Task.async(fn -> Client.prompt(client, session, "work") end)
    assert_receive {:active_worker, worker}
    assert :ok = Client.cancel(client, session)

    assert {:ok,
            %{
              "stopReason" => "refusal",
              "_meta" => %{
                "imp_acp" => %{
                  "failure" => %{"category" => "cancel_callback_failed", "operation" => "cancel"}
                }
              }
            }} = Task.await(prompt)

    assert Process.alive?(worker)
  end

  test "occupied path is refused without unlinking it", %{tmp_dir: tmp} do
    {listener, path} = listener(tmp)
    Process.flag(:trap_exit, true)
    assert {:error, :socket_path_exists} = Imp.ACP.Local.start_link(socket_path: path)
    assert File.exists?(path)
    assert Process.alive?(listener)
  end

  test "oversized input closes only that attachment", %{tmp_dir: tmp} do
    {listener, path} = listener(tmp, max_frame_bytes: 512)

    {:ok, socket} =
      :gen_tcp.connect({:local, String.to_charlist(path)}, 0, [:binary, active: false])

    :ok = :gen_tcp.send(socket, String.duplicate("x", 1024) <> "\n")
    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1000)
    assert Process.alive?(listener)
    :gen_tcp.close(socket)
  end
end
