defmodule Imp.Optimize.Anything.StructuredCandidate do
  @moduledoc false

  # Standalone GEPA v0.1.4 deliberately searches dict[str, str]. This codec is
  # an Imp-native extension: the public evaluator and result keep a structured,
  # JSON-safe artifact while the shared text-component engine receives a
  # tagged, canonical representation for hashing and durable resume.

  alias Imp.Optimizer.Report

  @payload_type "imp_optimize_anything_structured_component"
  @payload_version 1

  @enforce_keys [:schema, :digest, :proposal_contract]
  defstruct [:schema, :digest, :proposal_contract]

  @type t :: %__MODULE__{
          schema: map(),
          digest: String.t(),
          proposal_contract: :off | :auto | :required
        }

  @doc false
  def new!(artifact, proposal_contract \\ :off)

  def new!(artifact, proposal_contract)
      when is_map(artifact) and map_size(artifact) > 0 and
             proposal_contract in [:off, :auto, :required] do
    validate_component_keys!(artifact)
    schema = Map.new(artifact, fn {key, value} -> {key, schema!(value, [key])} end)
    digest = {schema, proposal_contract} |> :erlang.term_to_binary([:deterministic]) |> sha256()
    %__MODULE__{schema: schema, digest: digest, proposal_contract: proposal_contract}
  end

  def new!(artifact, proposal_contract) do
    raise ArgumentError,
          "structured Optimize Anything seed must be a non-empty map and proposal contract must be :off, :auto, or :required, got: #{inspect({artifact, proposal_contract})}"
  end

  @doc false
  def response_format(%__MODULE__{} = codec, component) do
    schema = codec |> fetch_schema!(component) |> json_schema()

    %{
      type: "json_schema",
      json_schema: %{
        name: "imp_optimize_anything_component",
        strict: true,
        schema: %{
          "type" => "object",
          "additionalProperties" => false,
          "properties" => %{"value" => schema},
          "required" => ["value"]
        }
      }
    }
  end

  @doc false
  def encode_candidate!(%__MODULE__{} = codec, artifact) when is_map(artifact) do
    artifact = normalize_artifact!(codec, artifact)
    Map.new(artifact, fn {key, value} -> {key, encode_component!(codec, key, value)} end)
  end

  def encode_candidate!(%__MODULE__{}, artifact) do
    raise ArgumentError,
          "structured Optimize Anything candidate must be a map, got: #{inspect(artifact)}"
  end

  @doc false
  def decode_candidate!(%__MODULE__{} = codec, candidate) when is_map(candidate) do
    validate_exact_keys!(candidate, codec.schema, [])
    Map.new(candidate, fn {key, payload} -> {key, decode_component!(codec, key, payload)} end)
  end

  def decode_candidate!(%__MODULE__{}, candidate) do
    raise ArgumentError,
          "structured Optimize Anything engine candidate must be a map, got: #{inspect(candidate)}"
  end

  @doc false
  def encode_component!(%__MODULE__{} = codec, component, value) do
    expected = fetch_schema!(codec, component)
    normalized = normalize!(expected, value, [component])

    Jason.encode!(%{
      "type" => @payload_type,
      "schema_version" => @payload_version,
      "artifact_schema_sha256" => codec.digest,
      "component" => Report.encode_term(component),
      "value" => Report.encode_term(normalized)
    })
  end

  @doc false
  def decode_component!(%__MODULE__{} = codec, component, payload) when is_binary(payload) do
    decoded =
      case Jason.decode(payload) do
        {:ok, value} -> value
        {:error, _reason} -> invalid_payload!(component, "is not valid JSON")
      end

    unless is_map(decoded), do: invalid_payload!(component, "must be a JSON object")

    expected_component = Report.encode_term(component)

    unless decoded["type"] == @payload_type and decoded["schema_version"] == @payload_version and
             decoded["artifact_schema_sha256"] == codec.digest and
             decoded["component"] == expected_component and Map.has_key?(decoded, "value") do
      invalid_payload!(component, "has missing or mismatched identity fields")
    end

    value = Report.decode_term(decoded["value"])
    normalize!(fetch_schema!(codec, component), value, [component])
  end

  def decode_component!(%__MODULE__{}, component, payload) do
    invalid_payload!(component, "must be a tagged binary, got: #{inspect(payload)}")
  end

  @doc false
  def render_component(%__MODULE__{} = codec, component, payload) do
    value = decode_component!(codec, component, payload)
    Jason.encode!(json_value(value), pretty: true)
  end

  @doc false
  def normalize_proposal(%__MODULE__{} = codec, component, current, response)
      when is_binary(current) and is_binary(response) do
    response = extract_fenced_text(response)

    with {:ok, decoded} <- Jason.decode(response),
         decoded <- unwrap_response_value(decoded),
         {:ok, normalized} <- normalize(fetch_schema!(codec, component), decoded, [component]) do
      encoded = encode_component!(codec, component, normalized)

      if encoded == current and map_size(codec.schema) == 1,
        do: {:error, {:no_op_structured_proposal, component}},
        else: {:ok, encoded}
    else
      {:error, %Jason.DecodeError{} = error} ->
        {:error, {:invalid_structured_proposal, Exception.message(error)}}

      {:error, reason} ->
        {:error, {:invalid_structured_proposal, reason}}
    end
  end

  @doc false
  def wrap_proposer(%__MODULE__{} = codec, proposer) when is_function(proposer, 4) do
    fn encoded_candidate, component, records, iteration ->
      candidate = decode_candidate!(codec, encoded_candidate)
      current = Map.fetch!(candidate, component)

      case proposer.(candidate, component, records, iteration) do
        {:error, reason} ->
          {:error, reason}

        {:ok, value} ->
          encode_proposed_value(codec, component, current, value)

        value ->
          encode_proposed_value(codec, component, current, value)
      end
    end
  end

  @doc false
  def validate_checkpoint!(%__MODULE__{}, nil), do: :ok

  def validate_checkpoint!(%__MODULE__{} = codec, checkpoint) when is_map(checkpoint) do
    candidates = Map.get(checkpoint, "candidates", Map.get(checkpoint, :candidates, []))

    unless is_list(candidates) do
      raise ArgumentError, "structured Optimize Anything resume candidates must be a list"
    end

    Enum.each(candidates, fn entry ->
      candidate =
        entry
        |> Map.get("candidate", Map.get(entry, :candidate))
        |> Report.decode_term()

      decode_candidate!(codec, candidate)
    end)

    :ok
  rescue
    error in ArgumentError ->
      raise ArgumentError,
            "structured Optimize Anything resume checkpoint is invalid: #{Exception.message(error)}"
  end

  def validate_checkpoint!(%__MODULE__{}, checkpoint) do
    raise ArgumentError,
          "structured Optimize Anything resume checkpoint must be a map, got: #{inspect(checkpoint)}"
  end

  defp encode_proposed_value(codec, component, current, value) do
    case normalize(fetch_schema!(codec, component), value, [component]) do
      {:ok, ^current} ->
        if map_size(codec.schema) == 1,
          do: {:error, {:no_op_structured_proposal, component}},
          else: {:ok, encode_component!(codec, component, current)}

      {:ok, normalized} ->
        {:ok, encode_component!(codec, component, normalized)}

      {:error, reason} ->
        {:error, {:invalid_structured_proposal, reason}}
    end
  end

  defp normalize_artifact!(codec, artifact) do
    validate_exact_keys!(artifact, codec.schema, [])

    Map.new(codec.schema, fn {key, expected} ->
      {key, normalize!(expected, fetch_value!(artifact, key, []), [key])}
    end)
  end

  defp schema!(value, _path) when is_binary(value), do: :string
  defp schema!(value, _path) when is_boolean(value), do: :boolean
  defp schema!(value, _path) when is_integer(value), do: :integer
  defp schema!(value, _path) when is_float(value), do: :float
  defp schema!(nil, _path), do: :null

  defp schema!(values, path) when is_list(values) do
    {:list,
     values
     |> Enum.with_index()
     |> Enum.map(fn {value, index} -> schema!(value, [index | path]) end)}
  end

  defp schema!(map, path) when is_map(map) and not is_struct(map) do
    validate_component_keys!(map, path)
    {:map, Map.new(map, fn {key, value} -> {key, schema!(value, [key | path])} end)}
  end

  defp schema!(value, path) do
    raise ArgumentError,
          "structured Optimize Anything value at #{format_path(path)} is not JSON-safe: #{inspect(value)}"
  end

  defp normalize!(:string, value, _path) when is_binary(value), do: value
  defp normalize!(:boolean, value, _path) when is_boolean(value), do: value
  defp normalize!(:integer, value, _path) when is_integer(value), do: value
  defp normalize!(:float, value, _path) when is_float(value), do: value
  defp normalize!(:null, nil, _path), do: nil

  defp normalize!({:list, expected}, values, path) when is_list(values) do
    if length(values) != length(expected) do
      invalid_value!(path, "expected a list of length #{length(expected)}, got #{length(values)}")
    end

    expected
    |> Enum.zip(values)
    |> Enum.with_index()
    |> Enum.map(fn {{item_schema, value}, index} ->
      normalize!(item_schema, value, [index | path])
    end)
  end

  defp normalize!({:map, expected}, map, path) when is_map(map) and not is_struct(map) do
    validate_component_keys!(map, path)
    validate_exact_keys!(map, expected, path)

    Map.new(expected, fn {key, value_schema} ->
      {key, normalize!(value_schema, fetch_value!(map, key, path), [key | path])}
    end)
  end

  defp normalize!(expected, value, path) do
    invalid_value!(path, "expected #{schema_name(expected)}, got #{inspect(value)}")
  end

  defp normalize(schema, value, path) do
    {:ok, normalize!(schema, value, path)}
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  defp validate_component_keys!(map, path \\ []) do
    Enum.each(Map.keys(map), fn key ->
      unless is_atom(key) or is_binary(key) do
        raise ArgumentError,
              "structured Optimize Anything key at #{format_path([key | path])} must be an atom or string"
      end

      if to_string(key) == "__imp_type__" do
        raise ArgumentError,
              "structured Optimize Anything key at #{format_path([key | path])} is reserved for durable Imp wire tags"
      end
    end)

    string_keys = map |> Map.keys() |> Enum.map(&to_string/1)

    if length(string_keys) != length(Enum.uniq(string_keys)) do
      raise ArgumentError,
            "structured Optimize Anything keys at #{format_path(path)} collide after JSON encoding"
    end
  end

  defp validate_exact_keys!(actual, expected, path) do
    expected_keys = expected |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()
    actual_keys = actual |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()

    if expected_keys != actual_keys or length(Map.keys(actual)) != length(Map.keys(expected)) do
      invalid_value!(
        path,
        "expected exact keys #{inspect(expected_keys)}, got #{inspect(actual_keys)}"
      )
    end
  end

  defp fetch_schema!(codec, component) do
    case fetch_value(codec.schema, component) do
      {:ok, schema} -> schema
      :error -> raise ArgumentError, "unknown structured component #{inspect(component)}"
    end
  end

  defp fetch_value!(map, key, path) do
    case fetch_value(map, key) do
      {:ok, value} -> value
      :error -> invalid_value!(path, "is missing key #{inspect(key)}")
    end
  end

  defp fetch_value(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        Enum.find_value(map, :error, fn {actual, value} ->
          if to_string(actual) == to_string(key), do: {:ok, value}
        end)
    end
  end

  defp json_value(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), json_value(nested)} end)
  end

  defp json_value(value) when is_list(value), do: Enum.map(value, &json_value/1)
  defp json_value(value), do: value

  defp unwrap_response_value(%{"value" => value} = response) when map_size(response) == 1,
    do: value

  defp unwrap_response_value(response), do: response

  defp json_schema(:string), do: %{"type" => "string"}
  defp json_schema(:boolean), do: %{"type" => "boolean"}
  defp json_schema(:integer), do: %{"type" => "integer"}
  defp json_schema(:float), do: %{"type" => "number"}
  defp json_schema(:null), do: %{"type" => "null"}

  defp json_schema({:list, items}) do
    %{
      "type" => "array",
      "prefixItems" => Enum.map(items, &json_schema/1),
      "minItems" => length(items),
      "maxItems" => length(items)
    }
  end

  defp json_schema({:map, fields}) do
    properties = Map.new(fields, fn {key, value} -> {to_string(key), json_schema(value)} end)

    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => properties,
      "required" => properties |> Map.keys() |> Enum.sort()
    }
  end

  defp extract_fenced_text(text) do
    case Regex.run(~r/```[^\n]*\n(.*?)```/s, text, capture: :all_but_first) do
      [candidate] -> String.trim(candidate)
      nil -> String.trim(text)
    end
  end

  defp schema_name({:list, _}), do: "list"
  defp schema_name({:map, _}), do: "map"
  defp schema_name(schema), do: Atom.to_string(schema)

  defp invalid_value!(path, message) do
    raise ArgumentError,
          "structured Optimize Anything value at #{format_path(path)} #{message}"
  end

  defp invalid_payload!(component, message) do
    raise ArgumentError,
          "structured Optimize Anything component #{inspect(component)} payload #{message}"
  end

  defp format_path([]), do: "<root>"
  defp format_path(path), do: path |> Enum.reverse() |> Enum.map_join(".", &to_string/1)
  defp sha256(binary), do: :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)
end
