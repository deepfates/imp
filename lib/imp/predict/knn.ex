defmodule Imp.Predict.KNN do
  @moduledoc """
  An embedding-based nearest-neighbor retriever over a trainset, with the same
  query and ranking semantics as DSPy 3.2.1 `KNN`.

  Construction embeds every trainset example ONCE through the required
  `:vectorizer` (any `Imp.Embeddings` provider — a module implementing
  `embed/2` or a 2-arity function; DSPy's `Embedder` analog). Each example is
  rendered as `"key: value"` pairs for its INPUT fields joined by `" | "`,
  exactly like upstream's `trainset_casted_to_vectorize`. At call time the
  query inputs are rendered the same way, embedded, and scored against the
  trainset by dot product; the top `k` examples return in descending-score
  order (upstream's `argsort()[-k:][::-1]`).

  Two details matter when moving data between Python and Elixir:

    * Field iteration order: Python dicts iterate in insertion order; Elixir
      maps do not preserve insertion order. Pass keyword-list inputs (or
      single-input-field examples) when the exact multi-field rendering order
      matters for embedding equality.
    * Tie-breaking among equal scores follows a stable sort (higher original
      index wins within a tie, matching a stable `argsort`); NumPy's default
      quicksort leaves ties unspecified.

  For token-overlap retrieval without an embedding provider, use
  `Imp.Retrievers.KNN`.
  """

  defstruct [:k, :trainset, :vectorizer, :trainset_vectors]

  @option_schema [
    vectorizer: [
      type: {:custom, __MODULE__, :validate_vectorizer, []},
      required: true
    ]
  ]

  @doc """
  Builds the retriever, embedding the trainset once (DSPy `KNN.__init__`).

  Options:

    * `:vectorizer` (required) — an `Imp.Embeddings` provider: a module
      exporting `embed/2` or a function of `(texts, opts)`.
  """
  def new(k, trainset, opts \\ []) do
    k = validate_k!(k)
    opts = Imp.Options.validate!(opts, @option_schema, "Imp.Predict.KNN.new/3")
    trainset = validate_trainset!(trainset)
    vectorizer = opts[:vectorizer]

    texts = Enum.map(trainset, &example_text/1)

    case Imp.Embeddings.embed(vectorizer, texts) do
      {:ok, vectors} ->
        %__MODULE__{k: k, trainset: trainset, vectorizer: vectorizer, trainset_vectors: vectors}

      {:error, reason} ->
        raise ArgumentError,
              "Imp.Predict.KNN.new/3 failed to embed the trainset: #{inspect(reason)}"
    end
  end

  @doc """
  Returns the `k` nearest trainset examples for the given inputs
  (DSPy `KNN.__call__`): embed the query, dot-product against the trainset
  vectors, take the top `k` by descending score.
  """
  def call(%__MODULE__{} = knn, inputs) do
    query = query_text(inputs)

    case Imp.Embeddings.embed(knn.vectorizer, [query]) do
      {:ok, [query_vector]} ->
        knn.trainset_vectors
        |> Enum.map(&dot(&1, query_vector))
        |> Enum.with_index()
        # Stable ascending argsort by score; last k reversed == top-k desc.
        |> Enum.sort_by(fn {score, _index} -> score end)
        |> Enum.take(-knn.k)
        |> Enum.reverse()
        |> Enum.map(fn {_score, index} -> Enum.fetch!(knn.trainset, index) end)

      {:error, reason} ->
        raise ArgumentError,
              "Imp.Predict.KNN.call/2 failed to embed the query: #{inspect(reason)}"
    end
  end

  # DSPy: " | ".join(f"{key}: {value}" for key, value in example.items()
  #                  if key in example._input_keys)
  defp example_text(example) do
    # DSPy raises here too (`key in example._input_keys` with None); the Imp
    # error just says why (loud, not silent).
    input_keys =
      example.input_keys ||
        raise(
          ArgumentError,
          "Imp.Predict.KNN.new/3 requires trainset examples with marked inputs " <>
            "(Imp.Example.with_inputs/2), matching DSPy KNN's use of example._input_keys; " <>
            "got example without input keys: #{inspect(Imp.Example.to_map(example))}"
        )

    example
    |> Imp.Example.items()
    |> Enum.filter(fn {key, _value} -> key in input_keys end)
    |> Enum.map_join(" | ", fn {key, value} ->
      "#{key}: #{Imp.Adapter.Chat.format_value(value)}"
    end)
  end

  # DSPy: " | ".join(f"{key}: {val}" for key, val in kwargs.items()) — every
  # provided input participates, unfiltered.
  defp query_text(inputs) when is_list(inputs) or is_map(inputs) do
    inputs
    |> Enum.map(fn
      {key, value} ->
        {key, value}

      other ->
        raise ArgumentError,
              "Imp.Predict.KNN.call/2 expects inputs as {key, value} pairs; got entry: #{inspect(other)}"
    end)
    |> Enum.map_join(" | ", fn {key, value} ->
      "#{key}: #{Imp.Adapter.Chat.format_value(value)}"
    end)
  end

  defp query_text(inputs) do
    raise ArgumentError,
          "Imp.Predict.KNN.call/2 expects inputs as a map or field pair list; got: #{inspect(inputs)}"
  end

  defp dot(left, right) do
    unless length(left) == length(right) do
      raise ArgumentError,
            "Imp.Predict.KNN: embedding dimensions differ (#{length(left)} vs #{length(right)}); " <>
              "the vectorizer must return same-length vectors for trainset and query"
    end

    Enum.zip_reduce(left, right, 0.0, fn a, b, acc -> acc + a * b end)
  end

  @doc false
  def validate_vectorizer(module) when is_atom(module) and not is_nil(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :embed, 2) do
      {:ok, module}
    else
      {:error, "expected an Imp.Embeddings provider module exporting embed/2"}
    end
  end

  def validate_vectorizer(fun) when is_function(fun, 2), do: {:ok, fun}

  def validate_vectorizer(_other),
    do: {:error, "expected an Imp.Embeddings provider module or a 2-arity function"}

  defp validate_k!(k) when is_integer(k) and k >= 0, do: k

  defp validate_k!(k) do
    raise ArgumentError,
          "Imp.Predict.KNN.new/3 expects k to be a non-negative integer; got: #{inspect(k)}"
  end

  defp validate_trainset!(trainset) do
    unless Enumerable.impl_for(trainset) do
      raise ArgumentError,
            "Imp.Predict.KNN.new/3 expects trainset to be an enumerable of examples; got: #{inspect(trainset)}"
    end

    trainset |> Enum.to_list() |> Enum.map(&Imp.Example.new/1)
  end
end
