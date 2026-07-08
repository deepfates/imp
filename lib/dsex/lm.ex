defmodule DSEx.LM do
  @moduledoc """
  Behaviour for language model clients.
  """

  @callback generate(messages :: list(map()), opts :: keyword()) ::
              {:ok, map() | binary() | DSEx.Prediction.t()} | {:error, term()}
  @callback stream(lm :: term(), messages :: list(map()), opts :: keyword()) :: Enumerable.t()
  @optional_callbacks stream: 3

  def generate(lm, messages, opts \\ [])

  def generate(lm, messages, opts) do
    opts = validate_opts!(opts, "DSEx.LM.generate/3")
    dispatch_generate(lm, messages, opts)
  end

  defp dispatch_generate(module, messages, opts) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :generate, 2) do
      module.generate(messages, opts)
    else
      {:error, {:not_an_lm, module}}
    end
  end

  defp dispatch_generate(%module{} = lm, messages, opts) do
    cond do
      function_exported?(module, :generate, 3) -> module.generate(lm, messages, opts)
      function_exported?(module, :generate, 2) -> module.generate(messages, opts)
      true -> {:error, {:not_an_lm, module}}
    end
  end

  defp dispatch_generate(%{module: module, opts: client_opts}, messages, opts) do
    client_opts = validate_opts!(client_opts, "DSEx.LM.generate/3 client :opts")
    dispatch_generate(module, messages, Keyword.merge(client_opts, opts))
  end

  defp dispatch_generate(fun, messages, opts) when is_function(fun, 2), do: fun.(messages, opts)

  defp dispatch_generate(lm, _messages, _opts), do: {:error, {:not_an_lm, lm}}

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
