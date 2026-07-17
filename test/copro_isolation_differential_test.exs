defmodule Imp.Optimizer.COPROIsolationDifferentialTest do
  use ExUnit.Case, async: false

  @moduletag :evidence_infrastructure

  @setup """
  git clone https://github.com/stanfordnlp/dspy.git tmp/dspy-3.2.1
  git -C tmp/dspy-3.2.1 checkout --detach 29448ae12756abdd14bd8796c819247ebb83673c
  IMP_DSPY_VENV=tmp/dspy-parity-venv scripts/setup_dspy_parity_env.sh
  """

  @tag timeout: 120_000
  test "pinned provider-free COPRO differential binds isolated C1 evidence" do
    python = Path.expand("tmp/dspy-parity-venv/bin/python")
    target = Path.expand("tmp/dspy-3.2.1")

    unless File.exists?(python) and File.dir?(Path.join(target, ".git")) do
      flunk("pinned DSPy 3.2.1 fixture environment is missing. Exact setup:\n#{@setup}")
    end

    {output, 0} =
      System.cmd(
        python,
        [
          "scripts/dspy_copro_isolation_differential.py",
          "--config",
          "test/fixtures/dspy_copro_isolation_differential.json"
        ],
        cd: File.cwd!(),
        env: [
          {"PYTHONPATH", target},
          {"OPENAI_API_KEY", "dummy-copro-canary-never-use"},
          {"AWS_SESSION_TOKEN", "dummy-copro-cloud-canary-never-use"},
          {"API_KEY", "dummy-copro-generic-canary-never-use"},
          {"TOKEN", "dummy-copro-generic-token-never-use"}
        ],
        stderr_to_stdout: true
      )

    artifact = Jason.decode!(output)

    fixture =
      "test/fixtures/dspy_copro_isolation_differential.json" |> File.read!() |> Jason.decode!()

    assert artifact["status"] == "passing"
    assert artifact["fixture_id"] == fixture["fixture_id"]
    assert artifact["source"] == fixture["source"]
    assert artifact["runtime_identity"]["distribution_version"] == "3.2.1"
    assert artifact["runtime_identity"]["module_version"] == "3.2.0"

    assert artifact["runtime_identity"]["git_commit"] ==
             "29448ae12756abdd14bd8796c819247ebb83673c"

    assert artifact["runtime_identity"]["git_clean"]
    assert artifact["runtime_identity"]["authority_manifest_verified_files"] == 296
    assert artifact["credential_environment"]["provider_credential_names_present"] == []
    assert artifact["isolation"]["isolated_process"]
    refute artifact["isolation"]["poison_marker_seen"]
    assert artifact["observations"]["proposal_n"] == [3]
    assert artifact["observations"]["proposal_order"] == fixture["copro"]["proposal_order"]

    history_order =
      for call <- artifact["observations"]["proposal_call_history"],
          response <- call["responses"] do
        Map.take(response, ["instruction", "prefix"])
      end

    assert artifact["observations"]["proposal_call_history"]
           |> List.first()
           |> Map.take(["requested_n", "response_choice_count"]) == %{
             "requested_n" => 3,
             "response_choice_count" => 3
           }

    assert artifact["observations"]["proposal_order"] == history_order
    assert artifact["observations"]["evaluation_order"] == fixture["copro"]["evaluation_order"]

    assert artifact["observations"]["candidate_program_count"] ==
             fixture["copro"]["candidate_program_count"]

    assert artifact["observations"]["total_calls"] == fixture["copro"]["total_calls"]
    assert "exact Python RNG parity" in artifact["scope"]["not_claimed"]
    assert "provider behavior or effectiveness" in artifact["scope"]["not_claimed"]
    assert "full optimizer parity" in artifact["scope"]["not_claimed"]

    assert "COPRO directly removes an equal-score duplicate candidate" in artifact["scope"][
             "claims"
           ]

    assert "The pinned COPRO source's greater-than-or-equal score guard retains the first record for an identical instruction/prefix duplicate" in artifact[
             "scope"
           ]["source_supported"]
  end
end
