defmodule DSEx.Optimizer.Parameter.Set do
  @moduledoc """
  Immutable parameter state with playbook-style revision lineage.

  A committed set increments `revision`, records the prior `hash` as
  `parent_hash`, and rehashes the complete canonical data representation. This
  gives a compact persistence boundary while each individual change retains its
  own `base_digest` optimistic guard.
  """

  alias DSEx.Optimizer.Parameter
  alias DSEx.Optimizer.Parameter.Change
  alias DSEx.Playbook.Canonical

  @enforce_keys [:id, :revision, :parent_hash, :parameters, :hash]
  defstruct [:id, :parent_hash, :hash, revision: 0, parameters: []]

  @type t :: %__MODULE__{
          id: String.t(),
          revision: non_neg_integer(),
          parent_hash: String.t() | nil,
          parameters: [Parameter.t()],
          hash: String.t()
        }

  @doc "Builds a root parameter set from unique typed parameters."
  @spec new(String.t(), [Parameter.t()]) :: t()
  def new(id, parameters) do
    id = Parameter.validate_id!(id)
    parameters = normalize_parameters!(parameters)

    rehash(%__MODULE__{
      id: id,
      revision: 0,
      parent_hash: nil,
      parameters: parameters,
      hash: ""
    })
  end

  @doc "Returns a parameter by stable string ID."
  @spec fetch(t(), String.t()) :: {:ok, Parameter.t()} | :error
  def fetch(%__MODULE__{} = set, id) when is_binary(id),
    do: Enum.find_value(set.parameters, :error, &if(&1.id == id, do: {:ok, &1}))

  def fetch(%__MODULE__{}, _id), do: :error

  @doc "Applies all changes or returns an error without yielding a partial set."
  @spec apply_changes(t(), [Change.t() | map()]) :: {:ok, t()} | {:error, term()}
  def apply_changes(%__MODULE__{} = set, changes) when is_list(changes) do
    with {:ok, changes} <- normalize_changes(changes),
         :ok <- validate_change_ids(changes),
         {:ok, replacements} <- validate_changes(set, changes) do
      if replacements == %{} do
        {:ok, set}
      else
        parameters =
          Enum.map(set.parameters, fn parameter ->
            case Map.fetch(replacements, parameter.id) do
              {:ok, change} -> Parameter.new(parameter.id, parameter.kind, change.value)
              :error -> parameter
            end
          end)

        committed =
          %__MODULE__{
            set
            | parameters: parameters,
              revision: set.revision + 1,
              parent_hash: set.hash
          }
          |> rehash()

        {:ok, committed}
      end
    end
  end

  def apply_changes(%__MODULE__{}, changes), do: {:error, {:changes_must_be_a_list, changes}}

  @doc "Returns the minimal ordered replacement changes from `source` to `target`."
  @spec diff(t(), t()) :: [Change.t()]
  def diff(%__MODULE__{} = source, %__MODULE__{} = target) do
    source_by_id = Map.new(source.parameters, &{&1.id, &1})
    target_by_id = Map.new(target.parameters, &{&1.id, &1})

    if Map.keys(source_by_id) |> MapSet.new() != Map.keys(target_by_id) |> MapSet.new() do
      raise ArgumentError, "cannot diff parameter sets with different parameter IDs"
    end

    target.parameters
    |> Enum.sort_by(& &1.id)
    |> Enum.flat_map(fn target_parameter ->
      source_parameter = Map.fetch!(source_by_id, target_parameter.id)

      cond do
        source_parameter.kind != target_parameter.kind ->
          raise ArgumentError,
                "cannot diff parameter #{inspect(target_parameter.id)} with different kinds"

        source_parameter.digest == target_parameter.digest ->
          []

        true ->
          [
            Change.new(target_parameter.id, target_parameter.kind, target_parameter.value,
              base_digest: source_parameter.digest
            )
          ]
      end
    end)
  end

  @doc "Returns a deterministic data-only representation."
  @spec dump(t()) :: map()
  def dump(%__MODULE__{} = set) do
    %{
      "hash" => set.hash,
      "id" => set.id,
      "parameters" => Enum.map(set.parameters, &Parameter.dump/1),
      "parent_hash" => set.parent_hash,
      "revision" => set.revision,
      "schema_version" => 1
    }
  end

  @doc "Loads and verifies a persisted parameter set."
  @spec load!(map()) :: t()
  def load!(%{} = state) do
    exact_keys!(
      state,
      ["hash", "id", "parameters", "parent_hash", "revision", "schema_version"],
      "parameter set"
    )

    unless state["schema_version"] == 1 do
      raise ArgumentError,
            "unsupported optimizer parameter set schema version: #{inspect(state["schema_version"])}"
    end

    revision = state["revision"]

    unless is_integer(revision) and revision >= 0 do
      raise ArgumentError, "parameter set revision must be a non-negative integer"
    end

    parent_hash = state["parent_hash"]

    unless (revision == 0 and is_nil(parent_hash)) or
             (revision > 0 and valid_hash?(parent_hash)) do
      raise ArgumentError, "parameter set parent_hash does not match its revision"
    end

    parameters = state["parameters"]

    unless is_list(parameters) do
      raise ArgumentError, "parameter set parameters must be a list"
    end

    set = %__MODULE__{
      id: Parameter.validate_id!(state["id"]),
      revision: revision,
      parent_hash: parent_hash,
      parameters: normalize_parameters!(Enum.map(parameters, &Parameter.load!/1)),
      hash: validate_hash!(state["hash"], "parameter set hash")
    }

    if rehash(set).hash == set.hash do
      set
    else
      raise ArgumentError, "parameter set hash does not match its content"
    end
  end

  def load!(state),
    do: raise(ArgumentError, "parameter set state must be a map, got: #{inspect(state)}")

  defp normalize_parameters!(parameters) when is_list(parameters) do
    parameters = Enum.map(parameters, &normalize_parameter!/1) |> Enum.sort_by(& &1.id)
    ids = Enum.map(parameters, & &1.id)

    if length(ids) == MapSet.size(MapSet.new(ids)) do
      parameters
    else
      raise ArgumentError, "optimizer parameter IDs must be unique strings"
    end
  end

  defp normalize_parameters!(parameters) do
    raise ArgumentError, "optimizer parameters must be a list, got: #{inspect(parameters)}"
  end

  defp normalize_parameter!(%Parameter{} = parameter),
    do: Parameter.new(parameter.id, parameter.kind, parameter.value)

  defp normalize_parameter!(parameter) do
    raise ArgumentError, "invalid optimizer parameter: #{inspect(parameter)}"
  end

  defp normalize_changes(changes) do
    changes
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {change, index}, {:ok, normalized} ->
      case coerce_change(change) do
        {:ok, change} -> {:cont, {:ok, normalized ++ [change]}}
        {:error, message} -> {:halt, {:error, {:invalid_change, index, message}}}
      end
    end)
  end

  defp coerce_change(change) do
    {:ok, Change.coerce!(change)}
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  defp validate_change_ids(changes) do
    ids = Enum.map(changes, & &1.id)

    if length(ids) == MapSet.size(MapSet.new(ids)) do
      :ok
    else
      {:error, :duplicate_parameter_changes}
    end
  end

  defp validate_changes(set, changes) do
    Enum.reduce_while(changes, {:ok, %{}}, fn change, {:ok, replacements} ->
      case fetch(set, change.id) do
        :error ->
          {:halt, {:error, {:unknown_parameter, change.id}}}

        {:ok, parameter} when parameter.kind != change.kind ->
          {:halt, {:error, {:parameter_kind_mismatch, change.id, parameter.kind, change.kind}}}

        {:ok, parameter} when parameter.digest != change.base_digest ->
          {:halt,
           {:error, {:stale_parameter_digest, change.id, change.base_digest, parameter.digest}}}

        {:ok, _parameter} ->
          {:cont, {:ok, Map.put(replacements, change.id, change)}}
      end
    end)
  end

  defp rehash(%__MODULE__{} = set) do
    payload = set |> dump() |> Map.delete("hash")
    %{set | hash: Canonical.hash(payload)}
  end

  defp validate_hash!(hash, context) do
    if valid_hash?(hash) do
      hash
    else
      raise ArgumentError, "#{context} must be a SHA-256 hex digest"
    end
  end

  defp valid_hash?(hash) when is_binary(hash), do: String.match?(hash, ~r/\A[0-9a-f]{64}\z/)
  defp valid_hash?(_hash), do: false

  defp exact_keys!(state, expected, context) do
    if MapSet.new(Map.keys(state)) == MapSet.new(expected) do
      :ok
    else
      raise ArgumentError, "#{context} has unexpected or missing fields"
    end
  end
end
