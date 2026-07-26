defmodule Imp.LocalGRPOOpaqueBanking77ExampleTest do
  use ExUnit.Case, async: false

  @source "examples/local_grpo_opaque_banking77/run.exs"
  @contract "priv/trl_worker/qwen-opaque-38-step-contract.json"
  @result "examples/local_grpo_opaque_banking77/exercised-result.json"
  @usefulness_data "benchmarks/data/grpo-usefulness-banking77-v1.json"
  @usefulness_config "examples/local_grpo_opaque_banking77/usefulness-v1-treatment.json"

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
    assert source =~ "length(ids) == 152"
    assert source =~ "twice == 64 and thrice == 8"
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

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
