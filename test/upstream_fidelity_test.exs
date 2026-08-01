defmodule Imp.UpstreamFidelityTest do
  use ExUnit.Case, async: true

  test "ledger is pinned to an immutable stable DSPy baseline" do
    report = Imp.UpstreamFidelity.report()

    assert report.schema_version == 3
    assert report.baseline.version == "3.2.1"
    assert report.baseline.git_ref == "refs/tags/3.2.1"
    assert report.baseline.tag_object_sha == "27a8e2a134b0b8dbd2d7433ea67ffe9be627d376"
    assert report.baseline.git_sha == "29448ae12756abdd14bd8796c819247ebb83673c"

    assert report.baseline.api_manifest_sha256 ==
             "3e6243532fba8a8412850cb6b3f5c277c044c3f021c5626869db74665b1e933d"

    assert report.prerelease_tracking.version == "3.3.0b1"
    assert report.prerelease_tracking.git_sha == "b2829b7ae3b6e276ac6a8bef66a7ec519dbc923f"
    refute report.prerelease_tracking.release_blocking
  end

  test "status is derived from explicit contracts and executable evidence" do
    report = Imp.UpstreamFidelity.report()
    by_id = Map.new(report.surfaces, &{&1.id, &1})

    assert by_id["programming.contracts"].status == :conformant
    assert by_id["models.runtime"].status == :elixir_native_equivalent
    assert by_id["models.normalized_runtime_prerelease"].status == :tracking
    react = by_id["agents.react_family"]
    assert react.status == :elixir_native_equivalent
    assert react.rationale =~ "provider-native function calls"
    assert react.rationale =~ "reserved submit tool"
    assert react.rationale =~ "fails fast"

    weights = by_id["optimization.weights"]
    assert weights.status == :elixir_native_equivalent
    assert weights.disposition == :elixir_native_equivalent
    assert "Avatar" in weights.upstream
    assert "AvatarOptimizer" in weights.upstream
    assert Imp.Predict.Avatar in weights.imp
    assert Imp.Optimizer.Avatar in weights.imp

    assert Enum.any?(weights.invariants, &String.starts_with?(&1, "Avatar runs"))
    assert Enum.any?(weights.invariants, &String.starts_with?(&1, "AvatarOptimizer contrasts"))

    assert Enum.any?(
             weights.invariants,
             &String.starts_with?(&1, "BetterTogether composes arbitrary named and repeated")
           )

    assert Enum.any?(
             weights.invariants,
             &String.starts_with?(&1, "BetterTogether evaluates the baseline")
           )

    refute Enum.any?(weights.evidence.missing, &String.contains?(&1, "implementation"))
    refute Enum.any?(weights.evidence.missing, &String.contains?(&1, "sequencing"))
    refute Enum.any?(weights.evidence.missing, &String.contains?(&1, "candidate-selection"))

    assert MapSet.new(weights.evidence.missing) ==
             MapSet.new([
               "paid-provider weight-training execution evidence",
               "BetterTogether paid-provider lifecycle completion",
               "general or consistently useful model-sampled GRPO learning; the complete local multi-step TRL/MPS treatments changed trainable tensors and reproduced verified artifacts, but the retained source-disjoint outcomes were neutral or regressed on held-out data",
               "matched Avatar and AvatarOptimizer effectiveness",
               "matched BetterTogether and GRPO effectiveness"
             ])

    assert weights.evidence.artifacts == [
             "benchmarks/evidence/admitted/local_mlx/7016478544971aba539f522905ec40f41a29380a1b09291ef7cca91cb7d4567d.json"
           ]

    assert by_id["primitives.multimodal"].status == :gap
    few_shot = by_id["optimization.few_shot"]
    assert few_shot.status == :elixir_native_equivalent
    assert few_shot.disposition == :elixir_native_equivalent
    assert few_shot.rationale =~ "explicit serializable BEAM RNG"
    assert Enum.any?(few_shot.invariants, &String.starts_with?(&1, "LabeledFewShot defaults"))
    assert by_id["agents.rlm"].status == :elixir_native_equivalent
    assert by_id["optimization.instructions"].status == :gap
    refute by_id["optimization.instructions"].release_blocking
    gepa = by_id["optimization.gepa"]
    assert gepa.status == :gap
    refute gepa.release_blocking
    assert gepa.local_conformance == :structural
    assert gepa.evidence_rung == "C3"
    assert gepa.claim_boundary =~ "one matched three-seed held-out TREC result"
    refute Enum.any?(gepa.evidence.missing, &String.starts_with?(&1, "C3 "))
    refute Enum.any?(gepa.evidence.missing, &String.starts_with?(&1, "C5 "))
    assert by_id["product.learning_path"].status == :conformant
    assert by_id["product.release"].status == :tracking
    refute by_id["product.release"].release_blocking

    assert Enum.any?(
             by_id["product.release"].evidence.missing,
             &String.contains?(&1, "published")
           )

    assert by_id["optimization.anything"].status == :gap

    assert report.summary.invalid_evidence == 0
    assert report.summary.invalid_rows == 0
    assert report.summary.local_conformance == 1
    assert report.summary.manifest_missing == 0
    assert report.summary.manifest_duplicates == 0
    assert report.summary.gaps > 0
    assert report.summary.non_blocking_gaps == report.summary.gaps
    assert report.summary.release_blockers == 0
    assert report.summary.passing
    assert report.blocking_ids == []

    bootstrap = Enum.find(few_shot.capabilities, &(&1.surface == "BootstrapFewShot"))
    assert bootstrap.status == :valid

    assert Enum.any?(
             bootstrap.claims,
             &(&1.id == "claim.optimizer.bootstrap_few_shot.semantic_conformance")
           )
  end

  test "every stable surface has exactly one owning ledger row" do
    stable_rows = Enum.reject(Imp.UpstreamFidelity.surfaces(), &(&1.disposition == :tracking))
    manifest = Imp.UpstreamFidelity.stable_api_manifest()

    surfaces = Enum.flat_map(stable_rows, & &1.upstream)
    duplicates = surfaces -- Enum.uniq(surfaces)

    assert duplicates == []
    assert length(surfaces) >= 75
    assert length(manifest) == 71
    assert "Avatar" in manifest
    assert "AvatarOptimizer" in manifest
  end

  test "gap and native-equivalent rows carry accountable decisions" do
    for row <- Imp.UpstreamFidelity.surfaces() do
      assert row.invariants != []
      assert row.evidence.tests != []
      assert row.evidence.docs != []

      case row.disposition do
        :gap -> assert is_binary(row.ticket) and row.ticket != ""
        :elixir_native_equivalent -> assert is_binary(row.rationale) and row.rationale != ""
        _other -> :ok
      end
    end
  end

  test "missing executable evidence cannot remain conformant" do
    root =
      Path.join(
        System.tmp_dir!(),
        "imp-missing-conformance-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)

    report = Imp.UpstreamFidelity.report(root: root)

    assert report.summary.invalid_rows > 0
    refute report.summary.passing
    assert Enum.all?(report.surfaces, &(&1.status == :invalid_evidence))

    assert Enum.any?(
             hd(report.surfaces).evidence_errors,
             &String.starts_with?(&1, "missing evidence file:")
           )
  end

  test "source anchors include every research lineage named by the product" do
    anchors = Imp.UpstreamFidelity.report().source_anchors

    assert anchors.dspy_paper == "arXiv:2310.03714"
    assert anchors.dsp_paper == "arXiv:2212.14024"
    assert anchors.mipro_v2_paper == "arXiv:2406.11695"
    assert anchors.gepa_paper == "arXiv:2507.19457"
    assert anchors.rlm_paper == "arXiv:2512.24601"
    assert anchors.optimize_anything_paper == "arXiv:2605.19633"
    assert anchors.fast_slow_paper == "arXiv:2605.12484v2"
  end

  test "checked-in readable projection reflects every executable ledger verdict" do
    report = Imp.UpstreamFidelity.report()
    body = File.read!("docs/CONFORMANCE.md")

    assert body =~ report.baseline.git_sha

    for row <- report.surfaces do
      assert body =~ "| #{row.id} | #{row.category} | #{row.status} |"
      assert body =~ "### `#{row.id}`"
    end

    assert body =~
             "| optimization.weights | optimization | elixir_native_equivalent | satisfied |"

    assert body =~
             "| optimization.few_shot | optimization | elixir_native_equivalent | satisfied |"

    assert body =~ "| optimization.instructions | optimization | gap | claim-specific gap |"
    assert body =~ "| optimization.anything | optimization | gap | claim-specific gap |"

    assert body =~
             "schema-v2 multi-seed effectiveness across all three declared non-prompt artifact classes; one retry-policy class has passed its scoped criterion"

    assert body =~ "two later modeled-MIPRO Banking77 conditions"
    assert body =~ "three-seed JSON-GEPA HotPotQA treatment"
    assert body =~ "IFBench remains compatibility-regression evidence only"
    refute body =~ "paper tasks reproduce at meaningful scale"

    assert body =~
             "| optimization.fast_slow | optimization | elixir_native_equivalent | satisfied |"
  end
end
