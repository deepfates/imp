defmodule DSEx.Training.FastSlow.Config do
  @moduledoc false

  @enforce_keys [
    :program_topology,
    :models,
    :dataset_digests,
    :verifier_version,
    :adapter_version,
    :t,
    :k,
    :g,
    :max_cycles
  ]
  defstruct @enforce_keys ++
              [optimizer_config: %{}, provider_config: %{}, sampling_config: %{}]

  @type json_scalar :: nil | boolean() | number() | String.t()
  @type json_value :: json_scalar() | [json_value()] | %{String.t() => json_value()}
  @type t :: %__MODULE__{
          program_topology: json_value(),
          models: json_value(),
          dataset_digests: %{String.t() => String.t()},
          verifier_version: String.t(),
          adapter_version: String.t(),
          t: pos_integer(),
          k: pos_integer(),
          g: pos_integer(),
          max_cycles: pos_integer(),
          optimizer_config: json_value(),
          provider_config: json_value(),
          sampling_config: json_value()
        }

  @keys @enforce_keys ++ [:optimizer_config, :provider_config, :sampling_config]
  @credential_keys ~w(api_key apikey authorization auth bearer credential credentials password secret token access_token refresh_token private_key headers)
  @callback_keys ~w(callback callbacks callback_fn checkpoint_fn)

  @spec new!(keyword() | map()) :: t()
  def new!(options) when is_list(options) or is_map(options) do
    options = if is_list(options), do: Map.new(options), else: options
    unknown = Map.keys(options) -- @keys

    if unknown != [],
      do: raise(ArgumentError, "unknown Fast-Slow config keys: #{inspect(unknown)}")

    config = struct!(__MODULE__, options)

    validate_positive!(config.t, :t)
    validate_positive!(config.k, :k)
    validate_positive!(config.g, :g)
    validate_positive!(config.max_cycles, :max_cycles)

    unless rem(config.g, config.k) == 0,
      do: raise(ArgumentError, "g must be divisible by k")

    validate_string!(config.verifier_version, :verifier_version)
    validate_string!(config.adapter_version, :adapter_version)

    normalized = %{
      config
      | program_topology: json_safe!(config.program_topology, [:program_topology]),
        models: json_safe!(config.models, [:models]),
        dataset_digests: digest_map!(config.dataset_digests),
        optimizer_config: json_safe!(config.optimizer_config, [:optimizer_config]),
        provider_config: json_safe!(config.provider_config, [:provider_config]),
        sampling_config: json_safe!(config.sampling_config, [:sampling_config])
    }

    reject_credentials!(compatibility(normalized))
    normalized
  end

  def new!(_options), do: raise(ArgumentError, "Fast-Slow config must be a keyword list or map")

  @spec compatibility(t()) :: %{String.t() => json_value()}
  def compatibility(%__MODULE__{} = config) do
    %{
      "program_topology" => config.program_topology,
      "models" => config.models,
      "dataset_digests" => config.dataset_digests,
      "verifier_version" => config.verifier_version,
      "adapter_version" => config.adapter_version,
      "t" => config.t,
      "k" => config.k,
      "g" => config.g,
      "max_cycles" => config.max_cycles,
      "optimizer_config" => config.optimizer_config,
      "provider_config" => config.provider_config,
      "sampling_config" => config.sampling_config
    }
  end

  @spec fingerprint(t()) :: String.t()
  def fingerprint(%__MODULE__{} = config), do: digest(compatibility(config))

  @spec persisted_safe!(term()) :: json_value()
  def persisted_safe!(value) do
    value = json_safe!(value)
    reject_credentials!(value)
    reject_callbacks!(value)
    value
  end

  @spec digest(json_value()) :: String.t()
  def digest(value) do
    value
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @spec json_safe!(term(), [atom() | String.t() | non_neg_integer()]) :: json_value()
  def json_safe!(value, path \\ [])

  def json_safe!(value, _path)
      when is_nil(value) or is_boolean(value) or is_binary(value) or is_integer(value),
      do: value

  def json_safe!(value, path) when is_float(value) do
    case Jason.encode(value) do
      {:ok, _encoded} -> value
      {:error, _reason} -> invalid_json!(path, value)
    end
  end

  def json_safe!(value, _path) when is_atom(value), do: Atom.to_string(value)

  def json_safe!(value, path) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.map(fn {item, index} -> json_safe!(item, path ++ [index]) end)
  end

  def json_safe!(value, path) when is_map(value) and not is_struct(value) do
    Map.new(value, fn {key, item} ->
      key = json_key!(key, path)
      {key, json_safe!(item, path ++ [key])}
    end)
  end

  def json_safe!(value, path), do: invalid_json!(path, value)

  defp digest_map!(value) when is_map(value) and not is_struct(value) do
    value = json_safe!(value, [:dataset_digests])

    if map_size(value) > 0 and
         Enum.all?(value, fn {key, digest} -> key != "" and valid_digest?(digest) end) do
      value
    else
      raise ArgumentError, "dataset_digests must be a non-empty string map of SHA-256 digests"
    end
  end

  defp digest_map!(_value),
    do: raise(ArgumentError, "dataset_digests must be a non-empty string map of SHA-256 digests")

  defp valid_digest?(digest), do: is_binary(digest) and Regex.match?(~r/\A[0-9a-f]{64}\z/, digest)

  defp reject_credentials!(value), do: walk_keys!(value, [])

  defp reject_callbacks!(value), do: walk_callback_keys!(value, [])

  defp walk_keys!(map, path) when is_map(map) do
    Enum.each(map, fn {key, value} ->
      normalized = key |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "_")

      if normalized in @credential_keys or String.ends_with?(normalized, "_token") or
           String.ends_with?(normalized, "_secret") or String.ends_with?(normalized, "_password") do
        raise ArgumentError,
              "Fast-Slow config may not contain credentials at #{format_path(path ++ [key])}"
      end

      walk_keys!(value, path ++ [key])
    end)
  end

  defp walk_keys!(list, path) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.each(fn {value, index} -> walk_keys!(value, path ++ [index]) end)
  end

  defp walk_keys!(_value, _path), do: :ok

  defp walk_callback_keys!(map, path) when is_map(map) do
    Enum.each(map, fn {key, value} ->
      normalized = key |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "_")

      if normalized in @callback_keys or String.ends_with?(normalized, "_callback") or
           String.ends_with?(normalized, "_callbacks") do
        raise ArgumentError,
              "Fast-Slow callbacks may not be persisted at #{format_path(path ++ [key])}"
      end

      walk_callback_keys!(value, path ++ [key])
    end)
  end

  defp walk_callback_keys!(list, path) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.each(fn {value, index} -> walk_callback_keys!(value, path ++ [index]) end)
  end

  defp walk_callback_keys!(_value, _path), do: :ok

  defp json_key!(key, _path) when is_binary(key), do: key
  defp json_key!(key, _path) when is_atom(key), do: Atom.to_string(key)
  defp json_key!(key, path), do: invalid_json!(path, {:map_key, key})

  defp validate_positive!(value, _name) when is_integer(value) and value > 0, do: :ok

  defp validate_positive!(_value, name),
    do: raise(ArgumentError, "#{name} must be a positive integer")

  defp validate_string!(value, _name) when is_binary(value) and byte_size(value) > 0, do: :ok

  defp validate_string!(_value, name),
    do: raise(ArgumentError, "#{name} must be a non-empty string")

  defp invalid_json!(path, value) do
    raise ArgumentError,
          "Fast-Slow persisted data must be JSON-safe at #{format_path(path)}; got: #{inspect(value)}"
  end

  defp format_path([]), do: "$"
  defp format_path(path), do: "$" <> Enum.map_join(path, "", &path_segment/1)
  defp path_segment(index) when is_integer(index), do: "[#{index}]"
  defp path_segment(key), do: ".#{key}"
end
