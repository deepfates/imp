defmodule Imp.LocalGRPOOpaqueBanking77ExampleTest do
  use ExUnit.Case, async: false

  @source "examples/local_grpo_opaque_banking77/run.exs"
  @contract "priv/trl_worker/qwen-opaque-38-step-contract.json"
  @result "examples/local_grpo_opaque_banking77/exercised-result.json"
  @usefulness_data "benchmarks/data/grpo-usefulness-banking77-v1.json"
  @usefulness_config "examples/local_grpo_opaque_banking77/usefulness-v1-treatment.json"
  @usefulness_result "examples/local_grpo_opaque_banking77/exercised-usefulness-v1-result.json"
  @semantic_config "examples/local_grpo_opaque_banking77/semantic-v1-treatment.json"
  @semantic_stopped_result "examples/local_grpo_opaque_banking77/exercised-semantic-v1-stopped-result.json"
  @trec_config "examples/local_grpo_opaque_banking77/trec-semantic-v1-treatment.json"
  @trec_correct_config "examples/local_grpo_opaque_banking77/trec-correct-semantics-v1-treatment.json"
  @trec_contract "priv/trl_worker/qwen-trec-14-step-contract.json"
  @trec_stopped_result "examples/local_grpo_opaque_banking77/exercised-trec-semantic-v1-stopped-result.json"
  @trec_source_guided_result "examples/local_grpo_opaque_banking77/exercised-trec-source-guided-v1-result.json"

  setup_all do
    output =
      Path.join(System.tmp_dir!(), "imp-grpo-opaque-define-#{System.unique_integer([:positive])}")

    previous_define = System.get_env("IMP_GRPO_OPAQUE_DEFINE_ONLY")
    previous_output = System.get_env("IMP_GRPO_OPAQUE_OUTPUT")
    System.put_env("IMP_GRPO_OPAQUE_DEFINE_ONLY", "1")
    System.put_env("IMP_GRPO_OPAQUE_OUTPUT", output)
    Code.require_file(@source, File.cwd!())

    on_exit(fn ->
      restore_env("IMP_GRPO_OPAQUE_DEFINE_ONLY", previous_define)
      restore_env("IMP_GRPO_OPAQUE_OUTPUT", previous_output)
      File.rm_rf!(output)
    end)

    %{output: output}
  end

  test "DEFINE_ONLY loads the ordinary front door without output or model activity", %{
    output: output
  } do
    refute File.exists?(output)

    assert apply(LocalGRPOOpaqueBanking77.Definition, :train_steps, []) == 38
    assert apply(LocalGRPOOpaqueBanking77.Definition, :train_width, []) == 4

    assert apply(LocalGRPOOpaqueBanking77.Definition, :train_kwargs, []) == [
             learning_rate: 1.0e-6,
             beta: 0.0,
             loss_type: :dapo,
             scale_rewards: :group
           ]
  end

  test "the task prompt exposes route identities but no semantic route key" do
    instruction = apply(LocalGRPOOpaqueBanking77.Definition, :instruction, [])

    for route <- ~w(R17 R42 R68 R93), do: assert(instruction =~ route)

    for leaked_meaning <-
          ~w(fee charged unrecognized recognised pending reversed reverted payment),
        do: refute(String.contains?(String.downcase(instruction), leaked_meaning))

    source = File.read!(@source)
    refute source =~ "R17:"
    refute source =~ "R42:"
    refute source =~ "R68:"
    refute source =~ "R93:"
  end

  test "pinned worker and public optimizer bind the same 38-step TRL defaults" do
    contract = @contract |> File.read!() |> Jason.decode!()
    source = File.read!(@source)

    assert contract["dependencies"] == %{
             "trl" => "1.6.0",
             "transformers" => "4.57.6",
             "peft" => "0.18.1",
             "torch" => "2.10.0"
           }

    assert contract["optimizer"]["max_steps"] == 38
    assert contract["optimizer"]["num_generations"] == 4
    assert contract["optimizer"]["learning_rate"] == 1.0e-6
    assert contract["optimizer"]["loss_type"] == "dapo"
    assert contract["optimizer"]["scale_rewards"] == "group"
    assert contract["optimizer"]["beta"] == 0.0

    assert contract["device"] == %{
             "type" => "mps",
             "dtype" => "float32",
             "allow_cpu_fallback" => false,
             "use_vllm" => false
           }

    contract_sha =
      @contract |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

    assert source =~ contract_sha
    assert source =~ "checkpoint_selection: :best_validation"
    assert source =~ "checkpoint_path: Path.join(paths.output, \"grpo-checkpoint.bin\")"
  end

  test "frozen 72/8/40 data is split before public GRPO and test stays outside selection" do
    source = File.read!(@source)

    data =
      "benchmarks/data/provider-training-banking77-v1.json" |> File.read!() |> Jason.decode!()

    grouped = Enum.group_by(data["train"], & &1["route"])
    routes = ~w(R17 R42 R68 R93)
    train = Enum.flat_map(routes, fn route -> Enum.take(grouped[route], 18) end)

    selection =
      Enum.flat_map(routes, fn route -> grouped[route] |> Enum.drop(18) |> Enum.take(2) end)

    digest = fn rows ->
      rows
      |> Enum.map(&Imp.Optimizer.Report.encode_term/1)
      |> Imp.Clients.TRLProtocol.digest()
    end

    assert length(train) == 72
    assert length(selection) == 8
    assert length(data["held_out"]) == 40

    assert digest.(train) ==
             "sha256:16d37a946696995fe343b2773e546f54c2d0a1a97adfc0fbce1782e79e281f34"

    assert digest.(selection) ==
             "sha256:5b34859cb5e6588dcc53360c68e76875c0fba2191b55a7169b4781acef97c6c1"

    assert source =~ "Imp.train(program(training_lm), optimizer, examples(rows.train),"
    assert source =~ "validation: examples(rows.selection)"
    refute source =~ "validation: examples(rows.test)"
    refute source =~ "Imp.train(program(training_lm), optimizer, examples(rows.test)"
    assert source =~ "source_schedule!(step_artifacts, rows.train)"
    assert source =~ "%{source_rows: 72, groups: 152, twice: 64, thrice: 8}"
  end

  test "result retention, stable arm selection, artifact verification and fresh rebind are explicit" do
    source = File.read!(@source)

    assert source =~
             "Atomic.write!(Path.join(paths.output, \"03-trained-selection.json\"), stage)"

    assert source =~ "Atomic.write!(Path.join(paths.output, \"04-selection.json\"), selection)"
    assert source =~ "Atomic.write!(Path.join(paths.output, \"05-base-test.json\"), base_test)"

    assert source =~
             "Atomic.write!(Path.join(paths.output, \"06-trained-test.json\"), trained_test)"

    assert source =~ "accuracy_then_macro_f1_tie_keeps_base"
    assert source =~ "TRLArtifact.verify_job(job)"
    assert source =~ "TrainingJob.rebind(job, portable, trainer: trainer)"
    assert source =~ "IMP_GRPO_OPAQUE_FRESH"
    assert source =~ "fresh selected predictions/errors differ"
    assert source =~ "TRLDeployment.stop(deployment)"
  end

  test "fresh-label usefulness treatment is source-pinned and split-disjoint" do
    data = @usefulness_data |> File.read!() |> Jason.decode!()
    config = @usefulness_config |> File.read!() |> Jason.decode!()

    assert data["source"] == %{
             "repository" => "PolyAI/banking77",
             "revision" => "796a4623935746f71378f0ebd435635a8ce08e50",
             "license" => "CC-BY-4.0",
             "train_file" => "data/train-00000-of-00001.parquet",
             "train_file_sha256" =>
               "4526edfa60622ff9b39e238657ab6d712f6aba1ba91c9d7ed7897b0715ee0390",
             "test_file" => "data/test-00000-of-00001.parquet",
             "test_file_sha256" =>
               "535fc96c4c2b4c2dbdeb0d4b31f24a4859620cf663d6c19c1bd1f97450c410be"
           }

    assert Enum.map(data["route_codes"], & &1["source_label_id"]) == [27, 38, 70, 32]
    assert Enum.map(data["route_codes"], & &1["route"]) == ~w(R17 R42 R68 R93)
    assert length(data["train"]) == 72
    assert length(data["validation"]) == 8
    assert length(data["held_out"]) == 40

    ids = Enum.map(data["train"] ++ data["validation"] ++ data["held_out"], & &1["id"])
    assert length(ids) == length(Enum.uniq(ids))
    assert config["train_ids"] == Enum.map(data["train"], & &1["id"])
    assert config["selection_ids"] == Enum.map(data["validation"], & &1["id"])
    assert config["selection_source"] == "validation"

    digest = fn rows ->
      rows
      |> Enum.map(&Imp.Optimizer.Report.encode_term/1)
      |> Imp.Clients.TRLProtocol.digest()
    end

    assert digest.(data["train"]) == config["train_sha256"]
    assert digest.(data["validation"]) == config["selection_sha256"]
    assert digest.(data["held_out"]) == config["test_sha256"]
  end

  test "disclosed-semantics treatment changes only the frozen information boundary and seed" do
    opaque = @usefulness_config |> File.read!() |> Jason.decode!()
    semantic = @semantic_config |> File.read!() |> Jason.decode!()

    assert semantic["schema_version"] == 2

    assert semantic["treatment_id"] ==
             "model-generated-banking77-disclosed-route-semantics-v1"

    for key <-
          ~w(data_sha256 train_sha256 selection_sha256 test_sha256 contract_sha256 model routes selection_source) do
      assert semantic[key] == opaque[key]
    end

    assert semantic["seed"] != opaque["seed"]
    assert semantic["instruction"] =~ "R17 means a transfer was declined"
    assert semantic["instruction"] =~ "R42 means the customer wants to obtain a physical card"
    assert semantic["instruction"] =~ "R68 means the customer must verify the source of funds"
    assert semantic["instruction"] =~ "R93 means the customer is asking about an exchange rate"

    source = File.read!(@source)
    assert source =~ "instruction_sha256: TRLProtocol.digest(instruction())"
    assert source =~ "Definition.instruction()"
  end

  test "misleading disclosed-semantics run remains stopped before selection and test" do
    result = @semantic_stopped_result |> File.read!() |> Jason.decode!()

    assert result["status"] == "stopped"
    assert result["completed_training_steps"] == 29
    assert result["steps_with_changed_trainable_tensors"] == 29
    assert result["trained_selection"] == nil
    assert result["selected_arm"] == nil
    refute result["untouched_test_opened"]
    refute result["deployable_artifact_selected"]
    assert result["stop_reason"] =~ "misleading semantic gloss"
  end

  test "TREC semantic treatment binds a source-disjoint task and official LoRA GRPO settings" do
    config = @trec_config |> File.read!() |> Jason.decode!()
    contract = @trec_contract |> File.read!() |> Jason.decode!()
    data = "benchmarks/data/simba-trec-coarse-v1.json" |> File.read!() |> Jason.decode!()

    assert config["schema_version"] == 3
    assert config["input_field"] == "question"
    assert config["train_steps"] == 14
    assert config["train_kwargs"]["learning_rate"] == 1.0e-5

    assert config["source_schedule"] == %{
             "source_rows" => 24,
             "groups" => 56,
             "twice" => 16,
             "thrice" => 8
           }

    assert contract["optimizer"]["seed"] == config["seed"]
    assert contract["optimizer"]["max_steps"] == config["train_steps"]

    assert contract["optimizer"]["learning_rate"] ==
             config["train_kwargs"]["learning_rate"]

    assert length(data["train"]) == 24
    assert length(data["validation"]) == 8
    assert length(data["held_out"]) == 40

    assert MapSet.disjoint?(
             MapSet.new(Enum.map(data["train"], & &1["source_id"])),
             MapSet.new(Enum.map(data["held_out"], & &1["source_id"]))
           )
  end

  test "mislabeled TREC treatment remains stopped before selection and test" do
    result = @trec_stopped_result |> File.read!() |> Jason.decode!()

    assert result["status"] == "stopped"
    assert result["completed_training_steps"] == 3
    assert result["steps_with_changed_trainable_tensors"] == 3
    assert result["trained_selection"] == nil
    assert result["selected_arm"] == nil
    refute result["untouched_test_opened"]
    assert result["stop_reason"] =~ "R42=HUM, R68=LOC"
  end

  test "corrected TREC treatment changes only the factual route legend" do
    stopped = @trec_config |> File.read!() |> Jason.decode!()
    corrected = @trec_correct_config |> File.read!() |> Jason.decode!()
    data = "benchmarks/data/simba-trec-coarse-v1.json" |> File.read!() |> Jason.decode!()

    assert corrected["treatment_id"] ==
             "model-generated-trec-coarse-correct-disclosed-semantics-v1"

    for key <-
          ~w(schema_version data_sha256 train_sha256 selection_sha256 test_sha256 contract_sha256 model seed routes selection_source input_field train_steps train_kwargs source_schedule) do
      assert corrected[key] == stopped[key]
    end

    route_coarse =
      data["train"]
      |> Enum.group_by(& &1["route"], & &1["coarse"])
      |> Map.new(fn {route, values} -> {route, Enum.uniq(values)} end)

    assert route_coarse == %{
             "R17" => ["DESC"],
             "R42" => ["HUM"],
             "R68" => ["LOC"],
             "R93" => ["NUM"]
           }

    instruction = corrected["instruction"]
    assert instruction =~ "R17 means a description"
    assert instruction =~ "R42 means a person or group of people"
    assert instruction =~ "R68 means a location"
    assert instruction =~ "R93 means a numeric answer"
    refute instruction =~ "R42 means an entity"
  end

  test "retained run preserves a complete neutral usefulness result" do
    result = @result |> File.read!() |> Jason.decode!()

    assert result["status"] == "complete"

    assert result["source_schedule"] == %{
             "scheduler" => "dspy_pinned_full_batch_padding",
             "source_rows" => 72,
             "groups" => 152,
             "twice" => 64,
             "thrice" => 8
           }

    assert length(result["training_steps"]) == 38
    assert Enum.all?(result["training_steps"], & &1["trainable_tensors_changed"])
    assert Enum.count(result["training_steps"], &(Enum.uniq(&1["rewards"]) |> length() > 1)) == 37
    assert result["base_selection"] == result["trained_selection"]
    assert result["base_test"] == result["trained_test"]
    assert result["base_test"]["accuracy"] == 0.475
    assert result["selected_arm"] == "base"
    assert result["fresh_selected_arm"] == "base"
    assert result["fresh_byte_identical"]
  end

  test "fresh-label treatment preserves its separate neutral result" do
    result = @usefulness_result |> File.read!() |> Jason.decode!()

    assert result["status"] == "complete"
    assert length(result["training_steps"]) == 38
    assert Enum.all?(result["training_steps"], & &1["trainable_tensors_changed"])
    assert Enum.all?(result["training_steps"], &(length(Enum.uniq(&1["rewards"])) > 1))

    assert Enum.count(result["training_steps"], &Enum.any?(&1["advantages"], fn x -> x != 0 end)) ==
             37

    assert result["base_selection"] == result["trained_selection"]
    assert result["base_selection"]["accuracy"] == 0.25
    assert result["selected_arm"] == "base"

    assert result["base_test"] == result["trained_test"]
    assert result["base_test"]["accuracy"] == 0.4
    assert_in_delta result["base_test"]["macro_f1"], 0.2812903225806451, 1.0e-12
    assert result["base_test"]["errors"] == 2
    assert result["fresh_selected_arm"] == "base"
    assert result["fresh_byte_identical"]
  end

  test "source-guided TREC result preserves the selected artifact and honest held-out regression" do
    result = @trec_source_guided_result |> File.read!() |> Jason.decode!()

    assert result["status"] == "complete_negative"
    assert result["training"]["steps"] == 33
    assert result["training"]["prompt_groups"] == 66
    assert result["training"]["rollouts_per_group"] == 8
    assert result["training"]["steps_with_nonuniform_rewards"] == 31
    assert result["training"]["steps_with_changed_trainable_tensors"] == 33
    assert result["training"]["selected_validation_step"] == 5

    assert result["selection"]["selected_arm"] == "trained"
    assert result["selection"]["trained"]["accuracy"] > result["selection"]["base"]["accuracy"]

    test_result = result["held_out_test"]
    assert test_result["base"]["accuracy"] == 0.25
    assert test_result["trained"]["accuracy"] == 0.225
    assert test_result["accuracy_delta"] == -0.025
    assert test_result["macro_f1_delta"] < 0
    refute test_result["predeclared_positive_rule_passed"]
    assert result["fresh_process"]["artifact_identity_matched"]
    assert result["fresh_process"]["ordered_predictions_and_errors_byte_identical"]
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
