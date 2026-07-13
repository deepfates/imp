defmodule DSEx.Tracking.Transport do
  @moduledoc "HTTP boundary used by tracking backends."

  @type method :: :delete | :get | :patch | :post | :put
  @type headers :: [{String.t(), String.t()}]
  @type response :: %{
          required(:status) => non_neg_integer(),
          required(:headers) => term(),
          required(:body) => term()
        }

  @callback request(method(), String.t(), headers(), iodata(), keyword()) ::
              {:ok, response()} | {:error, term()}
end
