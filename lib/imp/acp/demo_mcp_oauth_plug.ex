defmodule Imp.ACP.DemoMCPOAuthPlug do
  @moduledoc false

  @behaviour Plug

  import Plug.Conn

  alias ExMCP.Authorization.PKCE

  @scopes ["mcp:tools:list", "mcp:tools:execute"]

  @impl true
  def init(opts) do
    origin = Keyword.fetch!(opts, :origin)

    %{
      origin: origin,
      resource: origin <> "/mcp",
      state: Keyword.fetch!(opts, :state),
      token_ttl: Keyword.get(opts, :token_ttl, 3600),
      mcp:
        ExMCP.HttpPlug.init(
          path: "/mcp",
          handler: Imp.ACP.DemoMCPServer,
          server_info: %{name: "imp-acp-demo-oauth-mcp", version: "0.1.0"},
          allowed_hosts: ["localhost", "127.0.0.1", "::1"],
          allowed_origins: :any
        )
    }
  end

  @impl true
  def call(
        %Plug.Conn{method: "GET", path_info: [".well-known", "oauth-protected-resource", "mcp"]} =
          conn,
        opts
      ) do
    json(conn, 200, %{
      "resource" => opts.resource,
      "authorization_servers" => [opts.origin],
      "scopes_supported" => @scopes,
      "bearer_methods_supported" => ["header"]
    })
  end

  def call(
        %Plug.Conn{method: "GET", path_info: [".well-known", "oauth-protected-resource"]} = conn,
        opts
      ) do
    json(conn, 200, %{
      "resource" => opts.resource,
      "authorization_servers" => [opts.origin],
      "scopes_supported" => @scopes,
      "bearer_methods_supported" => ["header"]
    })
  end

  def call(%Plug.Conn{method: "GET", path_info: [".well-known", discovery]} = conn, opts)
      when discovery in ["oauth-authorization-server", "openid-configuration"] do
    json(conn, 200, %{
      "issuer" => opts.origin,
      "authorization_endpoint" => opts.origin <> "/authorize",
      "token_endpoint" => opts.origin <> "/token",
      "registration_endpoint" => opts.origin <> "/register",
      "response_types_supported" => ["code"],
      "grant_types_supported" => ["authorization_code", "refresh_token"],
      "code_challenge_methods_supported" => ["S256"],
      "token_endpoint_auth_methods_supported" => ["client_secret_post"],
      "scopes_supported" => @scopes,
      "authorization_response_iss_parameter_supported" => true
    })
  end

  def call(%Plug.Conn{method: "POST", path_info: ["register"]} = conn, opts) do
    with {:ok, request, conn} <- read_json(conn),
         {:ok, redirect_uri} <- registered_redirect_uri(request) do
      client_id = opaque("client")
      client_secret = opaque("secret")

      Agent.update(opts.state, fn state ->
        put_in(state, [:clients, client_id], %{
          client_secret: client_secret,
          redirect_uri: redirect_uri
        })
      end)

      json(conn, 201, %{
        "client_id" => client_id,
        "client_secret" => client_secret,
        "client_id_issued_at" => System.system_time(:second),
        "token_endpoint_auth_method" => "client_secret_post"
      })
    else
      {:error, reason, conn} -> oauth_error(conn, 400, reason)
      {:error, reason} -> oauth_error(conn, 400, reason)
    end
  end

  def call(%Plug.Conn{method: "GET", path_info: ["authorize"]} = conn, opts) do
    conn = fetch_query_params(conn)
    params = conn.query_params

    with :ok <- validate_authorization_request(params, opts) do
      hidden =
        params
        |> Enum.map(fn {name, value} ->
          ~s(<input type="hidden" name="#{escape(name)}" value="#{escape(value)}">)
        end)
        |> Enum.join("\n")

      body = """
      <!doctype html>
      <html lang="en">
        <head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Authorize MCP</title></head>
        <body style="font-family: system-ui; max-width: 38rem; margin: 4rem auto; padding: 0 1rem;">
          <h1>Connect protected workspace tools?</h1>
          <p>This local treatment server will let the selected agent call its MCP workspace tool.</p>
          <form method="post" action="/authorize">
            #{hidden}
            <button style="font: inherit; padding: .7rem 1rem;" type="submit">Authorize</button>
          </form>
        </body>
      </html>
      """

      conn
      |> put_resp_content_type("text/html")
      |> send_resp(200, body)
    else
      {:error, reason} -> oauth_error(conn, 400, reason)
    end
  end

  def call(%Plug.Conn{method: "POST", path_info: ["authorize"]} = conn, opts) do
    with {:ok, body, conn} <- read_body(conn),
         params <- URI.decode_query(body),
         :ok <- validate_authorization_request(params, opts) do
      code = opaque("code")

      Agent.update(opts.state, fn state ->
        put_in(state, [:codes, code], %{
          client_id: params["client_id"],
          redirect_uri: params["redirect_uri"],
          code_challenge: params["code_challenge"],
          resource: params["resource"]
        })
      end)

      location =
        params["redirect_uri"]
        |> URI.parse()
        |> Map.put(
          :query,
          URI.encode_query(%{"code" => code, "state" => params["state"], "iss" => opts.origin})
        )
        |> URI.to_string()

      conn
      |> put_resp_header("location", location)
      |> send_resp(302, "")
    else
      {:error, reason, conn} -> oauth_error(conn, 400, reason)
      {:error, reason} -> oauth_error(conn, 400, reason)
    end
  end

  def call(%Plug.Conn{method: "POST", path_info: ["token"]} = conn, opts) do
    with {:ok, body, conn} <- read_body(conn),
         params <- URI.decode_query(body),
         {:ok, token} <- issue_token(params, opts) do
      json(conn, 200, token)
    else
      {:error, reason, conn} -> oauth_error(conn, 400, reason)
      {:error, reason} -> oauth_error(conn, 400, reason)
    end
  end

  def call(%Plug.Conn{path_info: ["mcp" | _]} = conn, opts) do
    case bearer_token(conn) do
      {:ok, token} ->
        if token_active?(opts.state, token) do
          ExMCP.HttpPlug.call(conn, opts.mcp)
        else
          unauthorized(conn, opts)
        end

      :error ->
        unauthorized(conn, opts)
    end
  end

  def call(conn, _opts), do: send_resp(conn, 404, "Not found")

  defp validate_authorization_request(params, opts) do
    client = Agent.get(opts.state, &get_in(&1, [:clients, params["client_id"]]))

    cond do
      not is_map(client) -> {:error, "invalid_client"}
      client.redirect_uri != params["redirect_uri"] -> {:error, "invalid_redirect_uri"}
      params["response_type"] != "code" -> {:error, "unsupported_response_type"}
      params["code_challenge_method"] != "S256" -> {:error, "invalid_request"}
      not non_empty?(params["code_challenge"]) -> {:error, "invalid_request"}
      not non_empty?(params["state"]) -> {:error, "invalid_request"}
      params["resource"] != opts.resource -> {:error, "invalid_target"}
      true -> :ok
    end
  end

  defp issue_token(%{"grant_type" => "authorization_code"} = params, opts) do
    code = params["code"]

    authorization =
      Agent.get_and_update(opts.state, fn state ->
        {authorization, codes} = Map.pop(state.codes, code)
        {authorization, %{state | codes: codes}}
      end)

    client = Agent.get(opts.state, &get_in(&1, [:clients, params["client_id"]]))

    cond do
      not is_map(authorization) ->
        {:error, "invalid_grant"}

      not is_map(client) ->
        {:error, "invalid_client"}

      authorization.client_id != params["client_id"] ->
        {:error, "invalid_grant"}

      client.client_secret != params["client_secret"] ->
        {:error, "invalid_client"}

      authorization.redirect_uri != params["redirect_uri"] ->
        {:error, "invalid_grant"}

      not PKCE.validate_challenge(params["code_verifier"] || "", authorization.code_challenge) ->
        {:error, "invalid_grant"}

      true ->
        create_token(opts, authorization.client_id)
    end
  end

  defp issue_token(%{"grant_type" => "refresh_token"} = params, opts) do
    refresh_token = params["refresh_token"]

    client_id =
      Agent.get_and_update(opts.state, fn state ->
        {client_id, refresh_tokens} = Map.pop(state.refresh_tokens, refresh_token)
        {client_id, %{state | refresh_tokens: refresh_tokens}}
      end)

    client = Agent.get(opts.state, &get_in(&1, [:clients, params["client_id"]]))

    cond do
      not is_binary(client_id) -> {:error, "invalid_grant"}
      client_id != params["client_id"] -> {:error, "invalid_grant"}
      not is_map(client) -> {:error, "invalid_client"}
      client.client_secret != params["client_secret"] -> {:error, "invalid_client"}
      true -> create_token(opts, client_id)
    end
  end

  defp issue_token(_params, _opts), do: {:error, "unsupported_grant_type"}

  defp create_token(opts, client_id) do
    access_token = opaque("access")
    refresh_token = opaque("refresh")
    expires_at = System.system_time(:second) + opts.token_ttl

    Agent.update(opts.state, fn state ->
      state
      |> put_in([:access_tokens, access_token], expires_at)
      |> put_in([:refresh_tokens, refresh_token], client_id)
    end)

    {:ok,
     %{
       "access_token" => access_token,
       "refresh_token" => refresh_token,
       "token_type" => "Bearer",
       "expires_in" => opts.token_ttl,
       "scope" => Enum.join(@scopes, " ")
     }}
  end

  defp token_active?(state, token) do
    case Agent.get(state, &get_in(&1, [:access_tokens, token])) do
      expires_at when is_integer(expires_at) -> expires_at > System.system_time(:second)
      _missing -> false
    end
  end

  defp registered_redirect_uri(%{"redirect_uris" => [redirect_uri | _]})
       when is_binary(redirect_uri) and redirect_uri != "",
       do: {:ok, redirect_uri}

  defp registered_redirect_uri(_request), do: {:error, "invalid_redirect_uri"}

  defp read_json(conn) do
    with {:ok, body, conn} <- read_body(conn),
         {:ok, request} when is_map(request) <- Jason.decode(body) do
      {:ok, request, conn}
    else
      _invalid -> {:error, "invalid_request", conn}
    end
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token != "" -> {:ok, token}
      _missing -> :error
    end
  end

  defp unauthorized(conn, opts) do
    metadata = opts.origin <> "/.well-known/oauth-protected-resource/mcp"

    conn
    |> put_resp_header("www-authenticate", ~s(Bearer resource_metadata="#{metadata}"))
    |> send_resp(401, "Unauthorized")
    |> halt()
  end

  defp oauth_error(conn, status, reason), do: json(conn, status, %{"error" => reason})

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp opaque(prefix),
    do: prefix <> "_" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

  defp escape(value), do: value |> to_string() |> Plug.HTML.html_escape()
  defp non_empty?(value), do: is_binary(value) and value != ""
end
