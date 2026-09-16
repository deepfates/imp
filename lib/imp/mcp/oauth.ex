defmodule Imp.MCP.OAuth do
  @moduledoc """
  Browser-authorized OAuth credentials for remote HTTP MCP servers.

  A host that runs Imp programs — a Dwell resident, Haven, a script — can
  declare an MCP server whose Authorization header it does not know yet. A
  person authorizes once in a browser on the machine that runs the host, the
  resulting grant is written to disk encrypted, and a short-lived
  `Authorization` header is materialized only when a connection is built.
  Refreshing happens without the person.

  ExMCP owns the protocol work: protected-resource discovery, authorization
  server discovery, dynamic client registration, PKCE, callback validation,
  token exchange and refresh. This module owns where the grant lives, what
  protects it, and when a header is produced.

  ## Using it

      store = Imp.MCP.OAuth.store(directory: "~/.imp/mcp", secret: secret)

      {:ok, pending} =
        Imp.MCP.OAuth.begin(store, "https://mcp2.readwise.io/mcp", credential: "readwise")

      # Open pending.authorization_url in a browser on this machine.
      {:ok, "readwise"} = Imp.MCP.OAuth.await(pending)

  `begin/3` listens on `127.0.0.1` for the redirect, so `await/2` blocks until
  the person finishes in the browser. A host that already owns an HTTP route
  for the redirect passes `redirect_uri:` instead, keeps the pending value
  server-side, and calls `complete/2` with the callback's query parameters.

  After that, the server descriptor names the credential rather than a token:

      %{
        "name" => "readwise",
        "type" => "http",
        "url" => "https://mcp2.readwise.io/mcp",
        "auth" => %{"type" => "oauth", "credential" => "readwise"}
      }

  `Imp.MCP.connect(servers, credentials: store, ...)` resolves that to a header
  at connect time. See `Imp.MCP.Connections`.

  ## What protects the stored grant, and what does not

  Each credential is one file under the directory the host names, written with
  owner-only permissions. The whole record — access token, refresh token, any
  client secret, the token endpoint, the client id — is encrypted with
  AES-256-GCM. The key is derived with HKDF-SHA256 from the secret the host
  passes to `store/1`; the credential reference is authenticated as additional
  data, so a file copied or renamed to another reference is refused instead of
  decoded. A file whose bytes were changed is refused as a whole; there is no
  partial decode.

  That protects a copy of the file taken by someone who does not have the
  host's secret: a stray backup, a synced directory, a disk image.

  It does not protect against anyone who can read the host's secret or its
  memory, or run code as the host's user — they can materialize the same header
  the host can. It is not a substitute for the file permissions, and it does
  not expire a stolen refresh token. The host is responsible for keeping its
  secret out of its repository and out of its logs.

  Tokens are never logged, never put into the server descriptor, and never
  included in `inspect/1` output of the values this module returns.
  """

  alias ExMCP.Authorization.{FullOAuthFlow, OAuthFlow}

  @format "imp.mcp.oauth.v1"
  @key_info "imp.mcp.oauth.v1 credential key"
  @refresh_skew_seconds 60
  @default_authorize_timeout 300_000
  @callback_accept_timeout 300_000
  @callback_header_timeout 10_000
  @callback_max_headers 64
  @callback_max_line_bytes 8_192
  @listener_idle_timeout 600_000
  @lock_retries 50

  defmodule Store do
    @moduledoc """
    Where a host keeps MCP OAuth credentials and what protects them.

    Build one with `Imp.MCP.OAuth.store/1`. The struct hides its key material
    from `inspect/1`; the key is derived once and never written to disk.
    """

    @derive {Inspect, only: [:directory]}
    @enforce_keys [:directory, :key]
    defstruct [:directory, :key]

    @type t :: %__MODULE__{directory: String.t(), key: binary()}
  end

  defmodule Pending do
    @moduledoc """
    One authorization in progress.

    Holds the ExMCP transaction, which carries client credentials and PKCE
    material. Keep it in the host process; never serialize it into a cookie, a
    URL, a log line or a durable event. Its `inspect/1` output shows only the
    credential reference and the redirect URI.
    """

    @derive {Inspect, only: [:credential, :redirect_uri]}
    @enforce_keys [:store, :credential, :resource_url, :authorization_url, :redirect_uri, :flow]
    defstruct [
      :store,
      :credential,
      :resource_url,
      :authorization_url,
      :redirect_uri,
      :flow,
      :listener,
      :state
    ]

    @type t :: %__MODULE__{
            store: Imp.MCP.OAuth.Store.t(),
            credential: String.t(),
            resource_url: String.t(),
            authorization_url: String.t(),
            redirect_uri: String.t(),
            flow: ExMCP.Authorization.PendingAuthorization.t(),
            listener: pid() | nil,
            state: String.t() | nil
          }
  end

  @doc """
  Describes where credentials live and what protects them.

  Options:

    * `:directory` (required) — the directory the host owns. Created with
      owner-only permissions if absent. `~` is expanded.
    * `:secret` (required) — at least 32 bytes of host secret. Use random bytes
      the host stores outside its repository, not a passphrase; this is a key
      derivation, not a password hash.

  """
  @spec store(keyword()) :: Store.t()
  def store(opts) when is_list(opts) do
    directory =
      case Keyword.fetch(opts, :directory) do
        {:ok, directory} when is_binary(directory) and directory != "" ->
          Path.expand(directory)

        _missing ->
          raise ArgumentError, "Imp.MCP.OAuth.store/1 requires :directory as a non-empty string"
      end

    secret =
      case Keyword.fetch(opts, :secret) do
        {:ok, secret} when is_binary(secret) and byte_size(secret) >= 32 ->
          secret

        {:ok, secret} when is_binary(secret) ->
          raise ArgumentError,
                "Imp.MCP.OAuth.store/1 :secret must be at least 32 bytes, got #{byte_size(secret)}"

        _missing ->
          raise ArgumentError, "Imp.MCP.OAuth.store/1 requires :secret as a binary"
      end

    %Store{directory: directory, key: derive_key(secret)}
  end

  def store(opts) do
    raise ArgumentError, "Imp.MCP.OAuth.store/1 expects keyword options, got: #{inspect(opts)}"
  end

  @doc """
  Begins authorization for one MCP server URL.

  Returns an `Imp.MCP.OAuth.Pending` whose `:authorization_url` the host opens
  in a browser on this machine. By default a loopback listener is opened on
  `127.0.0.1` with an ephemeral port and `await/2` completes the flow when the
  browser is redirected back.

  Options:

    * `:credential` — the reference this grant is stored under. Defaults to a
      stable reference derived from the server URL.
    * `:redirect_port` — a fixed loopback port. Defaults to `0`, an ephemeral
      port chosen by the operating system. Use a fixed port when the
      authorization server only accepts pre-registered redirect URIs.
    * `:redirect_uri` — the host owns the redirect instead. No loopback
      listener is opened; call `complete/2` with the callback parameters.
    * `:scopes` — scopes to request. Defaults to what the resource advertises.
    * `:flow` — extra `ExMCP.Authorization.FullOAuthFlow` configuration, merged
      under the values this function computes.

  """
  @spec begin(Store.t(), String.t(), keyword()) :: {:ok, Pending.t()} | {:error, term()}
  def begin(store, server_url, opts \\ [])

  def begin(%Store{} = store, server_url, opts)
      when is_binary(server_url) and server_url != "" and is_list(opts) do
    credential =
      credential_reference!(Keyword.get(opts, :credential) || default_reference(server_url))

    with :ok <- ensure_ex_mcp(),
         {:ok, redirect_uri, listener} <- redirect(opts),
         {:ok, flow} <- flow_begin(server_url, redirect_uri, opts, listener) do
      {:ok,
       %Pending{
         store: store,
         credential: credential,
         resource_url: server_url,
         authorization_url: flow.authorization_url,
         redirect_uri: redirect_uri,
         flow: flow,
         listener: listener,
         state: flow.transaction[:state_param]
       }}
    end
  end

  def begin(%Store{}, server_url, _opts),
    do: {:error, {:invalid_mcp_server_url, shape(server_url)}}

  @doc """
  Waits for the loopback redirect and completes the flow.

  Returns the credential reference the grant was stored under. Only valid for a
  pending value that owns a loopback listener; a host that passed
  `:redirect_uri` calls `complete/2` itself.
  """
  @spec await(Pending.t(), timeout()) :: {:ok, String.t()} | {:error, term()}
  def await(pending, timeout \\ @default_authorize_timeout)

  def await(%Pending{listener: listener} = pending, timeout) when is_pid(listener) do
    ref = make_ref()
    monitor = Process.monitor(listener)
    send(listener, {:imp_mcp_oauth_take, self(), ref})

    receive do
      {^ref, {:ok, params}} ->
        Process.demonitor(monitor, [:flush])
        complete(pending, params)

      {^ref, {:error, reason}} ->
        Process.demonitor(monitor, [:flush])
        cancel(pending)
        {:error, reason}

      {:DOWN, ^monitor, :process, ^listener, reason} ->
        cancel(pending)
        {:error, {:mcp_oauth_callback_listener_down, reason}}
    after
      timeout ->
        Process.demonitor(monitor, [:flush])
        cancel(pending)
        {:error, :mcp_oauth_authorization_timeout}
    end
  end

  def await(%Pending{}, _timeout), do: {:error, :mcp_oauth_no_callback_listener}

  @doc """
  Completes a flow from the callback's query parameters.

  `callback_params` is the decoded query string of the redirect — `"code"` and
  `"state"`, or `"error"` when the person declined. Returns the credential
  reference the grant was stored under.
  """
  @spec complete(Pending.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def complete(%Pending{} = pending, callback_params) when is_map(callback_params) do
    callback_params = Map.new(callback_params, fn {key, value} -> {to_string(key), value} end)

    result =
      with {:ok, token} <- FullOAuthFlow.complete(pending.flow, callback_params),
           :ok <- write(pending.store, pending.credential, record_from_token(pending, token)) do
        {:ok, pending.credential}
      end

    stop_listener(pending)
    result
  end

  def complete(%Pending{} = pending, _callback_params) do
    stop_listener(pending)
    {:error, :invalid_mcp_oauth_callback}
  end

  @doc "Abandons a pending authorization and closes its loopback listener."
  @spec cancel(Pending.t()) :: :ok
  def cancel(%Pending{} = pending) do
    stop_listener(pending)
    FullOAuthFlow.cancel(pending.flow)
    :ok
  end

  @doc """
  Materializes a short-lived `Authorization` header from a stored credential.

  Refreshes first when the stored access token is within #{@refresh_skew_seconds}
  seconds of expiry, using the stored refresh token and without the person. The
  refreshed grant is written back before the header is returned. Returns
  `{"Authorization", "Bearer " <> token}`.

  Concurrent callers for the same credential are serialized so a rotating
  refresh token is redeemed once.
  """
  @spec authorization_header(Store.t(), String.t()) ::
          {:ok, {String.t(), String.t()}} | {:error, term()}
  def authorization_header(%Store{} = store, credential) when is_binary(credential) do
    with {:ok, reference} <- validate_reference(credential) do
      with_lock(store, reference, fn ->
        with {:ok, record} <- read(store, reference),
             {:ok, record} <- refresh_if_needed(store, reference, record) do
          case record["access_token"] do
            token when is_binary(token) and token != "" ->
              {:ok, {"Authorization", "Bearer " <> token}}

            _missing ->
              {:error, {:mcp_oauth_access_token_missing, reference}}
          end
        end
      end)
    end
  end

  @doc "True when a credential file exists for this reference."
  @spec stored?(Store.t(), String.t()) :: boolean()
  def stored?(%Store{} = store, credential) when is_binary(credential) do
    case validate_reference(credential) do
      {:ok, reference} -> File.regular?(path(store, reference))
      {:error, _reason} -> false
    end
  end

  @doc "Removes a stored credential. Returns `:ok` whether or not one existed."
  @spec forget(Store.t(), String.t()) :: :ok | {:error, term()}
  def forget(%Store{} = store, credential) when is_binary(credential) do
    with {:ok, reference} <- validate_reference(credential) do
      case File.rm(path(store, reference)) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, reason} -> {:error, {:mcp_oauth_credential_unwritable, reference, reason}}
      end
    end
  end

  @doc "The reference `begin/3` uses for a server URL when none is given."
  @spec default_reference(String.t()) :: String.t()
  def default_reference(server_url) when is_binary(server_url) do
    digest =
      :sha256 |> :crypto.hash(server_url) |> Base.encode16(case: :lower) |> binary_part(0, 12)

    host =
      case URI.parse(server_url) do
        %URI{host: host} when is_binary(host) and host != "" -> host
        _no_host -> "server"
      end

    sanitized = host |> String.replace(~r/[^A-Za-z0-9._-]/u, "-") |> String.trim("-")
    sanitized = if sanitized == "", do: "server", else: sanitized

    sanitized <> "-" <> digest
  end

  # -- flow ------------------------------------------------------------------

  defp flow_begin(server_url, redirect_uri, opts, listener) do
    case FullOAuthFlow.begin(flow_config(server_url, redirect_uri, opts)) do
      {:ok, flow} ->
        {:ok, flow}

      {:error, reason} ->
        stop_listener_pid(listener)
        {:error, {:mcp_oauth_begin_failed, reason}}
    end
  end

  defp flow_config(server_url, redirect_uri, opts) do
    extra = opts |> Keyword.get(:flow, %{}) |> Map.new()

    %{
      client_registration: :auto,
      application_type: :native,
      scopes: Keyword.get(opts, :scopes, []),
      protocol_version: ExMCP.protocol_version(),
      metadata_fetch: [allow_insecure_loopback: loopback?(server_url)]
    }
    |> Map.merge(extra)
    |> Map.merge(%{resource_url: server_url, redirect_uri: redirect_uri})
  end

  defp loopback?(url) do
    case URI.parse(url) do
      %URI{scheme: "http", host: host} when host in ["127.0.0.1", "::1", "localhost"] -> true
      _secure_or_remote -> false
    end
  end

  defp record_from_token(pending, token) do
    flow = pending.flow

    %{
      "format" => @format,
      "resource_url" => pending.resource_url,
      "issuer" => flow.authorization_server["issuer"],
      "client_id" => flow.client_info[:client_id],
      "client_secret" => flow.client_info[:client_secret],
      "token_endpoint" => flow.token_endpoint,
      "scopes" => granted_scopes(token, flow.config),
      "access_token" => token_field(token, :access_token),
      "refresh_token" => token_field(token, :refresh_token),
      "expires_at" => expires_at(token)
    }
  end

  defp refresh_if_needed(store, credential, record) do
    expires_at = record["expires_at"]

    if is_integer(expires_at) and
         expires_at <= System.system_time(:second) + @refresh_skew_seconds do
      refresh(store, credential, record)
    else
      {:ok, record}
    end
  end

  defp refresh(store, credential, record) do
    refresh_token = record["refresh_token"]

    if is_binary(refresh_token) and refresh_token != "" do
      with :ok <- ensure_ex_mcp(),
           {:ok, token} <-
             OAuthFlow.refresh_token(
               refresh_token,
               record["client_id"],
               record["token_endpoint"],
               refresh_opts(record)
             ) do
        record =
          record
          |> Map.put("access_token", token_field(token, :access_token))
          |> Map.put("refresh_token", token_field(token, :refresh_token) || refresh_token)
          |> Map.put("expires_at", expires_at(token))

        with :ok <- write(store, credential, record), do: {:ok, record}
      else
        {:error, reason} -> {:error, {:mcp_oauth_refresh_failed, credential, reason}}
      end
    else
      {:error, {:mcp_oauth_reauthorization_required, credential}}
    end
  end

  defp refresh_opts(record) do
    case record["client_secret"] do
      secret when is_binary(secret) and secret != "" -> [client_secret: secret]
      _public_client -> []
    end
  end

  defp expires_at(token) do
    case token_field(token, :expires_in) do
      seconds when is_integer(seconds) and seconds >= 0 -> System.system_time(:second) + seconds
      _absent -> nil
    end
  end

  defp granted_scopes(token, config) do
    case token_field(token, :scope) do
      scopes when is_binary(scopes) -> String.split(scopes, " ", trim: true)
      scopes when is_list(scopes) -> scopes
      _absent -> Map.get(config || %{}, :scopes) || []
    end
  end

  defp token_field(token, key) when is_map(token),
    do: Map.get(token, key) || Map.get(token, Atom.to_string(key))

  defp token_field(_token, _key), do: nil

  defp ensure_ex_mcp do
    case Application.ensure_all_started(:ex_mcp) do
      {:ok, _started} -> :ok
      {:error, reason} -> {:error, {:application_start_failed, reason}}
    end
  end

  # -- loopback callback listener --------------------------------------------

  defp redirect(opts) do
    case Keyword.fetch(opts, :redirect_uri) do
      {:ok, uri} when is_binary(uri) and uri != "" ->
        {:ok, uri, nil}

      {:ok, other} ->
        {:error, {:invalid_mcp_oauth_redirect_uri, shape(other)}}

      :error ->
        port = Keyword.get(opts, :redirect_port, 0)

        case start_listener(port) do
          {:ok, listener, actual_port} ->
            {:ok, "http://127.0.0.1:#{actual_port}/imp/mcp/oauth/callback", listener}

          {:error, reason} ->
            {:error, {:mcp_oauth_callback_listen_failed, reason}}
        end
    end
  end

  defp start_listener(port) when is_integer(port) and port >= 0 and port <= 65_535 do
    listen_opts = [
      :binary,
      ip: {127, 0, 0, 1},
      active: false,
      reuseaddr: true,
      backlog: 1,
      packet: :http_bin,
      packet_size: @callback_max_line_bytes
    ]

    with {:ok, socket} <- :gen_tcp.listen(port, listen_opts),
         {:ok, {_address, actual_port}} <- :inet.sockname(socket) do
      listener = spawn(fn -> listener_start(socket) end)

      case :gen_tcp.controlling_process(socket, listener) do
        :ok ->
          send(listener, :listen)
          {:ok, listener, actual_port}

        {:error, reason} ->
          :gen_tcp.close(socket)
          Process.exit(listener, :kill)
          {:error, reason}
      end
    end
  end

  defp start_listener(port), do: {:error, {:invalid_redirect_port, port}}

  defp listener_start(socket) do
    listen =
      receive do
        :listen -> true
        :stop -> false
      after
        @callback_accept_timeout -> false
      end

    if listen do
      result = accept_callback(socket)
      :gen_tcp.close(socket)
      listener_hold(result)
    else
      :gen_tcp.close(socket)
    end
  end

  defp listener_hold(result) do
    receive do
      {:imp_mcp_oauth_take, from, ref} -> send(from, {ref, result})
      :stop -> :ok
    after
      @listener_idle_timeout -> :ok
    end
  end

  defp accept_callback(socket) do
    case :gen_tcp.accept(socket, @callback_accept_timeout) do
      {:ok, connection} ->
        result = read_callback(connection)
        respond(connection, result)
        :gen_tcp.close(connection)
        result

      {:error, reason} ->
        {:error, {:mcp_oauth_callback_accept_failed, reason}}
    end
  end

  defp read_callback(connection) do
    case :gen_tcp.recv(connection, 0, @callback_header_timeout) do
      {:ok, {:http_request, _method, {:abs_path, path}, _version}} ->
        with :ok <- drain_headers(connection, @callback_max_headers) do
          {:ok, callback_params(path)}
        end

      {:ok, other} ->
        {:error, {:mcp_oauth_callback_malformed, shape(other)}}

      {:error, reason} ->
        {:error, {:mcp_oauth_callback_read_failed, reason}}
    end
  end

  defp drain_headers(_connection, 0), do: {:error, :mcp_oauth_callback_headers_too_many}

  defp drain_headers(connection, remaining) do
    case :gen_tcp.recv(connection, 0, @callback_header_timeout) do
      {:ok, :http_eoh} ->
        :ok

      {:ok, {:http_header, _length, _name, _reserved, _value}} ->
        drain_headers(connection, remaining - 1)

      {:ok, other} ->
        {:error, {:mcp_oauth_callback_malformed, shape(other)}}

      {:error, reason} ->
        {:error, {:mcp_oauth_callback_read_failed, reason}}
    end
  end

  defp callback_params(path) do
    case path |> to_string() |> URI.parse() do
      %URI{query: query} when is_binary(query) -> URI.decode_query(query)
      _no_query -> %{}
    end
  end

  # The response body is fixed text. Nothing from the request is reflected back
  # into the page, and nothing about the grant is shown.
  defp respond(connection, result) do
    body =
      case result do
        {:ok, %{"error" => _declined}} ->
          "Authorization was not granted. You can close this window and try again."

        {:ok, _params} ->
          "Authorization complete. You can close this window."

        {:error, _reason} ->
          "That request could not be read as an authorization redirect."
      end

    _ = :inet.setopts(connection, packet: :raw)

    response =
      "HTTP/1.1 200 OK\r\n" <>
        "Content-Type: text/plain; charset=utf-8\r\n" <>
        "Content-Length: #{byte_size(body)}\r\n" <>
        "Connection: close\r\n\r\n" <> body

    _ = :gen_tcp.send(connection, response)
    :ok
  end

  defp stop_listener(%Pending{listener: listener}), do: stop_listener_pid(listener)

  defp stop_listener_pid(nil), do: :ok

  defp stop_listener_pid(listener) when is_pid(listener) do
    if Process.alive?(listener), do: send(listener, :stop)
    :ok
  end

  # -- storage ---------------------------------------------------------------

  defp path(%Store{directory: directory}, credential),
    do: Path.join(directory, credential <> ".credential.json")

  defp write(store, credential, record) do
    with {:ok, plaintext} <- Jason.encode(record),
         :ok <- ensure_directory(store) do
      nonce = :crypto.strong_rand_bytes(12)

      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(
          :aes_256_gcm,
          store.key,
          nonce,
          plaintext,
          aad(credential),
          true
        )

      envelope =
        Jason.encode!(%{
          "format" => @format,
          "nonce" => Base.encode64(nonce),
          "tag" => Base.encode64(tag),
          "ciphertext" => Base.encode64(ciphertext)
        })

      write_atomically(store, credential, envelope)
    else
      {:error, reason} -> {:error, {:mcp_oauth_credential_unwritable, credential, reason}}
    end
  end

  # Replace the file in one rename so a crash mid-write never leaves a
  # half-written credential where a whole one used to be.
  defp write_atomically(store, credential, contents) do
    final = path(store, credential)
    temporary = final <> ".#{System.unique_integer([:positive])}.tmp"

    with :ok <- File.write(temporary, contents),
         :ok <- File.chmod(temporary, 0o600),
         :ok <- File.rename(temporary, final) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(temporary)
        {:error, {:mcp_oauth_credential_unwritable, credential, reason}}
    end
  end

  defp ensure_directory(%Store{directory: directory}) do
    with :ok <- File.mkdir_p(directory), do: File.chmod(directory, 0o700)
  end

  defp read(store, credential) do
    with {:ok, contents} <- read_file(store, credential),
         {:ok, envelope} <- decode_envelope(contents, credential) do
      decrypt(store, credential, envelope)
    end
  end

  defp read_file(store, credential) do
    case File.read(path(store, credential)) do
      {:ok, contents} -> {:ok, contents}
      {:error, :enoent} -> {:error, {:mcp_oauth_credential_not_found, credential}}
      {:error, reason} -> {:error, {:mcp_oauth_credential_unreadable, credential, reason}}
    end
  end

  defp decode_envelope(contents, credential) do
    with {:ok, %{"format" => @format} = envelope} <- Jason.decode(contents),
         {:ok, nonce} <- decode64(envelope["nonce"]),
         {:ok, tag} <- decode64(envelope["tag"]),
         {:ok, ciphertext} <- decode64(envelope["ciphertext"]),
         true <- byte_size(nonce) == 12 and byte_size(tag) == 16 do
      {:ok, %{nonce: nonce, tag: tag, ciphertext: ciphertext}}
    else
      _unusable -> {:error, {:mcp_oauth_credential_tampered, credential}}
    end
  end

  defp decode64(value) when is_binary(value), do: Base.decode64(value)
  defp decode64(_value), do: :error

  # AES-GCM verifies the tag before returning anything, so a changed byte
  # anywhere in the file — or a file moved to another credential reference,
  # which changes the authenticated data — fails as a whole. There is no
  # partially decoded record to act on.
  defp decrypt(store, credential, envelope) do
    case :crypto.crypto_one_time_aead(
           :aes_256_gcm,
           store.key,
           envelope.nonce,
           envelope.ciphertext,
           aad(credential),
           envelope.tag,
           false
         ) do
      plaintext when is_binary(plaintext) ->
        case Jason.decode(plaintext) do
          {:ok, record} when is_map(record) -> {:ok, record}
          _unusable -> {:error, {:mcp_oauth_credential_tampered, credential}}
        end

      _failed ->
        {:error, {:mcp_oauth_credential_tampered, credential}}
    end
  end

  defp aad(credential), do: @format <> ":" <> credential

  defp derive_key(secret) do
    # HKDF-SHA256 with a fixed salt and info: one extract, one expand block.
    pseudorandom_key = :crypto.mac(:hmac, :sha256, @format, secret)
    :crypto.mac(:hmac, :sha256, pseudorandom_key, @key_info <> <<1>>)
  end

  # Serialize per credential so two connections built at the same time do not
  # each redeem a rotating refresh token. The second caller re-reads the file
  # inside the lock and finds the token the first one stored.
  defp with_lock(store, credential, fun) do
    lock = {{:imp_mcp_oauth, path(store, credential)}, self()}

    case :global.trans(lock, fun, [Node.self()], @lock_retries) do
      :aborted -> {:error, {:mcp_oauth_credential_busy, credential}}
      result -> result
    end
  end

  defp credential_reference!(credential) do
    case validate_reference(credential) do
      {:ok, reference} ->
        reference

      {:error, {:invalid_mcp_oauth_credential, value}} ->
        raise ArgumentError,
              "MCP OAuth credential reference must be 1-128 characters of letters, digits, " <>
                "'.', '_' or '-', got: #{inspect(value)}"
    end
  end

  # A reference becomes a filename. Keep it to a conservative character set so
  # it can never climb out of the directory the host named.
  defp validate_reference(credential) when is_binary(credential) do
    if credential =~ ~r/\A[A-Za-z0-9._-]{1,128}\z/ and credential not in [".", ".."] do
      {:ok, credential}
    else
      {:error, {:invalid_mcp_oauth_credential, credential}}
    end
  end

  defp validate_reference(credential), do: {:error, {:invalid_mcp_oauth_credential, credential}}

  defp shape(value) when is_binary(value), do: :binary
  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_atom(value), do: :atom
  defp shape(value) when is_tuple(value), do: {:tuple, tuple_size(value)}
  defp shape(_value), do: :other
end
