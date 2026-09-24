defmodule Imp.MCP.OAuth.Flow do
  @moduledoc false

  # The browser authorization-code flow for one MCP server, from discovery to
  # the token response.
  #
  # ExMCP's `FullOAuthFlow.execute/1` runs the whole flow itself and follows
  # the authorization URL without a person, so it cannot show that URL in a
  # browser and wait. This module composes the same flow from ExMCP's public
  # pieces instead, and pauses where the person has to act:
  #
  #   1. protected-resource metadata (RFC 9728) names the authorization server;
  #   2. authorization-server metadata (RFC 8414, OpenID discovery) names its
  #      endpoints;
  #   3. `ExMCP.Authorization.RegistrationPolicy` picks a client: pre-registered,
  #      a Client ID Metadata Document, or dynamic registration (RFC 7591);
  #   4. `ExMCP.Authorization.OAuthFlow.start_authorization_flow/1` builds the
  #      PKCE authorization URL and records the transaction;
  #   5. after the redirect, `OAuthFlow.validate_authorization_response/2`
  #      consumes the transaction once and `OAuthFlow.exchange_code_for_token/1`
  #      redeems the code.
  #
  # Steps 1 and 2 read the metadata documents here, through ExMCP's hardened
  # `MetadataFetcher`, rather than through ExMCP's discovery functions, for two
  # reasons. ExMCP's protected-resource discovery drops the document's
  # `resource` and `scopes_supported`, and a client must check `resource`
  # against the server it is authorizing for (RFC 9728, section 3.3). And
  # ExMCP's authorization-server discovery accepts the first document that
  # fetches, then checks its issuer: an issuer that serves several tenants under
  # one host (Readwise's `https://readwise.io/o/`) answers the path-appended
  # location with the host's document and the RFC 8414 location with the
  # tenant's, so the first document names the wrong issuer and discovery fails
  # before the right location is read. Here a document is the answer only when
  # it names the issuer that was asked for; `OIDCDiscovery.validate_metadata/3`
  # does that check. Both retire if ExMCP's discovery keeps those fields and
  # walks on past a document that names another issuer.

  alias ExMCP.Authorization.{
    ClientRegistration,
    HTTPClient,
    MetadataFetcher,
    OAuthFlow,
    OAuthTransactionStore,
    OIDCDiscovery,
    RegistrationPolicy
  }

  @oidc_well_known "/.well-known/openid-configuration"
  @oauth_well_known "/.well-known/oauth-authorization-server"
  @resource_well_known "/.well-known/oauth-protected-resource"

  @derive {Inspect, only: [:resource_url, :redirect_uri]}
  @enforce_keys [
    :resource_url,
    :redirect_uri,
    :authorization_url,
    :transaction,
    :client,
    :issuer,
    :token_endpoint,
    :token_auth_method,
    :scopes
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          resource_url: String.t(),
          redirect_uri: String.t(),
          authorization_url: String.t(),
          transaction: map(),
          client: map(),
          issuer: String.t(),
          token_endpoint: String.t(),
          token_auth_method: :none | :client_secret_basic | :client_secret_post,
          scopes: [String.t()]
        }

  @type config :: %{
          required(:resource_url) => String.t(),
          required(:redirect_uri) => String.t(),
          optional(:scopes) => [String.t()],
          optional(:client_registration) => RegistrationPolicy.configured_strategy(),
          optional(:client_issuer) => String.t() | nil,
          optional(:metadata_fetch) => keyword()
        }

  @doc """
  Discovers the server's authorization server, selects a client and returns
  the pending flow whose `:authorization_url` the person opens.
  """
  @spec begin(config()) :: {:ok, t()} | {:error, term()}
  def begin(%{resource_url: resource_url, redirect_uri: redirect_uri} = config) do
    fetch_opts = Map.get(config, :metadata_fetch, [])

    with {:ok, resource} <- resource_metadata(resource_url, fetch_opts),
         {:ok, metadata} <- authorization_server(resource.issuer, fetch_opts),
         :ok <- authorization_code_supported(metadata),
         {:ok, client} <- client(metadata, config),
         {:ok, token_auth_method} <- token_auth_method(metadata, client),
         scopes = scopes(config, resource, metadata),
         {:ok, authorization_url, transaction} <-
           OAuthFlow.start_authorization_flow(%{
             client_id: client.client_id,
             redirect_uri: redirect_uri,
             authorization_endpoint: metadata["authorization_endpoint"],
             issuer: metadata["issuer"],
             require_issuer: metadata["authorization_response_iss_parameter_supported"] == true,
             scopes: scopes,
             resource: resource_url
           }) do
      {:ok,
       %__MODULE__{
         resource_url: resource_url,
         redirect_uri: redirect_uri,
         authorization_url: authorization_url,
         transaction: transaction,
         client: client,
         issuer: metadata["issuer"],
         token_endpoint: metadata["token_endpoint"],
         token_auth_method: token_auth_method,
         scopes: scopes
       }}
    end
  end

  @doc """
  Validates the redirect's query parameters against the flow and redeems the
  authorization code once. Returns the token response.
  """
  @spec complete(t(), map()) :: {:ok, map()} | {:error, term()}
  def complete(%__MODULE__{} = flow, callback_params) when is_map(callback_params) do
    with {:ok, code} <-
           OAuthFlow.validate_authorization_response(callback_params, flow.transaction) do
      exchange(flow, code)
    end
  after
    cancel(flow)
  end

  @doc "Forgets the flow's transaction, so its redirect can no longer be redeemed."
  @spec cancel(t()) :: :ok
  def cancel(%__MODULE__{transaction: %{transaction_id: transaction_id}}) do
    OAuthTransactionStore.abort(transaction_id)
  catch
    :exit, _not_running -> :ok
  end

  # -- token exchange ----------------------------------------------------------

  # `OAuthFlow.exchange_code_for_token/1` always sends a client secret in the
  # form body, so it serves `client_secret_post` and public clients. A server
  # that asks for `client_secret_basic` gets the same request through
  # `HTTPClient.make_token_request/3`, which moves the secret into the
  # Authorization header, after the same code redemption.
  defp exchange(%__MODULE__{token_auth_method: :client_secret_basic} = flow, code) do
    with :ok <-
           OAuthTransactionStore.redeem_code(
             flow.transaction.transaction_id,
             code,
             flow.redirect_uri
           ) do
      HTTPClient.make_token_request(
        flow.token_endpoint,
        [
          grant_type: "authorization_code",
          code: code,
          redirect_uri: flow.redirect_uri,
          client_id: flow.client.client_id,
          client_secret: flow.client.client_secret,
          code_verifier: flow.transaction.code_verifier,
          resource: flow.resource_url
        ],
        auth_method: :client_secret_basic
      )
    end
  end

  defp exchange(%__MODULE__{} = flow, code) do
    %{
      code: code,
      code_verifier: flow.transaction.code_verifier,
      client_id: flow.client.client_id,
      redirect_uri: flow.redirect_uri,
      token_endpoint: flow.token_endpoint,
      transaction_id: flow.transaction.transaction_id,
      resource: flow.resource_url
    }
    |> put_secret(flow)
    |> OAuthFlow.exchange_code_for_token()
  end

  defp put_secret(params, %__MODULE__{token_auth_method: :client_secret_post, client: client}),
    do: Map.put(params, :client_secret, client.client_secret)

  defp put_secret(params, _public_client), do: params

  # -- protected-resource metadata (RFC 9728) ----------------------------------

  # A server with no protected-resource document is treated as its own
  # authorization server, which is what MCP 2025-03-26 servers did.
  defp resource_metadata(resource_url, fetch_opts) do
    with :ok <- MetadataFetcher.validate_url(resource_url, fetch_opts) do
      case first_document(resource_documents(resource_url), fetch_opts) do
        {:ok, document} -> parse_resource(document, resource_url)
        {:error, {:metadata_fetch_error, _reason}} = error -> error
        {:error, _absent} -> {:ok, %{issuer: origin(resource_url), scopes: []}}
      end
    end
  end

  defp resource_documents(resource_url) do
    uri = URI.parse(resource_url)
    root = origin(resource_url) <> @resource_well_known

    case String.trim_trailing(uri.path || "", "/") do
      "" -> [root]
      path -> [root <> path, root]
    end
  end

  defp first_document([], _fetch_opts), do: {:error, :no_metadata}

  defp first_document([url | rest], fetch_opts) do
    case fetch_json(url, fetch_opts) do
      {:ok, document} -> {:ok, document}
      {:error, {:metadata_fetch_error, _reason}} = error -> error
      {:error, _absent} -> first_document(rest, fetch_opts)
    end
  end

  defp parse_resource(%{"authorization_servers" => [issuer | _]} = document, resource_url)
       when is_binary(issuer) and issuer != "" do
    with :ok <- resource_matches(document["resource"], resource_url) do
      scopes =
        case document["scopes_supported"] do
          scopes when is_list(scopes) -> Enum.filter(scopes, &is_binary/1)
          _absent -> []
        end

      {:ok, %{issuer: issuer, scopes: scopes}}
    end
  end

  defp parse_resource(_document, _resource_url), do: {:error, :invalid_resource_metadata}

  # The document may describe the whole origin or a path above the server; it
  # must not describe some other resource.
  defp resource_matches(nil, _resource_url), do: :ok

  defp resource_matches(resource, resource_url) when is_binary(resource) do
    declared = normalize(resource)
    server = normalize(resource_url)

    if server == declared or String.starts_with?(server, declared <> "/"),
      do: :ok,
      else: {:error, {:resource_mismatch, resource, resource_url}}
  end

  defp resource_matches(_invalid, _resource_url), do: {:error, :invalid_resource_metadata}

  defp normalize(url) do
    uri = URI.parse(url)
    path = String.trim_trailing(uri.path || "", "/")
    "#{uri.scheme}://#{String.downcase(uri.host || "")}:#{uri.port}#{path}"
  end

  # -- authorization-server metadata (RFC 8414, OpenID discovery) --------------

  defp authorization_server(issuer, fetch_opts) do
    with :ok <- MetadataFetcher.validate_url(issuer, fetch_opts) do
      issuer
      |> authorization_documents()
      |> matching_document(issuer, fetch_opts, {:error, {:as_discovery_failed, :no_metadata}})
    end
  end

  defp authorization_documents(issuer) do
    trimmed = String.trim_trailing(issuer, "/")
    appended = [trimmed <> @oidc_well_known, trimmed <> @oauth_well_known]

    case URI.parse(trimmed).path do
      path when path in [nil, "", "/"] ->
        appended

      path ->
        base = origin(issuer)
        appended ++ [base <> @oauth_well_known <> path, base <> @oidc_well_known <> path]
    end
  end

  defp matching_document([], _issuer, _fetch_opts, error), do: error

  defp matching_document([url | rest], issuer, fetch_opts, error) do
    with {:ok, metadata} <- fetch_json(url, fetch_opts),
         :ok <- OIDCDiscovery.validate_metadata(metadata, issuer, fetch_opts) do
      {:ok, metadata}
    else
      {:error, {:metadata_fetch_error, _reason}} = fetch_error ->
        fetch_error

      # A document that names another issuer says more about what the server
      # answered than a later location's 404, so it is the error kept.
      {:error, {:issuer_mismatch, _details}} = mismatch ->
        matching_document(rest, issuer, fetch_opts, mismatch)

      {:error, _reason} = other ->
        kept = if match?({:error, {:issuer_mismatch, _}}, error), do: error, else: other
        matching_document(rest, issuer, fetch_opts, kept)
    end
  end

  defp authorization_code_supported(metadata) do
    case metadata["grant_types_supported"] do
      nil ->
        :ok

      grants when is_list(grants) and grants == [] ->
        :ok

      grants when is_list(grants) ->
        if "authorization_code" in grants, do: :ok, else: unsupported()

      _invalid ->
        {:error, :invalid_authorization_server_grant_types}
    end
  end

  defp unsupported, do: {:error, :authorization_code_grant_not_supported}

  # -- client ------------------------------------------------------------------

  defp client(metadata, config) do
    # The policy asks for the redirect port because a dynamically registered
    # client is bound to its exact redirect URI; that URI is already fixed here.
    # A pre-registered client names the issuer it was registered with, and the
    # policy refuses one whose discovered issuer differs: a server could
    # otherwise name its own authorization server and receive the secret.
    policy_config =
      %{
        client_registration: Map.get(config, :client_registration, :auto),
        application_type: :native,
        protocol_version: ExMCP.protocol_version(),
        redirect_port: URI.parse(config.redirect_uri).port
      }
      |> put_present(:credential_issuer, Map.get(config, :client_issuer))

    case RegistrationPolicy.select(metadata, policy_config) do
      {:ok, {:dynamic, selection}} -> register(selection, metadata, config)
      {:ok, {_kind, client}} -> {:ok, client}
      {:error, _reason} = error -> error
    end
  end

  defp register(selection, metadata, config) do
    supported = metadata["token_endpoint_auth_methods_supported"] || []

    auth_method =
      Enum.find(["none", "client_secret_basic", "client_secret_post"], "none", &(&1 in supported))

    request = %{
      registration_endpoint: selection.registration_endpoint,
      client_name: "imp",
      application_type: Atom.to_string(selection.application_type),
      redirect_uris: [config.redirect_uri],
      grant_types: ["authorization_code", "refresh_token"],
      response_types: ["code"],
      token_endpoint_auth_method: auth_method,
      scope: Enum.join(Map.get(config, :scopes, []), " ")
    }

    case ClientRegistration.register_client(request) do
      {:ok, registration} ->
        {:ok,
         %{
           client_id: field(registration, :client_id),
           client_secret: field(registration, :client_secret)
         }}

      {:error, reason} ->
        {:error, {:registration_failed, reason}}
    end
  end

  # A client with a secret presents it the way the token endpoint says it
  # accepts (RFC 8414 makes `client_secret_basic` the default when the server
  # lists nothing). A client with no secret is a public client, which is what
  # `register/3` asked for when the server offered `none` or listed nothing.
  defp token_auth_method(metadata, client) do
    supported = metadata["token_endpoint_auth_methods_supported"] || ["client_secret_basic"]

    case client[:client_secret] do
      secret when is_binary(secret) and secret != "" ->
        cond do
          "client_secret_basic" in supported -> {:ok, :client_secret_basic}
          "client_secret_post" in supported -> {:ok, :client_secret_post}
          true -> {:error, {:no_usable_token_auth_method, supported}}
        end

      _public_client ->
        {:ok, :none}
    end
  end

  # Scopes the host asked for; otherwise what the resource advertises;
  # otherwise what the authorization server advertises.
  defp scopes(config, resource, metadata) do
    case Map.get(config, :scopes, []) do
      [_ | _] = scopes -> scopes
      _none when resource.scopes != [] -> resource.scopes
      _none -> List.wrap(metadata["scopes_supported"])
    end
  end

  # -- documents ---------------------------------------------------------------

  defp fetch_json(url, fetch_opts) do
    case MetadataFetcher.fetch(url, fetch_opts) do
      {:ok, %{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, document} when is_map(document) -> {:ok, document}
          _invalid -> {:error, :invalid_json}
        end

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, _reason} = error ->
        error
    end
  end

  defp origin(url) do
    uri = URI.parse(url)
    host = if String.contains?(uri.host || "", ":"), do: "[#{uri.host}]", else: uri.host

    port =
      case {uri.scheme, uri.port} do
        {"https", 443} -> ""
        {"http", 80} -> ""
        {_scheme, nil} -> ""
        {_scheme, port} -> ":#{port}"
      end

    "#{uri.scheme}://#{host}#{port}"
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp field(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
