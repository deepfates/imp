defmodule DSEx.Optimizer.SIMBA.StatePrimitivesTest do
  use ExUnit.Case, async: true

  alias DSEx.Optimizer.SIMBA.{Buckets, Population}

  test "finalist selection follows Python half-even rounding" do
    assert DSEx.Optimizer.SIMBA.finalist_indices(6, 4) == [0, 2, 3, 4, 6]
    assert DSEx.Optimizer.SIMBA.finalist_indices(0, 6) == [0]
  end

  test "rollout, rule, and eviction plans expose the production invariants" do
    assert DSEx.Optimizer.SIMBA.rollout_id_plan(7, 3, true) == [
             %{rollout_id: 7, teacher?: true, force_temperature?: false},
             %{rollout_id: 8, teacher?: false, force_temperature?: true},
             %{rollout_id: 9, teacher?: false, force_temperature?: true}
           ]

    assert DSEx.Optimizer.SIMBA.rule_disposition(0.2, 0.2, 0.2, 0.8) == :skip
    assert DSEx.Optimizer.SIMBA.rule_disposition(0.5, 0.5, 0.2, 0.8) == :suppress_good

    assert DSEx.Optimizer.SIMBA.eviction_parameters(4, 4) == %{
             demo_count: 4,
             poisson_mean: 1.0,
             poisson_denominator: 4,
             minimum_drop_count: 1,
             sample_with_replacement?: true,
             shared_indices_across_predictors?: true
           }
  end

  test "buckets trajectories by example and applies DSPy's lexicographic ranking" do
    trajectories = [
      %{example: :first, score: 1.0, output: :low},
      %{example: :second, score: 4.0, output: :high},
      %{example: :third, score: 5.0, output: :high},
      %{example: :first, score: 5.0, output: :high},
      %{example: :second, score: 0.0, output: :low},
      %{example: :third, score: 1.0, output: :low},
      %{example: :first, score: 4.0, output: :middle},
      %{example: :third, score: 1.0, output: :middle}
    ]

    buckets = Buckets.rank(trajectories)

    assert Enum.map(buckets, & &1.example) == [:third, :first, :second]
    assert Enum.map(hd(buckets).trajectories, & &1.score) == [5.0, 1.0, 1.0]
    assert hd(buckets).rank == {4.0, 5.0, 8.0 / 3}
  end

  test "computes batch 10th and 90th percentiles with linear interpolation" do
    trajectories = Enum.map([0, 10, 20, 30], &%{"example" => &1, "score" => &1})

    {p10, p90} = Buckets.batch_percentiles(trajectories)
    assert_in_delta p10, 3.0, 1.0e-12
    assert_in_delta p90, 27.0, 1.0e-12

    analysis = Buckets.analyze(trajectories)
    assert_in_delta analysis.batch_10th_percentile_score, 3.0, 1.0e-12
    assert_in_delta analysis.batch_90th_percentile_score, 27.0, 1.0e-12
  end

  test "population retains baseline and registers every candidate with score histories" do
    population = Population.new(:baseline, seed: 19)
    population = Population.record_scores(population, 0, [0.8, 0.6])
    {worse_id, population} = Population.register_with_id(population, :worse, [0.1, 0.2])
    {better_id, population} = Population.register_with_id(population, :better, [0.9, 1.0])

    assert worse_id == 1
    assert better_id == 2
    assert population.program_ids == [0, 1, 2]
    assert Population.scores(population, worse_id) == [0.1, 0.2]
    assert_in_delta Population.average_score(population, 0), 0.7, 1.0e-12
    assert Population.top_k_plus_baseline(population, 2) == [2, 0]
  end

  test "source selection is seeded, stable for large scores, and advances immutable RNG" do
    build_population = fn ->
      Population.new(:baseline, seed: 7)
      |> Population.record_scores(0, [10_000.0])
      |> Population.register(:peer, [10_000.0])
    end

    sample = fn population ->
      Enum.map_reduce(1..8, population, fn _, population ->
        Population.select_source(population, 2, 0.2)
      end)
    end

    {first_ids, first_population} = sample.(build_population.())
    {second_ids, second_population} = sample.(build_population.())

    assert first_ids == second_ids
    assert first_population.rng == second_population.rng
    assert Enum.all?(first_ids, &(&1 in [0, 1]))
  end

  test "reflection accepts partial module advice and serializes upstream-shaped inputs" do
    parent = self()

    prompt_lm = %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn messages, _opts ->
          send(parent, {:reflection_messages, messages})

          %{
            discussion: "Only the first module needs a change.",
            module_advice: %{first: "Be precise."}
          }
        end
      ]
    }

    payload = %{
      program_code: "Program module: Example.Program",
      modules_defn: "Module first\nModule second",
      program_inputs: %{question: "q"},
      oracle_metadata: %{answer: "a"},
      worse_program_trajectory: [],
      worse_program_outputs: %{answer: "wrong"},
      worse_reward_value: 0.0,
      worse_reward_info: %{},
      better_program_trajectory: [
        %{module_name: :first, inputs: %{question: "q"}, outputs: %{answer: "a"}}
      ],
      better_program_outputs: %{answer: "a"},
      better_reward_value: 1.0,
      better_reward_info: %{},
      module_names: [:first, :second]
    }

    assert {:ok, %{first: "Be precise."}, "Only the first module needs a change."} =
             DSEx.Optimizer.SIMBA.Reflection.run(prompt_lm, payload)

    assert_receive {:reflection_messages, messages}
    prompt = Enum.map_join(messages, "\n", & &1.content)
    assert prompt =~ "program_code"
    assert prompt =~ "modules_defn"
    assert prompt =~ ~s(\"module_name\": \"first\")
    assert prompt =~ ~s([\n  \"first\",\n  \"second\"\n])
  end
end
