defmodule Dachshund.Clients.OpenAI do
  @moduledoc "OpenAI chat client."
  def new(model, opts \\ []),
    do: Dachshund.Clients.HTTPLM.new(model, Keyword.put(opts, :provider, :openai))
end

defmodule Dachshund.Clients.LiteLLM do
  @moduledoc "LiteLLM proxy client using the OpenAI-compatible API."
  def new(model, opts \\ []),
    do: Dachshund.Clients.HTTPLM.new(model, Keyword.put(opts, :provider, :litellm))
end

defmodule Dachshund.Clients.Local do
  @moduledoc "Local OpenAI-compatible model server client."
  def new(model, opts \\ []),
    do: Dachshund.Clients.HTTPLM.new(model, Keyword.put(opts, :provider, :local))
end

defmodule Dachshund.Clients.Databricks do
  @moduledoc "Databricks model-serving client."
  def new(model, opts \\ []),
    do: Dachshund.Clients.HTTPLM.new(model, Keyword.put(opts, :provider, :databricks))
end
