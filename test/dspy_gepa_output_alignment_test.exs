defmodule Imp.DspyGepaOutputAlignmentTest do
  use ExUnit.Case, async: true

  @python "tmp/dspy-parity-venv/bin/python"
  @dspy "tmp/dspy-3.2.1"
  @gepa "tmp/gepa-v0.1.4"

  test "pinned DSPy trace evaluation drops deterministic failures before GEPA merges IDs" do
    unless Enum.all?([@python, @dspy, @gepa], &File.exists?/1) do
      flunk("pinned DSPy/GEPA sources are required; run scripts/setup_dspy_parity_env.sh")
    end

    {output, 0} =
      System.cmd(
        Path.expand(@python),
        [
          "scripts/dspy_gepa_output_alignment.py",
          "--dspy-root",
          @dspy,
          "--gepa-root",
          @gepa
        ],
        stderr_to_stdout: true
      )

    assert output =~ ~s("engine_error": "IndexError: list index out of range")
    assert output =~ ~s("example_indices": [)
    assert output =~ ~s("dropped_failure_kinds": [)
    assert output =~ ~s("parse_partial")
    assert output =~ ~s("metric_failure")
    assert output =~ ~s("outputs": 2)
  end
end
