defmodule DSEx.IdentityCollisionTest do
  use ExUnit.Case, async: true

  alias DSEx.IdentityCollision

  @checked_at "2026-07-13T21:00:00Z"

  test "constructs exact registry URLs and escapes a package path segment" do
    assert IdentityCollision.url_for("hex", "form_lab") ==
             "https://hex.pm/api/packages/form_lab"

    assert IdentityCollision.url_for("npm", "@scope/name") ==
             "https://registry.npmjs.org/%40scope%2Fname"

    assert IdentityCollision.url_for("pypi", "form lab") ==
             "https://pypi.org/pypi/form%20lab/json"

    assert IdentityCollision.url_for("crates", "form_lab") ==
             "https://crates.io/api/v1/crates/form_lab"
  end

  test "classifies exact registry responses without treating failures as availability" do
    collision =
      IdentityCollision.classify(
        "hex",
        "form_lab",
        {:ok, %{status: 200, headers: [{"etag", "abc"}], body: ~s({"name":"form_lab"})}}
      )

    assert collision["status"] == "collision"
    assert collision["claim_basis"] == "observed"
    assert collision["http_status"] == 200
    assert collision["response_metadata"]["etag"] == "abc"

    missing = IdentityCollision.classify("npm", "form_lab", {:ok, %{status: 404}})
    assert missing["status"] == "no-exact-record"
    assert missing["claim_basis"] == "observed"
    assert String.contains?(missing["summary"], "not an availability")

    limited = IdentityCollision.classify("pypi", "form_lab", {:ok, %{status: 429}})
    assert limited["status"] == "rate-limited"
    assert limited["claim_basis"] == "unverified"

    failed = IdentityCollision.classify("crates", "form_lab", {:error, :timeout})
    assert failed["status"] == "unverified"
    assert failed["http_status"] == nil
    refute String.contains?(failed["summary"], "available")
  end

  test "emits an explicit skipped observation for an unusable code form" do
    fetcher = fn _request -> flunk("a skipped code form must not issue a request") end

    result =
      IdentityCollision.run([enrichment("cand-0000000000000001", nil)], [], [],
        sources: ["hex", "npm"],
        checked_at: @checked_at,
        delay_ms: 0,
        fetcher: fetcher
      )

    assert length(result.checks) == 2
    assert Enum.all?(result.checks, &(&1["status"] == "skipped"))
    assert Enum.all?(result.checks, &(&1["query"] == nil))
    assert result.stats.network_attempts == 0
    assert result.flags == []
  end

  test "resume is idempotent and does not repeat a completed source-query check" do
    fetcher = fn _request -> {:ok, %{status: 404, headers: [], body: "missing"}} end

    first =
      IdentityCollision.run([enrichment("cand-0000000000000001", "form_lab")], [], [],
        sources: ["hex"],
        checked_at: @checked_at,
        delay_ms: 0,
        fetcher: fetcher
      )

    second =
      IdentityCollision.run(
        [enrichment("cand-0000000000000001", "form_lab")],
        first.checks,
        first.flags,
        sources: ["hex"],
        checked_at: "2026-07-13T22:00:00Z",
        delay_ms: 0,
        fetcher: fn _request -> flunk("resume must not repeat the HTTP check") end
      )

    assert second.checks == first.checks
    assert second.flags == first.flags
    assert second.stats.new_checks == 0
    assert second.stats.resumed_checks == 1
    assert second.stats.network_attempts == 0
  end

  test "refresh appends a new attempt under the same logical check key" do
    first =
      IdentityCollision.run([enrichment("cand-0000000000000001", "form_lab")], [], [],
        sources: ["hex"],
        checked_at: @checked_at,
        delay_ms: 0,
        fetcher: fn _request -> {:ok, %{status: 404}} end
      )

    refreshed =
      IdentityCollision.run(
        [enrichment("cand-0000000000000001", "form_lab")],
        first.checks,
        first.flags,
        sources: ["hex"],
        checked_at: "2026-07-13T22:00:00Z",
        delay_ms: 0,
        refresh: true,
        fetcher: fn _request -> {:ok, %{status: 200, body: "{}"}} end
      )

    assert [old, new] = refreshed.checks
    assert old["check_key"] == new["check_key"]
    assert old["id"] != new["id"]
    assert old["attempt"] == 1
    assert new["attempt"] == 2
    assert new["status"] == "collision"
    assert refreshed.stats.new_checks == 1
    assert length(refreshed.flags) == 1
  end

  test "fixed inputs produce deterministic checks and flags" do
    opts = [
      sources: ["hex"],
      checked_at: @checked_at,
      delay_ms: 0,
      fetcher: fn _request -> {:ok, %{status: 200, headers: [], body: "{}"}} end
    ]

    left = IdentityCollision.run([enrichment("cand-0000000000000001", "form_lab")], [], [], opts)
    right = IdentityCollision.run([enrichment("cand-0000000000000001", "form_lab")], [], [], opts)

    assert left.checks == right.checks
    assert left.flags == right.flags
  end

  test "registry requests identify the audit and ask for JSON" do
    fetcher = fn request ->
      assert {"accept", "application/json"} in request.headers
      assert {"user-agent", user_agent} = List.keyfind(request.headers, "user-agent", 0)
      assert String.contains?(user_agent, "Identity-Collision-Audit")
      {:ok, %{status: 404}}
    end

    IdentityCollision.run([enrichment("cand-0000000000000001", "form_lab")], [], [],
      sources: ["hex"],
      checked_at: @checked_at,
      delay_ms: 0,
      fetcher: fetcher
    )
  end

  test "collision flags match the identity flag schema shape" do
    result =
      IdentityCollision.run([enrichment("cand-0000000000000001", "form_lab")], [], [],
        sources: ["npm"],
        checked_at: @checked_at,
        delay_ms: 0,
        fetcher: fn _request -> {:ok, %{status: 200}} end
      )

    assert [flag] = result.flags
    assert Regex.match?(~r/^flag-[a-z0-9][a-z0-9-]*$/, flag["id"])
    assert flag["candidate_id"] == "cand-0000000000000001"
    assert flag["flagged_at"] == @checked_at

    assert flag["assessor"] == %{
             "kind" => "research",
             "name" => "npm exact package registry check"
           }

    assert flag["kind"] == "package-collision"
    assert flag["severity"] == "high"
    assert flag["status"] == "observed"
    assert flag["scope"] == "registry:npm:package:form_lab"
    assert flag["confidence"] == 1.0
    assert flag["evidence_refs"] == [hd(result.checks)["id"]]
    assert flag["supersedes"] == nil
  end

  test "bounded Retry-After handling retries once and records both attempts" do
    test_pid = self()

    fetcher = fn request ->
      send(test_pid, {:request, request.attempt})

      if request.attempt == 1 do
        {:ok, %{status: 429, headers: [{"Retry-After", "0"}]}}
      else
        {:ok, %{status: 404}}
      end
    end

    result =
      IdentityCollision.run([enrichment("cand-0000000000000001", "form_lab")], [], [],
        sources: ["hex"],
        checked_at: @checked_at,
        delay_ms: 0,
        fetcher: fetcher,
        sleep: fn milliseconds -> send(test_pid, {:sleep, milliseconds}) end
      )

    assert_receive {:request, 1}
    assert_receive {:sleep, 0}
    assert_receive {:request, 2}
    assert result.stats.network_attempts == 2
    assert hd(result.checks)["status"] == "no-exact-record"
    assert hd(result.checks)["response_metadata"]["prior_http_statuses"] == [429]
  end

  test "file execution merges existing unrelated flags without duplicate IDs" do
    root =
      Path.join(
        System.tmp_dir!(),
        "dsex-identity-collision-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(root) end)
    File.mkdir_p!(root)

    enrichments_path = Path.join(root, "enrichments.jsonl")
    checks_path = Path.join(root, "checks.jsonl")
    flags_path = Path.join(root, "flags.jsonl")

    unrelated_flag = %{"id" => "flag-unrelated", "candidate_id" => "cand-0000000000000001"}

    File.write!(
      enrichments_path,
      IdentityCollision.render_jsonl([enrichment("cand-0000000000000001", "form_lab")])
    )

    File.write!(flags_path, IdentityCollision.render_jsonl([unrelated_flag, unrelated_flag]))

    result =
      IdentityCollision.run_files!(
        enrichments: enrichments_path,
        checks_out: checks_path,
        flags_out: flags_path,
        sources: ["hex"],
        checked_at: @checked_at,
        delay_ms: 0,
        fetcher: fn _request -> {:ok, %{status: 200}} end
      )

    assert Enum.count(result.flags, &(&1["id"] == "flag-unrelated")) == 1
    assert length(result.flags) == 2
    assert File.exists?(checks_path)
    assert File.exists?(flags_path)
  end

  defp enrichment(candidate_id, hex_package) do
    %{
      "candidate_id" => candidate_id,
      "code_forms" => %{"hex_package" => hex_package}
    }
  end
end
