defmodule Imp.Optimizer.MIPROv2.ConfigTest do
  use ExUnit.Case, async: true

  alias Imp.Optimizer.MIPROv2.Config

  test "light auto settings derive candidates, trials, and minibatching" do
    resolved = Config.new() |> Config.resolve(2, Enum.to_list(1..120), Enum.to_list(1..80))

    assert resolved.num_instruct_candidates == 3
    assert resolved.num_fewshot_candidates == 6
    assert resolved.num_trials == 20
    assert resolved.minibatch
    assert length(resolved.valset) == 80
    refute resolved.zeroshot
  end

  test "medium and heavy auto modes cap validation data and derive budgets" do
    valset = Enum.to_list(1..1_200)

    medium = Config.new(auto: :medium) |> Config.resolve(1, [:train], valset)
    heavy = Config.new(auto: :heavy) |> Config.resolve(1, [:train], valset)

    assert {medium.num_instruct_candidates, medium.num_fewshot_candidates} == {6, 12}
    assert {medium.num_trials, length(medium.valset)} == {18, 300}
    assert {heavy.num_instruct_candidates, heavy.num_fewshot_candidates} == {9, 18}
    assert {heavy.num_trials, length(heavy.valset)} == {27, 1_000}
  end

  test "zero-shot uses only instruction variables and full N instruction candidates" do
    resolved =
      Config.new(max_bootstrapped_demos: 0, max_labeled_demos: 0)
      |> Config.resolve(2, [:train], Enum.to_list(1..60))

    assert resolved.zeroshot
    assert resolved.num_instruct_candidates == 6
    assert resolved.num_fewshot_candidates == 6
    assert resolved.num_trials == 10
  end

  test "manual mode requires candidates and trials and preserves minibatch choice" do
    assert_raise ArgumentError, ~r/num_trials must be provided/, fn ->
      Config.new(auto: nil, num_candidates: 8) |> Config.resolve(1, [:a], [:b])
    end

    resolved =
      Config.new(auto: nil, num_candidates: 8, num_trials: 17, minibatch: false)
      |> Config.resolve(3, [:a], [:b])

    assert resolved.num_trials == 17
    assert resolved.num_instruct_candidates == 8
    assert resolved.num_fewshot_candidates == 8
    refute resolved.minibatch
  end

  test "auto rejects explicit candidate or trial budgets" do
    assert_raise ArgumentError, ~r/cannot be set when auto is enabled/, fn ->
      Config.new(num_candidates: 6) |> Config.resolve(1, [:a], [:b])
    end

    assert_raise ArgumentError, ~r/cannot be set when auto is enabled/, fn ->
      Config.new(num_trials: 10) |> Config.resolve(1, [:a], [:b])
    end
  end

  test "compile overrides select effective demos, seed, and proposer settings" do
    resolved =
      Config.new(seed: 9, program_aware_proposer: true)
      |> Config.resolve(1, [:a], Enum.to_list(1..60),
        max_bootstrapped_demos: 0,
        max_labeled_demos: 0,
        seed: 22,
        program_aware_proposer: false,
        data_aware_proposer: false,
        tip_aware_proposer: false,
        fewshot_aware_proposer: false,
        view_data_batch_size: 7
      )

    assert resolved.seed == 22
    assert resolved.zeroshot
    refute resolved.program_aware_proposer
    refute resolved.data_aware_proposer
    refute resolved.tip_aware_proposer
    refute resolved.fewshot_aware_proposer
    assert resolved.view_data_batch_size == 7
  end

  test "program grounding defaults to structure and validates explicit source opt-in" do
    assert Config.new().program_grounding == :structure
    assert Config.new(program_grounding: :module_source).program_grounding == :module_source

    assert Config.new(program_grounding: {:text, "Public program context."}).program_grounding ==
             {:text, "Public program context."}

    for invalid <- [{:text, ""}, {:text, String.duplicate("x", 20_001)}, :ambient_source] do
      assert_raise ArgumentError, ~r/program_grounding must be/, fn ->
        Config.new(program_grounding: invalid)
      end
    end
  end

  test "BEAM-native compile honors an explicit zero seed" do
    config = Config.new(auto: nil, num_candidates: 2, num_trials: 1, seed: 9, minibatch: false)

    assert Config.resolve(config, 1, [:train], [:valid], seed: 0).seed == 0
    assert Config.resolve(config, 1, [:train], [:valid], seed: 3).seed == 3
  end

  test "pinned DSPy proposer preserves the constructor seed for compile seed zero" do
    config =
      Config.new(
        auto: nil,
        num_candidates: 2,
        num_trials: 1,
        seed: 9,
        minibatch: false,
        max_bootstrapped_demos: 0,
        max_labeled_demos: 0,
        program_aware_proposer: false,
        fewshot_aware_proposer: false,
        data_aware_proposer: true,
        tip_aware_proposer: true,
        proposer_fidelity: :dspy_3_2_1
      )

    assert Config.resolve(config, 1, [:train], [:valid], seed: 0).seed == 9
    assert Config.resolve(config, 1, [:train], [:valid], seed: 3).seed == 3
  end

  test "full pinned Optuna fidelity admits minibatching but startup-only does not" do
    common = [
      auto: nil,
      num_candidates: 2,
      num_trials: 1,
      max_bootstrapped_demos: 0,
      max_labeled_demos: 0,
      minibatch: true,
      program_aware_proposer: false,
      fewshot_aware_proposer: false,
      data_aware_proposer: true,
      tip_aware_proposer: true,
      proposer_fidelity: :dspy_3_2_1
    ]

    assert Config.new(Keyword.put(common, :search_fidelity, :dspy_3_2_1_optuna_4_9_0)).minibatch

    assert_raise ArgumentError, ~r/startup-only.*does not admit minibatching/s, fn ->
      Config.new(Keyword.put(common, :search_fidelity, :dspy_3_2_1_optuna_4_9_0_startup))
    end
  end

  test "dataset validation mirrors DSPy splitting rules" do
    resolved = Config.new() |> Config.resolve(1, Enum.to_list(1..10), minibatch_size: 1)
    assert resolved.trainset == [1, 2]
    assert resolved.valset == Enum.to_list(3..10)
    refute resolved.minibatch

    assert_raise ArgumentError, ~r/trainset cannot be empty/, fn ->
      Config.new() |> Config.resolve(1, [], [:valid])
    end

    assert_raise ArgumentError, ~r/at least 2 examples/, fn ->
      Config.new() |> Config.resolve(1, [:only])
    end

    assert_raise ArgumentError, ~r/valset must have at least 1 example/, fn ->
      Config.new() |> Config.resolve(1, [:train], [])
    end
  end

  test "minibatch size cannot exceed the effective validation set" do
    assert_raise ArgumentError, ~r/minibatch_size cannot exceed valset size 2/, fn ->
      Config.new(auto: nil, num_candidates: 2, num_trials: 2)
      |> Config.resolve(1, [:train], [:a, :b])
    end
  end

  test "seeded auto validation sampling is deterministic" do
    valset = Enum.to_list(1..200)
    first = Config.new(seed: 42) |> Config.resolve(1, [:train], valset)
    again = Config.new(seed: 42) |> Config.resolve(1, [:train], valset)
    other = Config.new(seed: 43) |> Config.resolve(1, [:train], valset)

    assert first.valset == again.valset
    refute first.valset == other.valset
  end
end
