defmodule InstructionOptimizerContractArtifactTest do
  use ExUnit.Case, async: false

  @moduletag :evidence_infrastructure

  import ExUnit.CaptureIO

  @tag timeout: 120_000
  test "pinned DSPy and Imp pass structural MIPROv2 and SIMBA contracts without implying T3" do
    unless File.exists?("tmp/dspy-parity-venv/bin/python") and
             File.dir?("tmp/dspy-current-target/dspy") do
      flunk("run the documented current-DSPy environment setup before this source-checkout gate")
    end

    out = tmp_dir("instruction-optimizer-contract")

    capture_io(fn ->
      Mix.Task.reenable("imp.benchmark.instruction_optimizer_contract")
      Mix.Tasks.Imp.Benchmark.InstructionOptimizerContract.run(["--out", out])
    end)

    [path] = Path.wildcard(Path.join(out, "instruction-optimizer-contract-*.json"))
    artifact = path |> File.read!() |> Jason.decode!()

    assert artifact["evidence_tier"] == "t1_instruction_optimizer_differential_contract"
    assert artifact["dspy"]["version"] == "3.3.0b1"
    assert artifact["dspy"]["commit"] == "b2829b7ae3b6e276ac6a8bef66a7ec519dbc923f"
    assert artifact["summary"]["structural_contract_complete"]
    assert artifact["summary"]["required_passing"] == 33
    refute artifact["summary"]["exact_sampler_sequence_parity"]
    refute artifact["summary"]["paper_protocol_complete"]
    refute artifact["summary"]["full_optimizer_parity"]
    assert Enum.all?(artifact["rows"], & &1["passing"])

    deviations = Map.new(artifact["declared_native_deviations"], &{&1["id"], &1})

    assert deviations["bootstrap_repeated_predictor_calls"] == %{
             "id" => "bootstrap_repeated_predictor_calls",
             "imp" =>
               "SHA-256 over the BEAM term {trajectory index, predictor name, demos}; digest-byte parity gates byte-modulo earlier index versus final",
             "dspy" =>
               "Python random.Random seeded by Hasher.hash(tuple(demos)); rng.random() gates rng.choice(demos[:-1]) versus demos[-1]",
             "consequence" =>
               "both return one demo and have a 1/2 earlier-or-final branch model under their respective uniform-randomness assumptions; this seven-case cross-runtime fixture checks branch/index shape and mixed exact outcomes, not empirical uniformity or Python RNG sequence parity",
             "fixture_id" => "bootstrap-repeated-predictor-calls-v3",
             "evidence_row" => "bootstrap_repeated_predictor_calls_behavior"
           }

    rows = Map.new(artifact["rows"], &{&1["id"], &1})
    repeated_calls = rows["bootstrap_repeated_predictor_calls_behavior"]

    assert repeated_calls["status"] == "matched"
    assert repeated_calls["expected"] == repeated_calls["actual"]

    fixture = repeated_calls["actual"]

    assert fixture["fixture_id"] == "bootstrap-repeated-predictor-calls-v3"

    assert fixture["scope"] ==
             "seven fixed trace inputs executed through both predictor runtimes; branch and earlier-index coverage, not an empirical distribution estimate"

    assert fixture["source_hashes"] == %{
             "dspy/teleprompt/bootstrap.py" =>
               "0a588f11f09a358a5306540cc42401d905073c9452e54d32348b13d12bbb1255",
             "dspy/predict/predict.py" =>
               "25acd81c09875e52442452fb318eff62161513de6fa08271e6a6766eb8d81a23",
             "dspy/utils/dummies.py" =>
               "e62b4cdaea8468277f4b11527d8c288e70a95a89d686982f089f1c26bf62a50c",
             "dspy/utils/hasher.py" =>
               "e04ed4699ddf39f2cf9992016b2ebbde715e0f16f255eec6f158a9fe86f477d2"
           }

    assert fixture["algorithms"]["dspy"] == %{
             "observed_via" =>
               "repeated dspy.Predict calls through BootstrapFewShot._bootstrap_one_example",
             "runtime_call_probe" => "DummyLM.history plus dspy.Predict trace identity",
             "trace_source_expression" => "trace.append((self, {**kwargs}, pred))",
             "source_expression" =>
               "demos = [rng.choice(demos[:-1]) if rng.random() < 0.5 else demos[-1]]",
             "rng" => "Python random.Random",
             "seed" => "Hasher.hash(tuple(demos))",
             "branch_draw" => "rng.random()",
             "earlier_when" => "branch_draw < 0.5",
             "earlier_choice" => "rng.choice(demos[:-1])",
             "final_choice" => "demos[-1]",
             "probability_basis" => "uniform random.Random.random() variate",
             "branch_probability_model" => %{"earlier" => 0.5, "final" => 0.5}
           }

    assert fixture["algorithms"]["imp"] == %{
             "observed_via" =>
               "BootstrapFewShot.compile/4 compiled predictor and optimizer report",
             "digest" => "sha256",
             "payload" => "erlang_term_trajectory_index_predictor_name_demos",
             "branch_byte_index" => 0,
             "branch_modulus" => 2,
             "earlier_remainder" => 0,
             "earlier_index_byte_index" => 1,
             "probability_basis" => "uniform_sha256_branch_byte_parity",
             "branch_probability_model" => %{"earlier" => 0.5, "final" => 0.5}
           }

    cases = Map.new(fixture["cases"], &{&1["id"], &1})

    expected_dspy = %{
      "trace_set_0" =>
        {"0460c53e6c18f543c88ad72c26a1cda739768f1a0c7ae6222eb47f71b6817e84", 0.7157076233012117,
         "final", 3},
      "trace_set_2" =>
        {"2e37eef58a2ff9d19682684a2eb368c5cdc7856effd8a0b7bc91c91315a92644", 0.8601016835594661,
         "final", 3},
      "trace_set_3" =>
        {"de3f5ae5261e369be2eb3bcc1f893af058ce02155c9e5b11c081f3a0d66e461a", 0.2573183427206168,
         "earlier", 0},
      "trace_set_4" =>
        {"524ee8bb69ee7de2b014e71bd5ec5559849db9cd64ba1f485c1d2454d70ddf19", 0.748174734575589,
         "final", 3},
      "trace_set_5" =>
        {"20708280eab2905c622c1ae25ec213371c6834f1aeb973a4fd387da7ef4d55f1", 0.2170616038822879,
         "earlier", 1},
      "trace_set_13" =>
        {"3f8a151ec65a0bf07918da5a0c9d57d1f510a1c6ed92ca26e4e2267bd1f915bd", 0.3303275522921808,
         "earlier", 2},
      "trace_set_30" =>
        {"b3f7ac72c6942122bc819a1bc11aed0c2ca007053090744f95364753870f99e7", 0.5050866552652811,
         "final", 3}
    }

    expected_imp = %{
      "trace_set_0" =>
        {"34fbc63abc20a7432db52aaffc7cb536ac6a3dc1ba1a855eb8e8e907b5047ae6", 52, 251, "earlier",
         2},
      "trace_set_2" =>
        {"a35edd6a69fe99b9fbd548a8bd34bf8f8bbeb413b0f75b1ba0698ff98a56c64b", 163, 94, "final", 3},
      "trace_set_3" =>
        {"45162346f6f28da72c8d47fface2bd87d060c8c76bad5bb948c34da5e7fa4c1b", 69, 22, "final", 3},
      "trace_set_4" =>
        {"74fad33fd95e380dcc91e3b63c977abd9d2790741f08b8468df19a1eb6263f75", 116, 250, "earlier",
         1},
      "trace_set_5" =>
        {"f152d8dc18d5668b5d8320a793019c9b89e25e7dbb70e17a9dfad34fbb6a4a2a", 241, 82, "final", 3},
      "trace_set_13" =>
        {"5c9dfa4a7585d287c0c76952d63609be9c5d4f133eeb33bb06566ac7c878a6ba", 92, 157, "earlier",
         1},
      "trace_set_30" =>
        {"94d8bcff220445139375e634c6c4a178af688a4388440acb36b247e65455846f", 148, 216, "earlier",
         0}
    }

    Enum.each([0, 2, 3, 4, 5, 13, 30], fn trace_set ->
      id = "trace_set_#{trace_set}"
      fixture_case = Map.fetch!(cases, id)

      assert fixture_case["input"]["trajectory_index"] == 0
      assert fixture_case["input"]["predictor_name"] == "answerer"
      assert fixture_call_projection(fixture_case) == expected_call_projection(trace_set)

      {hasher_seed, rng_draw, dspy_branch, dspy_index} = Map.fetch!(expected_dspy, id)

      assert fixture_case["dspy"] == %{
               "hasher_seed" => hasher_seed,
               "rng_draw" => rng_draw,
               "branch" => dspy_branch,
               "selected_index" => dspy_index,
               "selected_call_id" => "call_#{dspy_index}",
               "selected_count" => 1,
               "runtime_predictor_call_count" => 4,
               "runtime_lm_call_count" => 4,
               "observed_via" =>
                 "repeated dspy.Predict calls through BootstrapFewShot._bootstrap_one_example"
             }

      {sha256, branch_byte, earlier_index_byte, imp_branch, imp_index} =
        Map.fetch!(expected_imp, id)

      assert fixture_case["imp"] == %{
               "sha256" => sha256,
               "branch_byte" => branch_byte,
               "earlier_index_byte" => earlier_index_byte,
               "branch" => imp_branch,
               "selected_index" => imp_index,
               "selected_call_id" => "call_#{imp_index}",
               "compiled_demo_count" => 1,
               "compiled_selected_index" => imp_index,
               "compiled_selected_call_id" => "call_#{imp_index}",
               "report_selection_count" => 1,
               "report_selection_matches_compiled_demo" => true,
               "trajectory_index" => 0,
               "predictor_name" => "answerer",
               "call_count" => 4
             }
    end)

    assert fixture["comparison"] == %{
             "dspy_runtime_calls_match_fixture" => true,
             "one_demo_per_predictor" => true,
             "branch_probability_model_agreement" => true,
             "fixed_case_branch_coverage" => %{
               "dspy" => ["earlier", "final"],
               "imp" => ["earlier", "final"]
             },
             "fixed_case_earlier_index_coverage" => %{
               "dspy" => [0, 1, 2],
               "imp" => [0, 1, 2]
             },
             "case_selection_parity" => %{
               "trace_set_0" => false,
               "trace_set_2" => true,
               "trace_set_3" => false,
               "trace_set_4" => false,
               "trace_set_5" => false,
               "trace_set_13" => false,
               "trace_set_30" => false
             },
             "exact_selection_parity" => false,
             "mixed_case_selection_parity" => true
           }

    assert rows["mipro_minibatch_schedule_12"]["status"] == "matched"
    assert rows["simba_batch_bucket_ordering"]["status"] == "matched"
    assert rows["simba_tie_strictly_between"]["actual"] == "suppress_good"
  end

  test "contract auto modes use a closed mapping independent of VM atom state" do
    contract = Mix.Tasks.Imp.Benchmark.InstructionOptimizerContract

    assert contract.auto_mode!("light") == :light
    assert contract.auto_mode!("medium") == :medium
    assert contract.auto_mode!("heavy") == :heavy

    assert_raise Mix.Error, ~r/unsupported MIPROv2 auto mode/, fn ->
      contract.auto_mode!("unexpected")
    end
  end

  defp tmp_dir(name) do
    path = Path.join(System.tmp_dir!(), "imp-#{name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    path
  end

  defp fixture_call_projection(fixture_case) do
    Enum.map(fixture_case["input"]["calls"], fn call ->
      {call["call_id"], call["inputs"]["question"], call["outputs"]["hint"]}
    end)
  end

  defp expected_call_projection(trace_set) do
    Enum.map(0..3, fn call_index ->
      {
        "call_#{call_index}",
        "fixture-#{trace_set}-q-#{call_index}",
        "fixture-#{trace_set}-h-#{call_index}"
      }
    end)
  end
end
