defmodule DSPy.HTTP do
  @moduledoc "Small injectable HTTP boundary used by provider clients."

  @callback post(String.t(), [{String.t(), String.t()}], iodata(), keyword()) ::
              {:ok, %{status: non_neg_integer(), body: binary(), headers: list()}}
              | {:error, term()}

  def post(transport, url, headers, body, opts \\ [])

  def post(module, url, headers, body, opts) when is_atom(module),
    do: module.post(url, headers, body, opts)

  def post(fun, url, headers, body, opts) when is_function(fun, 4),
    do: fun.(url, headers, body, opts)
end

defmodule DSPy.HTTP.Hackneyless do
  @moduledoc """
  Default HTTP transport implemented with Erlang `:httpc`.

  It is intentionally boring and dependency-light. Tests inject their own
  transport so provider contracts are verified without live credentials.
  """

  @behaviour DSPy.HTTP

  @impl true
  def post(url, headers, body, opts) do
    :inets.start()
    :ssl.start()

    request = {String.to_charlist(url), headers, ~c"application/json", IO.iodata_to_binary(body)}
    http_opts = Keyword.get(opts, :http_opts, [])
    request_opts = Keyword.get(opts, :request_opts, [])

    case :httpc.request(:post, request, http_opts, request_opts) do
      {:ok, {{_version, status, _reason}, response_headers, response_body}} ->
        {:ok,
         %{status: status, headers: response_headers, body: IO.iodata_to_binary(response_body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
