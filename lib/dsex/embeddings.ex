defmodule DSEx.Embeddings do
  @moduledoc "Embedding behaviour plus deterministic local bag-of-words embeddings."

  @callback embed([String.t()], keyword()) :: {:ok, [[number()]]} | {:error, term()}

  def embed(embedder, texts, opts \\ [])

  def embed(embedder, texts, opts) do
    opts = validate_opts!(opts, "DSEx.Embeddings.embed/3")
    texts = validate_texts!(texts, "DSEx.Embeddings.embed/3")
    dispatch(embedder, texts, opts)
  end

  defp dispatch(module, texts, opts) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :embed, 2) do
      call_embedder(fn -> module.embed(texts, opts) end, module)
    else
      {:error, {:not_embedding_provider, module}}
    end
  end

  defp dispatch(fun, texts, opts) when is_function(fun, 2),
    do: call_embedder(fn -> fun.(texts, opts) end, :anonymous_embedder)

  defp dispatch(embedder, _texts, _opts), do: {:error, {:not_embedding_provider, embedder}}

  defp call_embedder(fun, provider) do
    case fun.() do
      {:ok, vectors} when is_list(vectors) ->
        if valid_vectors?(vectors) do
          {:ok, vectors}
        else
          {:error, {:invalid_embedding_result, vectors}}
        end

      {:error, _reason} = error ->
        error

      other ->
        {:error, {:invalid_embedding_result, other}}
    end
  rescue
    error ->
      {:error, {:embedding_provider_failed, provider, Exception.message(error)}}
  catch
    kind, reason ->
      {:error, {:embedding_provider_failed, provider, {kind, reason}}}
  end

  defp valid_vectors?(vectors) do
    Enum.all?(vectors, fn
      vector when is_list(vector) -> Enum.all?(vector, &is_number/1)
      _other -> false
    end)
  end

  defmodule BagOfWords do
    @moduledoc "Deterministic hashing bag-of-words embedder."
    @behaviour DSEx.Embeddings

    @option_schema [
      dims: [type: :pos_integer, default: 64]
    ]

    @impl true
    def embed(texts, opts) do
      texts = DSEx.Embeddings.validate_texts!(texts, "#{inspect(__MODULE__)}.embed/2")
      opts = DSEx.Options.validate!(opts, @option_schema, "#{inspect(__MODULE__)}.embed/2")
      dims = opts[:dims]

      {:ok, Enum.map(texts, &vectorize(&1, dims))}
    end

    defp vectorize(text, dims) do
      vector = List.duplicate(0.0, dims)

      text
      |> terms()
      |> Enum.reduce(vector, fn term, acc ->
        index = :erlang.phash2(term, dims)
        List.update_at(acc, index, &(&1 + 1.0))
      end)
      |> normalize()
    end

    defp normalize(vector) do
      norm = vector |> Enum.map(&(&1 * &1)) |> Enum.sum() |> :math.sqrt()
      if norm == 0.0, do: vector, else: Enum.map(vector, &(&1 / norm))
    end

    defp terms(text),
      do:
        Regex.scan(~r/[a-z0-9]+/i, to_string(text))
        |> List.flatten()
        |> Enum.map(&String.downcase/1)
  end

  def validate_texts!(texts, context) when is_list(texts) do
    if Enum.all?(texts, &is_binary/1) do
      texts
    else
      raise ArgumentError,
            "#{context} expects texts to be a list of strings, got: #{inspect(texts)}"
    end
  end

  def validate_texts!(texts, context) do
    raise ArgumentError,
          "#{context} expects texts to be a list of strings, got: #{inspect(texts)}"
  end

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
