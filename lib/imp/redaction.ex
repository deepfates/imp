defmodule Imp.Redaction do
  @moduledoc """
  Shared redaction helpers for traces, telemetry, and runtime metadata.

  Imp keeps prompts, tool inputs, provider metadata, and optimizer reports
  inspectable, but credentials and credential-shaped strings must not leak into
  those artifacts. `redact/2` walks ordinary Elixir maps, lists, tuples, and structs,
  replacing known secret fields and every string that holds a credential
  with `"[REDACTED]"`.

  Clients, retrievers and trackers that hold a credential print through a
  redacting `Inspect` implementation, which hides every header value and the
  query, fragment and user info of every URL as well;
  `inspect(term, structs: false)`, Erlang's `~p`, and a credential kept
  outside those structs (a bare keyword list in a process's state) bypass it.
  """

  @default_redact_keys [
    :api_key,
    :authorization,
    :proxy_authorization,
    :auth,
    :bearer,
    :session,
    :token,
    :api_token,
    :auth_token,
    :bearer_token,
    :refresh_token,
    :id_token,
    :session_token,
    :password,
    :secret,
    :access_token,
    :access_key,
    :access_key_id,
    :secret_key,
    :secret_access_key,
    :client_secret,
    :private_key,
    :private_token,
    :service_account_key,
    :credential,
    :credentials,
    :code_verifier,
    :"x-api-key"
  ]

  @credential_key_names MapSet.new(
                          Enum.map(@default_redact_keys, fn key ->
                            key
                            |> Atom.to_string()
                            |> String.replace(~r/[^A-Za-z0-9]/, "")
                          end)
                        )
  @credential_key_suffixes [
    ["api", "key"],
    ["api", "token"],
    ["authorization"],
    ["auth"],
    ["auth", "token"],
    ["bearer"],
    ["bearer", "token"],
    ["refresh", "token"],
    ["id", "token"],
    ["session"],
    ["session", "token"],
    ["access", "token"],
    ["access", "key"],
    ["access", "key", "id"],
    ["secret", "key"],
    ["security", "token"],
    ["secret", "access", "key"],
    ["client", "secret"],
    ["private", "key"],
    ["private", "token"],
    ["service", "account", "key"],
    ["password"],
    ["secret"],
    ["credential"],
    ["credentials"]
  ]
  @schema_descriptor_keys MapSet.new(~w(
    $defs $ref additionalProperties allOf anyOf definitions description exclusiveMaximum
    exclusiveMinimum format items maxItems maxLength maxProperties maximum minItems minLength
    minProperties minimum multipleOf not nullable oneOf pattern properties propertyNames
    required title type uniqueItems
  ))

  # Structs that hold a connection's headers and URLs. ExMCP's client and HTTP
  # transport keep an `Authorization` bearer or an API-key header in their
  # process state, which is printed when the process crashes or is inspected
  # with `:sys.get_state/1`; ExMCP 1.5 has no `Inspect` implementation for
  # either, so Imp gives them its own. That entry goes when ExMCP redacts its
  # own state; if ExMCP adds an implementation, the two conflict.
  @connection_structs [
    Imp.Clients.ReqLLM,
    Imp.Retrievers.HTTP,
    Imp.Tracking.MLflow,
    Imp.Tracking.WandB,
    Imp.Optimize.Anything.Config.Tracking,
    ExMCP.Client,
    ExMCP.Transport.HTTP
  ]

  @doc false
  def connection_structs, do: @connection_structs

  @doc """
  Returns the default key names treated as sensitive.

      iex> :api_key in Imp.Redaction.default_keys()
      true

      iex> :"x-api-key" in Imp.Redaction.default_keys()
      true

  """
  def default_keys, do: @default_redact_keys

  @doc false
  def credential_key?(key) when is_atom(key) or is_binary(key) do
    tokens = key_tokens(key)

    MapSet.member?(@credential_key_names, normalize_key(key)) or
      Enum.any?(@credential_key_suffixes, &token_suffix?(tokens, &1))
  end

  def credential_key?(key) when is_map(key) do
    key
    |> tagged_key_names()
    |> Enum.any?(&credential_key?/1)
  end

  def credential_key?(_key), do: false

  @doc false
  # What a saved program may hold: no header at all. A header value is a
  # credential more often than not, and a saved file outlives the process.
  def drop_headers(value) when is_struct(value), do: value

  def drop_headers(value) when is_map(value) do
    value
    |> Map.reject(fn {key, _value} -> header_key?(key) end)
    |> Map.new(fn {key, nested} -> {key, drop_headers(nested)} end)
  end

  def drop_headers(value) when is_list(value) do
    value
    |> Enum.reject(fn
      {key, _value} -> header_key?(key)
      [key, _value] -> header_key?(key)
      _item -> false
    end)
    |> Enum.map(fn
      {key, nested} -> {key, drop_headers(nested)}
      [key, nested] when is_atom(key) or is_binary(key) -> [key, drop_headers(nested)]
      item -> drop_headers(item)
    end)
  end

  def drop_headers(value), do: value

  @doc false
  # True for a URL whose query, fragment or user info may carry a credential.
  def url_with_secret_parts?(%URI{} = uri), do: secret_parts?(uri)

  def url_with_secret_parts?(value) when is_binary(value) do
    case url(value) do
      %URI{} = uri -> secret_parts?(uri)
      nil -> false
    end
  end

  def url_with_secret_parts?(_value), do: false

  defp secret_parts?(%URI{} = uri),
    do: uri.query not in [nil, ""] or uri.fragment not in [nil, ""] or uri.userinfo != nil

  defp hide_headers_and_urls(value) when is_struct(value), do: value

  defp hide_headers_and_urls(value) when is_map(value) do
    Map.new(value, fn {key, nested} ->
      if header_key?(key),
        do: {key, hide_header_values(nested)},
        else: {key, hide_headers_and_urls(nested)}
    end)
  end

  defp hide_headers_and_urls(value) when is_list(value) do
    Enum.map(value, fn
      {key, nested} when is_atom(key) or is_binary(key) ->
        if header_key?(key),
          do: {key, hide_header_values(nested)},
          else: {key, hide_headers_and_urls(nested)}

      item ->
        hide_headers_and_urls(item)
    end)
  end

  defp hide_headers_and_urls(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> hide_headers_and_urls() |> List.to_tuple()

  defp hide_headers_and_urls(value) when is_binary(value) do
    with %URI{} = uri <- url(value), true <- secret_parts?(uri) do
      uri
      |> Map.put(:query, if(uri.query in [nil, ""], do: uri.query, else: "[REDACTED]"))
      |> Map.put(:fragment, if(uri.fragment in [nil, ""], do: uri.fragment, else: "[REDACTED]"))
      |> Map.put(:userinfo, if(uri.userinfo, do: "[REDACTED]"))
      |> URI.to_string()
    else
      _other -> value
    end
  end

  defp hide_headers_and_urls(value), do: value

  defp hide_header_values(headers) when is_list(headers) do
    Enum.map(headers, fn
      {name, _value} -> {name, "[REDACTED]"}
      [name, _value] -> [name, "[REDACTED]"]
      %{} = header -> hide_header_values(header)
      _other -> "[REDACTED]"
    end)
  end

  defp hide_header_values(%{} = headers) do
    if Map.has_key?(headers, "value") or Map.has_key?(headers, :value),
      do: headers |> Map.replace("value", "[REDACTED]") |> Map.replace(:value, "[REDACTED]"),
      else: Map.new(headers, fn {name, _value} -> {name, "[REDACTED]"} end)
  end

  defp hide_header_values(_headers), do: "[REDACTED]"

  defp header_key?(key), do: key in [:headers, "headers"]

  defp url(value) do
    if String.starts_with?(value, ["http://", "https://"]) do
      URI.parse(value)
    end
  rescue
    _error -> nil
  end

  @doc false
  def credential_entry?(key, value) do
    credential_key?(key) and not semantic_schema_descriptor?(value)
  end

  @doc false
  def validate_keys(keys) when is_list(keys) do
    case Enum.find(keys, &(not valid_key?(&1))) do
      nil ->
        {:ok, keys}

      invalid ->
        {:error,
         "expected a list of atom or string key names, got invalid key: #{inspect(invalid)}"}
    end
  end

  def validate_keys(keys) do
    {:error, "expected a list of atom or string key names, got: #{inspect(keys)}"}
  end

  @doc """
  Redacts sensitive keys and secret-looking string values.

  Key matching is intentionally conservative around common credential names:
  exact keys plus token-delimited or camel-case provider prefixes such as
  `:openai_api_key` are redacted.

  A string that holds a credential is replaced whole: a credential is rarely
  alone, and the text beside a recognized one (the rest of an env dump, a
  cookie header, a `.netrc` entry) often holds others no pattern names. This
  is the one set of credential patterns in Imp; text cleaned anywhere else
  before it is kept or shown (a command's captured output, as a whole; an
  optimizer pricing URL) is cleaned with it. A string is a credential when it holds:

    * a private key: a PEM block of any type, a PGP private key block, or a
      PuTTY key file;
    * a token in a vendor's format: OpenAI, Anthropic and OpenRouter (`sk-`),
      Stripe (`sk_live_`, `rk_live_`), GitHub, GitLab (`glpat-`), Hugging
      Face (`hf_`), AWS access key ids (`AKIA`, `ASIA`), Google API keys
      (`AIza`) and OAuth tokens (`ya29.`), Slack (`xox?-`), SendGrid
      (`SG.`), npm (`npm_`), PyPI (`pypi-`), Vault (`hvs.`), or a JSON Web
      Token;
    * a `Bearer` token that ends the string or its line or is closed by
      punctuation, or one with a digit or symbol in it followed by anything
      (a token of letters alone there reads as prose, `Bearer authentication
      is ...`); or a `Basic` credential that ends the string;
    * a `session=` value, or a long hex value assigned to a credential name
      (`token=<hex>`, `api_key: <hex>`);
    * a URL with a password in its user info, or a signed URL's signature or
      security token (`X-Amz-Signature`, `X-Amz-Security-Token`,
      `X-Goog-Signature`, Azure's `sig`).

      iex> Imp.Redaction.redact(%{api_key: "sk-test-secret-1234567890", model: "demo"})
      %{api_key: "[REDACTED]", model: "demo"}

      iex> Imp.Redaction.redact(%{nested: [%{"authorization" => "Bearer abcdefghijklmnop"}]})
      %{nested: [%{"authorization" => "[REDACTED]"}]}

      iex> Imp.Redaction.redact("sk-test-secret-1234567890")
      "[REDACTED]"

      iex> Imp.Redaction.redact(%{tenant_id: "public"}, [:tenant_id])
      %{tenant_id: "[REDACTED]"}

      iex> Imp.Redaction.redact({:error, "Bearer abcdefghijklmnop"})
      {:error, "[REDACTED]"}

      iex> Imp.Redaction.redact("key sk-test-secret-1234567890 was used")
      "[REDACTED]"

      iex> Imp.Redaction.redact("sha 0badcafe0badcafe0badcafe0badcafe0badcafe")
      "sha 0badcafe0badcafe0badcafe0badcafe0badcafe"

  """
  def redact(value, keys \\ @default_redact_keys)

  def redact(%Imp.Adapter.Types.Image{} = image, keys) do
    %{image | url: redact(image.url, keys), metadata: redact(image.metadata, keys)}
  end

  # Optimizer reports have an explicit, lossless JSON wire tag. Preserve the
  # known struct through this sanitization pass so Report.encode_term/1 can
  # emit that tag after redaction instead of persisting an indistinguishable
  # plain map. Report fields are still walked recursively, including candidate
  # and error payloads that may contain credentials.
  def redact(%Imp.Optimizer.Report{} = report, keys) do
    %{
      report
      | optimizer: redact(report.optimizer, keys),
        best_score: redact(report.best_score, keys),
        candidate_count: redact(report.candidate_count, keys),
        candidates: redact(report.candidates, keys),
        errors: redact(report.errors, keys),
        metadata: redact(report.metadata, keys)
    }
  end

  # A connection struct is redacted as it prints: ordinary redaction, then
  # every header value whatever the header is called, and the query, fragment
  # and user info of every URL. A header's name says nothing reliable about its
  # value (`X-Subscription-Token`, `Cookie`), and a URL's query often carries a
  # key. The struct keeps its type.
  def redact(%module{} = value, keys) when module in @connection_structs do
    Map.merge(value, value |> Map.from_struct() |> redact(keys) |> hide_headers_and_urls())
  end

  # The MCP OAuth structs hold secrets under names that say nothing about them:
  # a store's derived HMAC key, a flow's PKCE transaction and registered client,
  # and the `state` that an authorization URL also carries. Each keeps its type
  # and the fields its `Inspect` implementation shows; the secret fields become
  # the redaction marker.
  def redact(%Imp.MCP.OAuth.Store{} = store, keys) do
    %{store | directory: redact(store.directory, keys), key: "[REDACTED]"}
  end

  def redact(%Imp.MCP.OAuth.Flow{} = flow, keys) do
    %{
      flow
      | resource_url: redact(flow.resource_url, keys),
        redirect_uri: redact(flow.redirect_uri, keys),
        authorization_url: "[REDACTED]",
        transaction: "[REDACTED]",
        client: "[REDACTED]",
        issuer: redact(flow.issuer, keys),
        token_endpoint: redact(flow.token_endpoint, keys),
        scopes: redact(flow.scopes, keys)
    }
  end

  def redact(%Imp.MCP.OAuth.Pending{} = pending, keys) do
    %{
      pending
      | store: redact(pending.store, keys),
        credential: redact(pending.credential, keys),
        server_url: redact(pending.server_url, keys),
        authorization_url: "[REDACTED]",
        redirect_uri: redact(pending.redirect_uri, keys),
        flow: redact(pending.flow, keys),
        state: if(is_nil(pending.state), do: nil, else: "[REDACTED]")
    }
  end

  # An exception keeps its type, so a redacted failure still matches as the
  # failure it is; only its fields are redacted.
  def redact(value, keys) when is_exception(value) do
    struct(value.__struct__, value |> Map.from_struct() |> redact(keys))
  end

  # A URI is redacted as the URL it spells, so its query, fragment and user
  # info are hidden the same way whether it was given as a string or a struct.
  def redact(%URI{} = uri, keys), do: uri |> URI.to_string() |> redact(keys)

  def redact(value, keys) when is_struct(value) do
    value
    |> Map.from_struct()
    |> redact(keys)
  end

  def redact(value, keys) when is_map(value) do
    tagged_entry_keys = tagged_map_entry_keys(value)

    Map.new(value, fn {key, nested} ->
      cond do
        key in tagged_entry_keys -> {key, redact_tagged_entries(nested, keys)}
        redacted_entry?(key, nested, keys) -> {key, "[REDACTED]"}
        true -> {key, redact(nested, keys)}
      end
    end)
  end

  def redact([key, nested], keys) when is_atom(key) or is_binary(key) or is_map(key) do
    cond do
      redacted_entry?(key, nested, keys) -> [key, "[REDACTED]"]
      is_map(key) and tagged_key_names(key) == [] -> [redact(key, keys), redact(nested, keys)]
      true -> [key, redact(nested, keys)]
    end
  end

  def redact([], _keys), do: []

  # Provider failures and low-level protocol metadata can contain improper lists.
  # Walking cons cells directly preserves their shape and keeps the observability
  # boundary fail-safe instead of crashing inside Enumerable.
  def redact([head | tail], keys), do: [redact(head, keys) | redact(tail, keys)]

  def redact({key, nested}, keys) when is_atom(key) or is_binary(key) do
    if redacted_entry?(key, nested, keys),
      do: {key, "[REDACTED]"},
      else: {key, redact(nested, keys)}
  end

  def redact(value, keys) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&redact(&1, keys))
    |> List.to_tuple()
  end

  def redact(value, _keys) when is_binary(value),
    do: if(secret_value?(value), do: "[REDACTED]", else: value)

  def redact(value, _keys), do: value

  @doc """
  Recursively removes credential-bearing entries while preserving semantic data.

  This is intended for persistence and cache identity boundaries where restoring
  a redaction marker as a runtime option would be misleading.
  """
  def drop_credentials(value) do
    case drop_credential_value(value) do
      {:keep, sanitized} -> sanitized
      :drop -> nil
    end
  end

  defp redacted_key?(key, keys) do
    names =
      case tagged_key_names(key) do
        [] when is_atom(key) or is_binary(key) -> [key]
        [] -> []
        tagged_names -> tagged_names
      end

    Enum.any?(names, fn name ->
      if keys == @default_redact_keys do
        credential_key?(name)
      else
        tokens = key_tokens(name)

        Enum.any?(keys, fn redact_key ->
          redact_tokens = key_tokens(redact_key)
          tokens == redact_tokens or token_suffix?(tokens, redact_tokens)
        end)
      end
    end)
  end

  defp redacted_entry?(key, value, keys) do
    redacted_key?(key, keys) and
      (keys != @default_redact_keys or not semantic_schema_descriptor?(value))
  end

  defp valid_key?(key), do: is_atom(key) or is_binary(key)

  defp normalize_key(key) do
    key
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]/, "")
  end

  defp key_tokens(key) do
    key
    |> to_string()
    |> String.replace(~r/([a-z0-9])([A-Z])/, "\\1_\\2")
    |> String.replace(~r/([A-Z]+)([A-Z][a-z])/, "\\1_\\2")
    |> String.downcase()
    |> String.split(~r/[^a-z0-9]+/, trim: true)
  end

  defp token_suffix?(tokens, suffix) do
    suffix != [] and length(tokens) >= length(suffix) and
      Enum.take(tokens, -length(suffix)) == suffix
  end

  defp drop_credential_value(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> drop_credential_value()
  end

  defp drop_credential_value(map) when is_map(map) do
    tagged_entry_keys = tagged_map_entry_keys(map)

    sanitized =
      Enum.reduce(map, %{}, fn {key, nested}, acc ->
        cond do
          key in tagged_entry_keys ->
            Map.put(acc, key, drop_tagged_entries(nested))

          credential_entry?(key, nested) ->
            acc

          true ->
            case drop_credential_value(nested) do
              {:keep, value} -> Map.put(acc, key, value)
              :drop -> acc
            end
        end
      end)

    {:keep, sanitized}
  end

  defp drop_credential_value([key, nested])
       when is_atom(key) or is_binary(key) or is_map(key) do
    if credential_entry?(key, nested), do: :drop, else: drop_noncredential_pair([key, nested])
  end

  defp drop_credential_value(list) when is_list(list), do: drop_list_values(list, [])

  defp drop_credential_value({key, nested}) when is_atom(key) or is_binary(key) do
    if credential_entry?(key, nested) do
      :drop
    else
      case drop_credential_value(nested) do
        {:keep, value} -> {:keep, {key, value}}
        :drop -> :drop
      end
    end
  end

  defp drop_credential_value(tuple) when is_tuple(tuple) do
    values =
      tuple
      |> Tuple.to_list()
      |> Enum.reduce([], fn nested, acc ->
        case drop_credential_value(nested) do
          {:keep, value} -> [value | acc]
          :drop -> acc
        end
      end)
      |> Enum.reverse()

    {:keep, List.to_tuple(values)}
  end

  defp drop_credential_value(value) when is_binary(value), do: {:keep, redact(value)}
  defp drop_credential_value(value), do: {:keep, value}

  defp drop_noncredential_pair([key, nested]) do
    case drop_credential_value(nested) do
      {:keep, value} -> {:keep, [key, value]}
      :drop -> :drop
    end
  end

  defp drop_list_values([], acc), do: {:keep, Enum.reverse(acc)}

  defp drop_list_values([head | tail], acc) do
    acc =
      case drop_credential_value(head) do
        {:keep, value} -> [value | acc]
        :drop -> acc
      end

    drop_list_values(tail, acc)
  end

  defp drop_list_values(tail, acc) do
    sanitized_tail =
      case drop_credential_value(tail) do
        {:keep, value} -> value
        :drop -> []
      end

    {:keep, Enum.reduce(acc, sanitized_tail, fn value, rest -> [value | rest] end)}
  end

  defp keep_tagged_entry(acc, encoded_key, nested) do
    case drop_credential_value(nested) do
      {:keep, sanitized} -> [[encoded_key, sanitized] | acc]
      :drop -> acc
    end
  end

  defp redact_tagged_entries(entries, keys) when is_list(entries) do
    Enum.map(entries, fn
      [encoded_key, nested] ->
        if redacted_entry?(encoded_key, nested, keys),
          do: [encoded_key, "[REDACTED]"],
          else: [redact(encoded_key, keys), redact(nested, keys)]

      nested ->
        redact(nested, keys)
    end)
  end

  defp redact_tagged_entries(value, keys), do: redact(value, keys)

  defp drop_tagged_entries(entries) when is_list(entries) do
    entries
    |> Enum.reduce([], fn
      [encoded_key, nested], acc ->
        if credential_entry?(encoded_key, nested),
          do: acc,
          else: keep_tagged_entry(acc, encoded_key, nested)

      nested, acc ->
        case drop_credential_value(nested) do
          {:keep, sanitized} -> [sanitized | acc]
          :drop -> acc
        end
    end)
    |> Enum.reverse()
  end

  defp drop_tagged_entries(value) do
    case drop_credential_value(value) do
      {:keep, sanitized} -> sanitized
      :drop -> nil
    end
  end

  defp tagged_map_entry_keys(value) do
    types = [Map.get(value, "__imp_type__"), Map.get(value, :__imp_type__)]

    if Enum.any?(types, &(&1 in ["map", :map])) do
      ["entries", :entries]
      |> Enum.filter(&is_list(Map.get(value, &1)))
    else
      []
    end
  end

  defp tagged_key_names(encoded_key) when is_map(encoded_key) do
    types = [Map.get(encoded_key, "__imp_type__"), Map.get(encoded_key, :__imp_type__)]

    if Enum.any?(types, &(&1 in ["atom", :atom])) do
      encoded_key
      |> then(&[Map.get(&1, "value"), Map.get(&1, :value)])
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()
    else
      []
    end
  end

  defp tagged_key_names(_value), do: []

  defp semantic_schema_descriptor?(value)
       when value in [
              :string,
              :integer,
              :float,
              :number,
              :boolean,
              :object,
              :map,
              :list,
              :array,
              :any
            ],
       do: true

  defp semantic_schema_descriptor?(value)
       when value in ~w(string integer float number boolean object map list array any),
       do: true

  defp semantic_schema_descriptor?(value) when is_map(value) do
    types = [Map.get(value, "__imp_type__"), Map.get(value, :__imp_type__)]
    values = [Map.get(value, "value"), Map.get(value, :value)]
    schema_types = [Map.get(value, "type"), Map.get(value, :type)]

    (Enum.any?(types, &(&1 in ["atom", :atom])) and
       Enum.any?(
         values,
         &(&1 in ~w(string integer float number boolean object map list array any))
       ) and
       Enum.all?(Map.keys(value), &(&1 in ["__imp_type__", :__imp_type__, "value", :value]))) or
      (Enum.any?(
         schema_types,
         &(&1 in ([
                    :string,
                    :integer,
                    :float,
                    :number,
                    :boolean,
                    :object,
                    :map,
                    :list,
                    :array,
                    :any
                  ] ++ ~w(string integer float number boolean object map list array any)))
       ) and schema_descriptor_keys?(value)) or
      tagged_schema_descriptor?(value)
  end

  defp semantic_schema_descriptor?(_value), do: false

  defp tagged_schema_descriptor?(value) do
    types = [Map.get(value, "__imp_type__"), Map.get(value, :__imp_type__)]

    if Enum.any?(types, &(&1 in ["map", :map])) do
      value
      |> Imp.Optimizer.Report.decode_term()
      |> semantic_schema_descriptor?()
    else
      false
    end
  rescue
    _error -> false
  end

  defp schema_descriptor_keys?(value) do
    Enum.all?(Map.keys(value), fn
      key when is_atom(key) or is_binary(key) ->
        MapSet.member?(@schema_descriptor_keys, to_string(key))

      _key ->
        false
    end)
  end

  # The patterns are compiled once per loaded module and kept in
  # `:persistent_term`: a regex literal is rebuilt on every evaluation, and
  # `redact/2` tries every pattern on every string it walks.
  @secret_patterns_key {__MODULE__, :secret_patterns, System.unique_integer([:positive])}

  defp secret_patterns do
    case :persistent_term.get(@secret_patterns_key, nil) do
      nil ->
        patterns = compile_secret_patterns()
        :persistent_term.put(@secret_patterns_key, patterns)
        patterns

      patterns ->
        patterns
    end
  end

  defp secret_value?(value) do
    trimmed = String.trim(value)

    Enum.any?(secret_patterns(), fn
      {:basic, pattern} -> basic_credential?(pattern, trimmed)
      pattern -> Regex.match?(pattern, trimmed)
    end)
  end

  # Each pattern is one credential shape; a string that matches any is
  # replaced whole. Every token pattern has a boundary on each side, so a
  # longer word that contains the prefix is not taken for a token.
  #
  # `Bearer` and `Basic` are matched in any case, and both patterns turn off
  # PCRE's start-of-match optimization with `(*NO_START_OPT)`. With it, PCRE
  # looks for a leading letter that may be either case by searching for each
  # case separately; when one case never occurs again, each failed attempt
  # searches to the end of the string, so a string of near misses in one case
  # (`BEARER x` lines) took quadratic time. `session` does not show this and
  # keeps the optimization.
  defp compile_secret_patterns do
    [
      # Private keys: a PEM block of any type (PKCS#8, RSA, EC, OpenSSH,
      # encrypted), a PGP private key block, a PuTTY key file.
      ~r/-----BEGIN [A-Z0-9 ]{0,40}PRIVATE KEY(?: BLOCK)?-----/,
      ~r/PuTTY-User-Key-File-[0-9]+:/,
      # OpenAI (`sk-`, `sk-proj-`), Anthropic (`sk-ant-`), OpenRouter (`sk-or-`).
      ~r/(?:\A|[^A-Za-z0-9_-])sk-[A-Za-z0-9_-]{8,}(?=\z|[^A-Za-z0-9_-])/,
      # Stripe secret and restricted live keys.
      ~r/(?<![A-Za-z0-9_])[sr]k_live_[A-Za-z0-9]{16,}(?![A-Za-z0-9_])/,
      # GitHub classic, OAuth, user-to-server, server and refresh tokens, and
      # fine-grained personal access tokens.
      ~r/(?<![A-Za-z0-9_])(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{22,})(?![A-Za-z0-9_])/,
      # GitLab personal access tokens.
      ~r/(?<![A-Za-z0-9_-])glpat-[A-Za-z0-9_-]{20,}(?![A-Za-z0-9_-])/,
      # Hugging Face user access tokens.
      ~r/(?<![A-Za-z0-9_])hf_[A-Za-z0-9]{30,}(?![A-Za-z0-9_])/,
      # AWS access key ids: AKIA (long-term) or ASIA (temporary), then 16 or
      # more uppercase base-32 characters.
      ~r/(?:\A|[^A-Z0-9])(?:AKIA|ASIA)[0-9A-Z]{16,}(?=\z|[^A-Z0-9])/,
      # Google API keys: AIza and exactly 35 url-safe base64 characters.
      ~r/(?:\A|[^A-Za-z0-9_-])AIza[0-9A-Za-z_-]{35}(?=\z|[^A-Za-z0-9_-])/,
      # Google OAuth access tokens.
      ~r/(?<![A-Za-z0-9_.-])ya29\.[A-Za-z0-9_-]{16,}/,
      # Slack bot, user, app and configuration tokens (`xoxb-`, `xoxp-`, ...).
      ~r/(?<![A-Za-z0-9_-])xox[a-z]-[A-Za-z0-9-]{10,}(?![A-Za-z0-9_-])/,
      # SendGrid API keys: `SG.` and two dot-separated parts.
      ~r/(?<![A-Za-z0-9_.-])SG\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/,
      # npm access tokens.
      ~r/(?<![A-Za-z0-9_])npm_[A-Za-z0-9]{30,}(?![A-Za-z0-9_])/,
      # PyPI API tokens: `pypi-` and a macaroon, which always starts `AgE`.
      ~r/(?<![A-Za-z0-9_-])pypi-AgE[A-Za-z0-9_-]{16,}/,
      # HashiCorp Vault service tokens.
      ~r/(?<![A-Za-z0-9_.-])hvs\.[A-Za-z0-9_-]{20,}/,
      # JSON Web Tokens: header.payload.signature, each base64url; the first
      # two are JSON objects, so they start `eyJ`.
      ~r/(?<![A-Za-z0-9_-])eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\./,
      ~r/(*NO_START_OPT)(?:\A|[\s:;,"'=({\[])Bearer[ \t]+(?:[A-Za-z0-9._~+\/-]{12,}={0,2}(?=\z|[\r\n"'`}\]),;])|(?=[A-Za-z]*[0-9._~+\/-])[A-Za-z0-9._~+\/-]{12,}={0,2}(?![A-Za-z0-9._~+\/=-]))/i,
      {:basic, ~r/(*NO_START_OPT)(?:\A|[\s:;,])Basic[ \t]+([A-Za-z0-9+\/]+={0,2})\z/i},
      ~r/(?:\A|[?&;,\s])session\s*=\s*[A-Za-z0-9._~+\/-]{8,}={0,2}(?=\z|[?&;,\s])/i,
      # Long hex strings alone are not credentials: Imp passes SHA-1 and
      # SHA-256 digests around as cache keys and git identities. One is a
      # credential in an explicit assignment (`token=<hex>`, `secret: <hex>`),
      # where the name says what it is.
      ~r/(?:secret|token|password|api[_-]?key|credential)s?\s*[=:]\s*"?[0-9a-fA-F]{32,}"?(?=\z|[^0-9a-fA-F])/i,
      # A URL with a password in its user info, as a database URL carries one.
      ~r/:\/\/[^\s\/?#@:]*:[^\s\/?#@]+@/,
      # A signed URL's signature or session token, with a value long enough
      # to be one.
      ~r/[?&](?:X-Amz-Signature|X-Amz-Security-Token|X-Goog-Signature|sig)=[^&#\s]{16,}/
    ]
  end

  # `Basic` is followed by base64 in prose too ("Basic authentication"); it is
  # a credential only when the decoded text is `user:password`.
  defp basic_credential?(pattern, value) do
    case Regex.run(pattern, value, capture: :all_but_first) do
      [encoded] ->
        case Base.decode64(encoded) do
          {:ok, decoded} -> String.contains?(decoded, ":")
          :error -> false
        end

      _other ->
        false
    end
  end
end

# A connection struct prints as `Imp.Redaction.redact/1` leaves it: an LM
# client's `api_key` or headers, a retriever's or tracker's headers. A program
# prints its LM, so a program in IEx, a log line or a crash report would
# otherwise carry the key.
for module <- Imp.Redaction.connection_structs() do
  defimpl Inspect, for: module do
    def inspect(struct, opts), do: Inspect.Any.inspect(Imp.Redaction.redact(struct), opts)
  end
end
