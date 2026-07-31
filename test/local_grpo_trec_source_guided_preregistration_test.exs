defmodule LocalGRPOTRECSourceGuidedPreregistrationTest do
  use ExUnit.Case, async: true

  alias Imp.Clients.TRLProtocol
  alias Imp.Optimizer.Report

  @treatment_id "imp-grpo-trec-coarse-lora-source-guided-v1"
  @data_path "examples/local_grpo_opaque_banking77/trec-source-guided-v1-data.json"
  @config_path "examples/local_grpo_opaque_banking77/trec-source-guided-v1-treatment.json"
  @contract_path "priv/trl_worker/qwen-trec-source-guided-33-step-contract.json"
  @runner_path "examples/local_grpo_opaque_banking77/run.exs"
  @source_path "benchmarks/data/confidence-calibration-trec-fine.jsonl"
  @simba_path "benchmarks/data/simba-trec-coarse-v1.json"
  @legend [{"DESC", "R17"}, {"HUM", "R42"}, {"LOC", "R68"}, {"NUM", "R93"}]

  test "the committed 64/32/40 rows are mechanically derived and SIMBA-disjoint" do
    data = decode!(@data_path)
    simba = decode!(@simba_path)
    excluded = collect_source_ids(simba)

    assert sha256_file(@source_path) == data["source"]["fixture_sha256"]
    assert sha256_file(@simba_path) == data["exclusion"]["fixture_sha256"]
    assert data["exclusion"]["identity_field"] == "source_id"
    assert data["exclusion"]["excluded_source_ids"] == Enum.sort(MapSet.to_list(excluded))

    fixture_rows = decode_jsonl!(@source_path)
    expected = derive_rows(fixture_rows, excluded)

    assert data["train"] == expected.train
    assert data["validation"] == expected.validation
    assert data["held_out"] == expected.held_out

    assert Enum.map(@legend, fn {coarse, route} ->
             %{"coarse" => coarse, "route" => route}
           end) == data["route_codes"]

    assert data["selection_policy"]["available_after_exclusion"] == %{
             "DESC" => %{"calibration" => 37, "held_out" => 53},
             "HUM" => %{"calibration" => 32, "held_out" => 18},
             "LOC" => %{"calibration" => 25, "held_out" => 14},
             "NUM" => %{"calibration" => 27, "held_out" => 29}
           }
  end

  test "row identities, exact route legend, and split digests cannot drift" do
    data = decode!(@data_path)
    config = decode!(@config_path)
    legend = Map.new(@legend)
    splits = [{"train", 64, "train"}, {"validation", 32, "train"}, {"held_out", 40, "test"}]

    for {name, size, source_split} <- splits do
      rows = data[name]
      assert length(rows) == size
      assert split_digest(rows) == data["split_digests"][name]

      for {coarse, route} <- @legend do
        assert Enum.count(rows, &(&1["coarse"] == coarse)) == div(size, 4)
        assert Enum.all?(Enum.filter(rows, &(&1["coarse"] == coarse)), &(&1["route"] == route))
      end

      assert Enum.all?(rows, fn row ->
               row["route"] == Map.fetch!(legend, row["coarse"]) and
                 String.starts_with?(row["source_label"], row["coarse"] <> ":") and
                 row["source_split"] == source_split
             end)
    end

    all_rows = data["train"] ++ data["validation"] ++ data["held_out"]

    for field <- ~w(id source_id group_id) do
      values = Enum.map(all_rows, &Map.fetch!(&1, field))
      assert length(values) == length(Enum.uniq(values))
    end

    assert MapSet.disjoint?(
             MapSet.new(Enum.map(data["train"] ++ data["validation"], & &1["source_id"])),
             MapSet.new(Enum.map(data["held_out"], & &1["source_id"]))
           )

    assert config["train_sha256"] == data["split_digests"]["train"]
    assert config["selection_sha256"] == data["split_digests"]["validation"]
    assert config["test_sha256"] == data["split_digests"]["held_out"]
    assert config["data_sha256"] == sha256_file(@data_path)
    assert config["contract_sha256"] == sha256_file(@contract_path)
  end

  test "schema-v4 treatment binds the seed, padded epoch, and pinned worker settings" do
    data = decode!(@data_path)
    config = decode!(@config_path)
    contract = decode!(@contract_path)
    optimizer = contract["optimizer"]

    assert config["schema_version"] == 4
    assert config["treatment_id"] == @treatment_id
    assert config["routes"] == ~w(R17 R42 R68 R93)
    assert config["selection_source"] == "validation"
    assert config["input_field"] == "question"
    assert config["seed"] == deterministic_seed(@treatment_id)
    assert config["seed"] == 532_978_328

    assert config["train_steps"] == 33
    assert config["train_width"] == 2
    assert config["num_rollouts"] == 8
    assert config["train_width"] * config["num_rollouts"] == 16
    assert config["train_width"] * config["num_rollouts"] < 32

    assert config["source_schedule"] == %{
             "source_rows" => 64,
             "groups" => 66,
             "once" => 62,
             "twice" => 2,
             "thrice" => 0
           }

    assert config["source_schedule"]["groups"] ==
             config["train_steps"] * config["train_width"]

    assert config["source_schedule"]["once"] + 2 * config["source_schedule"]["twice"] +
             3 * config["source_schedule"]["thrice"] == config["source_schedule"]["groups"]

    assert optimizer["seed"] == config["seed"]
    assert optimizer["max_steps"] == config["train_steps"]
    assert optimizer["num_generations"] == config["num_rollouts"]
    assert optimizer["max_completion_length"] == 16
    assert optimizer["temperature"] == 1.0
    assert optimizer["learning_rate"] == 1.0e-5
    assert optimizer["loss_type"] == "dapo"
    assert optimizer["scale_rewards"] == "group"
    assert optimizer["beta"] == 0.0
    assert contract["imp_runtime"]["train_kwargs"] == config["train_kwargs"]

    assert optimizer["lora"] == %{
             "rank" => 8,
             "alpha" => 16,
             "dropout" => 0.0,
             "target_modules" => ~w(q_proj k_proj v_proj o_proj gate_proj up_proj down_proj)
           }

    assert contract["model"]["revision"] ==
             "7ae557604adf67be50417f59c2c2f167def9a775"

    assert contract["device"] == %{
             "type" => "mps",
             "dtype" => "float32",
             "allow_cpu_fallback" => false,
             "use_vllm" => false
           }

    assert data["training_basis"]["budget_rule"] == %{
             "basis" =>
               "One predeclared Imp padded epoch; not a TRL task-specific step recommendation.",
             "source_rows" => 64,
             "train_width" => 2,
             "padding_groups" => 2,
             "groups" => 66,
             "optimizer_steps" => 33
           }
  end

  test "official guidance is qualified separately from the pinned runtime and outcome claims" do
    data = decode!(@data_path)
    basis = data["training_basis"]
    runtime = basis["pinned_runtime"]
    guidance = basis["current_official_guidance"]
    policy = data["outcome_policy"]
    config = decode!(@config_path)
    contract = decode!(@contract_path)
    runner = File.read!(@runner_path)

    assert runtime["trl"] == %{
             "version" => "1.6.0",
             "revision" => "0dac440542c2ef9b575f56534f29f6fca1febe4a",
             "grpo_config_sha256" =>
               "5ae40ed6e516a7d3231db77318bb6c2b267c27ea6d54a9a6602c9f5772861965",
             "facts" => %{
               "learning_rate_default" => 1.0e-6,
               "num_generations_default" => 8,
               "loss_type_default" => "dapo",
               "scale_rewards_default" => "group",
               "beta_default" => 0.0
             }
           }

    assert runtime["transformers"]["training_args_sha256"] ==
             "444c4c5617b89e05ae4a31de3c4f7fc1f6311496a9bf7ef357aa69be3aa2afff"

    assert runtime["transformers"]["facts"] == %{
             "lr_scheduler_type_default" => "linear",
             "warmup_ratio_default" => 0.0,
             "warmup_steps_default" => 0
           }

    assert runtime["peft"]["lora_layer_sha256"] ==
             "e8a47a49cf69f92ded68bf7ab286aeaf068f0ac809ab3465ad16f78a8f9f8b63"

    assert guidance["commit"] == "c9ecd143f0aab0bd0c50f8b137b8f87167045dc5"

    assert guidance["qualification"] ==
             "Current official local source, not proven present at the pinned TRL 1.6.0 runtime revision."

    assert guidance["files"] == [
             %{
               "path" => "docs/source/peft_integration.md",
               "sha256" => "78968674f528b57d649512cb16382b3be459f3cd4bbc892a724fef6585df71fe"
             },
             %{
               "path" => "docs/source/lora_without_regret.md",
               "sha256" => "f8f0bcd99cabdd403d38793c184376aaa62abdc7547b437ec731eca2272bf627"
             }
           ]

    assert guidance["facts"] == %{
             "grpo_lora_learning_rate" => 1.0e-5,
             "rl_lora_rank_min" => 1,
             "rl_lora_rank_max" => 32,
             "target_modules" => "all-linear",
             "effective_batch_size" => "less_than_32",
             "num_generations" => 8
           }

    refute policy["route_semantics_exposed_to_model"]

    assert policy["selection"]["checkpoint"] == %{
             "mode" => "best_validation",
             "validation_frequency_steps" => 1,
             "metric" => "mean exact-route reward",
             "higher_is_better" => true,
             "tie" => "earliest"
           }

    assert policy["selection"]["arm_comparison"] == %{
             "metrics" => ["accuracy", "macro_f1"],
             "order" => "lexicographic",
             "trained_requires" => "strictly_greater",
             "tie" => "base"
           }

    assert runner =~ "checkpoint_selection: :best_validation"
    assert runner =~ "num_steps_for_val: 1"
    assert runner =~ "base_key = {base.accuracy, base.macro_f1}"
    assert runner =~ "trained_key = {trained.accuracy, trained.macro_f1}"
    assert runner =~ "if trained_key > base_key do"

    assert contract["acceptance"] == %{
             "require_non_uniform_rewards" => false,
             "require_non_uniform_advantages" => false,
             "require_weight_change" => false
           }

    assert "Uniform-reward groups remain in the frozen schedule and may legitimately produce no weight change." in policy[
             "non_claims"
           ]

    assert policy["test"]["positive_min_accuracy_delta"] == 0.05
    assert policy["test"]["macro_f1_must_not_decrease"]
    assert policy["test"]["errors_must_not_increase"]

    public_instruction = String.downcase(config["instruction"])
    assert Enum.all?(~w(r17 r42 r68 r93), &String.contains?(public_instruction, &1))

    refute Enum.any?(
             ~w(desc hum loc num description person location numeric),
             &String.contains?(public_instruction, &1)
           )

    assert File.regular?(@data_path)
    refute @data_path in Mix.Project.config()[:package][:files]
  end

  defp derive_rows(rows, excluded) do
    allowed = MapSet.new(Enum.map(@legend, &elem(&1, 0)))
    routes = Map.new(@legend)

    grouped =
      rows
      |> Enum.map(&Map.put(&1, "coarse", &1["label"] |> String.split(":") |> hd()))
      |> Enum.filter(&MapSet.member?(allowed, &1["coarse"]))
      |> Enum.reject(&MapSet.member?(excluded, &1["source_id"]))
      |> Enum.group_by(&{&1["split"], &1["coarse"]})

    selected = fn split, coarse, offset, count ->
      grouped
      |> Map.fetch!({split, coarse})
      |> Enum.sort_by(&{sha256(@treatment_id <> ":" <> &1["group_id"]), &1["id"]})
      |> Enum.drop(offset)
      |> Enum.take(count)
      |> Enum.map(&project_row(&1, Map.fetch!(routes, coarse)))
    end

    %{
      train:
        Enum.flat_map(@legend, fn {coarse, _route} -> selected.("calibration", coarse, 0, 16) end),
      validation:
        Enum.flat_map(@legend, fn {coarse, _route} -> selected.("calibration", coarse, 16, 8) end),
      held_out:
        Enum.flat_map(@legend, fn {coarse, _route} -> selected.("heldout", coarse, 0, 10) end)
    }
  end

  defp project_row(row, route) do
    %{
      "id" => row["id"],
      "question" => row["text"],
      "route" => route,
      "coarse" => row["coarse"],
      "source_label" => row["label"],
      "source_id" => row["source_id"],
      "source_split" => row["source_split"],
      "source_row" => row["source_row"],
      "group_id" => row["group_id"]
    }
  end

  defp collect_source_ids(value) when is_map(value) do
    Enum.reduce(value, MapSet.new(), fn
      {"source_id", source_id}, ids when is_binary(source_id) -> MapSet.put(ids, source_id)
      {_key, nested}, ids -> MapSet.union(ids, collect_source_ids(nested))
    end)
  end

  defp collect_source_ids(value) when is_list(value) do
    Enum.reduce(value, MapSet.new(), &MapSet.union(&2, collect_source_ids(&1)))
  end

  defp collect_source_ids(_value), do: MapSet.new()

  defp deterministic_seed(value) do
    <<word::unsigned-big-32, _rest::binary>> = :crypto.hash(:sha256, value)
    Bitwise.band(word, 0x7FFFFFFF)
  end

  defp split_digest(rows) do
    rows
    |> Enum.map(&Report.encode_term/1)
    |> TRLProtocol.digest()
  end

  defp decode!(path), do: path |> File.read!() |> Jason.decode!()

  defp decode_jsonl!(path) do
    path
    |> File.stream!()
    |> Enum.map(&Jason.decode!/1)
  end

  defp sha256_file(path), do: path |> File.read!() |> sha256()

  defp sha256(value),
    do: value |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
end
