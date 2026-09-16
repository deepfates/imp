defmodule Imp.MCPOAuthTest.AnonymousPlug do
  @moduledoc false
  # Answers MCP regardless of Authorization, and reports what it was sent, so a
  # test can tell "connected with no header" apart from "did not connect".

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts) do
    %{
      notify: Keyword.fetch!(opts, :notify),
      mcp:
        ExMCP.HttpPlug.init(
          handler: Imp.ACP.DemoMCPServer,
          server_info: %{name: "imp-mcp-auth-fixture", version: "0.1.0"},
          allowed_hosts: ["localhost", "127.0.0.1", "::1"],
          allowed_origins: :any
        )
    }
  end

  @impl true
  def call(conn, opts) do
    send(opts.notify, {:authorization, get_req_header(conn, "authorization")})
    ExMCP.HttpPlug.call(conn, opts.mcp)
  end
end

defmodule Imp.MCPOAuthTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Imp.MCP.OAuth

  @moduletag capture_log: true

  setup_all do
    {:ok, _started} = Application.ensure_all_started(:ex_mcp)
    {:ok, _inets} = Application.ensure_all_started(:inets)
    :ok
  end

  setup do
    on_exit(fn -> System.delete_env("IMP_TEST_MCP_KEY") end)
    System.delete_env("IMP_TEST_MCP_KEY")
    :ok
  end

  @tag :tmp_dir
  test "a browser grant becomes a connection header, and the token stays out of the descriptor, logs and inspect output",
       %{tmp_dir: tmp_dir} do
    %{origin: origin, resource_url: resource_url} = oauth_server()
    store = OAuth.store(directory: tmp_dir, secret: :crypto.strong_rand_bytes(32))

    assert {:ok, pending} = OAuth.begin(store, resource_url, credential: "workspace")

    query = pending.authorization_url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    assert query["redirect_uri"] == pending.redirect_uri
    assert String.starts_with?(pending.redirect_uri, "http://127.0.0.1:")
    assert query["code_challenge_method"] == "S256"
    assert is_binary(query["code_challenge"])
    assert is_binary(query["state"])

    :ok = authorize_in_browser(origin, query)

    assert {:ok, "workspace"} = OAuth.await(pending, 30_000)
    assert OAuth.stored?(store, "workspace")

    assert {:ok, {"Authorization", "Bearer " <> access_token}} =
             OAuth.authorization_header(store, "workspace")

    assert access_token != ""

    server = %{
      "name" => "protected-workspace",
      "type" => "http",
      "url" => resource_url,
      "auth" => %{"type" => "oauth", "credential" => "workspace"}
    }

    log =
      capture_log(fn ->
        assert {:ok, imported} =
                 Imp.MCP.connect([server], trusted_servers: [server], credentials: store)

        assert Enum.map(imported.tools, & &1.name) == ["external_workspace_name"]
        send(self(), {:provenance, imported.provenance})
        imported.cleanup.()
      end)

    assert_received {:provenance, provenance}

    # The token reaches the transport and nothing else: not the descriptor the
    # authorization callback and provenance see, not the log, not inspect.
    refute inspect(server) =~ access_token
    refute inspect(provenance) =~ access_token
    refute log =~ access_token
    refute inspect(store) =~ access_token
    refute inspect(pending) =~ access_token
    refute inspect(store) =~ Base.encode16(store.key, case: :lower)

    stored_bytes = File.read!(credential_path(tmp_dir, "workspace"))
    assert :binary.match(stored_bytes, access_token) == :nomatch

    assert {:ok, %File.Stat{mode: mode}} = File.stat(credential_path(tmp_dir, "workspace"))
    assert Bitwise.band(mode, 0o077) == 0
  end

  @tag :tmp_dir
  test "a stored grant near expiry is refreshed from its refresh token without the person",
       %{tmp_dir: tmp_dir} do
    # A zero-second lifetime puts every issued token inside the refresh skew.
    %{origin: origin, resource_url: resource_url, state: state} = oauth_server(token_ttl: 0)
    store = OAuth.store(directory: tmp_dir, secret: :crypto.strong_rand_bytes(32))

    assert {:ok, pending} = OAuth.begin(store, resource_url, credential: "workspace")
    query = pending.authorization_url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    :ok = authorize_in_browser(origin, query)
    assert {:ok, "workspace"} = OAuth.await(pending, 30_000)

    granted = Agent.get(state, & &1)
    assert map_size(granted.access_tokens) == 1
    assert map_size(granted.refresh_tokens) == 1
    assert granted.codes == %{}

    assert {:ok, {"Authorization", "Bearer " <> refreshed_token}} =
             OAuth.authorization_header(store, "workspace")

    after_refresh = Agent.get(state, & &1)

    # A second access token exists, the first refresh token was redeemed and
    # replaced, and no new authorization code was issued: no person was asked.
    assert map_size(after_refresh.access_tokens) == 2
    assert Map.keys(after_refresh.refresh_tokens) != Map.keys(granted.refresh_tokens)
    assert map_size(after_refresh.refresh_tokens) == 1
    assert after_refresh.codes == %{}
    assert Map.keys(after_refresh.clients) == Map.keys(granted.clients)
    refute Map.has_key?(granted.access_tokens, refreshed_token)
    assert Map.has_key?(after_refresh.access_tokens, refreshed_token)
  end

  @tag :tmp_dir
  test "a tampered or relabelled credential file is refused whole, never partly decoded",
       %{tmp_dir: tmp_dir} do
    %{origin: origin, resource_url: resource_url} = oauth_server()
    store = OAuth.store(directory: tmp_dir, secret: :crypto.strong_rand_bytes(32))

    assert {:ok, pending} = OAuth.begin(store, resource_url, credential: "workspace")
    query = pending.authorization_url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    :ok = authorize_in_browser(origin, query)
    assert {:ok, "workspace"} = OAuth.await(pending, 30_000)
    assert {:ok, {"Authorization", _header}} = OAuth.authorization_header(store, "workspace")

    path = credential_path(tmp_dir, "workspace")
    envelope = path |> File.read!() |> Jason.decode!()

    # The file is a sealed envelope: nothing about the grant is readable, and
    # the reader hands back no partial record.
    assert Map.keys(envelope) |> Enum.sort() == ["ciphertext", "format", "nonce", "tag"]

    <<first, rest::binary>> = Base.decode64!(envelope["ciphertext"])
    flipped = Base.encode64(<<Bitwise.bxor(first, 1), rest::binary>>)
    File.write!(path, Jason.encode!(%{envelope | "ciphertext" => flipped}))

    assert {:error, {:mcp_oauth_credential_tampered, "workspace"}} =
             OAuth.authorization_header(store, "workspace")

    # A credential file moved to another reference is refused too: the
    # reference is authenticated alongside the ciphertext.
    File.write!(path, Jason.encode!(envelope))
    File.cp!(path, credential_path(tmp_dir, "other"))

    assert {:error, {:mcp_oauth_credential_tampered, "other"}} =
             OAuth.authorization_header(store, "other")

    assert {:ok, {"Authorization", _still_valid}} =
             OAuth.authorization_header(store, "workspace")

    # Truncation is refused as well, rather than read as far as it parses.
    File.write!(path, binary_part(File.read!(path), 0, 40))

    assert {:error, {:mcp_oauth_credential_tampered, "workspace"}} =
             OAuth.authorization_header(store, "workspace")

    assert {:error, {:mcp_oauth_credential_not_found, "absent"}} =
             OAuth.authorization_header(store, "absent")
  end

  @tag :tmp_dir
  test "the oauth auth form refuses clearly when the host passed no credential store",
       %{tmp_dir: tmp_dir} do
    _store = OAuth.store(directory: tmp_dir, secret: :crypto.strong_rand_bytes(32))

    server = %{
      "name" => "protected-workspace",
      "type" => "http",
      "url" => "https://mcp2.readwise.io/mcp",
      "auth" => %{"type" => "oauth", "credential" => "workspace"}
    }

    assert {:error, {:mcp_auth_unavailable, "protected-workspace", message}} =
             Imp.MCP.connect([server], trusted_servers: [server])

    assert message =~ ":credentials"
  end

  test "bearer_env resolves from the environment and reaches the server" do
    %{url: url} = anonymous_server()
    System.put_env("IMP_TEST_MCP_KEY", "imp-test-secret-key")

    server = %{
      "name" => "exa",
      "type" => "http",
      "url" => url,
      "auth" => %{"type" => "bearer_env", "variable" => "IMP_TEST_MCP_KEY"}
    }

    assert {:ok, imported} = Imp.MCP.connect([server], trusted_servers: [server])
    imported.cleanup.()

    assert_received {:authorization, ["Bearer imp-test-secret-key"]}
  end

  test "an unset bearer_env variable connects with no Authorization header and warns once" do
    %{url: url} = anonymous_server()

    server = %{
      "name" => "exa",
      "type" => "http",
      "url" => url,
      "auth" => %{"type" => "bearer_env", "variable" => "IMP_TEST_MCP_KEY"}
    }

    log =
      capture_log(fn ->
        assert {:ok, imported} = Imp.MCP.connect([server], trusted_servers: [server])
        assert Enum.map(imported.tools, & &1.name) == ["external_workspace_name"]
        imported.cleanup.()
      end)

    assert_received {:authorization, []}

    assert log =~ "IMP_TEST_MCP_KEY"
    assert log =~ "exa"
    assert log =~ "no Authorization header"
    assert length(String.split(log, "IMP_TEST_MCP_KEY")) == 2
  end

  test "an unset bearer_env variable marked required refuses and names the variable" do
    %{url: url} = anonymous_server()

    server = %{
      "name" => "exa",
      "type" => "http",
      "url" => url,
      "auth" => %{
        "type" => "bearer_env",
        "variable" => "IMP_TEST_MCP_KEY",
        "required" => true
      }
    }

    assert {:error, {:mcp_auth_unavailable, "exa", message}} =
             Imp.MCP.connect([server], trusted_servers: [server])

    assert message =~ "IMP_TEST_MCP_KEY"
    refute_received {:authorization, _headers}
  end

  test "static headers keep working unchanged" do
    %{url: url} = anonymous_server()

    server = %{
      "name" => "static",
      "type" => "http",
      "url" => url,
      "headers" => [%{"name" => "Authorization", "value" => "Bearer literal-token"}]
    }

    assert {:ok, imported} = Imp.MCP.connect([server], trusted_servers: [server])
    imported.cleanup.()

    assert_received {:authorization, ["Bearer literal-token"]}
  end

  @tag :tmp_dir
  test "a store refuses a weak secret and a reference that could escape its directory",
       %{tmp_dir: tmp_dir} do
    assert_raise ArgumentError, ~r/at least 32 bytes/, fn ->
      OAuth.store(directory: tmp_dir, secret: "short")
    end

    store = OAuth.store(directory: tmp_dir, secret: :crypto.strong_rand_bytes(32))

    assert {:error, {:invalid_mcp_oauth_credential, "../escape"}} =
             OAuth.authorization_header(store, "../escape")

    assert_raise ArgumentError, ~r/credential reference/, fn ->
      OAuth.begin(store, "https://example.test/mcp", credential: "../escape")
    end
  end

  # -- fixtures --------------------------------------------------------------

  defp oauth_server(opts \\ []) do
    port = free_port()
    origin = "http://127.0.0.1:#{port}"

    {:ok, state} =
      Agent.start_link(fn ->
        %{clients: %{}, codes: %{}, access_tokens: %{}, refresh_tokens: %{}}
      end)

    {:ok, server} =
      Bandit.start_link(
        plug:
          {Imp.ACP.DemoMCPOAuthPlug,
           [origin: origin, state: state, token_ttl: Keyword.get(opts, :token_ttl, 3600)]},
        port: port,
        ip: {127, 0, 0, 1}
      )

    on_exit(fn ->
      if Process.alive?(server), do: Process.exit(server, :shutdown)
    end)

    %{origin: origin, resource_url: origin <> "/mcp", state: state}
  end

  defp anonymous_server do
    port = free_port()
    notify = self()

    {:ok, server} =
      Bandit.start_link(
        plug: {Imp.MCPOAuthTest.AnonymousPlug, [notify: notify]},
        port: port,
        ip: {127, 0, 0, 1}
      )

    on_exit(fn ->
      if Process.alive?(server), do: Process.exit(server, :shutdown)
    end)

    %{url: "http://127.0.0.1:#{port}/mcp"}
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  # Stands in for the person: approves the consent form, then follows the
  # redirect the authorization server returns, which is the loopback listener.
  defp authorize_in_browser(origin, query) do
    form = URI.encode_query(query)

    assert {:ok, {{_version, 302, _reason}, headers, _body}} =
             :httpc.request(
               :post,
               {~c"#{origin}/authorize", [], ~c"application/x-www-form-urlencoded", form},
               [autoredirect: false],
               []
             )

    location =
      Enum.find_value(headers, fn {name, value} ->
        if name |> List.to_string() |> String.downcase() == "location", do: value
      end)

    assert is_list(location)

    assert {:ok, {{_v, 200, _r}, _headers, body}} =
             :httpc.request(:get, {location, []}, [autoredirect: false], [])

    assert List.to_string(body) =~ "Authorization complete"
    :ok
  end

  defp credential_path(directory, credential),
    do: Path.join(directory, credential <> ".credential.json")
end
