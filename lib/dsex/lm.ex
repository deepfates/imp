defmodule DSEx.LM do
  @moduledoc """
  Behaviour for language model clients.
  """

  @callback generate(messages :: list(map()), opts :: keyword()) ::
              {:ok, map() | binary() | DSEx.Prediction.t()} | {:error, term()}
  @callback stream(lm :: term(), messages :: list(map()), opts :: keyword()) :: Enumerable.t()
  @optional_callbacks stream: 3

  def generate(lm, messages, opts \\ [])
  def generate(module, messages, opts) when is_atom(module), do: module.generate(messages, opts)

  def generate(%module{} = lm, messages, opts) do
    cond do
      function_exported?(module, :generate, 3) -> module.generate(lm, messages, opts)
      function_exported?(module, :generate, 2) -> module.generate(messages, opts)
      true -> {:error, {:not_an_lm, module}}
    end
  end

  def generate(%{module: module, opts: client_opts}, messages, opts) do
    module.generate(messages, Keyword.merge(client_opts, opts))
  end

  def generate(fun, messages, opts) when is_function(fun, 2), do: fun.(messages, opts)
end
