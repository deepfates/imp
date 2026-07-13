defmodule DSEx.BenchmarkTruth.ConfidenceCalibrationTest do
  use ExUnit.Case, async: true

  alias DSEx.BenchmarkTruth.ConfidenceCalibration

  @data "benchmarks/data/confidence-calibration.jsonl"
  @moduletag :tmp_dir

  test "checked-in fixture passes source and group identity preflight" do
    assert :ok = ConfidenceCalibration.validate_data!(@data)
  end

  test "live preflight rejects namespaced evaluation IDs with duplicate held-out sources",
       %{tmp_dir: tmp_dir} do
    rows = load_rows()
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
    rows = load_rows()
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

  defp load_rows do
    @data
    |> File.stream!()
    |> Enum.map(&Jason.decode!/1)
  end

  defp write_rows!(tmp_dir, rows) do
    path = Path.join(tmp_dir, "confidence-calibration.jsonl")
    body = Enum.map(rows, &[Jason.encode!(&1), "\n"])
    File.write!(path, body)
    path
  end
end
