defmodule Imp.BenchmarkTruth.ConfidenceCalibrationTest do
  use ExUnit.Case, async: true

  alias Imp.BenchmarkTruth.ConfidenceCalibration

  @data "benchmarks/data/confidence-calibration.jsonl"
  @trec_data "benchmarks/data/confidence-calibration-trec-fine.jsonl"
  @trec_provenance "benchmarks/data/confidence-calibration-trec-fine.provenance.json"
  @moduletag :tmp_dir

  test "checked-in fixture passes source and group identity preflight" do
    assert :ok = ConfidenceCalibration.validate_data!(@data)
  end

  test "pinned TREC fixture passes label provenance and partition preflight" do
    assert :ok =
             ConfidenceCalibration.validate_data!(@trec_data,
               provenance: @trec_provenance
             )

    rows = load_rows(@trec_data)
    calibration = Enum.filter(rows, &(&1["split"] == "calibration"))
    heldout = Enum.filter(rows, &(&1["split"] == "heldout"))

    assert length(calibration) == 200
    assert length(heldout) == 200
    assert Enum.all?(calibration, &(&1["source_split"] == "train"))
    assert Enum.all?(heldout, &(&1["source_split"] == "test"))
    assert Enum.all?(rows, &(&1["label"] == &1["source_label"]))
    assert disjoint?(calibration, heldout, "source_id")
    assert disjoint?(calibration, heldout, "group_id")
  end

  test "TREC preflight rejects source labels altered after acquisition", %{tmp_dir: tmp_dir} do
    rows = load_rows(@trec_data)

    altered =
      List.update_at(rows, 0, fn row ->
        %{row | "label" => "NUM:weight"}
      end)

    path = write_rows!(tmp_dir, altered)

    assert_raise ArgumentError, ~r/data contract mismatch/, fn ->
      ConfidenceCalibration.validate_data!(path, provenance: @trec_provenance)
    end
  end

  test "TREC preflight binds the exact serialized data to provenance", %{tmp_dir: tmp_dir} do
    rows = load_rows(@trec_data)

    altered =
      List.update_at(rows, 0, fn row ->
        Map.update!(row, "text", &(&1 <> " "))
      end)

    path = write_rows!(tmp_dir, altered)

    assert_raise ArgumentError, ~r/provenance contract mismatch/, fn ->
      ConfidenceCalibration.validate_data!(path, provenance: @trec_provenance)
    end
  end

  test "live preflight rejects namespaced evaluation IDs with duplicate held-out sources",
       %{tmp_dir: tmp_dir} do
    rows = load_rows(@data)
    first_heldout = Enum.find(rows, &(&1["split"] == "heldout"))

    duplicate_source_rows =
      Enum.map(rows, fn row ->
        if row["id"] == "held:policy:07" do
          Map.put(row, "source_id", first_heldout["source_id"])
        else
          row
        end
      end)

    path = write_rows!(tmp_dir, duplicate_source_rows)

    assert_raise ArgumentError, ~r/data contract mismatch/, fn ->
      ConfidenceCalibration.validate_data!(path)
    end
  end

  test "live preflight rejects calibration and held-out group overlap", %{tmp_dir: tmp_dir} do
    rows = load_rows(@data)
    calibration_group = rows |> hd() |> Map.fetch!("group_id")

    overlapping_group_rows =
      Enum.map(rows, fn row ->
        if row["id"] == "held:minimal:01" do
          Map.put(row, "group_id", calibration_group)
        else
          row
        end
      end)

    path = write_rows!(tmp_dir, overlapping_group_rows)

    assert_raise ArgumentError, ~r/data contract mismatch/, fn ->
      ConfidenceCalibration.validate_data!(path)
    end
  end

  defp load_rows(path) do
    path
    |> File.stream!()
    |> Enum.map(&Jason.decode!/1)
  end

  defp write_rows!(tmp_dir, rows) do
    path = Path.join(tmp_dir, "confidence-calibration.jsonl")
    body = Enum.map(rows, &[Jason.encode!(&1), "\n"])
    File.write!(path, body)
    path
  end

  defp disjoint?(left, right, key) do
    MapSet.disjoint?(MapSet.new(left, & &1[key]), MapSet.new(right, & &1[key]))
  end

  defp mixed?(%{"correct" => correct, "incorrect" => incorrect}),
    do: correct > 0 and incorrect > 0

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
