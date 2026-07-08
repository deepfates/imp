defmodule DSEx.HTTP do
  @moduledoc "Small injectable HTTP boundary used by provider clients."

  @callback post(String.t(), [{String.t(), String.t()}], iodata(), keyword()) ::
              {:ok, %{status: non_neg_integer(), body: binary(), headers: list()}}
              | {:error, term()}

  @callback stream(String.t(), [{String.t(), String.t()}], iodata(), keyword()) ::
              Enumerable.t()

  @optional_callbacks stream: 4

  def post(transport, url, headers, body, opts \\ [])

  def post(transport, url, headers, body, opts) do
    opts = validate_opts!(opts, "DSEx.HTTP.post/5")
    do_post(transport, url, headers, body, opts)
  end

  defp do_post(module, url, headers, body, opts) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :post, 4) do
      safe_transport_call(module, fn -> module.post(url, headers, body, opts) end)
    else
      {:error, {:not_http_transport, module}}
    end
  end

  defp do_post(fun, url, headers, body, opts) when is_function(fun, 4),
    do: safe_transport_call(:anonymous_http_transport, fn -> fun.(url, headers, body, opts) end)

  defp do_post(transport, _url, _headers, _body, _opts),
    do: {:error, {:not_http_transport, transport}}

  def stream(transport, url, headers, body, opts \\ [])

  def stream(transport, url, headers, body, opts) do
    opts = validate_opts!(opts, "DSEx.HTTP.stream/5")
    do_stream(transport, url, headers, body, opts)
  end

  defp do_stream(module, url, headers, body, opts) when is_atom(module) do
    cond do
      Code.ensure_loaded?(module) and function_exported?(module, :stream, 4) ->
        safe_stream(module, fn -> module.stream(url, headers, body, opts) end)

      Code.ensure_loaded?(module) and function_exported?(module, :post, 4) ->
        post_stream(module, url, headers, body, opts)

      true ->
        error_stream({:not_http_transport, module})
    end
  end

  defp do_stream(fun, url, headers, body, opts) when is_function(fun, 4),
    do: post_stream(fun, url, headers, body, opts)

  defp do_stream(transport, _url, _headers, _body, _opts),
    do: error_stream({:not_http_transport, transport})

  defp post_stream(module, url, headers, body, opts) do
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

  defp error_stream(reason), do: Stream.map([{:error, reason}], & &1)

  defp safe_stream(transport, fun) do
    case safe_transport_call(transport, fun) do
      {:error, {:http_transport_failed, ^transport, _reason} = reason} -> error_stream(reason)
      {:error, reason} -> error_stream(reason)
      stream -> stream
    end
  end

  defp safe_transport_call(transport, fun) do
    fun.()
  rescue
    error -> {:error, {:http_transport_failed, transport, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:http_transport_failed, transport, {kind, reason}}}
  end

  defp validate_opts!(opts, context) when is_list(opts) do
    if Keyword.keyword?(opts) do
      opts
    else
      raise ArgumentError, "#{context} expects keyword options, got: #{inspect(opts)}"
    end
  end

  defp validate_opts!(opts, context) do
    raise ArgumentError, "#{context} expects keyword options, got: #{inspect(opts)}"
  end
end

defmodule DSEx.HTTP.Hackneyless do
  @moduledoc false

  @behaviour DSEx.HTTP

  @default_timeout 15_000

  @impl true
  def post(url, headers, body, opts) do
    opts = validate_opts!(opts, "#{inspect(__MODULE__)}.post/4")

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
    validate_nested_opts!(http_opts, "#{inspect(__MODULE__)}.secure_http_opts/1")

    Keyword.update(http_opts, :ssl, default_ssl_opts(), fn ssl_opts ->
      Keyword.merge(default_ssl_opts(), ssl_opts)
    end)
  end

  def http_opts(opts) do
    opts = validate_opts!(opts, "#{inspect(__MODULE__)}.http_opts/1")
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    http_opts = Keyword.get(opts, :http_opts, [])
    validate_nested_opts!(http_opts, "#{inspect(__MODULE__)}.http_opts/1 :http_opts")

    http_opts
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

  defp validate_opts!(opts, context) when is_list(opts) do
    if Keyword.keyword?(opts) do
      opts
    else
      raise ArgumentError, "#{context} expects keyword options, got: #{inspect(opts)}"
    end
  end

  defp validate_opts!(opts, context) do
    raise ArgumentError, "#{context} expects keyword options, got: #{inspect(opts)}"
  end

  defp validate_nested_opts!(opts, context) when is_list(opts) do
    unless Keyword.keyword?(opts) do
      raise ArgumentError, "#{context} expects a keyword list, got: #{inspect(opts)}"
    end
  end

  defp validate_nested_opts!(opts, context) do
    raise ArgumentError, "#{context} expects a keyword list, got: #{inspect(opts)}"
  end
end
