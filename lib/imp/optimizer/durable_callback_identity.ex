defmodule Imp.Optimizer.DurableCallbackIdentity do
  @moduledoc false

  alias Imp.Clients.TRLProtocol

  def normalize!(nil, _option), do: nil

  def normalize!(identity, option) when is_atom(option) do
    unless is_map(identity) and not is_struct(identity) and
             Map.keys(identity) |> Enum.all?(&is_binary/1) do
      raise ArgumentError,
            "#{inspect(option)} must use string keys and contain JSON-safe id, version, and config"
    end

    unless Map.keys(identity) |> Enum.sort() == ["config", "id", "version"] and
             is_binary(identity["id"]) and String.trim(identity["id"]) != "" and
             valid_version?(identity["version"]) and json_safe?(identity["config"]) do
      raise ArgumentError,
            "#{inspect(option)} must contain exactly non-empty string id, string/integer version, " <>
              "and already JSON-safe config"
    end

    %{
      "id" => identity["id"],
      "version" => identity["version"],
      "config_sha256" => TRLProtocol.digest(identity["config"])
    }
  end

  def durable?(callback, normalized_identity, durable_controls?)
      when is_boolean(durable_controls?) do
    not is_nil(normalized_identity) or external_function?(callback) or durable_controls?
  end

  def resolve!(callback, normalized_identity, durable?, owner, option)
      when is_binary(owner) and is_atom(option) do
    cond do
      not is_nil(normalized_identity) ->
        Map.put(normalized_identity, "kind", "declared")

      external_function?(callback) ->
        %{
          "kind" => "external_function",
          "module" => callback |> :erlang.fun_info(:module) |> elem(1) |> Atom.to_string(),
          "name" => callback |> :erlang.fun_info(:name) |> elem(1) |> Atom.to_string(),
          "arity" => callback |> :erlang.fun_info(:arity) |> elem(1)
        }

      durable? ->
        raise ArgumentError,
              "durable #{owner} with an anonymous or captured metric requires " <>
                "#{inspect(option)} with stable JSON-safe id/version/config; got metric " <>
                inspect(callback)

      true ->
        nil
    end
  end

  def validate_normalized!(nil, _owner), do: :ok

  def validate_normalized!(identity, owner) when is_binary(owner) do
    unless is_map(identity) and
             Map.keys(identity) |> Enum.sort() == ["config_sha256", "id", "version"] and
             is_binary(identity["id"]) and String.trim(identity["id"]) != "" and
             valid_version?(identity["version"]) and is_binary(identity["config_sha256"]) do
      raise ArgumentError, "invalid normalized #{owner} metric identity"
    end

    :ok
  end

  def external_function?(callback) when is_function(callback) do
    callback |> :erlang.fun_info(:type) |> elem(1) == :external
  end

  def external_function?(_callback), do: false

  @doc false
  def runtime_identity(callback) when is_function(callback) do
    Map.new([:module, :name, :arity, :type, :uniq, :index], fn key ->
      {key, callback |> :erlang.fun_info(key) |> elem(1)}
    end)
  end

  def runtime_identity(%_{} = struct),
    do: struct |> Map.from_struct() |> runtime_identity()

  def runtime_identity(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      {key, runtime_identity_entry(key, value)}
    end)
  end

  def runtime_identity({key, value}) when is_atom(key) or is_binary(key),
    do: {key, runtime_identity_entry(key, value)}

  def runtime_identity(list) when is_list(list), do: Enum.map(list, &runtime_identity/1)

  def runtime_identity(tuple) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.map(&runtime_identity/1)
    |> List.to_tuple()
  end

  def runtime_identity(pid) when is_pid(pid), do: :runtime_pid
  def runtime_identity(reference) when is_reference(reference), do: :runtime_reference
  def runtime_identity(port) when is_port(port), do: :runtime_port
  def runtime_identity(value), do: value

  defp runtime_identity_entry(key, value) do
    if Imp.Redaction.credential_entry?(key, value),
      do: :runtime_credential,
      else: runtime_identity(value)
  end

  defp json_safe?(nil), do: true
  defp json_safe?(value) when is_binary(value) or is_boolean(value), do: true
  defp json_safe?(value) when is_integer(value), do: true

  defp json_safe?(value) when is_float(value) do
    try do
      value |> :erlang.float_to_binary([:compact]) |> then(&(&1 not in ["nan", "inf", "-inf"]))
    rescue
      ArgumentError -> false
    end
  end

  defp json_safe?(values) when is_list(values), do: Enum.all?(values, &json_safe?/1)

  defp json_safe?(map) when is_map(map) and not is_struct(map) do
    Enum.all?(map, fn {key, value} -> is_binary(key) and json_safe?(value) end)
  end

  defp json_safe?(_value), do: false

  defp valid_version?(version) when is_integer(version), do: version >= 0
  defp valid_version?(version) when is_binary(version), do: String.trim(version) != ""
  defp valid_version?(_version), do: false
end
