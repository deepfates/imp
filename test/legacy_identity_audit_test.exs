defmodule LegacyIdentityAuditTest do
  use ExUnit.Case, async: true

  alias Imp.LegacyIdentityAudit, as: Audit

  test "all tracked identity matches are explicitly classified" do
    assert {:ok, report} = Audit.audit()
    assert report.findings != []
    assert report.violations == []
  end

  test "the cutover does not allowlist the removed compatibility module or test" do
    allowlisted = Audit.policy().allowlisted_files

    refute Map.has_key?(allowlisted, "lib/imp/persistence/legacy.ex")
    refute Map.has_key?(allowlisted, "test/persistence_legacy_test.exs")
  end

  test "historical benchmark results remain allowlisted by path policy" do
    legacy = "DS" <> "Ex"

    [finding] =
      Audit.scan([
        %{path: "benchmarks/results/frozen.json", content: "source: " <> legacy}
      ])

    assert finding.policy == :historical
    assert Audit.allowlisted?(finding)
  end

  test "a legacy token in a live source fixture is a violation" do
    legacy = "d" <> "sex"

    findings =
      Audit.scan([
        %{path: "lib/imp/controlled_fixture.ex", content: "legacy = " <> legacy}
      ])

    assert [%{policy: :live_package}] = Enum.reject(findings, &Audit.allowlisted?/1)
  end

  test "audit ignores tracked files deleted from the working tree" do
    root =
      Path.join(System.tmp_dir!(), "imp-identity-audit-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(root) end)

    File.mkdir_p!(root)
    File.write!(Path.join(root, "kept.txt"), "Imp\n")
    File.write!(Path.join(root, "removed.txt"), "DS" <> "Ex\n")
    {_, 0} = System.cmd("git", ["init", "--quiet"], cd: root)
    {_, 0} = System.cmd("git", ["add", "kept.txt", "removed.txt"], cd: root)
    File.rm!(Path.join(root, "removed.txt"))

    assert {:ok, %{violations: [], tracked_paths: 1}} = Audit.audit(root)
  end
end
