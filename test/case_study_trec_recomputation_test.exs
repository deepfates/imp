defmodule ImpTest.CaseStudyTRECRecomputationTest do
  @moduledoc """
  The README calls TREC the strongest matched result and docs/CASE_STUDY_TREC.md
  publishes an exact command for recomputing it. The epic requires that an
  independent consumer can recompute the strongest claims without maintainer
  machinery — so that command working is itself a release-blocking property.

  It silently stopped working for two days (imp-x83e): a shared, mutable
  dependency lock was edited in place for a different campaign, invalidating
  this contract's seal. Nothing caught it because nothing ran it. This does.

  Provider-free and fast: it re-aggregates archived scored rows, makes no
  network calls, and starts no models.
  """
  use ExUnit.Case, async: true

  @root Path.expand("..", __DIR__)
  @expected "matched TREC compact recomputation passed: GEPA +0.4000, MIPROv2 +0.1458, GEPA Imp-minus-DSPy -0.0083"

  @doc_path "docs/CASE_STUDY_TREC.md"
  @script "examples/matched_instruction_optimizers_trec/recompute_compact.exs"
  @contract "examples/matched_instruction_optimizers_trec/contract.json"
  @imp_rows "benchmarks/evidence/archive/matched_experiments/trec/imp-scored-rows.json"
  @upstream_rows "benchmarks/evidence/archive/matched_experiments/trec/upstream-scored-rows.json"
  @aggregate "benchmarks/evidence/archive/matched_experiments/trec/aggregate-recomputed.json"

  test "the published TREC recomputation command still reproduces the documented result" do
    {output, status} =
      System.cmd(
        "mix",
        ["run", "--no-start", @script, "--", @contract, @imp_rows, @upstream_rows, @aggregate],
        cd: @root,
        stderr_to_stdout: true,
        env: [{"MIX_ENV", "test"}]
      )

    assert status == 0, "published recomputation command failed:\n#{output}"
    assert String.contains?(output, @expected), "recomputation output drifted:\n#{output}"
  end

  test "the case study still documents exactly the line the command prints" do
    doc = File.read!(Path.join(@root, @doc_path))

    assert String.contains?(doc, @expected),
           "#{@doc_path} no longer documents the line the recomputation prints; " <>
             "docs and evidence have drifted apart"

    for path <- [@script, @contract, @imp_rows, @upstream_rows, @aggregate] do
      assert String.contains?(doc, Path.basename(path)),
             "#{@doc_path} no longer references #{Path.basename(path)}"
    end
  end
end
