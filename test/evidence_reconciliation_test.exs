defmodule EvidenceReconciliationTest do
  use ExUnit.Case, async: false

  # docs/EVIDENCE.md states the asserted-vs-computed reconciliation ("N of the
  # M proven, B blocked, I informational (profile ready: X)") as prose. Those
  # numbers were hand-set once; this gate recomputes them the way the doc
  # defines them — a fresh source checkout, committed evidence only — and fails
  # when the prose drifts from the computation (dee-sc3q piece 3). Venv-free,
  # ~2s: the dashboard only reads committed files when the ephemeral lane
  # directories are empty, which is exactly the fresh-checkout semantics the
  # doc describes.
  @moduletag :evidence_infrastructure

  @evidence_doc "docs/EVIDENCE.md"

  test "EVIDENCE.md reconciliation block matches the freshly computed dashboard state" do
    empty = Path.join(System.tmp_dir!(), "imp-recon-empty-#{System.unique_integer([:positive])}")
    out = Path.join(System.tmp_dir!(), "imp-recon-out-#{System.unique_integer([:positive])}")
    File.mkdir_p!(empty)
    File.mkdir_p!(out)
    on_exit(fn -> Enum.each([empty, out], &File.rm_rf!/1) end)

    # The standard `mix benchmark.dashboard` alias arguments, with every
    # ephemeral (gitignored) lane directory replaced by an empty directory so
    # the computation sees committed evidence only, as on a fresh checkout.
    Mix.Task.reenable("imp.benchmark.dashboard")

    ExUnit.CaptureIO.capture_io(fn ->
      Mix.Tasks.Imp.Benchmark.Dashboard.run([
        "--profile",
        "v0.1",
        "--trace-dir",
        empty,
        "--failure-campaign-dir",
        empty,
        "--overhead-dir",
        empty,
        "--optimizer-dir",
        empty,
        "--instruction-optimizer-dir",
        empty,
        "--gepa-dir",
        empty,
        "--optimize-anything-dir",
        "benchmarks/evidence/admitted/optimize_anything",
        "--rlm-dir",
        empty,
        "--live-matrix-dir",
        empty,
        "--results-dir",
        empty,
        "--gate-dir",
        empty,
        "--out",
        out
      ])
    end)

    assert [dashboard_path] = Path.wildcard(Path.join(out, "parity-dashboard-*.json"))
    dashboard = dashboard_path |> File.read!() |> Jason.decode!()

    computed = dashboard["claims"]["summary"]
    computed_ready = dashboard["profile_ready"]

    doc = @evidence_doc |> File.read!() |> String.replace(~r/\s+/, " ")

    assert [_, proven, total, blocked, informational, ready] =
             Regex.run(
               ~r/reports \*\*(\d+) of the (\d+) proven, (\d+) blocked, (\d+) informational\*\* \(profile ready: (true|false)\)/,
               doc
             ),
           "#{@evidence_doc} no longer contains the reconciliation sentence in the " <>
             "pinned form; restate it with the computed numbers and update this gate"

    stated = %{
      "proven" => String.to_integer(proven),
      "total" => String.to_integer(total),
      "blocked" => String.to_integer(blocked),
      "informational" => String.to_integer(informational)
    }

    assert stated == Map.take(computed, ["proven", "total", "blocked", "informational"]),
           "#{@evidence_doc} states #{inspect(stated)} but a fresh-checkout dashboard " <>
             "computes #{inspect(computed)}; re-pin the reconciliation block " <>
             "deliberately (dee-sc3q)"

    assert ready == to_string(computed_ready),
           "#{@evidence_doc} states profile ready: #{ready} but the dashboard " <>
             "computes #{computed_ready}; re-pin the reconciliation block"

    # The ledger-overview sentence and the reconciliation must agree on the
    # asserted count: the dashboard evaluates exactly the asserted rows.
    assert [_, asserted] = Regex.run(~r/(\d+) asserted, \d+ still targets/, doc),
           "#{@evidence_doc} no longer states the asserted/targets split"

    assert String.to_integer(asserted) == computed["total"],
           "#{@evidence_doc} claims #{asserted} asserted rows but the dashboard " <>
             "evaluated #{computed["total"]}"
  end
end
