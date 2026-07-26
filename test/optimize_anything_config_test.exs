defmodule Imp.Optimize.Anything.ConfigTest do
  use ExUnit.Case, async: true

  alias Imp.Optimize.Anything.Config
  alias Imp.Optimize.Anything.Config.{Engine, Merge, Refiner, Reflection, Tracking}
  alias Imp.Optimizer.GEPA.Stopper

  defmodule ReflectionStrategy do
    def reflect(_candidate, _dataset, [component]) do
      %{new_texts: %{component => "improved"}}
    end
  end

  test "defaults mirror released settings without choosing an external model" do
    config = Config.new()

    assert config.engine.seed == 0
    assert config.engine.frontier_type == :hybrid
    assert config.engine.candidate_selection_strategy == :pareto
    assert config.engine.parallel
    assert config.engine.cache_evaluation_storage == :auto
    assert config.engine.best_example_evals_k == 30
    assert config.reflection.batch_sampler == :epoch_shuffled
    assert config.reflection.module_selector == :round_robin
    assert config.reflection.reflection_lm == nil
    assert config.merge == nil
    assert config.refiner == nil
    assert config.tracking == Tracking.new()
  end

  test "nested constructors accept keyword settings and remain immutable" do
    baseline = Config.new()

    configured =
      Config.new(
        engine: [max_metric_calls: 120, cache_evaluation: true, max_workers: 4],
        reflection: [reflection_minibatch_size: 3, skip_perfect_score: true, perfect_score: 1.0],
        merge: [max_merge_invocations: 7],
        refiner: [max_refinements: 2],
        tracking: [use_wandb: true]
      )

    assert baseline.engine.max_metric_calls == nil
    assert configured.engine.max_metric_calls == 120
    assert configured.reflection.reflection_minibatch_size == 3
    assert configured.merge == %Merge{max_merge_invocations: 7}
    assert configured.refiner == %Refiner{max_refinements: 2}
    assert configured.tracking.use_wandb
  end

  test "cache mode follows the released auto memory and disk behavior" do
    assert Engine.new() |> Engine.cache_mode() == :off
    assert Engine.new(cache_evaluation: true) |> Engine.cache_mode() == :memory

    assert Engine.new(cache_evaluation: true, run_dir: "tmp/run") |> Engine.cache_mode() ==
             :disk

    assert_raise ArgumentError, ~r/requires run_dir/, fn ->
      Engine.new(cache_evaluation: true, cache_evaluation_storage: :disk)
    end
  end

  test "engine bridge covers budgets, frontier, stopper, callbacks, and merge" do
    stopper = Stopper.no_improvement(4)

    config =
      Config.new(
        engine: [
          seed: 9,
          max_metric_calls: 50,
          max_full_evaluations: 8,
          max_candidate_proposals: 12,
          raise_on_exception: false,
          frontier_type: :cartesian
        ],
        reflection: [reflection_minibatch_size: 2],
        merge: [max_merge_invocations: 3, merge_val_overlap_floor: 2],
        stopper: stopper
      )

    opts = Config.to_engine_options(config)

    assert opts[:seed] == 9
    assert opts[:raise_on_exception] == false
    assert opts[:max_metric_calls] == 50
    assert opts[:max_full_evaluations] == 8
    assert opts[:max_iterations] == 12
    assert opts[:frontier_type] == :cartesian
    assert opts[:cache_evaluation] == false
    assert opts[:cache_evaluation_storage] == :memory
    assert opts[:candidate_selection_strategy] == :pareto
    assert opts[:module_selector] == :round_robin
    assert opts[:max_reflection_calls] == :infinity
    assert opts[:track_best_outputs] == false
    assert opts[:skip_perfect_score] == false
    assert opts[:perfect_score] == nil
    assert opts[:evaluation_policy] == :full
    assert opts[:minibatch_size] == 2
    assert opts[:stopper] == stopper
    assert opts[:callbacks] == []
    assert opts[:use_merge]
    assert opts[:max_merge_invocations] == 3
    assert opts[:merge_val_overlap_floor] == 2
  end

  test "engine bridge selects disk cache and multi-component reflection" do
    config =
      Config.new(
        engine: [run_dir: "tmp/gepa", cache_evaluation: true],
        reflection: [module_selector: :all]
      )

    opts = Config.to_engine_options(config)
    assert opts[:cache_evaluation_storage] == {:disk, "tmp/gepa"}
    assert opts[:module_selector] == :all
  end

  test "engine bridge accepts and forwards the released reflection strategy" do
    config = Config.new(reflection: [reflection_strategy: ReflectionStrategy])

    assert config.reflection.reflection_strategy == ReflectionStrategy
    assert Config.to_engine_options(config)[:reflection_strategy] == ReflectionStrategy
  end

  test "constructors reject invalid released settings and unknown options" do
    assert_raise ArgumentError, ~r/unknown options.*wat/, fn -> Engine.new(wat: true) end

    assert_raise ArgumentError, ~r/positive integer/, fn ->
      Reflection.new(reflection_minibatch_size: 0)
    end

    assert_raise ArgumentError, ~r/perfect_score must be numeric/, fn ->
      Config.new(reflection: [skip_perfect_score: true])
    end

    assert_raise ArgumentError, ~r/non negative integer/, fn ->
      Merge.new(max_merge_invocations: -1)
    end

    assert_raise ArgumentError, ~r/arity-4/, fn ->
      Reflection.new(custom_candidate_proposer: fn _candidate -> :invalid end)
    end

    assert_raise ArgumentError, ~r/invalid Optimize Anything stopper/, fn ->
      Config.new(stopper: :invalid)
    end
  end

  test "versioned persistence round trips JSON-safe nested settings" do
    config =
      Config.new(
        engine: [
          run_dir: "tmp/gepa",
          max_metric_calls: 30,
          cache_evaluation: true,
          frontier_type: :objective
        ],
        reflection: [reflection_minibatch_size: 3, module_selector: :all],
        merge: Merge.new(merge_subsample_size: 4),
        refiner: Refiner.new(max_refinements: 2),
        tracking: [use_mlflow: true, mlflow_experiment_name: "anything"]
      )

    persisted = config |> Config.to_map() |> Jason.encode!() |> Jason.decode!()

    assert persisted["type"] == "imp_optimize_anything_config"
    assert persisted["schema_version"] == 1
    assert Config.from_map(persisted) == config
  end

  test "tracking persistence never stores W&B credentials" do
    config = Config.new(tracking: [use_wandb: true, wandb_api_key: "secret-api-key"])
    persisted = Config.to_map(config)

    assert get_in(persisted, ["tracking", "wandb_api_key"]) == nil
    refute inspect(persisted) =~ "secret-api-key"
    assert Config.from_map(persisted).tracking.wandb_api_key == nil
  end

  test "persistence rejects runtime-only model, strategy, proposer, stopper, and callback values" do
    reflection_lm = fn _messages, _opts -> {:ok, "proposal"} end

    assert_raise ArgumentError, ~r/runtime-only value/, fn ->
      Config.new(reflection: [reflection_lm: reflection_lm]) |> Config.to_map()
    end

    assert_raise ArgumentError, ~r/reflection_strategy is runtime-only/, fn ->
      Config.new(reflection: [reflection_strategy: ReflectionStrategy]) |> Config.to_map()
    end

    assert_raise ArgumentError, ~r/stopper and callbacks are runtime-only/, fn ->
      Config.new(stopper: Stopper.timeout(10)) |> Config.to_map()
    end
  end
end
