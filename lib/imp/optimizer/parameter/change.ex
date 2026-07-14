defmodule Imp.Optimizer.Parameter.Change do
  @moduledoc """
  A replace-only parameter change guarded by the source content digest.

  `base_digest` gives optimistic concurrency at parameter granularity. A change
  is intentionally data-only and has no operation that can introduce a new
  parameter, remove one, or execute code.
  """

  alias Imp.Optimizer.Parameter

  @enforce_keys [:id, :kind, :value, :base_digest]
  defstruct [:id, :kind, :value, :base_digest]

  @type t :: %__MODULE__{
          id: String.t(),
          kind: Parameter.kind(),
          value: Parameter.json_value(),
          base_digest: String.t()
        }

  @doc "Builds a digest-guarded replacement change."
  @spec new(String.t(), Parameter.kind() | String.t(), Parameter.json_value(), keyword()) :: t()
  def new(id, kind, value, opts \\ []) when is_list(opts) do
    id = Parameter.validate_id!(id)
    kind = Parameter.normalize_kind!(kind)
    Parameter.validate_value!(value)
    base_digest = opts |> Keyword.fetch!(:base_digest) |> validate_digest!()

    %__MODULE__{id: id, kind: kind, value: value, base_digest: base_digest}
  end

  @doc "Builds a change from a data-only persisted representation."
  @spec load!(map()) :: t()
  def load!(%{} = state) do
    exact_keys!(state, ["base_digest", "id", "kind", "value"], "parameter change")
    new(state["id"], state["kind"], state["value"], base_digest: state["base_digest"])
  end

  def load!(state),
    do: raise(ArgumentError, "parameter change state must be a map, got: #{inspect(state)}")

  @doc "Returns a data-only representation suitable for JSON persistence."
  @spec dump(t()) :: map()
  def dump(%__MODULE__{} = change) do
    %{
      "base_digest" => change.base_digest,
      "id" => change.id,
      "kind" => Atom.to_string(change.kind),
      "value" => change.value
    }
  end

  @doc false
  @spec coerce!(t() | map()) :: t()
  def coerce!(%__MODULE__{} = change) do
    new(change.id, change.kind, change.value, base_digest: change.base_digest)
  end

  def coerce!(%{} = change), do: load!(change)

  def coerce!(change),
    do:
      raise(
        ArgumentError,
        "parameter change must be a change struct or map, got: #{inspect(change)}"
      )

  defp validate_digest!(digest) when is_binary(digest) do
    if String.match?(digest, ~r/\A[0-9a-f]{64}\z/) do
      digest
    else
      raise ArgumentError, "parameter change base_digest must be a SHA-256 hex digest"
    end
  end

  defp validate_digest!(_digest),
    do: raise(ArgumentError, "parameter change base_digest must be a SHA-256 hex digest")

  defp exact_keys!(state, expected, context) do
    if MapSet.new(Map.keys(state)) == MapSet.new(expected) do
      :ok
    else
      raise ArgumentError, "#{context} has unexpected or missing fields"
    end
  end
end
