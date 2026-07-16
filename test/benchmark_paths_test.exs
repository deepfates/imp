defmodule Imp.BenchmarkTruth.PathsTest do
  use ExUnit.Case, async: true

  alias Imp.BenchmarkTruth.Paths

  test "separates disposable runs from resumable checkpoints" do
    assert Paths.runs_root() == "benchmarks/runs"
    assert Paths.checkpoints_root() == "benchmarks/checkpoints"
    assert Paths.admitted_root() == "benchmarks/evidence/admitted"
    assert Paths.runs("gepa-paper") == "benchmarks/runs/gepa-paper"
    assert Paths.checkpoints("gepa-paper") == "benchmarks/checkpoints/gepa-paper"
    assert Paths.admitted("gepa_paper") == "benchmarks/evidence/admitted/gepa_paper"
  end

  test "lane names cannot escape their canonical root" do
    for lane <- ["../evidence", "/tmp", "nested/path", "", :gepa] do
      assert_raise ArgumentError, fn -> Paths.runs(lane) end
      assert_raise ArgumentError, fn -> Paths.checkpoints(lane) end
      assert_raise ArgumentError, fn -> Paths.admitted(lane) end
    end
  end

  test "canonical paths resolve existing symlink ancestors" do
    root = Path.join(System.tmp_dir!(), "benchmark-paths-#{System.unique_integer([:positive])}")
    outside = Path.join(root, "outside")
    link = Path.join(root, "link")

    File.mkdir_p!(outside)
    File.ln_s!(outside, link)

    on_exit(fn -> File.rm_rf!(root) end)

    assert Paths.canonical_path!(Path.join(link, "future.json")) ==
             Paths.canonical_path!(Path.join(outside, "future.json"))
  end

  test "artifact paths accept a symlinked root but bind to its physical identity" do
    container = tmp_path("symlink-root")
    physical_root = Path.join(container, "physical")
    linked_root = Path.join(container, "linked")

    File.mkdir_p!(physical_root)
    File.ln_s!(physical_root, linked_root)
    on_exit(fn -> File.rm_rf!(container) end)

    prepared = Paths.prepare_file_path!(linked_root, "nested/artifact.json")

    assert prepared ==
             Paths.canonical_path!(Path.join(physical_root, "nested/artifact.json"))

    assert File.dir?(Path.join(physical_root, "nested"))
  end

  test "nested and future symlinks cannot escape an artifact root" do
    container = tmp_path("nested-escape")
    root = Path.join(container, "root")
    outside = Path.join(container, "outside")
    escape = Path.join(root, "escape")
    future = Path.join(root, "future")

    File.mkdir_p!(root)
    File.mkdir_p!(outside)
    File.ln_s!(outside, escape)
    on_exit(fn -> File.rm_rf!(container) end)

    assert_raise ArgumentError, ~r/escapes its canonical root/, fn ->
      Paths.prepare_file_path!(root, "escape/artifact.json")
    end

    before = Paths.canonical_path!(Path.join(future, "artifact.json"))
    assert String.ends_with?(before, "/root/future/artifact.json")

    File.ln_s!(outside, future)

    assert Paths.canonical_path!(Path.join(future, "artifact.json")) ==
             Paths.canonical_path!(Path.join(outside, "artifact.json"))

    assert_raise ArgumentError, ~r/escapes its canonical root/, fn ->
      Paths.prepare_file_path!(root, "future/artifact.json")
    end
  end

  test "canonicalization rejects symlink cycles and relative traversal" do
    container = tmp_path("symlink-cycle")
    root = Path.join(container, "root")
    first = Path.join(root, "first")
    second = Path.join(root, "second")

    File.mkdir_p!(root)
    File.ln_s!(second, first)
    File.ln_s!(first, second)
    on_exit(fn -> File.rm_rf!(container) end)

    assert_raise ArgumentError, ~r/cyclic benchmark symlink/, fn ->
      Paths.canonical_path!(Path.join(first, "artifact.json"))
    end

    assert_raise ArgumentError, ~r/without traversal/, fn ->
      Paths.prepare_file_path!(root, "../outside.json")
    end
  end

  defp tmp_path(label) do
    Path.join(
      System.tmp_dir!(),
      "benchmark-paths-#{label}-#{System.unique_integer([:positive])}"
    )
  end
end
