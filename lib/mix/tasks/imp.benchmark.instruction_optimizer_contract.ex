defmodule Mix.Tasks.Imp.Benchmark.InstructionOptimizerContract do
  @moduledoc """
  Run provider-free MIPROv2 and SIMBA contracts against pinned DSPy 3.3.0b1.

  The artifact covers structural control-flow semantics only. It records native
  RNG and sampler differences explicitly and does not claim optimizer lift or
  paper-protocol reproduction.
  """

  use Mix.Task

  alias Imp.Optimizer.{
    BootstrapFewShot,
    DemoCandidates,
    InstructionProposer,
    MIPROv2,
    Report,
    SIMBA
  }

  alias Imp.Optimizer.MIPROv2.Config
  alias Imp.Optimizer.SIMBA.Buckets

  @shortdoc "Run matched Imp/DSPy instruction-optimizer contracts"
  @default_out "tmp/instruction-optimizer-contract"
  @bootstrap_fixture_id "bootstrap-repeated-predictor-calls-v3"
  @bootstrap_imp_algorithm %{
    "observed_via" => "BootstrapFewShot.compile/4 compiled predictor and optimizer report",
    "digest" => "sha256",
    "payload" => "erlang_term_trajectory_index_predictor_name_demos",
    "branch_byte_index" => 0,
    "branch_modulus" => 2,
    "earlier_remainder" => 0,
    "earlier_index_byte_index" => 1,
    "probability_basis" => "uniform_sha256_branch_byte_parity",
    "branch_probability_model" => %{"earlier" => 0.5, "final" => 0.5}
  }
  @bootstrap_imp_outcomes %{
    "trace_set_0" => %{
      "sha256" => "34fbc63abc20a7432db52aaffc7cb536ac6a3dc1ba1a855eb8e8e907b5047ae6",
      "branch_byte" => 52,
      "earlier_index_byte" => 251,
      "branch" => "earlier",
      "selected_index" => 2,
      "selected_call_id" => "call_2",
      "compiled_demo_count" => 1,
      "compiled_selected_index" => 2,
      "compiled_selected_call_id" => "call_2",
      "report_selection_count" => 1,
      "report_selection_matches_compiled_demo" => true,
      "trajectory_index" => 0,
      "predictor_name" => "answerer",
      "call_count" => 4
    },
    "trace_set_2" => %{
      "sha256" => "a35edd6a69fe99b9fbd548a8bd34bf8f8bbeb413b0f75b1ba0698ff98a56c64b",
      "branch_byte" => 163,
      "earlier_index_byte" => 94,
      "branch" => "final",
      "selected_index" => 3,
      "selected_call_id" => "call_3",
      "compiled_demo_count" => 1,
      "compiled_selected_index" => 3,
      "compiled_selected_call_id" => "call_3",
      "report_selection_count" => 1,
      "report_selection_matches_compiled_demo" => true,
      "trajectory_index" => 0,
      "predictor_name" => "answerer",
      "call_count" => 4
    },
    "trace_set_3" => %{
      "sha256" => "45162346f6f28da72c8d47fface2bd87d060c8c76bad5bb948c34da5e7fa4c1b",
      "branch_byte" => 69,
      "earlier_index_byte" => 22,
      "branch" => "final",
      "selected_index" => 3,
      "selected_call_id" => "call_3",
      "compiled_demo_count" => 1,
      "compiled_selected_index" => 3,
      "compiled_selected_call_id" => "call_3",
      "report_selection_count" => 1,
      "report_selection_matches_compiled_demo" => true,
      "trajectory_index" => 0,
      "predictor_name" => "answerer",
      "call_count" => 4
    },
    "trace_set_4" => %{
      "sha256" => "74fad33fd95e380dcc91e3b63c977abd9d2790741f08b8468df19a1eb6263f75",
      "branch_byte" => 116,
      "earlier_index_byte" => 250,
      "branch" => "earlier",
      "selected_index" => 1,
      "selected_call_id" => "call_1",
      "compiled_demo_count" => 1,
      "compiled_selected_index" => 1,
      "compiled_selected_call_id" => "call_1",
      "report_selection_count" => 1,
      "report_selection_matches_compiled_demo" => true,
      "trajectory_index" => 0,
      "predictor_name" => "answerer",
      "call_count" => 4
    },
    "trace_set_5" => %{
      "sha256" => "f152d8dc18d5668b5d8320a793019c9b89e25e7dbb70e17a9dfad34fbb6a4a2a",
      "branch_byte" => 241,
      "earlier_index_byte" => 82,
      "branch" => "final",
      "selected_index" => 3,
      "selected_call_id" => "call_3",
      "compiled_demo_count" => 1,
      "compiled_selected_index" => 3,
      "compiled_selected_call_id" => "call_3",
      "report_selection_count" => 1,
      "report_selection_matches_compiled_demo" => true,
      "trajectory_index" => 0,
      "predictor_name" => "answerer",
      "call_count" => 4
    },
    "trace_set_13" => %{
      "sha256" => "5c9dfa4a7585d287c0c76952d63609be9c5d4f133eeb33bb06566ac7c878a6ba",
      "branch_byte" => 92,
      "earlier_index_byte" => 157,
      "branch" => "earlier",
      "selected_index" => 1,
      "selected_call_id" => "call_1",
      "compiled_demo_count" => 1,
      "compiled_selected_index" => 1,
      "compiled_selected_call_id" => "call_1",
      "report_selection_count" => 1,
      "report_selection_matches_compiled_demo" => true,
      "trajectory_index" => 0,
      "predictor_name" => "answerer",
      "call_count" => 4
    },
    "trace_set_30" => %{
      "sha256" => "94d8bcff220445139375e634c6c4a178af688a4388440acb36b247e65455846f",
      "branch_byte" => 148,
      "earlier_index_byte" => 216,
      "branch" => "earlier",
      "selected_index" => 0,
      "selected_call_id" => "call_0",
      "compiled_demo_count" => 1,
      "compiled_selected_index" => 0,
      "compiled_selected_call_id" => "call_0",
      "report_selection_count" => 1,
      "report_selection_matches_compiled_demo" => true,
      "trajectory_index" => 0,
      "predictor_name" => "answerer",
      "call_count" => 4
    }
  }

  defmodule BootstrapRepeatedCallProgram do
    @moduledoc false

    defstruct [:answerer, :calls]

    def optimizer_predictors(program), do: [answerer: program.answerer]

    def update_optimizer_predictor(program, :answerer, update),
      do: %{program | answerer: update.(program.answerer)}

    def call(program, _inputs) do
      result =
        Enum.reduce_while(program.calls, {:ok, nil, []}, fn call, {:ok, _last, trace} ->
          inputs = %{question: call["inputs"]["question"]}
          expected_hint = call["outputs"]["hint"]

          case Imp.call(program.answerer, inputs) do
            {:ok, prediction} ->
              if Imp.get(prediction, :hint) == expected_hint do
                step = %{
                  predictor: :answerer,
                  inputs: inputs,
                  outputs: Imp.Prediction.to_map(prediction)
                }

                {:cont, {:ok, prediction, trace ++ [step]}}
              else
                {:halt, {:error, :fixture_hint_mismatch}}
              end

            {:error, _reason} = error ->
              {:halt, error}
          end
        end)

      case result do
        {:ok, nil, []} ->
          {:error, :empty_fixture_trace}

        {:ok, prediction, trace} ->
          {:ok, %{prediction | metadata: Map.put(prediction.metadata, :optimizer_trace, trace)}}

        {:error, _reason} = error ->
          error
      end
    end
  end

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, invalid} =
      OptionParser.parse(args, strict: [out: :string, python: :string])

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    out_dir = Keyword.get(opts, :out, @default_out)
    python = opts |> Keyword.get(:python, current_dspy_python()) |> Path.expand()
    File.mkdir_p!(out_dir)

    upstream = run_dspy!(python, out_dir)
    comparison = compare(upstream)

    artifact =
      Map.merge(comparison, %{
        "schema_version" => 1,
        "evidence_tier" => "t1_instruction_optimizer_differential_contract",
        "claim_scope" => "provider-free MIPROv2/SIMBA structural control-flow semantics",
        "generated_at" =>
          DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
        "git_sha" => git_sha(),
        "dspy" => upstream["dspy"]
      })

    path =
      Path.join(out_dir, "instruction-optimizer-contract-#{timestamp_slug()}.json")
      |> Imp.BenchmarkTruth.ArtifactFile.write_json!(artifact)

    Mix.shell().info("Instruction optimizer T1 differential contract: #{path}")

    unless artifact["summary"]["structural_contract_complete"] do
      Mix.raise("instruction optimizer T1 differential contract failed; inspect #{path}")
    end
  end

  @doc false
  def compare(upstream) when is_map(upstream) do
    rows = contract_rows(upstream)
    required = Enum.filter(rows, & &1["required"])
    complete = required != [] and Enum.all?(required, & &1["passing"])

    %{
      "summary" => %{
        "total_cases" => length(rows),
        "required_cases" => length(required),
        "required_passing" => Enum.count(required, & &1["passing"]),
        "structural_contract_complete" => complete,
        "exact_sampler_sequence_parity" => false,
        "paper_protocol_complete" => false,
        "full_optimizer_parity" => false
      },
      "declared_native_deviations" => declared_native_deviations(),
      "rows" => rows
    }
  end

  defp contract_rows(upstream) do
    mipro = upstream["mipro_v2"]
    simba = upstream["simba"]

    mipro_budget_rows(mipro) ++
      mipro_demo_rows(mipro) ++
      mipro_bootstrap_repeated_call_rows(mipro) ++
      mipro_rotation_rows(mipro) ++
      mipro_schedule_rows(mipro) ++
      mipro_categorical_rows(mipro) ++
      simba_bucket_rows(simba) ++
      simba_finalist_rows(simba) ++
      simba_rollout_rows(simba) ++
      simba_tie_rows(simba) ++
      simba_eviction_rows(simba)
  end

  defp mipro_budget_rows(mipro) do
    auto =
      Enum.map(mipro["budgets"]["auto"], fn expected ->
        mode = auto_mode!(expected["mode"])

        opts =
          if expected["zeroshot"],
            do: [auto: mode, max_bootstrapped_demos: 0, max_labeled_demos: 0],
            else: [auto: mode]

        config =
          Config.resolve(Config.new(opts), 2, Enum.to_list(1..1_200), Enum.to_list(1..1_200), [])

        actual = %{
          "mode" => Atom.to_string(config.auto),
          "zeroshot" => config.zeroshot,
          "predictors" => 2,
          "num_trials" => config.num_trials,
          "num_instruct_candidates" => config.num_instruct_candidates,
          "num_fewshot_candidates" => config.num_fewshot_candidates,
          "valset_size" => length(config.valset),
          "minibatch" => config.minibatch
        }

        row("mipro_auto_#{expected["mode"]}_#{expected["zeroshot"]}", expected, actual)
      end)

    expected = mipro["budgets"]["manual"]["derived"]

    config =
      Config.new(auto: nil, num_candidates: 5, num_trials: 17, minibatch: true)
      |> Config.resolve(2, Enum.to_list(1..80), Enum.to_list(1..80), [])

    actual = %{
      "num_trials" => config.num_trials,
      "valset_size" => length(config.valset),
      "minibatch" => config.minibatch,
      "num_instruct_candidates" => config.num_instruct_candidates,
      "num_fewshot_candidates" => config.num_fewshot_candidates
    }

    recommendations = mipro["budgets"]["manual"]["recommended_trials_from_5_candidates"]

    auto ++
      [
        row("mipro_manual_budget", expected, actual),
        row("mipro_recommended_trials", recommendations, %{
          "fewshot" => Config.recommended_num_trials(2, false, 5),
          "zeroshot" => Config.recommended_num_trials(2, true, 5)
        })
      ]
  end

  @doc false
  def auto_mode!("light"), do: :light
  def auto_mode!("medium"), do: :medium
  def auto_mode!("heavy"), do: :heavy

  def auto_mode!(mode) do
    Mix.raise("unsupported MIPROv2 auto mode in DSPy contract: #{inspect(mode)}")
  end

  defp mipro_demo_rows(mipro) do
    topology = mipro["demo_arm_topology"]

    for {id, expected, labels} <- [
          {"mipro_demo_arms_with_labels", topology["with_labels"], 4},
          {"mipro_demo_arms_zero_labels", topology["zero_labels"], 0}
        ] do
      actual =
        DemoCandidates.arm_plan(6, labels)
        |> Enum.map(&stringify_atom_values/1)

      row(id, expected, actual)
    end
  end

  defp mipro_bootstrap_repeated_call_rows(mipro) do
    fixture = mipro["bootstrap_repeated_predictor_calls"]

    selections =
      Enum.map(fixture["cases"], fn fixture_case ->
        {algorithm, outcome} = compile_bootstrap_fixture_case(fixture_case)
        {fixture_case["id"], algorithm, outcome}
      end)

    [actual_imp_algorithm] =
      selections
      |> Enum.map(&elem(&1, 1))
      |> Enum.uniq()

    actual_imp_outcomes = Map.new(selections, fn {id, _algorithm, outcome} -> {id, outcome} end)

    expected =
      bootstrap_fixture_contract(fixture, @bootstrap_imp_algorithm, @bootstrap_imp_outcomes)

    actual =
      bootstrap_fixture_contract(fixture, actual_imp_algorithm, actual_imp_outcomes)

    [row("bootstrap_repeated_predictor_calls_behavior", expected, actual)]
  end

  defp bootstrap_fixture_contract(fixture, imp_algorithm, imp_outcomes) do
    cases =
      Enum.map(fixture["cases"], fn fixture_case ->
        %{
          "id" => fixture_case["id"],
          "input" => Map.take(fixture_case, ["trajectory_index", "predictor_name", "calls"]),
          "dspy" => fixture_case["dspy"],
          "imp" => Map.fetch!(imp_outcomes, fixture_case["id"])
        }
      end)

    %{
      "fixture_id" => fixture["fixture_id"],
      "scope" => fixture["scope"],
      "source_hashes" => fixture["source_hashes"],
      "algorithms" => %{"dspy" => fixture["algorithm"], "imp" => imp_algorithm},
      "cases" => cases,
      "comparison" => bootstrap_fixture_comparison(fixture["algorithm"], imp_algorithm, cases)
    }
  end

  defp bootstrap_fixture_comparison(dspy_algorithm, imp_algorithm, cases) do
    case_parity =
      Map.new(cases, fn fixture_case ->
        {fixture_case["id"],
         fixture_case["dspy"]["selected_call_id"] ==
           fixture_case["imp"]["compiled_selected_call_id"]}
      end)

    dspy_branches = cases |> Enum.map(& &1["dspy"]["branch"]) |> Enum.uniq() |> Enum.sort()
    imp_branches = cases |> Enum.map(& &1["imp"]["branch"]) |> Enum.uniq() |> Enum.sort()

    dspy_earlier_indices =
      cases
      |> Enum.filter(&(&1["dspy"]["branch"] == "earlier"))
      |> Enum.map(& &1["dspy"]["selected_index"])
      |> Enum.uniq()
      |> Enum.sort()

    imp_earlier_indices =
      cases
      |> Enum.filter(&(&1["imp"]["branch"] == "earlier"))
      |> Enum.map(& &1["imp"]["selected_index"])
      |> Enum.uniq()
      |> Enum.sort()

    %{
      "dspy_runtime_calls_match_fixture" =>
        Enum.all?(cases, fn fixture_case ->
          fixture_case["dspy"]["runtime_predictor_call_count"] ==
            length(fixture_case["input"]["calls"]) and
            fixture_case["dspy"]["runtime_lm_call_count"] ==
              length(fixture_case["input"]["calls"])
        end),
      "one_demo_per_predictor" =>
        Enum.all?(cases, fn fixture_case ->
          fixture_case["dspy"]["selected_count"] == 1 and
            fixture_case["imp"]["compiled_demo_count"] == 1 and
            fixture_case["imp"]["report_selection_count"] == 1 and
            fixture_case["imp"]["report_selection_matches_compiled_demo"]
        end),
      "branch_probability_model_agreement" =>
        dspy_algorithm["branch_probability_model"] == %{"earlier" => 0.5, "final" => 0.5} and
          imp_algorithm["branch_probability_model"] == %{"earlier" => 0.5, "final" => 0.5},
      "fixed_case_branch_coverage" => %{"dspy" => dspy_branches, "imp" => imp_branches},
      "fixed_case_earlier_index_coverage" => %{
        "dspy" => dspy_earlier_indices,
        "imp" => imp_earlier_indices
      },
      "case_selection_parity" => case_parity,
      "exact_selection_parity" => Enum.all?(case_parity, fn {_id, parity?} -> parity? end),
      "mixed_case_selection_parity" =>
        Enum.any?(case_parity, fn {_id, parity?} -> parity? end) and
          Enum.any?(case_parity, fn {_id, parity?} -> not parity? end)
    }
  end

  defp compile_bootstrap_fixture_case(fixture_case) do
    Code.ensure_loaded!(BootstrapRepeatedCallProgram)
    calls = fixture_case["calls"]

    program = %BootstrapRepeatedCallProgram{
      answerer: Imp.predict("question -> hint", lm: bootstrap_fixture_lm(calls)),
      calls: calls
    }

    example =
      Imp.example(question: "contract-#{fixture_case["id"]}")
      |> Imp.with_inputs(:question)

    compiled =
      BootstrapFewShot.new(nil, max_bootstrapped_demos: 1, max_labeled_demos: 0)
      |> BootstrapFewShot.compile(program, [example])

    compiled_demos = compiled.answerer.demos
    report = Report.fetch(compiled.answerer)

    unless length(compiled_demos) == 1 do
      Mix.raise(
        "bootstrap fixture #{fixture_case["id"]} compiled #{length(compiled_demos)} demos: " <>
          inspect(report, limit: :infinity)
      )
    end

    [compiled_demo] = compiled_demos
    report_selections = report.metadata.repeated_call_selections
    [selection] = report_selections
    compiled_selected_index = compiled_demo_index!(compiled_demo, calls)

    outcome = %{
      "sha256" => selection.sha256,
      "branch_byte" => selection.branch_byte,
      "earlier_index_byte" => selection.earlier_index_byte,
      "branch" => Atom.to_string(selection.branch),
      "selected_index" => selection.selected_index,
      "selected_call_id" => call_id_at!(calls, selection.selected_index),
      "compiled_demo_count" => length(compiled_demos),
      "compiled_selected_index" => compiled_selected_index,
      "compiled_selected_call_id" => call_id_at!(calls, compiled_selected_index),
      "report_selection_count" => length(report_selections),
      "report_selection_matches_compiled_demo" =>
        selection.selected_index == compiled_selected_index,
      "trajectory_index" => selection.trajectory_index,
      "predictor_name" => Atom.to_string(selection.predictor),
      "call_count" => selection.call_count
    }

    algorithm =
      selection.algorithm
      |> stringify_keys()
      |> Map.put(
        "observed_via",
        "BootstrapFewShot.compile/4 compiled predictor and optimizer report"
      )

    {algorithm, outcome}
  end

  defp compiled_demo_index!(compiled_demo, calls) do
    question = Imp.Example.get(compiled_demo, :question)
    hint = Imp.Example.get(compiled_demo, :hint)

    Enum.find_index(calls, fn call ->
      call["inputs"]["question"] == question and call["outputs"]["hint"] == hint
    end) || Mix.raise("compiled bootstrap demo does not match its fixed trace input")
  end

  defp call_id_at!(calls, index), do: calls |> Enum.fetch!(index) |> Map.fetch!("call_id")

  defp bootstrap_fixture_lm(calls) do
    responses =
      Map.new(calls, fn call ->
        {call["inputs"]["question"], call["outputs"]["hint"]}
      end)

    %{
      module: Imp.LM.Static,
      opts: [
        handler: fn messages, _opts ->
          prompt = inspect(messages, limit: :infinity)

          case Enum.find(responses, fn {question, _hint} -> String.contains?(prompt, question) end) do
            {_question, hint} -> %{hint: hint}
            nil -> {:error, :fixture_question_not_found}
          end
        end
      ]
    }
  end

  defp mipro_rotation_rows(mipro) do
    demo_sets = Enum.map(0..5, &[&1])

    Enum.map(mipro["proposal_rotation"]["slots"], fn expected ->
      slot = expected["proposal_slot"]

      actual = %{
        "proposal_slot" => slot,
        "demo_set_rotation" => InstructionProposer.grounded_demo_rotation(demo_sets, slot, 6),
        "task_demos_forced_to_none" => slot == 0
      }

      expected =
        if slot == 0,
          do: Map.put(expected, "demo_set_rotation", []),
          else: expected

      row("mipro_proposal_rotation_#{slot}", expected, actual)
    end)
  end

  defp mipro_schedule_rows(mipro) do
    Enum.map(mipro["released_minibatch_schedule"]["cases"], fn expected ->
      actual =
        MIPROv2.upstream_trial_schedule(
          expected["num_trials"],
          expected["minibatch_full_eval_steps"]
        )

      row("mipro_minibatch_schedule_#{expected["num_trials"]}", expected, stringify_keys(actual))
    end)
  end

  defp mipro_categorical_rows(mipro) do
    expected = mipro["categorical_parameter_shape"]
    predictors = [%{name: :zero}, %{name: :one}]
    instructions = %{zero: [:i0, :i1, :i2], one: [:j0, :j1]}
    demos = %{zero: [[], [], [], []], one: [[], [], [], []]}

    for {id, upstream_space, imp_space} <- [
          {"mipro_categorical_with_demos", expected["with_demos"],
           MIPROv2.categorical_space(predictors, instructions, demos)},
          {"mipro_categorical_without_demos", expected["without_demos"],
           MIPROv2.categorical_space(predictors, instructions, nil)}
        ] do
      expected_shape = categorical_shape(upstream_space, & &1["choices"])
      actual_shape = categorical_shape(imp_space, & &1)
      row(id, expected_shape, actual_shape)
    end
  end

  defp simba_bucket_rows(simba) do
    contract = simba["batch_bucket_ordering"]
    model_major = contract["fixture"]["model_major_scores"]
    outputs = for scores <- model_major, score <- scores, do: %{score: score}
    buckets = Buckets.rank(outputs, length(hd(model_major)))
    {p10, p90} = Buckets.batch_percentiles(outputs)

    actual = %{
      "percentiles" => %{"p10" => p10, "p90" => p90},
      "ordered_buckets" =>
        Enum.map(buckets, fn bucket ->
          %{
            "example_index" => bucket.example,
            "scores_desc" => Enum.map(bucket.trajectories, &Buckets.score/1),
            "sort_key" => Tuple.to_list(bucket.rank)
          }
        end)
    }

    expected = Map.take(contract, ["percentiles", "ordered_buckets"])
    [row("simba_batch_bucket_ordering", expected, actual, &approximately_equal?/2)]
  end

  defp simba_finalist_rows(simba) do
    Enum.map(simba["finalist_index_selection"]["cases"], fn expected ->
      actual = SIMBA.finalist_indices(expected["max_winning_index"], expected["num_candidates"])
      row("simba_finalists_#{expected["max_winning_index"]}", expected["indices"], actual)
    end)
  end

  defp simba_rollout_rows(simba) do
    contract = simba["rollout_model_ids"]
    start = contract["base_start_rollout_id"]

    for {id, expected, teacher?} <- [
          {"simba_rollouts_without_teacher", contract["without_teacher"], false},
          {"simba_rollouts_with_teacher", contract["with_teacher"], true}
        ] do
      expected =
        Enum.map(expected, fn rollout ->
          %{
            "rollout_id" => rollout["rollout_id"],
            "teacher?" => rollout["is_teacher_object"],
            "force_temperature?" => rollout["temperature"] == 1.0
          }
        end)

      actual =
        SIMBA.rollout_id_plan(start, 4, teacher?)
        |> Enum.map(&stringify_keys/1)

      row(id, expected, actual)
    end
  end

  defp simba_tie_rows(simba) do
    Enum.map(simba["tied_rule_semantics"]["cases"], fn expected ->
      actual =
        SIMBA.rule_disposition(
          expected["good_score"],
          expected["bad_score"],
          expected["batch_p10"],
          expected["batch_p90"]
        )

      expected_disposition =
        case expected["result"] do
          "strategy_returns_false_before_provider" -> :skip
          "good_trajectory_replaced_with_NA_then_provider_is_invoked" -> :suppress_good
        end

      row(
        "simba_tie_#{expected["id"]}",
        Atom.to_string(expected_disposition),
        Atom.to_string(actual)
      )
    end)
  end

  defp simba_eviction_rows(simba) do
    Enum.map(simba["demo_eviction"]["cases"], fn expected ->
      actual = SIMBA.eviction_parameters(expected["num_demos"], expected["max_demos"])

      expected_invariants = %{
        "demo_count" => expected["num_demos"],
        "poisson_mean" => expected["num_demos"] / expected["poisson_denominator"],
        "poisson_denominator" => expected["poisson_denominator"],
        "minimum_drop_count" =>
          if(expected["num_demos"] >= expected["poisson_denominator"], do: 1, else: 0),
        "sample_with_replacement?" => true,
        "shared_indices_across_predictors?" => true
      }

      row(
        "simba_eviction_#{expected["seed"]}_#{expected["num_demos"]}_#{expected["max_demos"]}",
        expected_invariants,
        stringify_keys(actual),
        &approximately_equal?/2
      )
    end)
  end

  defp categorical_shape(space, choices) do
    counts =
      space
      |> Enum.map(fn {_name, value} -> value |> choices.() |> length() end)
      |> Enum.sort()

    %{"variable_count" => length(counts), "choice_counts" => counts}
  end

  defp row(id, expected, actual, comparator \\ &Kernel.==/2) do
    passing = comparator.(expected, actual)

    %{
      "id" => id,
      "required" => true,
      "status" => if(passing, do: "matched", else: "mismatch"),
      "passing" => passing,
      "expected" => expected,
      "actual" => actual,
      "errors" => if(passing, do: [], else: ["Imp result differs from pinned DSPy contract"])
    }
  end

  defp approximately_equal?(left, right) when is_number(left) and is_number(right),
    do: abs(left - right) <= 1.0e-12

  defp approximately_equal?(left, right) when is_list(left) and is_list(right) do
    length(left) == length(right) and
      Enum.zip(left, right) |> Enum.all?(fn {a, b} -> approximately_equal?(a, b) end)
  end

  defp approximately_equal?(left, right) when is_map(left) and is_map(right) do
    Map.keys(left) |> MapSet.new() == Map.keys(right) |> MapSet.new() and
      Enum.all?(left, fn {key, value} -> approximately_equal?(value, Map.fetch!(right, key)) end)
  end

  defp approximately_equal?(left, right), do: left == right

  defp stringify_atom_values(map) do
    Map.new(map, fn
      {key, value} when is_atom(value) -> {to_string(key), Atom.to_string(value)}
      {key, value} -> {to_string(key), value}
    end)
  end

  defp stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value) when is_boolean(value) or is_nil(value), do: value
  defp stringify_keys(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_keys(value), do: value

  defp declared_native_deviations do
    [
      %{
        "id" => "mipro_sampler_sequence",
        "dspy" => "Optuna multivariate TPE",
        "imp" => "joint categorical Parzen sampler",
        "consequence" => "search-space shape matches; exact sampled trial sequence does not"
      },
      %{
        "id" => "optimizer_rng_sequence",
        "dspy" => "Python random plus NumPy Generator",
        "imp" => "BEAM :rand streams",
        "consequence" => "sampling invariants match; exact seeded decision sequence does not"
      },
      %{
        "id" => "bootstrap_repeated_predictor_calls",
        "dspy" =>
          "Python random.Random seeded by Hasher.hash(tuple(demos)); rng.random() gates rng.choice(demos[:-1]) versus demos[-1]",
        "imp" =>
          "SHA-256 over the BEAM term {trajectory index, predictor name, demos}; digest-byte parity gates byte-modulo earlier index versus final",
        "consequence" =>
          "both return one demo and have a 1/2 earlier-or-final branch model under their respective uniform-randomness assumptions; this seven-case cross-runtime fixture checks branch/index shape and mixed exact outcomes, not empirical uniformity or Python RNG sequence parity",
        "fixture_id" => @bootstrap_fixture_id,
        "evidence_row" => "bootstrap_repeated_predictor_calls_behavior"
      },
      %{
        "id" => "grounded_proposer_call_graph",
        "dspy" => "GroundedProposer data summary and module-description calls",
        "imp" => "native grounded prompt with program, data, and rotated demo context",
        "consequence" => "rotation semantics match; provider call graph and prompt text do not"
      }
    ]
  end

  defp run_dspy!(python, out_dir) do
    path = Path.join(out_dir, "dspy-instruction-optimizer-contract-#{timestamp_slug()}.json")

    case System.cmd(
           python,
           ["scripts/dspy_instruction_optimizer_contract.py", "--out", path],
           stderr_to_stdout: true,
           env: current_dspy_env()
         ) do
      {_output, 0} ->
        path |> File.read!() |> Jason.decode!()

      {output, status} ->
        Mix.raise("DSPy instruction optimizer contract failed with status #{status}:\n#{output}")
    end
  end

  defp current_dspy_python do
    System.get_env("IMP_DSPY_CURRENT_PYTHON") || "tmp/dspy-parity-venv/bin/python"
  end

  defp current_dspy_env do
    case System.get_env("IMP_DSPY_CURRENT_PYTHONPATH") do
      nil ->
        target = Path.expand("tmp/dspy-current-target")
        if File.dir?(Path.join(target, "dspy")), do: [{"PYTHONPATH", target}], else: []

      path ->
        [{"PYTHONPATH", Path.expand(path)}]
    end
  end

  defp git_sha do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> "unknown"
    end
  end

  defp timestamp_slug, do: Calendar.strftime(DateTime.utc_now(), "%Y%m%dT%H%M%SZ")
end
