defmodule Imp.DspyGepaTraceSemanticsTest do
  use ExUnit.Case, async: true

  # Requires the pinned DSPy parity environment (scripts/setup_dspy_parity_env.sh
  # + setup_dspy_stable_source.sh) and/or example-project deps; runs in the CI
  # differential lane, not fast.check.
  @moduletag :dspy_parity

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
    assert output =~ ~s("reflection_byte_identical": true)
    assert output =~ ~s("reflection_opportunities": 2)
    assert output =~ ~s("trajectory_indices": [)
    assert output =~ ~s("all_failure_orderings_checked": 120)
    assert output =~ ~s("reflection_parse_failures": 2)
    assert output =~ ~s("default_reflection_parse_failures": 0)
    assert output =~ ~s("adapted_program_required_to_reproduce": false)
    assert output =~ ~s("scoped_adapter_installed": true)
    assert output =~ ~s("scoped_adapter_restored": true)
    assert output =~ ~s("public_compile_constructed_fixed_adapter": true)
    assert output =~ ~s("public_compile_success_opportunity_identical": true)
    assert output =~ ~s("metric_calls": 18)
    assert output =~ ~s("message_calls": 18)

    assert output =~
             ~s("program_or_metric_failure_reflection": "diagnostic only; no invented feedback")
  end
end
