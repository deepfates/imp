defmodule DSEx.Optimizer.Parameter do
  @moduledoc """
  A bounded, data-only optimizer parameter.

  Parameters use stable string IDs and one of the supported kinds. Their
  values are restricted to JSON data with string map keys so optimizer state
  can be hashed, persisted, and inspected without capturing executable
  runners, credentials, atoms, or other runtime terms.
  """

  alias DSEx.Playbook.Canonical

  @kinds ~w(instruction demos config playbook tool_description tool_schema artifact)a

  @enforce_keys [:id, :kind, :value, :digest]
  defstruct [:id, :kind, :value, :digest]

  @type kind ::
          :instruction
          | :demos
          | :config
          | :playbook
          | :tool_description
          | :tool_schema
          | :artifact
  @type json_value ::
          nil | boolean() | number() | String.t() | [json_value()] | %{String.t() => json_value()}
  @type t :: %__MODULE__{id: String.t(), kind: kind(), value: json_value(), digest: String.t()}

  @doc "Returns every parameter kind supported by the contract."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "Builds a parameter after validating its stable ID and data-only value."
  @spec new(String.t(), kind() | String.t(), json_value()) :: t()
  def new(id, kind, value) do
    id = validate_id!(id)
    kind = normalize_kind!(kind)
    validate_value!(value)

    %__MODULE__{
      id: id,
      kind: kind,
      value: value,
      digest: content_digest(kind, value)
    }
  end

  @doc "Returns the deterministic content digest for a kind and JSON value."
  @spec content_digest(kind() | String.t(), json_value()) :: String.t()
  def content_digest(kind, value) do
    kind = normalize_kind!(kind)
    validate_value!(value)
    Canonical.hash(%{"kind" => Atom.to_string(kind), "value" => value})
  end

  @doc "Returns a data-only representation suitable for JSON persistence."
  @spec dump(t()) :: map()
  def dump(%__MODULE__{} = parameter) do
    %{
      "digest" => parameter.digest,
      "id" => parameter.id,
      "kind" => Atom.to_string(parameter.kind),
      "value" => parameter.value
    }
  end

  @doc "Loads and verifies a persisted parameter representation."
  @spec load!(map()) :: t()
  def load!(%{} = state) do
    exact_keys!(state, ["digest", "id", "kind", "value"], "parameter")
    parameter = new(state["id"], state["kind"], state["value"])

    if parameter.digest == state["digest"] do
      parameter
    else
      raise ArgumentError, "parameter digest does not match its kind and value"
    end
  end

  def load!(state),
    do: raise(ArgumentError, "parameter state must be a map, got: #{inspect(state)}")

  @doc false
  @spec validate_value!(term()) :: :ok
  def validate_value!(value) do
    unless json_value?(value) do
      raise ArgumentError,
            "optimizer parameter values must be JSON data with string map keys; functions, atoms, structs, tuples, and process terms are not allowed"
    end

    if DSEx.Redaction.redact(value) != value do
      raise ArgumentError,
            "optimizer parameter values must not contain credentials or secret-shaped data"
    end

    :ok
  end

  @doc false
  @spec normalize_kind!(kind() | String.t()) :: kind()
  def normalize_kind!(kind) when is_atom(kind) and kind in @kinds, do: kind

  def normalize_kind!(kind) when is_binary(kind) do
    Enum.find(@kinds, &(Atom.to_string(&1) == kind)) ||
      raise ArgumentError,
            "unsupported optimizer parameter kind: #{inspect(kind)}; expected one of #{inspect(@kinds)}"
  end

  def normalize_kind!(kind) do
    raise ArgumentError,
          "unsupported optimizer parameter kind: #{inspect(kind)}; expected one of #{inspect(@kinds)}"
  end

  @doc false
  @spec validate_id!(term()) :: String.t()
  def validate_id!(id) when is_binary(id) do
    if id != "" and String.valid?(id) do
      id
    else
      raise ArgumentError, "optimizer parameter IDs must be non-empty UTF-8 strings"
    end
  end

  def validate_id!(id),
    do: raise(ArgumentError, "optimizer parameter IDs must be strings, got: #{inspect(id)}")

  defp json_value?(nil), do: true

  defp json_value?(value) when is_boolean(value) or is_integer(value) or is_binary(value),
    do: true

  defp json_value?(value) when is_float(value), do: value == value

  defp json_value?(value) when is_list(value), do: Enum.all?(value, &json_value?/1)

  defp json_value?(value) when is_map(value) and not is_struct(value) do
    Enum.all?(value, fn
      {key, nested} when is_binary(key) -> json_value?(nested)
      _entry -> false
    end)
  end

  defp json_value?(_value), do: false

  defp exact_keys!(state, expected, context) do
    if MapSet.new(Map.keys(state)) == MapSet.new(expected) do
      :ok
    else
      raise ArgumentError, "#{context} has unexpected or missing fields"
    end
  end
end
