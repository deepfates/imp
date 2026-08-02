defmodule Imp.BenchmarkTruth.GepaStudyConditionTest do
  use ExUnit.Case, async: true

  alias Imp.BenchmarkTruth.GepaStudyCondition

  defmodule NeverLM do
    defstruct []

    def generate(_messages, _opts), do: raise("provider call was not expected")
    def generate(_lm, _messages, _opts), do: raise("provider call was not expected")
  end

  @root "tmp/gepa-six-task-current-root"

  @tag :evidence_infrastructure
  test "constructs exact Heavy MIPRO and pinned no-merge GEPA treatments without providers" do
    lm = %NeverLM{}

    prepared =
      GepaStudyCondition.prepare!(@root, "AIMEBench", %{
        task: lm,
        reflection: lm,
        judge: lm
      })

    mipro = GepaStudyCondition.optimizer!(:mipro_v2_heavy, prepared, 17)
    assert mipro.config.auto == :heavy
    assert mipro.config.proposer_fidelity == :dspy_3_2_1
    assert mipro.config.search_fidelity == :dspy_3_2_1_optuna_4_9_0
    assert mipro.config.program_aware_proposer
    assert mipro.max_errors == 10_000

    gepa = GepaStudyCondition.optimizer!(:gepa_v0_1_4_no_merge, prepared, 17)
    assert gepa.execution_profile == :gepa_v0_1_4
    assert gepa.max_metric_calls == 1_839
    assert gepa.max_reflection_calls == 1_196
    assert gepa.minibatch_size == 3
    assert gepa.module_selector == :round_robin
    refute gepa.use_merge

    assert prepared.loaded.test_count == 150
    refute Map.has_key?(prepared.loaded, :test)
  end
end
