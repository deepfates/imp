defmodule Imp.Redaction do
  @moduledoc """
  Shared redaction helpers for traces, telemetry, and runtime metadata.

  Imp keeps prompts, tool inputs, provider metadata, and optimizer reports
  inspectable, but credentials and credential-shaped strings must not leak into
  those artifacts. `redact/2` walks ordinary Elixir maps, lists, tuples, and structs,
  replacing known secret fields and secret-looking string values with
  `"[REDACTED]"`.

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
  # What a client, retriever or tracker prints: `redact/1`, then every header
  # value whatever the header is called, and the query, fragment and user info
  # of every URL. A header's name says nothing reliable about its value
  # (`X-Subscription-Token`, `Cookie`), and a URL's query often carries a key.
  def redact_for_print(value), do: value |> redact() |> hide_headers_and_urls()

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

  def redact(value, _keys) when is_binary(value) do
    if secret_value?(value), do: "[REDACTED]", else: value
  end

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

    allowed_keys = MapSet.new(["__imp_type__", :__imp_type__, "value", :value])

    (Enum.any?(types, &(&1 in ["atom", :atom])) and
       Enum.any?(
         values,
         &(&1 in ~w(string integer float number boolean object map list array any))
       ) and
       Enum.all?(Map.keys(value), &MapSet.member?(allowed_keys, &1))) or
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

  defp secret_value?(value) do
    trimmed = String.trim(value)

    String.match?(
      value,
      ~r/(?:\A|[^A-Za-z0-9_-])sk-[A-Za-z0-9_-]{8,}(?=\z|[^A-Za-z0-9_-])/
    ) or bearer_credential?(trimmed) or basic_credential?(trimmed) or
      session_assignment?(value) or aws_access_key_id?(value) or google_api_key?(value) or
      hex_credential_assignment?(value)
  end

  # AWS access key ids have a fixed, distinctive shape: a 4-letter prefix
  # (AKIA long-term, ASIA temporary) followed by exactly 16 uppercase
  # base-32-ish characters. Distinctive enough to redact standalone.
  defp aws_access_key_id?(value),
    do: String.match?(value, ~r/(?:\A|[^A-Z0-9])(?:AKIA|ASIA)[0-9A-Z]{16}(?=\z|[^A-Z0-9])/)

  # Google API keys are "AIza" followed by exactly 35 url-safe base64 chars.
  defp google_api_key?(value),
    do:
      String.match?(
        value,
        ~r/(?:\A|[^A-Za-z0-9_-])AIza[0-9A-Za-z_-]{35}(?=\z|[^A-Za-z0-9_-])/
      )

  # Long hex strings alone are NOT treated as secrets — this codebase passes
  # SHA-1/SHA-256 digests around as cache keys and git identities, and blanket
  # hex redaction would destroy them. A long hex value is only redacted when it
  # sits in an explicit credential assignment (`token=<hex>`, `secret: <hex>`),
  # where the key name already says what it is.
  defp hex_credential_assignment?(value),
    do:
      String.match?(
        value,
        ~r/(?:secret|token|password|api[_-]?key|credential)s?\s*[=:]\s*"?[0-9a-fA-F]{32,}"?(?=\z|[^0-9a-fA-F])/i
      )

  defp bearer_credential?(value),
    do:
      String.match?(
        value,
        ~r/(?:\A|[\s:;,"'=({\[])Bearer[ \t]+[A-Za-z0-9._~+\/-]{12,}={0,2}(?=\z|["'`}\]),;])/i
      )

  defp basic_credential?(value) do
    case Regex.run(~r/(?:\A|[\s:;,])Basic[ \t]+([A-Za-z0-9+\/]+={0,2})\z/i, value,
           capture: :all_but_first
         ) do
      [encoded] ->
        case Base.decode64(encoded) do
          {:ok, decoded} -> String.contains?(decoded, ":")
          :error -> false
        end

      _other ->
        false
    end
  end

  defp session_assignment?(value) do
    String.match?(
      value,
      ~r/(?:\A|[?&;,\s])session\s*=\s*[A-Za-z0-9._~+\/-]{8,}={0,2}(?=\z|[?&;,\s])/i
    )
  end
end

# Structs that can hold a credential print it redacted: an LM client's
# `api_key` or headers, a retriever's or tracker's headers. A program prints
# its LM, so a program in IEx, a log line or a crash report would otherwise
# carry the key.
defimpl Inspect,
  for: [
    Imp.Clients.ReqLLM,
    Imp.Retrievers.HTTP,
    Imp.Tracking.MLflow,
    Imp.Tracking.WandB,
    Imp.Optimize.Anything.Config.Tracking
  ] do
  # `redact_for_print/1` returns a struct's fields as a map; merging them back
  # keeps the struct, so it prints as one.
  def inspect(struct, opts),
    do: Inspect.Any.inspect(Map.merge(struct, Imp.Redaction.redact_for_print(struct)), opts)
end
