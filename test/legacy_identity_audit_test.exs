defmodule LegacyIdentityAuditTest do
  use ExUnit.Case, async: true

  alias Imp.LegacyIdentityAudit, as: Audit

  test "all tracked identity matches are explicitly classified" do
    assert {:ok, report} = Audit.audit()
    assert report.findings != []
    assert report.violations == []
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
end
