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

  def validate_lm(nil), do: {:ok, nil}

  def validate_lm(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :generate, 2) do
      {:ok, module}
    else
      {:error, "expected an LM module exporting generate/2"}
    end
  end

  def validate_lm(fun) when is_function(fun, 2), do: {:ok, fun}

  def validate_lm(%module{} = lm) do
    if Code.ensure_loaded?(module) and
         (function_exported?(module, :generate, 3) or function_exported?(module, :generate, 2)) do
      {:ok, lm}
    else
      {:error, "expected an LM struct whose module exports generate/3 or generate/2"}
    end
  end

  def validate_lm(%{module: module, opts: opts} = lm) when is_atom(module) do
    cond do
      not Keyword.keyword?(opts) ->
        {:error, "expected configured LM :opts to be a keyword list"}

      Code.ensure_loaded?(module) and function_exported?(module, :generate, 2) ->
        {:ok, lm}

      true ->
        {:error, "expected configured LM :module to export generate/2"}
    end
  end

  def validate_lm(_lm) do
    {:error,
     "expected nil, an LM module, an LM struct, a configured %{module: module, opts: keyword} map, or an arity-2 callback"}
  end

  defp dispatch_generate(module, messages, opts) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :generate, 2) do
      call_lm(fn -> module.generate(messages, opts) end, module)
    else
      {:error, {:not_an_lm, module}}
    end
  end

  defp dispatch_generate(%module{} = lm, messages, opts) do
    cond do
      Code.ensure_loaded?(module) and function_exported?(module, :generate, 3) ->
        call_lm(fn -> module.generate(lm, messages, opts) end, module)

      Code.ensure_loaded?(module) and function_exported?(module, :generate, 2) ->
        call_lm(fn -> module.generate(messages, opts) end, module)

      true ->
        {:error, {:not_an_lm, module}}
    end
  end

  defp dispatch_generate(%{module: module, opts: client_opts}, messages, opts) do
    client_opts = validate_opts!(client_opts, "DSEx.LM.generate/3 client :opts")
    dispatch_generate(module, messages, Keyword.merge(client_opts, opts))
  end

  defp dispatch_generate(fun, messages, opts) when is_function(fun, 2) do
    call_lm(fn -> fun.(messages, opts) end, fun)
  end

  defp dispatch_generate(lm, _messages, _opts), do: {:error, {:not_an_lm, lm}}

  defp call_lm(fun, lm) do
    case fun.() do
      {:ok, %DSEx.Prediction{}} = success -> success
      {:ok, value} when is_binary(value) or is_map(value) -> {:ok, value}
      {:error, _reason} = error -> error
      {:ok, other} -> {:error, {:invalid_lm_result, other}}
      other -> {:error, {:invalid_lm_result, other}}
    end
  rescue
    error -> {:error, {:lm_failed, lm_name(lm), error_message(error)}}
  catch
    kind, reason -> {:error, {:lm_failed, lm_name(lm), error_message({kind, reason})}}
  end

  defp lm_name(lm) when is_atom(lm), do: lm
  defp lm_name(fun) when is_function(fun), do: :anonymous_lm
  defp lm_name(%module{}), do: module
  defp lm_name(other), do: other

  defp error_message(%_{} = exception), do: Exception.message(exception)
  defp error_message(error), do: inspect(error)

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
