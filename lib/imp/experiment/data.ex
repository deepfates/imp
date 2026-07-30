defmodule Imp.Experiment.Data do
  @moduledoc """
  Disjoint train, selection, and untouched-test data for `Imp.Experiment.check/5`.

  Rows are identified before any optimizer or model call. By default identity is
  the deterministic content digest of the complete row. Pass `id: :field_name`
  (or an arity-one function) when the dataset has a stronger source identity.
  Duplicate identities within or across splits are rejected.
  """

  @enforce_keys [:train, :selection, :test, :ids, :digests]
  defstruct [:train, :selection, :test, :ids, :digests]

  @type split :: :train | :selection | :test
  @type t :: %__MODULE__{
          train: [term()],
          selection: [term()],
          test: [term()],
          ids: %{required(split()) => [String.t()]},
          digests: %{required(split()) => String.t()}
        }

  @doc "Builds and validates a disjoint experiment dataset."
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    unless Keyword.keyword?(opts), do: invalid!(opts)

    unknown = Keyword.keys(opts) -- [:train, :selection, :test, :id]

    if unknown != [],
      do: raise(ArgumentError, "unknown experiment data options: #{inspect(unknown)}")

    rows = %{
      train: fetch_rows!(opts, :train),
      selection: fetch_rows!(opts, :selection),
      test: fetch_rows!(opts, :test)
    }

    identity = Keyword.get(opts, :id, :content)

    ids =
      Map.new(rows, fn {split, values} -> {split, Enum.map(values, &row_id!(&1, identity))} end)

    reject_duplicates!(ids)

    digests = Map.new(ids, fn {split, values} -> {split, digest(values)} end)
    struct!(__MODULE__, Map.merge(rows, %{ids: ids, digests: digests}))
  end

  def new(opts), do: invalid!(opts)

  @doc "Returns the rows for a named split."
  @spec split(t(), split()) :: [term()]
  def split(%__MODULE__{} = data, split) when split in [:train, :selection, :test],
    do: Map.fetch!(data, split)

  @doc "Returns the content-bound public description stored in experiment results."
  @spec manifest(t()) :: map()
  def manifest(%__MODULE__{} = data) do
    %{
      "counts" => Map.new(data.ids, fn {split, ids} -> {Atom.to_string(split), length(ids)} end),
      "digests" => stringify_keys(data.digests),
      "ids" => stringify_keys(data.ids)
    }
  end

  @doc false
  def digest(value) do
    value
    |> Imp.Optimizer.Report.encode_term()
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp fetch_rows!(opts, split) do
    case Keyword.fetch(opts, split) do
      {:ok, rows} when is_list(rows) and rows != [] ->
        rows

      {:ok, rows} ->
        raise ArgumentError,
              "experiment #{split} split must be a non-empty list, got: #{inspect(rows)}"

      :error ->
        raise ArgumentError, "experiment data requires #{split}: rows"
    end
  end

  defp row_id!(row, :content), do: digest(row)

  defp row_id!(row, key) when is_atom(key) or is_binary(key) do
    value =
      case row do
        %Imp.Example{} -> Imp.Example.get(row, key)
        map when is_map(map) -> Map.get(map, key, Map.get(map, alternate_key(key)))
        _ -> nil
      end

    if is_binary(value) or is_number(value) or is_atom(value) do
      to_string(value)
    else
      raise ArgumentError,
            "experiment row is missing scalar identity #{inspect(key)}: #{inspect(row)}"
    end
  end

  defp row_id!(row, identity) when is_function(identity, 1) do
    case identity.(row) do
      value when is_binary(value) and value != "" ->
        value

      value when is_number(value) or is_atom(value) ->
        to_string(value)

      value ->
        raise ArgumentError, "experiment identity function returned invalid id: #{inspect(value)}"
    end
  end

  defp row_id!(_row, identity) do
    raise ArgumentError,
          "experiment :id must be :content, a field name, or an arity-one function, got: #{inspect(identity)}"
  end

  defp reject_duplicates!(ids) do
    occurrences =
      for {split, values} <- ids, id <- values, reduce: %{} do
        acc -> Map.update(acc, id, [split], &[split | &1])
      end

    duplicates =
      occurrences
      |> Enum.filter(fn {_id, splits} -> length(splits) > 1 end)
      |> Enum.sort()

    if duplicates != [] do
      raise ArgumentError,
            "experiment splits must be identity-disjoint; duplicate rows: #{inspect(duplicates)}"
    end
  end

  defp alternate_key(key) when is_atom(key), do: Atom.to_string(key)

  defp alternate_key(key) when is_binary(key) do
    try do
      String.to_existing_atom(key)
    rescue
      ArgumentError -> nil
    end
  end

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {Atom.to_string(key), value} end)

  defp invalid!(opts),
    do:
      raise(
        ArgumentError,
        "Imp.Experiment.Data.new/1 expects keyword options, got: #{inspect(opts)}"
      )
end
