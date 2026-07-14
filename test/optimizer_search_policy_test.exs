defmodule Imp.Optimizer.SearchPolicyTest do
  use ExUnit.Case, async: true

  alias Imp.Optimizer.SearchPolicy
  alias Imp.Optimizer.SearchPolicy.{CategoricalTPE, Sampling}

  test "categorical policy resumes the exact suggestion sequence from JSON" do
    policy =
      SearchPolicy.new(CategoricalTPE,
        space: %{"main:instruction" => [0, 1, 2], "main:demos" => [0, 1]},
        seed: 71,
        startup_trials: 2,
        candidates: 8
      )
      |> SearchPolicy.observe(%{
        params: %{"main:instruction" => 0, "main:demos" => 0},
        score: 0.25
      })

    {_first, policy} = SearchPolicy.suggest(policy, :candidate)
    checkpoint = policy |> SearchPolicy.dump() |> Jason.encode!() |> Jason.decode!()
    restored = SearchPolicy.load!(checkpoint)

    {expected, expected_policy} = suggestions(policy, 12)
    {actual, actual_policy} = suggestions(restored, 12)

    assert actual == expected
    assert SearchPolicy.dump(actual_policy) == SearchPolicy.dump(expected_policy)
    assert Jason.encode!(SearchPolicy.dump(actual_policy))
  end

  test "sampling policy preserves one interleaved random stream across operation types" do
    policy = SearchPolicy.new(Sampling, seed: 19)
    {_chosen, policy} = SearchPolicy.suggest(policy, {:choose, [:demo, :rule]})
    {_source, policy} = SearchPolicy.suggest(policy, {:softmax, [{0, 0.2}, {1, 0.8}], 0.2})

    restored =
      policy |> SearchPolicy.dump() |> Jason.encode!() |> Jason.decode!() |> SearchPolicy.load!()

    continue = fn policy ->
      {order, policy} = SearchPolicy.suggest(policy, {:shuffle, Enum.to_list(0..9)})
      {index, policy} = SearchPolicy.suggest(policy, {:integer, 17})
      {strategy, policy} = SearchPolicy.suggest(policy, {:choose, [:demo, :rule]})
      {{order, index, strategy}, policy}
    end

    assert continue.(policy) == continue.(restored)
  end

  test "checkpoints fail closed for unknown policies and malformed categorical state" do
    assert_raise ArgumentError, ~r/unknown optimizer search policy/, fn ->
      SearchPolicy.load!(%{"schema_version" => 1, "policy" => "Elixir.System", "state" => %{}})
    end

    policy = SearchPolicy.new(CategoricalTPE, space: %{"choice" => [0, 1]}, seed: 2)
    checkpoint = SearchPolicy.dump(policy)

    malformed =
      put_in(checkpoint, ["state", "observations"], [%{"params" => %{}, "score" => 1.0}])

    assert_raise ArgumentError, ~r/keys do not match/, fn -> SearchPolicy.load!(malformed) end
  end

  test "MIPROv2 and SIMBA population expose restorable concrete policy state" do
    population = Imp.Optimizer.SIMBA.Population.new(:baseline, seed: 23)
    population = Imp.Optimizer.SIMBA.Population.register(population, :candidate, [1.0])
    {_source, population} = Imp.Optimizer.SIMBA.Population.select_source(population, 2, 0.2)

    checkpoint =
      population.policy |> SearchPolicy.dump() |> Jason.encode!() |> Jason.decode!()

    assert %SearchPolicy{module: Sampling} = SearchPolicy.load!(checkpoint)

    mipro =
      SearchPolicy.new(CategoricalTPE,
        space:
          Imp.Optimizer.MIPROv2.categorical_space(
            [%{name: :main}],
            %{main: ["base", "candidate"]},
            nil
          ),
        seed: 23
      )

    assert %SearchPolicy{module: CategoricalTPE} =
             mipro
             |> SearchPolicy.dump()
             |> Jason.encode!()
             |> Jason.decode!()
             |> SearchPolicy.load!()
  end

  defp suggestions(policy, count) do
    Enum.map_reduce(1..count, policy, fn _, policy ->
      {params, policy} = SearchPolicy.suggest(policy, :candidate)
      score = (params["main:instruction"] + params["main:demos"]) / 3
      {params, SearchPolicy.observe(policy, %{params: params, score: score})}
    end)
  end
end
