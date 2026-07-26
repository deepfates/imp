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
