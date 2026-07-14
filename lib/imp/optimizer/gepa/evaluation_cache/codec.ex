defmodule Imp.Optimizer.GEPA.EvaluationCache.Codec do
  @moduledoc false

  alias Imp.Optimizer.Report

  @spec digest(term()) :: String.t()
  def digest(value) do
    value
    |> Report.json_safe()
    |> canonical_json!()
    |> sha256()
  end

  @spec checksum(term()) :: String.t()
  def checksum(value), do: "sha256:" <> (value |> canonical_json!() |> sha256())

  @spec canonical_json!(term()) :: binary()
  def canonical_json!(value), do: value |> ordered() |> Jason.encode!()

  defp ordered(%Jason.OrderedObject{} = value), do: value

  defp ordered(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested} -> {key, ordered(nested)} end)
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Jason.OrderedObject.new()
  end

  defp ordered(value) when is_list(value), do: Enum.map(value, &ordered/1)
  defp ordered(value), do: value

  defp sha256(value) do
    value
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
