defmodule Imp.BenchmarkTruth.ReleaseProfile do
  @moduledoc false

  @schema_version 1
  @default "v0.1"
  @profiles %{
    "v0.1" => ["v0.1"],
    "telos" => ["v0.1", "telos"],
    "research" => ["v0.1", "telos", "research"]
  }

  def default, do: @default
  def names, do: Map.keys(@profiles) |> Enum.sort()

  def fetch!(name) do
    case @profiles do
      %{^name => releases} ->
        %{
          "id" => name,
          "schema_version" => @schema_version,
          "claim_releases" => releases
        }

      _profiles ->
        raise ArgumentError,
              "unknown release profile #{inspect(name)}; expected one of #{Enum.join(names(), ", ")}"
    end
  end

  def select_claims(claims, %{"claim_releases" => releases}) when is_list(claims) do
    Enum.filter(claims, &(&1["release"] in releases))
  end

  def lane_requirements(claims, profile) do
    claims
    |> select_claims(profile)
    |> Enum.filter(&(&1["gate_policy"] == "blocking"))
    |> Enum.flat_map(fn claim ->
      Enum.map(claim["requirements"] || [], fn requirement ->
        %{
          "lane" => requirement["lane"],
          "evidence" => requirement["evidence"] || "full",
          "claim_id" => claim["id"],
          "requirement_id" => requirement["id"]
        }
      end)
    end)
    |> Enum.reject(&is_nil(&1["lane"]))
    |> Enum.group_by(& &1["lane"])
    |> Enum.map(fn {lane, requirements} ->
      %{
        "lane" => lane,
        "evidence" => strongest_evidence(requirements),
        "claim_ids" => requirements |> Enum.map(& &1["claim_id"]) |> Enum.uniq(),
        "requirement_ids" => requirements |> Enum.map(& &1["requirement_id"]) |> Enum.uniq()
      }
    end)
    |> Enum.sort_by(& &1["lane"])
  end

  defp strongest_evidence(requirements) do
    if Enum.any?(requirements, &(&1["evidence"] == "full")), do: "full", else: "passing"
  end
end
