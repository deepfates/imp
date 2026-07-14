defmodule Imp.Predict.RLM.Trace do
  @moduledoc false

  @hash_range 4_294_967_296

  def compact(value, limit) when is_integer(limit) and limit >= 0 do
    bytes = :erlang.external_size(value)

    if bytes <= limit do
      Imp.Redaction.redact(value)
    else
      %{
        type: type(value),
        bytes: bytes,
        sha256: digest(value, bytes),
        truncated: true
      }
    end
  end

  # phash2 traverses the term without allocating its external binary. Hashing
  # fixed-size metadata keeps compaction allocation bounded for large values.
  defp digest(value, bytes) do
    fingerprint = :erlang.phash2(value, @hash_range)

    :crypto.hash(:sha256, [type_tag(value), <<bytes::unsigned-64, fingerprint::unsigned-32>>])
    |> Base.encode16(case: :lower)
  end

  defp type_tag(value), do: Atom.to_string(type(value))

  defp type(value) when is_binary(value), do: :binary
  defp type(value) when is_map(value), do: :map
  defp type(value) when is_list(value), do: :list
  defp type(value) when is_tuple(value), do: :tuple
  defp type(_value), do: :term
end
