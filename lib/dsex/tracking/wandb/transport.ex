defmodule DSEx.Tracking.WandB.Transport do
  @moduledoc """
  Injectable HTTP boundary for the isolated W&B protocol client.

  A transport can be a module implementing `request/5` or an arity-five
  function. The callback receives method, URL, headers, body, and request
  options. It must return a response map without performing JSON decoding.
  """

  @type method :: :post | :put
  @type headers :: [{String.t(), String.t()}]
  @type response :: %{
          required(:status) => non_neg_integer(),
          required(:body) => binary(),
          optional(:headers) => list()
        }

  @callback request(method(), String.t(), headers(), iodata(), keyword()) ::
              {:ok, response()} | {:error, term()}

  @spec request(module() | function(), method(), String.t(), headers(), iodata(), keyword()) ::
          {:ok, response()} | {:error, term()}
  def request(transport, method, url, headers, body, opts)

  def request(module, method, url, headers, body, opts) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :request, 5) do
      safe_call(module, fn -> module.request(method, url, headers, body, opts) end)
    else
      {:error, {:not_wandb_transport, module}}
    end
  end

  def request(fun, method, url, headers, body, opts) when is_function(fun, 5) do
    safe_call(:anonymous_wandb_transport, fn -> fun.(method, url, headers, body, opts) end)
  end

  def request(transport, _method, _url, _headers, _body, _opts),
    do: {:error, {:not_wandb_transport, transport}}

  defp safe_call(transport, fun) do
    fun.()
  rescue
    error -> {:error, {:wandb_transport_failed, transport, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:wandb_transport_failed, transport, {kind, reason}}}
  end
end
