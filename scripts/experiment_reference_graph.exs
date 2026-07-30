#!/usr/bin/env elixir

# Computed migration guard for the five matched execution directories. This is
# deliberately not a status ledger: claims remain in benchmarks/claims.json and
# scientific records remain byte-owned by their result files.
defmodule ImpExperimentReferenceGraph do
  @origin "e376cbdd2858eedb305bbd23c45ee12bb9594d48"
  @roots [
    "examples/matched_instruction_optimizers_trec",
    "examples/matched_gepa_mipro_ifbench",
    "examples/matched_gepa_mipro_ifbench_v2",
    "examples/matched_gepa_mipro_ifbench_v3",
    "examples/matched_gepa_mipro_ifbench_gepa014"
  ]
  @design_owner "examples/matched_instruction_family_ifbench"
  @script "scripts/experiment_reference_graph.exs"

  @migrations [
    {"benchmarks/results/matched-instruction-optimizers-trec-20260726.json",
     "benchmarks/evidence/archive/matched_experiments/trec/matched-instruction-optimizers-trec-20260726.json"},
    {"examples/matched_gepa_mipro_ifbench/exercised-sealed-imp-baseline.json",
     "benchmarks/evidence/archive/matched_experiments/ifbench-v1/exercised-sealed-imp-baseline.json"},
    {"examples/matched_gepa_mipro_ifbench/exercised-sealed-upstream-baseline.json",
     "benchmarks/evidence/archive/matched_experiments/ifbench-v1/exercised-sealed-upstream-baseline.json"},
    {"examples/matched_gepa_mipro_ifbench/exercised-stopped-imp.json",
     "benchmarks/evidence/archive/matched_experiments/ifbench-v1/exercised-stopped-imp.json"},
    {"examples/matched_gepa_mipro_ifbench/exercised-stopped-upstream.json",
     "benchmarks/evidence/archive/matched_experiments/ifbench-v1/exercised-stopped-upstream.json"},
    {"examples/matched_gepa_mipro_ifbench/stopped-result.json",
     "benchmarks/evidence/archive/matched_experiments/ifbench-v1/stopped-result.json"},
    {"examples/matched_gepa_mipro_ifbench_v2/exercised-stopped-imp.json",
     "benchmarks/evidence/archive/matched_experiments/ifbench-v2/exercised-stopped-imp.json"},
    {"examples/matched_gepa_mipro_ifbench_v2/exercised-stopped-upstream.json",
     "benchmarks/evidence/archive/matched_experiments/ifbench-v2/exercised-stopped-upstream.json"},
    {"examples/matched_gepa_mipro_ifbench_v2/exercised-stopped-sealed/imp-2026072705-baseline.json",
     "benchmarks/evidence/archive/matched_experiments/ifbench-v2/imp-2026072705-baseline.json"},
    {"examples/matched_gepa_mipro_ifbench_v2/exercised-stopped-sealed/upstream-2026072705-baseline.json",
     "benchmarks/evidence/archive/matched_experiments/ifbench-v2/upstream-2026072705-baseline.json"},
    {"examples/matched_gepa_mipro_ifbench_v3/exercised-stopped-imp.json",
     "benchmarks/evidence/archive/matched_experiments/ifbench-v3/exercised-stopped-imp.json"},
    {"examples/matched_gepa_mipro_ifbench_v3/exercised-stopped-upstream.json",
     "benchmarks/evidence/archive/matched_experiments/ifbench-v3/exercised-stopped-upstream.json"},
    {"examples/matched_gepa_mipro_ifbench_v3/exercised-stopped-sealed/imp-2026072705-baseline.json",
     "benchmarks/evidence/archive/matched_experiments/ifbench-v3/imp-2026072705-baseline.json"},
    {"examples/matched_gepa_mipro_ifbench_v3/exercised-stopped-sealed/upstream-2026072705-baseline.json",
     "benchmarks/evidence/archive/matched_experiments/ifbench-v3/upstream-2026072705-baseline.json"}
  ]

  @unavailable_local_records [
    %{
      "execution" => "examples/matched_gepa_mipro_ifbench_gepa014",
      "path" => nil,
      "sha256" => "97dee6d4f757ab2c925a5c0dd9033c16f6f98bd9b87b959844dac059bb0a0692",
      "reason" => "ignored local output was never committed"
    },
    %{
      "execution" => "examples/matched_gepa_mipro_ifbench_gepa014",
      "path" => nil,
      "sha256" => "530b32ad107d32ae8109741cb9e80dd36b7bf4019fd178fec32904c1b23e1970",
      "reason" => "ignored local output was never committed"
    }
  ]

  def run!(root) do
    verify_roots!(root)
    migrations = Enum.map(@migrations, &verify_migration!(root, &1))
    claims = active_claim_edges!(root)
    inbound = Map.new(@roots, &{&1, inbound_refs(root, &1)})
    unavailable = @unavailable_local_records ++ unavailable_trec_records!(root)

    %{
      "schema_version" => 1,
      "computed_from_commit" => @origin,
      "execution_roots" => @roots,
      "shared_design_data_owner" => @design_owner,
      "claim_edges" => claims,
      "inbound_references" => inbound,
      "byte_migrations" => migrations,
      "unavailable_local_records" => unavailable,
      "deletion_allowed" => false,
      "deletion_blockers" => deletion_blockers(inbound, unavailable)
    }
  end

  defp verify_roots!(root) do
    Enum.each(@roots ++ [@design_owner], fn path ->
      unless File.dir?(Path.join(root, path)),
        do: fail!("missing matched experiment root #{path}")
    end)

    discovered =
      Path.wildcard(Path.join(root, "examples/matched_*"))
      |> Enum.filter(&File.dir?/1)
      |> Enum.map(&Path.relative_to(&1, root))
      |> Enum.sort()

    expected = Enum.sort(@roots ++ [@design_owner])

    if discovered != expected,
      do: fail!("matched directory set drifted: #{inspect(discovered -- expected)}")
  end

  defp verify_migration!(root, {source, archive}) do
    historical = git_blob!(root, @origin, source)
    source_bytes = File.read!(Path.join(root, source))
    archive_bytes = File.read!(Path.join(root, archive))

    unless source_bytes == historical,
      do: fail!("current historical result bytes drifted: #{source}")

    unless archive_bytes == historical, do: fail!("archived result bytes drifted: #{archive}")

    %{
      "source" => source,
      "archive" => archive,
      "sha256" => sha256(historical),
      "bytes" => byte_size(historical),
      "origin_commit" => @origin
    }
  end

  defp active_claim_edges!(root) do
    claims = root |> Path.join("benchmarks/claims.json") |> File.read!() |> :json.decode()

    claims["claims"]
    |> Enum.filter(&(&1["claim_state"] == "asserted"))
    |> Enum.filter(fn claim -> Enum.any?(List.wrap(claim["sources"]), &matched_reference?/1) end)
    |> Enum.flat_map(fn claim ->
      claim["sources"]
      |> List.wrap()
      |> Enum.map(fn source ->
        unless reference_resolves?(root, source),
          do: fail!("active claim #{claim["id"]} has missing source #{source}")

        %{"claim" => claim["id"], "source" => source}
      end)
    end)
  end

  defp matched_reference?(source) do
    Enum.any?(@roots, &String.starts_with?(source, &1)) or
      source in [
        "benchmarks/results/matched-instruction-optimizers-trec-20260726.json",
        "benchmarks/evidence/archive/matched_experiments/trec/matched-instruction-optimizers-trec-20260726.json"
      ]
  end

  defp reference_resolves?(root, source) do
    if String.contains?(source, ["*", "?", "["]) do
      Path.wildcard(Path.join(root, source)) != []
    else
      File.exists?(Path.join(root, source))
    end
  end

  defp inbound_refs(root, execution_root) do
    {output, status} =
      System.cmd("rg", ["-l", "--fixed-strings", execution_root, "."],
        cd: root,
        stderr_to_stdout: true
      )

    if status not in [0, 1], do: fail!("cannot scan references for #{execution_root}: #{output}")

    output
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim_leading(&1, "./"))
    |> Enum.reject(&(&1 == @script or String.starts_with?(&1, execution_root <> "/")))
    |> Enum.sort()
  end

  defp unavailable_trec_records!(root) do
    result =
      root
      |> Path.join("benchmarks/results/matched-instruction-optimizers-trec-20260726.json")
      |> File.read!()
      |> :json.decode()

    Enum.map(result["raw_retained_artifacts"], fn {owner, record} ->
      path = record["path"]
      absolute = Path.join(root, path)

      if File.regular?(absolute) do
        bytes = File.read!(absolute)

        unless byte_size(bytes) == record["bytes"] and sha256(bytes) == record["sha256"] do
          fail!("TREC raw artifact does not match canonical summary: #{path}")
        end
      end

      %{
        "execution" => "examples/matched_instruction_optimizers_trec",
        "owner" => owner,
        "path" => path,
        "bytes" => record["bytes"],
        "sha256" => record["sha256"],
        "reason" =>
          if(File.regular?(absolute),
            do: "ignored local output is not repository-persistent",
            else: "ignored local output is unavailable"
          )
      }
    end)
  end

  defp deletion_blockers(inbound, unavailable) do
    references =
      inbound
      |> Enum.flat_map(fn {root, refs} ->
        Enum.map(refs, &%{"execution" => root, "inbound" => &1})
      end)

    missing =
      Enum.map(unavailable, fn record ->
        %{
          "execution" => record["execution"],
          "unavailable_sha256" => record["sha256"],
          "inbound" => record["path"] || "historical ignored result"
        }
      end)

    Enum.sort_by(references ++ missing, &{&1["execution"], &1["inbound"]})
  end

  defp git_blob!(root, commit, path) do
    case System.cmd("git", ["show", "#{commit}:#{path}"], cd: root, stderr_to_stdout: true) do
      {bytes, 0} -> bytes
      {output, _status} -> fail!("cannot read historical result #{commit}:#{path}: #{output}")
    end
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  defp fail!(message), do: raise("experiment reference graph refused: " <> message)
end

root = Path.expand("..", __DIR__)
graph = ImpExperimentReferenceGraph.run!(root)

if "--check" not in System.argv() do
  IO.puts(:json.encode(graph))
end
