defmodule ParityMatrixTest do
  use ExUnit.Case

  test "parity matrix has no unclassified public rows" do
    matrix = File.read!("PARITY.md")

    refute matrix =~ "TODO"
    refute matrix =~ "unclassified"
    refute matrix =~ "missing"

    rows =
      matrix
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "| `"))

    assert length(rows) >= 75

    Enum.each(rows, fn row ->
      assert row =~
               ~r/\| (operational|equivalent|compat|intentional|operational contract|intentional safe sandbox) /
    end)
  end
end
