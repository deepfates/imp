defmodule DSPy.Clients.OpenAI do
  @moduledoc "OpenAI chat client."
  def new(model, opts \\ []),
    do: DSPy.Clients.HTTPLM.new(model, Keyword.put(opts, :provider, :openai))
end

defmodule DSPy.Clients.LiteLLM do
  @moduledoc "LiteLLM proxy client using the OpenAI-compatible API."
  def new(model, opts \\ []),
    do: DSPy.Clients.HTTPLM.new(model, Keyword.put(opts, :provider, :litellm))
end

defmodule DSPy.Clients.Local do
  @moduledoc "Local OpenAI-compatible model server client."
  def new(model, opts \\ []),
    do: DSPy.Clients.HTTPLM.new(model, Keyword.put(opts, :provider, :local))
end

defmodule DSPy.Clients.Databricks do
  @moduledoc "Databricks model-serving client."
  def new(model, opts \\ []),
    do: DSPy.Clients.HTTPLM.new(model, Keyword.put(opts, :provider, :databricks))
end
