defmodule ImpTest.GEPAFamilyManifestProvisioningTest do
  @moduledoc """
  `families.json` carries a retrieval `status` field. It read "present" while
  the corpus and BM25 index were absent from disk — the earlier HoVer rows only
  worked off a 1,485-entry retrieval cache, which is what "capped" meant. A
  declared status that contradicts the filesystem is worse than no status: it
  sent me to plan a full-scale run against data that did not exist.

  This computes the property instead of trusting the field. Cheap: it stats
  paths, it does not read the 1.7GB corpus.
  """
  use ExUnit.Case, async: true

  @manifest "benchmarks/data/gepa-campaign-full/families.json"
  @artifact_root "tmp/gepa-artifact"

  @tag :local_provisioning
  test "any family declaring retrieval status 'present' actually has its corpus and index on disk" do
    manifest = @manifest |> File.read!() |> Jason.decode!()

    for family <- manifest["families"],
        retrieval = family["retrieval"],
        is_map(retrieval),
        retrieval["status"] == "present" do
      for key <- ~w(corpus_path index_path),
          path = retrieval[key],
          is_binary(path) do
        full = Path.join(@artifact_root, path)

        assert File.exists?(full),
               "#{family["family"]} declares retrieval status 'present' but #{key} " <>
                 "#{full} does not exist. Either provision it or stop claiming present."
      end
    end
  end

  test "declared split files exist for every family whose splits were exported" do
    manifest = @manifest |> File.read!() |> Jason.decode!()
    root = Path.dirname(@manifest)

    for family <- manifest["families"],
        counts = family["split_counts"],
        is_map(counts) do
      dir = Path.join(root, family["family"])

      if File.dir?(dir) do
        for split <- Map.keys(counts) do
          path = Path.join(dir, "#{split}.jsonl")

          assert File.exists?(path),
                 "#{family["family"]} has an exported split directory but #{path} is missing"
        end
      end
    end
  end
end
