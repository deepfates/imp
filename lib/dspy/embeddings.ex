defmodule DSPy.Embeddings do
  @moduledoc "Embedding behaviour plus deterministic local bag-of-words embeddings."

  @callback embed([String.t()], keyword()) :: {:ok, [[number()]]} | {:error, term()}

  def embed(embedder, texts, opts \\ [])
  def embed(module, texts, opts) when is_atom(module), do: module.embed(texts, opts)
  def embed(fun, texts, opts) when is_function(fun, 2), do: fun.(texts, opts)

  defmodule BagOfWords do
    @moduledoc "Deterministic hashing bag-of-words embedder."
    @behaviour DSPy.Embeddings

    @impl true
    def embed(texts, opts) do
      dims = Keyword.get(opts, :dims, 64)
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
end
