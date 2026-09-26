defmodule ImpTest.CaseStudyTRECRecomputationTest do
  @moduledoc """
  The README calls TREC the strongest matched result and research/CASE_STUDY_TREC.md
  publishes an exact command for recomputing it. The epic requires that an
  independent consumer can recompute the strongest claims without maintainer
  machinery — so that command working is itself a release-blocking property.

  It silently stopped working for two days: a shared, mutable dependency lock
  was edited in place for a different campaign, invalidating this contract's
  seal. Nothing caught it because nothing ran it. This does.

  Provider-free and fast: it re-aggregates the committed scored rows, makes no
  network calls, and starts no models.
  """
  use ExUnit.Case, async: true

  import ExUnit.Callbacks, only: [on_exit: 1]

  @root Path.expand("..", __DIR__)
  @expected [
    "GEPA over its own baseline: +0.4000 95% CI [0.2958, 0.5042], Holm-adjusted p = 0.00020",
    "MIPROv2 over its own baseline: +0.1458 95% CI [0.0458, 0.2458], Holm-adjusted p = 0.00270",
    "GEPA Imp minus DSPy: -0.0083 95% CI [-0.0458, 0.0292]"
  ]

  @doc_path "research/CASE_STUDY_TREC.md"
  @script "research/matched_instruction_optimizers_trec/recompute_compact.exs"
  @contract "research/matched_instruction_optimizers_trec/contract.json"
  @imp_rows "research/matched_instruction_optimizers_trec/data/imp-scored-rows.json"
  @upstream_rows "research/matched_instruction_optimizers_trec/data/upstream-scored-rows.json"
  @aggregate "research/matched_instruction_optimizers_trec/data/aggregate-recomputed.json"

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

    for line <- @expected do
      assert String.contains?(output, line), "recomputation output drifted:\n#{output}"
    end

    assert String.contains?(
             output,
             "Recomputation agrees with aggregate-recomputed.json in full."
           ),
           "recomputation no longer reports agreement:\n#{output}"
  end

  test "the recomputation reports a mismatch and fails instead of printing a stored answer" do
    tampered =
      Path.join(
        System.tmp_dir!(),
        "trec-aggregate-tampered-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(tampered) end)

    aggregate =
      @root
      |> Path.join(@aggregate)
      |> File.read!()
      |> Jason.decode!()

    File.write!(
      tampered,
      aggregate
      |> put_in(["acceptance", "improvements", "gepa", "mean"], 0.5)
      |> Jason.encode!()
    )

    {output, status} =
      System.cmd(
        "mix",
        ["run", "--no-start", @script, "--", @contract, @imp_rows, @upstream_rows, tampered],
        cd: @root,
        stderr_to_stdout: true,
        env: [{"MIX_ENV", "test"}]
      )

    assert status != 0, "a tampered aggregate did not fail the recomputation:\n#{output}"
    assert String.contains?(output, "MISMATCH")

    assert String.contains?(output, "GEPA over its own baseline: +0.4000"),
           "the recomputed value was not printed, so the command is not recomputing:\n#{output}"
  end

  test "the case study still documents exactly the line the command prints" do
    doc = File.read!(Path.join(@root, @doc_path))

    for line <- @expected do
      assert String.contains?(doc, line),
             "#{@doc_path} no longer documents a line the recomputation prints; " <>
               "docs and evidence have drifted apart"
    end

    assert String.contains?(doc, "recomputable, not reproducible"),
           "#{@doc_path} no longer states that the result cannot be reproduced"

    for path <- [@script, @contract, @imp_rows, @upstream_rows, @aggregate] do
      assert String.contains?(doc, Path.basename(path)),
             "#{@doc_path} no longer references #{Path.basename(path)}"
    end
  end
end
