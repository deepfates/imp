defmodule Imp.Embeddings do
  @moduledoc """
  Embedding behaviour plus deterministic local bag-of-words embeddings.

  Providers must return one numeric vector for each input text, in the same
  order. Imp validates that shape at this boundary so retrieval code does not
  silently pair a query or document with the wrong vector.
  """

  @callback embed([String.t()], keyword()) :: {:ok, [[number()]]} | {:error, term()}

  def embed(embedder, texts, opts \\ [])

  def embed(embedder, texts, opts) do
    opts = validate_opts!(opts, "Imp.Embeddings.embed/3")
    texts = validate_texts!(texts, "Imp.Embeddings.embed/3")
    dispatch(embedder, texts, opts)
  end

  defp dispatch(module, texts, opts) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :embed, 2) do
      call_embedder(fn -> module.embed(texts, opts) end, module, length(texts))
    else
      {:error, {:not_embedding_provider, module}}
    end
  end

  defp dispatch(fun, texts, opts) when is_function(fun, 2),
    do: call_embedder(fn -> fun.(texts, opts) end, :anonymous_embedder, length(texts))

  defp dispatch(embedder, _texts, _opts), do: {:error, {:not_embedding_provider, embedder}}

  defp call_embedder(fun, provider, expected_count) do
    case fun.() do
      {:ok, vectors} when is_list(vectors) ->
        if valid_vectors?(vectors, expected_count) do
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
    safety in Imp.OperationalSafetyError ->
      {:error, safety}

    error ->
      {:error, {:embedding_provider_failed, provider, error}}
  catch
    kind, reason ->
      case Imp.OperationalSafetyError.find({kind, reason}) do
        %Imp.OperationalSafetyError{} = safety ->
          {:error, safety}

        nil ->
          {:error, {:embedding_provider_failed, provider, {kind, reason}}}
      end
  end

  defp valid_vectors?(vectors, expected_count) do
    length(vectors) == expected_count and
      Enum.all?(vectors, fn
        vector when is_list(vector) -> Enum.all?(vector, &is_number/1)
        _other -> false
      end)
  end

  defmodule BagOfWords do
    @moduledoc """
    Deterministic hashing bag-of-words embedder.

    This is a local baseline for examples, tests, and small retrieval
    experiments. It is not a semantic embedding model; production semantic
    retrieval should inject a real embedding provider through `Imp.Embeddings`.
    """
    @behaviour Imp.Embeddings

    @option_schema [
      dims: [type: :pos_integer, default: 64]
    ]

    @impl true
    def embed(texts, opts) do
      texts = Imp.Embeddings.validate_texts!(texts, "#{inspect(__MODULE__)}.embed/2")
      opts = Imp.Options.validate!(opts, @option_schema, "#{inspect(__MODULE__)}.embed/2")
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

  @doc false
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
