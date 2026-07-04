defmodule DSPy.LM do
  @moduledoc """
  Behaviour for language model clients.
  """

  @callback generate(messages :: list(map()), opts :: keyword()) ::
              {:ok, map() | binary() | DSPy.Prediction.t()} | {:error, term()}

  def generate(lm, messages, opts \\ [])
  def generate(module, messages, opts) when is_atom(module), do: module.generate(messages, opts)

  def generate(%{module: module, opts: client_opts}, messages, opts) do
    module.generate(messages, Keyword.merge(client_opts, opts))
  end

  def generate(fun, messages, opts) when is_function(fun, 2), do: fun.(messages, opts)
end
