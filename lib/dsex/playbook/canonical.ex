defmodule DSEx.Playbook.Canonical do
  @moduledoc false

  @spec encode(term()) :: String.t()
  def encode(value), do: encode_value(value)

  @spec hash(term()) :: String.t()
  def hash(value) do
    value
    |> encode()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp encode_value(value) when is_struct(value), do: value |> Map.from_struct() |> encode_value()

  defp encode_value(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested} -> {to_string(key), nested} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map_join(",", fn {key, nested} ->
      Jason.encode!(key) <> ":" <> encode_value(nested)
    end)
    |> then(&("{" <> &1 <> "}"))
  end

  defp encode_value(value) when is_list(value) do
    value
    |> Enum.map_join(",", &encode_value/1)
    |> then(&("[" <> &1 <> "]"))
  end

  defp encode_value(value) when value in [true, false, nil], do: Jason.encode!(value)

  defp encode_value(value) when is_atom(value) and not is_nil(value),
    do: value |> Atom.to_string() |> Jason.encode!()

  defp encode_value(value), do: Jason.encode!(value)
end
