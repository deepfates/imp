defmodule Imp.CurrentDSPyStateBoundaryTest do
  use ExUnit.Case, async: false

  alias Imp.Optimizer.Artifact

  @moduletag :evidence_infrastructure

  test "current DSPy and Imp expose different honest portable-state contracts" do
    root = File.cwd!()
    python = Path.join(root, "tmp/dspy-current-venv/bin/python")
    target = Path.join(root, "tmp/dspy-current-target")

    unless File.exists?(python) and File.dir?(target) do
      flunk(
        "install the source-verified DSPy 3.3.0b1 target and venv documented in docs/internal/BENCHMARK_TRUTH.md"
      )
    end

    {stdout, 0} =
      System.cmd(python, ["scripts/current_dspy_state_boundary.py", "--dspy-target", target],
        env: [{"PYTHONPATH", ""}]
      )

    dspy = Jason.decode!(stdout)

    assert dspy["dspy_version"] == "3.3.0b1"

    assert dspy["scope"] == %{
             "provider_calls" => 0,
             "serving_framework_exercised" => false,
             "supervision_compared" => false
           }

    assert dspy["state_json"] == %{
             "api_key_absent" => true,
             "creation_umask" => "0022",
             "endpoint_config_present" => true,
             "fresh_process_instruction" => "selected instruction",
             "integrity_field_present" => false,
             "invalid_state_rejected_transactionally" => true,
             "mode" => "0644",
             "operator_edit_accepted" => true,
             "owner_private_by_default" => false,
             "unsafe_endpoint_removed_on_default_load" => true
           }

    assert dspy["whole_program"] == %{
             "format" => "cloudpickle",
             "untrusted_load_requires_explicit_opt_in" => true
           }

    path =
      Path.join(
        System.tmp_dir!(),
        "imp-current-dspy-state-boundary-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(path) end)

    program = Imp.predict("question -> answer")
    candidate = Artifact.parameter_candidate("selected", program, score: 1.0)
    artifact = Artifact.new(candidate, [], provenance: %{comparison: "dspy-3.3.0b1"})

    assert :ok = Artifact.write!(artifact, path)
    assert {:ok, %{mode: 0o100600}} = File.stat(path)
    assert Artifact.read!(path) == artifact

    tampered = put_in(artifact, ["payload", "provenance", "comparison"], "operator-edited")
    File.write!(path, Jason.encode!(tampered))

    assert_raise ArgumentError, ~r/checksum mismatch/, fn ->
      Artifact.read!(path)
    end
  end
end
