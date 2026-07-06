defmodule DSEx.HTTP do
  @moduledoc "Small injectable HTTP boundary used by provider clients."

  @callback post(String.t(), [{String.t(), String.t()}], iodata(), keyword()) ::
              {:ok, %{status: non_neg_integer(), body: binary(), headers: list()}}
              | {:error, term()}

  @callback stream(String.t(), [{String.t(), String.t()}], iodata(), keyword()) ::
              Enumerable.t()

  @optional_callbacks stream: 4

  def post(transport, url, headers, body, opts \\ [])

  def post(module, url, headers, body, opts) when is_atom(module),
    do: module.post(url, headers, body, opts)

  def post(fun, url, headers, body, opts) when is_function(fun, 4),
    do: fun.(url, headers, body, opts)

  def stream(transport, url, headers, body, opts \\ [])

  def stream(module, url, headers, body, opts) when is_atom(module) do
    if function_exported?(module, :stream, 4) do
      module.stream(url, headers, body, opts)
    else
      Stream.resource(
        fn -> post(module, url, headers, body, opts) end,
        fn
          {:ok, %{body: response}} -> {[response], :done}
          {:error, reason} -> {[{:error, reason}], :done}
          :done -> {:halt, :done}
        end,
        fn _ -> :ok end
      )
    end
  end

  def stream(fun, url, headers, body, opts) when is_function(fun, 4),
    do: Stream.map([fun.(url, headers, body, opts)], & &1)
end

defmodule DSEx.HTTP.Hackneyless do
  @moduledoc """
  Default HTTP transport implemented with Erlang `:httpc`.

  It is intentionally boring and dependency-light. Tests inject their own
  transport so provider contracts are verified without live credentials.
  """

  @behaviour DSEx.HTTP

  @default_timeout 15_000

  @impl true
  def post(url, headers, body, opts) do
    :inets.start()
    :ssl.start()

    headers =
      headers
      |> Enum.reject(fn {key, _value} -> String.downcase(to_string(key)) == "content-type" end)
      |> Enum.map(fn {key, value} ->
        {String.to_charlist(to_string(key)), String.to_charlist(to_string(value))}
      end)

    request = {String.to_charlist(url), headers, ~c"application/json", IO.iodata_to_binary(body)}
    http_opts = http_opts(opts)
    request_opts = Keyword.get(opts, :request_opts, [])

    case :httpc.request(:post, request, http_opts, request_opts) do
      {:ok, {{_version, status, _reason}, response_headers, response_body}} ->
        {:ok,
         %{status: status, headers: response_headers, body: IO.iodata_to_binary(response_body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def secure_http_opts(http_opts) do
    Keyword.update(http_opts, :ssl, default_ssl_opts(), fn ssl_opts ->
      Keyword.merge(default_ssl_opts(), ssl_opts)
    end)
  end

  def http_opts(opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    opts
    |> Keyword.get(:http_opts, [])
    |> Keyword.put_new(:timeout, timeout)
    |> Keyword.put_new(:connect_timeout, timeout)
    |> secure_http_opts()
  end

  def default_ssl_opts do
    [
      verify: :verify_peer,
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ]
    |> maybe_put_cacertfile()
  end

  defp maybe_put_cacertfile(ssl_opts) do
    case Enum.find(ca_cert_paths(), &File.regular?/1) do
      nil -> ssl_opts
      path -> Keyword.put(ssl_opts, :cacertfile, String.to_charlist(path))
    end
  end

  defp ca_cert_paths do
    [
      "/etc/ssl/cert.pem",
      "/etc/ssl/certs/ca-certificates.crt",
      "/etc/pki/tls/certs/ca-bundle.crt",
      "/etc/ssl/ca-bundle.pem"
    ]
  end
end
