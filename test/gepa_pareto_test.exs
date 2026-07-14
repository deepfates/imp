defmodule Imp.Optimizer.GEPA.ParetoTest do
  use ExUnit.Case, async: true

  alias Imp.Optimizer.GEPA.Pareto

  test "builds per-instance winner sets instead of vector nondominance" do
    mapping =
      Pareto.winner_mapping([
        {:a, %{x: 1.0, y: 0.0}},
        {:b, %{x: 0.0, y: 1.0}},
        {:c, %{x: 0.5, y: 0.5}}
      ])

    assert mapping == %{x: MapSet.new([:a]), y: MapSet.new([:b])}
    assert Pareto.candidate_ids(mapping) == [:a, :b]
  end

  test "removes a candidate whose winner coverage is supplied by other candidates" do
    mapping = %{
      x: MapSet.new([:general, :x]),
      y: MapSet.new([:general, :y])
    }

    assert Pareto.remove_dominated(mapping, %{general: 0.5, x: 0.6, y: 0.7}) == %{
             x: MapSet.new([:x]),
             y: MapSet.new([:y])
           }
  end

  test "samples candidates in proportion to surviving winner-set coverage" do
    mapping = %{
      x: MapSet.new([:wide]),
      y: MapSet.new([:wide]),
      z: MapSet.new([:narrow])
    }

    rng = :rand.seed_s(:exsss, {8, 9, 10})

    {draws, _rng} =
      Enum.map_reduce(1..300, rng, fn _, rng -> Pareto.sample(mapping, %{}, rng) end)

    wide = Enum.count(draws, &(&1 == :wide))
    narrow = Enum.count(draws, &(&1 == :narrow))

    assert wide > narrow
    assert wide + narrow == 300
  end

  test "equal seeds produce equal selection sequences" do
    mapping = %{x: MapSet.new([:a]), y: MapSet.new([:b])}
    seed = fn -> :rand.seed_s(:exsss, {2, 3, 4}) end

    draw = fn rng ->
      Enum.map_reduce(1..20, rng, fn _, rng -> Pareto.sample(mapping, %{}, rng) end)
    end

    assert draw.(seed.()) == draw.(seed.())
  end
end
