defmodule Imp.DspyGepaTraceSemanticsTest do
  use ExUnit.Case, async: true

  test "source-shaped DSPy repair preserves success bytes and ordered failed slots" do
    python = Path.expand("tmp/dspy-parity-venv/bin/python")

    unless Enum.all?(
             [python, "tmp/dspy-3.2.1", "tmp/gepa-v0.1.4"],
             &File.exists?/1
           ) do
      flunk("pinned DSPy/GEPA sources are required; run scripts/setup_dspy_parity_env.sh")
    end

    {output, 0} =
      System.cmd(
        python,
        [
          "scripts/dspy_gepa_trace_semantics.py",
          "--dspy-root",
          "tmp/dspy-3.2.1",
          "--gepa-root",
          "tmp/gepa-v0.1.4"
        ],
        stderr_to_stdout: true
      )

    assert output =~ ~s("byte_identical": true)
    assert output =~ ~s("rendered_messages_byte_identical": true)
    assert output =~ ~s("trajectory_indices": [)
    assert output =~ ~s("reflection_parse_failures": 2)
    assert output =~ ~s("default_reflection_parse_failures": 0)
    assert output =~ ~s("adapted_program_required_to_reproduce": false)

    assert output =~
             ~s("program_or_metric_failure_reflection": "diagnostic only; no invented feedback")
  end
end
