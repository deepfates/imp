defmodule Imp.BenchmarkTruth.GepaStudyCondition do
  @moduledoc false

  alias Imp.BenchmarkTruth.GepaSuite
  alias Imp.Optimizer.{Artifact, GEPA, MIPROv2}

  @doc "Prepares one official family without opening its held-out rows."
  def prepare!(dataset_root, family, lms, opts \\ []) do
    loaded = GepaSuite.load!(dataset_root, family)
    task_lm = fetch_lm!(lms, :task)
    judge_lm = Map.get(lms, :judge, task_lm)
    execution = Keyword.get(opts, :execution, %{})
    max_concurrency = Keyword.get(opts, :max_concurrency, 1)

    unless is_integer(max_concurrency) and max_concurrency > 0 do
      raise ArgumentError, "GEPA study max_concurrency must be a positive integer"
    end

    metric_opts = Keyword.get(opts, :metric_opts, []) |> Keyword.put_new(:judge_lm, judge_lm)
    program = GepaSuite.program!(loaded.spec, task_lm, execution)
    metric = GepaSuite.metric!(loaded.spec, metric_opts)
    gepa_metric = GepaSuite.gepa_metric!(loaded.spec, metric_opts)
    feedback_metric = GepaSuite.feedback_metric!(loaded.spec, metric_opts)

    %{
      loaded: loaded,
      program: program,
      metric: metric,
      gepa_metric: gepa_metric,
      feedback_metric: feedback_metric,
      component_feedback:
        GepaSuite.component_feedback!(loaded.spec, program, feedback_metric, gepa_metric),
      lms: %{task: task_lm, reflection: fetch_lm!(lms, :reflection), judge: judge_lm},
      outer_max_concurrency: max_concurrency,
      program_grounding: program_grounding(loaded.spec, program)
    }
  end

  @doc "Builds the exact Imp optimizer treatment for one declared arm."
  def optimizer!(:baseline, _prepared, _seed), do: nil

  def optimizer!(:mipro_v2_heavy, prepared, seed) do
    MIPROv2.new(prepared.metric,
      auto: :heavy,
      prompt_lm: prepared.lms.reflection,
      task_lm: prepared.lms.task,
      max_errors: 10_000,
      max_concurrency: prepared.outer_max_concurrency,
      seed: seed,
      proposer_fidelity: :dspy_3_2_1,
      search_fidelity: :dspy_3_2_1_optuna_4_9_0,
      program_aware_proposer: true,
      data_aware_proposer: true,
      tip_aware_proposer: true,
      fewshot_aware_proposer: true,
      program_grounding: {:text, prepared.program_grounding}
    )
  end

  def optimizer!(:gepa_v0_1_4_merge, prepared, seed) do
    spec = prepared.loaded.spec
    dev_size = get_in(spec, ["split_counts", "dev"])
    semantic_metric_calls = Map.fetch!(spec, "metric_calls")
    envelope = GEPA.v014_budget_envelope(dev_size, 3, semantic_metric_calls)

    GEPA.new(prepared.gepa_metric,
      execution_profile: :gepa_v0_1_4_merge,
      reflection_lm: prepared.lms.reflection,
      component_feedback: prepared.component_feedback,
      minibatch_size: 3,
      module_selector: :round_robin,
      use_merge: true,
      seed: seed,
      max_concurrency: prepared.outer_max_concurrency,
      max_metric_calls: semantic_metric_calls,
      max_reflection_calls: envelope.max_reflection_calls,
      raise_on_exception: false
    )
  end

  def optimizer!(arm, _prepared, _seed) do
    raise ArgumentError, "unknown matched GEPA study arm: #{inspect(arm)}"
  end

  @doc "Runs optimization only; held-out rows remain unopened until this returns."
  def optimize!(arm, prepared, seed, opts \\ [])

  def optimize!(:baseline, prepared, _seed, _opts),
    do: %{selected: prepared.program, artifact: nil, report: nil}

  def optimize!(:mipro_v2_heavy, prepared, seed, opts) do
    selected =
      prepared
      |> optimizer!(:mipro_v2_heavy, seed)
      |> MIPROv2.compile(prepared.program, prepared.loaded.train, prepared.loaded.dev)

    %{
      selected: selected,
      report: Imp.Optimizer.Report.fetch(selected),
      artifact:
        Artifact.from_optimized_program(selected,
          artifact_id: artifact_id(prepared.loaded.spec, :mipro_v2_heavy, seed),
          provenance: provenance(prepared.loaded.spec, :mipro_v2_heavy, seed, opts)
        )
    }
  end

  def optimize!(:gepa_v0_1_4_merge, prepared, seed, opts) do
    {selected, report, artifact} =
      prepared
      |> optimizer!(:gepa_v0_1_4_merge, seed)
      |> GEPA.compile_with_artifact(
        prepared.program,
        prepared.loaded.train,
        prepared.loaded.dev,
        artifact_id: artifact_id(prepared.loaded.spec, :gepa_v0_1_4_merge, seed),
        provenance: provenance(prepared.loaded.spec, :gepa_v0_1_4_merge, seed, opts)
      )

    %{selected: selected, report: report, artifact: artifact}
  end

  @doc "Scores a program on an already materialized split through Imp.Evaluate."
  def evaluate!(program, rows, metric, opts \\ []) do
    Imp.Evaluate.run(
      Imp.Evaluate.new(rows, metric,
        max_errors: Keyword.get(opts, :max_errors, 10_000),
        max_concurrency: Keyword.get(opts, :max_concurrency, 1),
        timeout: Keyword.get(opts, :timeout, :infinity)
      ),
      program
    )
  end

  @doc "Opens held-out rows only after optimization and evaluates exactly the declared arm."
  def heldout!(arm, prepared, optimized, opts \\ []) do
    test = GepaSuite.load_test!(prepared.loaded)
    program = if arm == :baseline, do: prepared.program, else: optimized.selected
    opts = Keyword.put_new(opts, :max_concurrency, prepared.outer_max_concurrency)

    %{
      arm: arm,
      result: evaluate!(program, test, prepared.metric, opts),
      test_count: length(test)
    }
  end

  defp program_grounding(spec, program) do
    predictors =
      program
      |> Imp.ProgramParameters.predictors()
      |> Enum.map_join("\n", fn %{name: name, predictor: predictor} ->
        inputs = Enum.map_join(predictor.signature.inputs, ", ", &to_string(&1.name))
        outputs = Enum.map_join(predictor.signature.outputs, ", ", &to_string(&1.name))
        "#{name}: Predict(#{inputs}) -> #{outputs}"
      end)

    "Official #{spec["family"]} #{spec["program"]} program\n" <> predictors
  end

  defp provenance(spec, arm, seed, opts) do
    base = %{
      study: "matched-current-model-gepa-suite-v1",
      family: spec["family"],
      arm: Atom.to_string(arm),
      seed: seed,
      source: spec["source"] || spec["source_commit"],
      split_checksums: spec["split_checksums"] || spec["checksums"]
    }

    case Keyword.get(opts, :matched_baseline) do
      nil -> base
      receipt when is_map(receipt) -> Map.put(base, :matched_baseline, receipt)
      other -> raise ArgumentError, "matched_baseline must be a map, got: #{inspect(other)}"
    end
  end

  defp artifact_id(spec, arm, seed),
    do: "gepa-suite-#{spec["family"]}-#{arm}-seed-#{seed}"

  defp fetch_lm!(lms, role) when is_map(lms) do
    Map.fetch!(lms, role)
  rescue
    KeyError -> raise ArgumentError, "GEPA study requires #{role} LM"
  end
end
