defmodule DocumentationContractTest do
  use ExUnit.Case, async: true

  test "coverage matrix describes current evidence instead of closed planning tickets" do
    body = File.read!("docs/COVERAGE_MATRIX.md")

    refute_closed_ticket_refs(body)
    refute body =~ "integration gate should"
    refute body =~ "integration gate required"
    refute body =~ "integration gate needed"

    assert body =~ "mix integration.check"
    assert body =~ "mix protocol.training.check"
    assert body =~ "mix protocol.check"
  end

  test "release criteria are expressed as current product evidence, not historical tickets" do
    body = File.read!("docs/RELEASE_CRITERIA.md")

    refute_closed_ticket_refs(body)
    refute body =~ "The production release scope is tracked under ticket"

    assert body =~ ~r/Historical planning tickets are not release\s+criteria/
    assert body =~ "mix production.check"
    assert body =~ "mix benchmark.dashboard.full"
  end

  defp refute_closed_ticket_refs(body) do
    refute body =~ "de-wrnz"
    refute body =~ "de-i8cc"
    refute body =~ "de-qvwf"
    refute body =~ "de-i4o5"
  end
end
