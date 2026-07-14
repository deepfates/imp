defmodule Imp.Test.GepaCampaignFixture do
  @moduledoc false

  @campaign_manifest "benchmarks/config/gepa-paper-campaign-v2.json"
  @families_manifest "benchmarks/data/gepa-campaign-full/families.json"

  def create! do
    root =
      Path.join(
        System.tmp_dir!(),
        "imp-gepa-controls-#{System.unique_integer([:positive, :monotonic])}"
      )

    dataset_root = Path.join(root, "data")
    File.mkdir_p!(dataset_root)

    families =
      @families_manifest
      |> File.read!()
      |> Jason.decode!()
      |> update_in(["families"], &Enum.map(&1, fn spec -> write_family!(dataset_root, spec) end))

    families_path = Path.join(dataset_root, "families.json")
    File.write!(families_path, Jason.encode!(families, pretty: true))

    manifest =
      @campaign_manifest
      |> File.read!()
      |> Jason.decode!()
      |> Map.put("campaign_id", "imp-gepa-controls-fixture")
      |> put_in(["dataset", "root"], "data")
      |> put_in(["dataset", "families_manifest_sha256"], sha256(families_path))
      |> put_in(["output", "out_dir"], "results")
      |> put_in(["output", "checkpoint_dir"], "results/checkpoints")

    manifest_path = Path.join(root, "campaign.json")
    File.write!(manifest_path, Jason.encode!(manifest, pretty: true))

    %{root: root, manifest_path: manifest_path}
  end

  defp write_family!(dataset_root, spec) do
    family = spec["family"]
    family_dir = Path.join(dataset_root, family)
    File.mkdir_p!(family_dir)

    checksums =
      Map.new(~w(train dev test), fn split ->
        path = Path.join(family_dir, "#{split}.jsonl")
        File.write!(path, Jason.encode!(%{"family" => family, "split" => split}) <> "\n")
        {split, "sha256:" <> sha256(path)}
      end)

    spec
    |> Map.put("split_counts", %{"train" => 1, "dev" => 1, "test" => 1})
    |> Map.put("split_checksums", checksums)
  end

  defp sha256(path),
    do: path |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
end
