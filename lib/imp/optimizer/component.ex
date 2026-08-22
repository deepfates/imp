defmodule Imp.Optimizer.Component do
  @moduledoc """
  A program-owned description of one optimizable component.

  Components pair a persisted, JSON-safe `Imp.Optimizer.Parameter` with the
  trusted runtime contract that gives the value meaning. Descriptions,
  constraints, and dependencies come from the fresh program, not from an
  optimizer artifact, so loading an artifact cannot weaken validation or gain
  executable authority.

  The supported constraint vocabulary is deliberately small and executable:
  `type`, `enum`, `minimum`, `maximum`, `minLength`, `maxLength`, `minItems`,
  `maxItems`, and `pattern`. Unknown constraints are rejected rather than
  displayed as if Imp enforced them.
  """

  alias Imp.Optimizer.Parameter

  @constraint_keys ~w(type enum minimum maximum minLength maxLength minItems maxItems pattern)
  @json_types ~w(null boolean number integer string array object)

  @enforce_keys [:parameter, :description, :constraints, :dependencies]
  defstruct [:parameter, :description, constraints: %{}, dependencies: []]

  @type t :: %__MODULE__{
          parameter: Parameter.t(),
          description: String.t(),
          constraints: %{optional(String.t()) => Parameter.json_value()},
          dependencies: [String.t()]
        }

  @doc "Builds and validates a described component around a parameter."
  @spec new(Parameter.t(), keyword()) :: t()
  def new(parameter, opts \\ [])

  def new(%Parameter{} = parameter, opts) when is_list(opts) do
    description = Keyword.get(opts, :description, default_description(parameter))
    constraints = normalize_constraints!(Keyword.get(opts, :constraints, %{}))
    dependencies = normalize_dependencies!(Keyword.get(opts, :dependencies, []), parameter.id)

    unless is_binary(description) and description != "" and String.valid?(description) do
      raise ArgumentError, "optimizer component descriptions must be non-empty UTF-8 strings"
    end

    validate_value!(parameter.value, constraints)

    %__MODULE__{
      parameter: parameter,
      description: description,
      constraints: constraints,
      dependencies: dependencies
    }
  end

  def new(parameter, _opts) do
    raise ArgumentError,
          "optimizer components require an Imp.Optimizer.Parameter, got: #{inspect(parameter)}"
  end

  @doc "Returns the component's stable parameter ID."
  @spec id(t()) :: String.t()
  def id(%__MODULE__{parameter: parameter}), do: parameter.id

  @doc "Validates a proposed JSON value against the component's enforced constraints."
  @spec validate_value!(t(), Parameter.json_value()) :: :ok
  def validate_value!(%__MODULE__{constraints: constraints}, value),
    do: validate_value!(value, constraints)

  @spec validate_value!(Parameter.json_value(), map()) :: :ok
  def validate_value!(value, constraints) when is_map(constraints) do
    Parameter.validate_value!(value)

    validate_type!(value, constraints["type"])
    validate_enum!(value, constraints["enum"])
    validate_number!(value, constraints)
    validate_length!(value, constraints)
    validate_pattern!(value, constraints["pattern"])
    :ok
  end

  @doc "Returns a JSON-safe public description without executable callbacks."
  @spec dump(t()) :: map()
  def dump(%__MODULE__{} = component) do
    %{
      "parameter" => Parameter.dump(component.parameter),
      "description" => component.description,
      "constraints" => component.constraints,
      "dependencies" => component.dependencies
    }
  end

  defp normalize_constraints!(constraints)
       when is_map(constraints) and not is_struct(constraints) do
    constraints =
      Map.new(constraints, fn
        {key, value} when is_atom(key) ->
          {Atom.to_string(key), value}

        {key, value} when is_binary(key) ->
          {key, value}

        {key, _value} ->
          raise ArgumentError, "component constraint keys must be strings, got: #{inspect(key)}"
      end)

    unknown = Map.keys(constraints) -- @constraint_keys

    if unknown != [] do
      raise ArgumentError,
            "unsupported optimizer component constraints: #{inspect(Enum.sort(unknown))}"
    end

    Parameter.validate_value!(constraints)
    validate_constraint_shapes!(constraints)
    constraints
  end

  defp normalize_constraints!(constraints) do
    raise ArgumentError,
          "optimizer component constraints must be a JSON object, got: #{inspect(constraints)}"
  end

  defp normalize_dependencies!(dependencies, own_id) when is_list(dependencies) do
    dependencies = Enum.map(dependencies, &Parameter.validate_id!/1)

    cond do
      own_id in dependencies ->
        raise ArgumentError, "optimizer component #{inspect(own_id)} cannot depend on itself"

      length(dependencies) != MapSet.size(MapSet.new(dependencies)) ->
        raise ArgumentError, "optimizer component dependencies must be unique"

      true ->
        dependencies
    end
  end

  defp normalize_dependencies!(dependencies, _own_id) do
    raise ArgumentError,
          "optimizer component dependencies must be a list, got: #{inspect(dependencies)}"
  end

  defp validate_constraint_shapes!(constraints) do
    case constraints["type"] do
      nil ->
        :ok

      type when type in @json_types ->
        :ok

      type ->
        raise ArgumentError,
              "component type must be one of #{inspect(@json_types)}, got: #{inspect(type)}"
    end

    case constraints["enum"] do
      nil ->
        :ok

      values when is_list(values) and values != [] ->
        :ok

      value ->
        raise ArgumentError,
              "component enum must be a non-empty JSON list, got: #{inspect(value)}"
    end

    for key <- ~w(minimum maximum), value = constraints[key], not is_nil(value) do
      unless is_number(value), do: raise(ArgumentError, "component #{key} must be a number")
    end

    for key <- ~w(minLength maxLength minItems maxItems),
        value = constraints[key],
        not is_nil(value) do
      unless is_integer(value) and value >= 0,
        do: raise(ArgumentError, "component #{key} must be a non-negative integer")
    end

    case constraints["pattern"] do
      nil -> :ok
      pattern when is_binary(pattern) -> pattern |> Regex.compile!() |> compiled_pattern!()
      value -> raise ArgumentError, "component pattern must be a string, got: #{inspect(value)}"
    end

    validate_bound_order!(constraints, "minimum", "maximum")
    validate_bound_order!(constraints, "minLength", "maxLength")
    validate_bound_order!(constraints, "minItems", "maxItems")
  end

  defp compiled_pattern!(%Regex{}), do: :ok

  defp validate_bound_order!(constraints, low, high) do
    case {constraints[low], constraints[high]} do
      {left, right} when not is_nil(left) and not is_nil(right) and left > right ->
        raise ArgumentError, "component #{low} cannot exceed #{high}"

      _ ->
        :ok
    end
  end

  defp validate_type!(_value, nil), do: :ok
  defp validate_type!(nil, "null"), do: :ok
  defp validate_type!(value, "boolean") when is_boolean(value), do: :ok
  defp validate_type!(value, "number") when is_number(value), do: :ok
  defp validate_type!(value, "integer") when is_integer(value), do: :ok
  defp validate_type!(value, "string") when is_binary(value), do: :ok
  defp validate_type!(value, "array") when is_list(value), do: :ok
  defp validate_type!(value, "object") when is_map(value) and not is_struct(value), do: :ok

  defp validate_type!(value, type),
    do:
      raise(
        ArgumentError,
        "optimizer component value #{inspect(value)} does not satisfy type #{inspect(type)}"
      )

  defp validate_enum!(_value, nil), do: :ok

  defp validate_enum!(value, values) when is_list(values) do
    unless value in values,
      do: raise(ArgumentError, "optimizer component value is not one of the allowed enum values")
  end

  defp validate_number!(value, constraints) when is_number(value) do
    if not is_nil(constraints["minimum"]) and value < constraints["minimum"],
      do: raise(ArgumentError, "optimizer component value is below minimum")

    if not is_nil(constraints["maximum"]) and value > constraints["maximum"],
      do: raise(ArgumentError, "optimizer component value is above maximum")
  end

  defp validate_number!(_value, _constraints), do: :ok

  defp validate_length!(value, constraints) when is_binary(value) do
    validate_size!(
      String.length(value),
      constraints["minLength"],
      constraints["maxLength"],
      "length"
    )
  end

  defp validate_length!(value, constraints) when is_list(value) do
    validate_size!(length(value), constraints["minItems"], constraints["maxItems"], "item count")
  end

  defp validate_length!(_value, _constraints), do: :ok

  defp validate_size!(size, minimum, maximum, label) do
    if not is_nil(minimum) and size < minimum,
      do: raise(ArgumentError, "optimizer component #{label} is below its minimum")

    if not is_nil(maximum) and size > maximum,
      do: raise(ArgumentError, "optimizer component #{label} exceeds its maximum")
  end

  defp validate_pattern!(_value, nil), do: :ok

  defp validate_pattern!(value, pattern) when is_binary(value) do
    unless Regex.match?(Regex.compile!(pattern), value),
      do: raise(ArgumentError, "optimizer component value does not match its required pattern")
  end

  defp validate_pattern!(_value, _pattern), do: :ok

  defp default_description(%Parameter{id: id}), do: "Optimizable parameter #{id}"
end
