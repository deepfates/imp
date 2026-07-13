defmodule DSEx.Tracking.Transport.Req do
  @moduledoc "Req-backed tracking transport."

  @behaviour DSEx.Tracking.Transport

  @impl true
  def request(method, url, headers, body, opts) do
    request_opts =
      opts
      |> Keyword.put(:method, method)
      |> Keyword.put(:url, url)
      |> Keyword.put(:headers, headers)
      |> Keyword.put(:body, IO.iodata_to_binary(body))
      |> Keyword.put_new(:decode_body, false)
      |> Keyword.put_new(:retry, false)

    case Req.request(request_opts) do
      {:ok, %Req.Response{} = response} ->
        {:ok, %{status: response.status, headers: response.headers, body: response.body}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error -> {:error, {:req_failed, Exception.message(error)}}
  end
end
