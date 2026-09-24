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

defmodule Imp.MCPOAuthTest.FakeAuthServer do
  @moduledoc false
  # An authorization server whose token responses the test controls: whether
  # `expires_in` is present, absent, or a string; whether a refresh token is
  # issued at all; and whether a refresh is answered with `invalid_grant`.
  # State lives in a named Agent because the suite is not async.

  use Plug.Router

  @state Imp.MCPOAuthTest.FakeState

  plug(:match)
  plug(:dispatch)

  def initial_state do
    %{
      expires_in: 0,
      refresh_expires_in: 3600,
      issue_refresh_token: true,
      refresh_mode: :rotate,
      code_grants: 0,
      refresh_grants: 0,
      issued_refresh: nil,
      issued_access: [],
      # "o" serves the authorization server as a tenant issuer `origin/o/`, the
      # way Readwise serves `https://readwise.io/o/`.
      tenant: nil,
      # The `resource` the protected-resource document names; nil is this server.
      resource: nil,
      token_auth: "client_secret_post",
      token_requests: []
    }
  end

  get "/.well-known/oauth-protected-resource/mcp" do
    protected_resource(conn)
  end

  get "/.well-known/oauth-protected-resource" do
    protected_resource(conn)
  end

  get "/.well-known/openid-configuration" do
    authorization_metadata(conn, origin(conn))
  end

  get "/.well-known/oauth-authorization-server" do
    authorization_metadata(conn, origin(conn))
  end

  # A tenant issuer's path-appended locations answer with the host's own
  # document, whose issuer is the host; only the RFC 8414 location names the
  # tenant.
  get "/o/.well-known/openid-configuration" do
    authorization_metadata(conn, origin(conn))
  end

  get "/o/.well-known/oauth-authorization-server" do
    authorization_metadata(conn, origin(conn))
  end

  get "/.well-known/oauth-authorization-server/o" do
    authorization_metadata(conn, origin(conn) <> "/o/")
  end

  post "/register" do
    json(conn, 201, %{
      "client_id" => "imp-test-client",
      "client_secret" => "imp-test-client-secret",
      "token_endpoint_auth_method" => Agent.get(@state, & &1.token_auth)
    })
  end

  post "/token" do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    params = URI.decode_query(body)

    Agent.update(@state, fn state ->
      request = %{
        authorization: Plug.Conn.get_req_header(conn, "authorization"),
        client_secret: params["client_secret"],
        grant_type: params["grant_type"]
      }

      Map.update!(state, :token_requests, &(&1 ++ [request]))
    end)

    case params do
      %{"grant_type" => "authorization_code", "code" => "accepted-code", "code_verifier" => v}
      when is_binary(v) and v != "" ->
        json(conn, 200, issue(:code))

      %{"grant_type" => "refresh_token", "refresh_token" => presented} ->
        state = Agent.get(@state, & &1)

        cond do
          state.refresh_mode == :invalid_grant ->
            json(conn, 400, %{"error" => "invalid_grant"})

          presented != state.issued_refresh ->
            json(conn, 400, %{"error" => "invalid_grant"})

          true ->
            json(conn, 200, issue(:refresh))
        end

      _invalid ->
        json(conn, 400, %{"error" => "invalid_grant"})
    end
  end

  match _ do
    Plug.Conn.send_resp(conn, 404, "not found")
  end

  defp issue(grant) do
    Agent.get_and_update(@state, fn state ->
      counter = state.code_grants + state.refresh_grants + 1
      access = "access-token-#{counter}"
      refresh = if state.issue_refresh_token, do: "refresh-token-#{counter}"

      expires_in =
        case grant do
          :code -> state.expires_in
          :refresh -> state.refresh_expires_in
        end

      body =
        %{
          "access_token" => access,
          "token_type" => "Bearer",
          "scope" => "workspace:read"
        }
        |> maybe_put("refresh_token", refresh)
        |> maybe_put("expires_in", expires_in)

      state =
        state
        |> Map.update!(if(grant == :code, do: :code_grants, else: :refresh_grants), &(&1 + 1))
        |> Map.put(:issued_refresh, refresh)
        |> Map.update!(:issued_access, &(&1 ++ [access]))

      {body, state}
    end)
  end

  defp maybe_put(body, _key, nil), do: body
  defp maybe_put(body, _key, :absent), do: body
  defp maybe_put(body, key, value), do: Map.put(body, key, value)

  defp protected_resource(conn) do
    state = Agent.get(@state, & &1)
    issuer = if state.tenant, do: origin(conn) <> "/#{state.tenant}/", else: origin(conn)

    json(conn, 200, %{
      "resource" => state.resource || origin(conn) <> "/mcp",
      "authorization_servers" => [issuer],
      "scopes_supported" => ["workspace:read"]
    })
  end

  defp authorization_metadata(conn, issuer) do
    origin = origin(conn)

    json(conn, 200, %{
      "issuer" => issuer,
      "authorization_endpoint" => origin <> "/authorize",
      "token_endpoint" => origin <> "/token",
      "registration_endpoint" => origin <> "/register",
      "response_types_supported" => ["code"],
      "grant_types_supported" => ["authorization_code", "refresh_token"],
      "code_challenge_methods_supported" => ["S256"],
      "token_endpoint_auth_methods_supported" => [Agent.get(@state, & &1.token_auth)]
    })
  end

  defp origin(conn), do: "http://127.0.0.1:#{conn.port}"

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
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
  test "a browser grant becomes a connection header, and the token stays out of the descriptor, provenance, inspect output and Imp's own log",
       %{tmp_dir: tmp_dir} do
    %{origin: origin, resource_url: resource_url} = oauth_server()
    store = OAuth.store(directory: tmp_dir, secret: :crypto.strong_rand_bytes(32))

    assert {:ok, pending} = OAuth.begin(store, resource_url, credential: "workspace")

    query = pending.authorization_url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    assert query["redirect_uri"] == pending.redirect_uri
    assert String.starts_with?(pending.redirect_uri, "http://127.0.0.1:")
    assert query["code_challenge_method"] == "S256"
    assert is_binary(query["code_challenge"])
    assert query["state"] == pending.state

    :ok = authorize_in_browser(origin, query)

    assert {:ok, "workspace"} = OAuth.await(pending, 30_000)
    assert OAuth.stored?(store, "workspace")

    assert {:ok, {"Authorization", "Bearer " <> access_token}} =
             OAuth.authorization_header(store, "workspace", resource_url)

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

    # The token reaches the transport and nothing else Imp controls.
    refute inspect(server) =~ access_token
    refute inspect(provenance) =~ access_token
    refute inspect(store) =~ access_token
    refute inspect(pending) =~ access_token
    refute inspect(store) =~ Base.encode16(store.key, case: :lower)

    # This says only that a successful connection logs no token. It is not
    # evidence that a token can never reach a log: once the header is handed to
    # ExMCP.Client it lives in that client's transport state, and an OTP crash
    # report prints that state. The same is true of a static "headers" entry.
    # Redacting it belongs in ExMCP, not here.
    refute log =~ access_token

    stored_bytes = File.read!(credential_path(tmp_dir, "workspace"))
    assert :binary.match(stored_bytes, access_token) == :nomatch

    assert {:ok, %File.Stat{mode: mode}} = File.stat(credential_path(tmp_dir, "workspace"))
    assert Bitwise.band(mode, 0o077) == 0
  end

  @tag :tmp_dir
  test "a credential answers only for the server it was authorized for", %{tmp_dir: tmp_dir} do
    %{origin: origin, resource_url: resource_url} = oauth_server()
    %{url: other_url} = anonymous_server()
    store = OAuth.store(directory: tmp_dir, secret: :crypto.strong_rand_bytes(32))

    assert {:ok, pending} = OAuth.begin(store, resource_url, credential: "workspace")
    query = pending.authorization_url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    :ok = authorize_in_browser(origin, query)
    assert {:ok, "workspace"} = OAuth.await(pending, 30_000)

    assert {:error, {:mcp_oauth_credential_binding_mismatch, "workspace"}} =
             OAuth.authorization_header(store, "workspace", other_url)

    # A descriptor for a different server that names this credential is refused,
    # and that server is never contacted with the token.
    elsewhere = %{
      "name" => "elsewhere",
      "type" => "http",
      "url" => other_url,
      "auth" => %{"type" => "oauth", "credential" => "workspace"}
    }

    assert {:error,
            {:mcp_auth_unavailable, "elsewhere",
             {:mcp_oauth_credential_binding_mismatch, "workspace"}}} =
             Imp.MCP.connect([elsewhere], trusted_servers: [elsewhere], credentials: store)

    refute_received {:authorization, _headers}

    assert {:ok, {"Authorization", _header}} =
             OAuth.authorization_header(store, "workspace", resource_url)
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
             OAuth.authorization_header(store, "workspace", resource_url)

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
  test "a token whose lifetime the server never stated is refreshed rather than repeated",
       %{tmp_dir: tmp_dir} do
    # This server never states a lifetime, on the code grant or on a refresh.
    %{resource_url: resource_url} =
      fake_auth_server(expires_in: :absent, refresh_expires_in: :absent)

    store = OAuth.store(directory: tmp_dir, secret: :crypto.strong_rand_bytes(32))

    assert {:ok, "workspace"} = authorize_without_browser(store, resource_url)
    assert %{code_grants: 1, refresh_grants: 0} = fake_state()

    assert {:ok, {"Authorization", "Bearer " <> first}} =
             OAuth.authorization_header(store, "workspace", resource_url)

    assert {:ok, {"Authorization", "Bearer " <> second}} =
             OAuth.authorization_header(store, "workspace", resource_url)

    # Unknown lifetime is not read as a long one: the token the code grant
    # issued is never handed out, and the same token is never handed out twice.
    assert fake_state().refresh_grants == 2
    assert first == "access-token-2"
    assert second == "access-token-3"
    refute first == second
  end

  @tag :tmp_dir
  test "a string expires_in is read as seconds instead of as an unknown lifetime",
       %{tmp_dir: tmp_dir} do
    %{resource_url: resource_url} = fake_auth_server(expires_in: "3600")
    store = OAuth.store(directory: tmp_dir, secret: :crypto.strong_rand_bytes(32))

    assert {:ok, "workspace"} = authorize_without_browser(store, resource_url)

    assert {:ok, {"Authorization", "Bearer access-token-1"}} =
             OAuth.authorization_header(store, "workspace", resource_url)

    assert fake_state().refresh_grants == 0
  end

  @tag :tmp_dir
  test "an expired grant with no refresh token asks for reauthorization", %{tmp_dir: tmp_dir} do
    %{resource_url: resource_url} = fake_auth_server(expires_in: 0, issue_refresh_token: false)
    store = OAuth.store(directory: tmp_dir, secret: :crypto.strong_rand_bytes(32))

    assert {:ok, "workspace"} = authorize_without_browser(store, resource_url)

    assert {:error, {:mcp_oauth_reauthorization_required, "workspace"}} =
             OAuth.authorization_header(store, "workspace", resource_url)

    assert fake_state().refresh_grants == 0
  end

  @tag :tmp_dir
  test "a grant with no expiry and no refresh token is returned as it stands", %{tmp_dir: tmp_dir} do
    %{resource_url: resource_url} =
      fake_auth_server(expires_in: :absent, issue_refresh_token: false)

    store = OAuth.store(directory: tmp_dir, secret: :crypto.strong_rand_bytes(32))
    assert {:ok, "workspace"} = authorize_without_browser(store, resource_url)

    assert {:ok, {"Authorization", "Bearer access-token-1"}} =
             OAuth.authorization_header(store, "workspace", resource_url)
  end

  @tag :tmp_dir
  test "a revoked refresh token asks for reauthorization instead of looking retryable",
       %{tmp_dir: tmp_dir} do
    %{resource_url: resource_url} = fake_auth_server(expires_in: 0)
    store = OAuth.store(directory: tmp_dir, secret: :crypto.strong_rand_bytes(32))

    assert {:ok, "workspace"} = authorize_without_browser(store, resource_url)
    Agent.update(Imp.MCPOAuthTest.FakeState, &Map.put(&1, :refresh_mode, :invalid_grant))

    assert {:error, {:mcp_oauth_reauthorization_required, "workspace"}} =
             OAuth.authorization_header(store, "workspace", resource_url)
  end

  @tag :tmp_dir
  test "concurrent callers redeem one rotating refresh token and all get the same header",
       %{tmp_dir: tmp_dir} do
    %{resource_url: resource_url} = fake_auth_server(expires_in: 0, refresh_expires_in: 3600)
    store = OAuth.store(directory: tmp_dir, secret: :crypto.strong_rand_bytes(32))

    assert {:ok, "workspace"} = authorize_without_browser(store, resource_url)

    headers =
      1..6
      |> Enum.map(fn _index ->
        Task.async(fn -> OAuth.authorization_header(store, "workspace", resource_url) end)
      end)
      |> Task.await_many(30_000)

    # Without serialization the second redeemer presents a refresh token the
    # server has already rotated away, and gets invalid_grant.
    assert Enum.uniq(headers) == [{:ok, {"Authorization", "Bearer access-token-2"}}]
    assert fake_state().refresh_grants == 1
  end

  @tag :tmp_dir
  test "a stray local request cannot consume the loopback listener", %{tmp_dir: tmp_dir} do
    %{origin: origin, resource_url: resource_url} = oauth_server()
    store = OAuth.store(directory: tmp_dir, secret: :crypto.strong_rand_bytes(32))

    assert {:ok, pending} = OAuth.begin(store, resource_url, credential: "workspace")
    callback = URI.parse(pending.redirect_uri)
    base = "http://127.0.0.1:#{callback.port}"

    # A browser probing for a favicon, and a redirect carrying someone else's
    # state, both get 404 and neither is told anything completed.
    for path <- ["/favicon.ico", "/imp/mcp/oauth/callback?code=x&state=not-this-flow"] do
      assert {:ok, {{_version, 404, _reason}, _headers, body}} =
               :httpc.request(:get, {~c"#{base}#{path}", []}, [autoredirect: false], [])

      refute List.to_string(body) =~ "Authorization complete"
    end

    query = pending.authorization_url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    :ok = authorize_in_browser(origin, query)

    assert {:ok, "workspace"} = OAuth.await(pending, 30_000)

    assert {:ok, {"Authorization", _header}} =
             OAuth.authorization_header(store, "workspace", resource_url)
  end

  @tag :tmp_dir
  test "the loopback listener releases its port when the process that began the flow dies",
       %{tmp_dir: tmp_dir} do
    %{resource_url: resource_url} = oauth_server()
    store = OAuth.store(directory: tmp_dir, secret: :crypto.strong_rand_bytes(32))
    test_process = self()

    {owner, monitor} =
      spawn_monitor(fn ->
        {:ok, pending} = OAuth.begin(store, resource_url, credential: "workspace")
        send(test_process, {:redirect_uri, pending.redirect_uri})
      end)

    assert_receive {:redirect_uri, redirect_uri}, 30_000
    assert_receive {:DOWN, ^monitor, :process, ^owner, _reason}, 5_000

    port = redirect_uri |> URI.parse() |> Map.fetch!(:port)
    assert wait_for_closed_port(port), "loopback callback port #{port} stayed bound"
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

  test "an auth value that is not a map says so instead of blaming the transport" do
    server = %{
      "name" => "misconfigured",
      "type" => "http",
      "url" => "https://example.test/mcp",
      "auth" => "oauth"
    }

    assert {:error, {:mcp_auth_unavailable, "misconfigured", message}} =
             Imp.MCP.connect([server], trusted_servers: [server])

    assert message =~ "auth must be a map naming a type"
    refute message =~ "http and sse"
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
  test "a tampered or relabelled credential file is refused whole, never partly decoded",
       %{tmp_dir: tmp_dir} do
    %{origin: origin, resource_url: resource_url} = oauth_server()
    store = OAuth.store(directory: tmp_dir, secret: :crypto.strong_rand_bytes(32))

    assert {:ok, pending} = OAuth.begin(store, resource_url, credential: "workspace")
    query = pending.authorization_url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    :ok = authorize_in_browser(origin, query)
    assert {:ok, "workspace"} = OAuth.await(pending, 30_000)

    assert {:ok, {"Authorization", _header}} =
             OAuth.authorization_header(store, "workspace", resource_url)

    path = credential_path(tmp_dir, "workspace")
    envelope = path |> File.read!() |> Jason.decode!()

    # The file is a sealed envelope: nothing about the grant is readable, and
    # the reader hands back no partial record.
    assert Map.keys(envelope) |> Enum.sort() == ["ciphertext", "format", "nonce", "tag"]

    <<first, rest::binary>> = Base.decode64!(envelope["ciphertext"])
    flipped = Base.encode64(<<Bitwise.bxor(first, 1), rest::binary>>)
    File.write!(path, Jason.encode!(%{envelope | "ciphertext" => flipped}))

    assert {:error, {:mcp_oauth_credential_tampered, "workspace"}} =
             OAuth.authorization_header(store, "workspace", resource_url)

    # A credential file moved to another reference is refused too: the
    # reference is authenticated alongside the ciphertext.
    File.write!(path, Jason.encode!(envelope))
    File.cp!(path, credential_path(tmp_dir, "other"))

    assert {:error, {:mcp_oauth_credential_tampered, "other"}} =
             OAuth.authorization_header(store, "other", resource_url)

    assert {:ok, {"Authorization", _still_valid}} =
             OAuth.authorization_header(store, "workspace", resource_url)

    # Truncation is refused as well, rather than read as far as it parses.
    File.write!(path, binary_part(File.read!(path), 0, 40))

    assert {:error, {:mcp_oauth_credential_tampered, "workspace"}} =
             OAuth.authorization_header(store, "workspace", resource_url)

    assert {:error, {:mcp_oauth_credential_not_found, "absent"}} =
             OAuth.authorization_header(store, "absent", resource_url)
  end

  @tag :tmp_dir
  test "a store refuses a weak secret and a reference that could escape its directory",
       %{tmp_dir: tmp_dir} do
    assert_raise ArgumentError, ~r/at least 32 bytes/, fn ->
      OAuth.store(directory: tmp_dir, secret: "short")
    end

    store = OAuth.store(directory: tmp_dir, secret: :crypto.strong_rand_bytes(32))

    assert {:error, {:invalid_mcp_oauth_credential, "../escape"}} =
             OAuth.authorization_header(store, "../escape", "https://example.test/mcp")

    assert_raise ArgumentError, ~r/credential reference/, fn ->
      OAuth.begin(store, "https://example.test/mcp", credential: "../escape")
    end
  end

  # Discovery walks every location an issuer's metadata can live at and takes
  # the one whose document names that issuer. Taking the first document that
  # fetches reads the host's document for a tenant issuer and fails.
  @tag :tmp_dir
  test "a tenant issuer is discovered at the location that names it", %{tmp_dir: tmp_dir} do
    %{resource_url: resource_url} = fake_auth_server(tenant: "o", expires_in: 3600)
    store = OAuth.store(directory: tmp_dir, secret: :crypto.strong_rand_bytes(32))

    assert {:ok, "workspace"} = authorize_without_browser(store, resource_url)

    assert {:ok, {"Authorization", "Bearer access-token-1"}} =
             OAuth.authorization_header(store, "workspace", resource_url)
  end

  # RFC 9728 section 3.3: the protected-resource document must describe the
  # server being authorized, or a server could send the person to authorize a
  # client for some other resource.
  @tag :tmp_dir
  test "a protected-resource document that names another resource is refused",
       %{tmp_dir: tmp_dir} do
    %{resource_url: resource_url} =
      fake_auth_server(resource: "https://elsewhere.example/mcp")

    store = OAuth.store(directory: tmp_dir, secret: :crypto.strong_rand_bytes(32))

    assert {:error, {:mcp_oauth_begin_failed, {:resource_mismatch, _declared, ^resource_url}}} =
             OAuth.begin(store, resource_url,
               credential: "workspace",
               redirect_uri: "http://127.0.0.1:65535/host/callback"
             )
  end

  # A confidential client presents its secret the way the token endpoint says
  # it accepts: in the Authorization header for client_secret_basic, never in
  # the form body as well.
  @tag :tmp_dir
  test "a client_secret_basic token endpoint gets the secret in the Authorization header",
       %{tmp_dir: tmp_dir} do
    %{resource_url: resource_url} =
      fake_auth_server(token_auth: "client_secret_basic", expires_in: 3600)

    store = OAuth.store(directory: tmp_dir, secret: :crypto.strong_rand_bytes(32))

    assert {:ok, "workspace"} = authorize_without_browser(store, resource_url)

    basic = "Basic " <> Base.encode64("imp-test-client:imp-test-client-secret")

    assert [%{grant_type: "authorization_code", authorization: [^basic], client_secret: nil}] =
             fake_state().token_requests
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

  defp fake_auth_server(opts) do
    port = free_port()

    initial =
      Enum.reduce(opts, Imp.MCPOAuthTest.FakeAuthServer.initial_state(), fn {key, value}, state ->
        Map.replace!(state, key, value)
      end)

    {:ok, agent} = Agent.start(fn -> initial end, name: Imp.MCPOAuthTest.FakeState)

    {:ok, server} =
      Bandit.start_link(
        plug: Imp.MCPOAuthTest.FakeAuthServer,
        port: port,
        ip: {127, 0, 0, 1}
      )

    on_exit(fn ->
      if Process.alive?(server), do: Process.exit(server, :shutdown)
      if Process.alive?(agent), do: Agent.stop(agent)
    end)

    %{origin: "http://127.0.0.1:#{port}", resource_url: "http://127.0.0.1:#{port}/mcp"}
  end

  defp fake_state, do: Agent.get(Imp.MCPOAuthTest.FakeState, & &1)

  # The host-owned redirect path: no loopback listener, the host hands the
  # callback parameters to complete/2 itself. This is a desktop client's shape.
  defp authorize_without_browser(store, resource_url) do
    assert {:ok, pending} =
             OAuth.begin(store, resource_url,
               credential: "workspace",
               redirect_uri: "http://127.0.0.1:65535/host/callback"
             )

    assert pending.listener == nil
    assert is_binary(pending.state)

    OAuth.complete(pending, %{"code" => "accepted-code", "state" => pending.state})
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

  defp wait_for_closed_port(port, attempts \\ 100)

  defp wait_for_closed_port(_port, 0), do: false

  defp wait_for_closed_port(port, attempts) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 100) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        Process.sleep(50)
        wait_for_closed_port(port, attempts - 1)

      {:error, _refused} ->
        true
    end
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
