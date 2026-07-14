defmodule Imp.Optimizer.SearchPrimitivesTest do
  use ExUnit.Case, async: true

  alias Imp.Optimizer.{CategoricalTPE, Sampling}

  test "seeded sampling is reproducible" do
    first = sample_sequence(17)
    assert first == sample_sequence(17)
    refute first == sample_sequence(18)
  end

  test "percentiles use linear interpolation" do
    assert_in_delta Sampling.percentile([0, 10, 20, 30], 10), 3.0, 1.0e-12
    assert_in_delta Sampling.percentile([0, 10, 20, 30], 90), 27.0, 1.0e-12
  end

  test "categorical TPE learns interacting parameters without mutable process state" do
    tpe =
      CategoricalTPE.new(%{instruction: [:weak, :strong], demos: [:bad, :good]},
        seed: 11,
        startup_trials: 4
      )

    tpe =
      Enum.reduce(1..40, tpe, fn _, tpe ->
        {params, tpe} = CategoricalTPE.suggest(tpe)
        score = if params == %{instruction: :strong, demos: :good}, do: 1.0, else: 0.0
        CategoricalTPE.observe(tpe, params, score)
      end)

    suggestions =
      Enum.map_reduce(1..20, tpe, fn _, tpe -> CategoricalTPE.suggest(tpe) end)
      |> elem(0)

    assert Enum.count(suggestions, &(&1 == %{instruction: :strong, demos: :good})) >= 12
  end

  test "joint kernels preserve interactions when every marginal is uninformative" do
    tpe =
      CategoricalTPE.new(%{left: [0, 1], right: [0, 1]},
        seed: 5,
        startup_trials: 0,
        candidates: 64,
        bandwidth: 0.05
      )
      |> CategoricalTPE.observe(%{left: 0, right: 0}, 1.0)
      |> CategoricalTPE.observe(%{left: 1, right: 1}, 1.0)
      |> CategoricalTPE.observe(%{left: 0, right: 1}, 0.0)
      |> CategoricalTPE.observe(%{left: 1, right: 0}, 0.0)

    {suggestion, _tpe} = CategoricalTPE.suggest(tpe)
    assert suggestion in [%{left: 0, right: 0}, %{left: 1, right: 1}]
  end

  test "categorical TPE rejects malformed spaces and observations" do
    assert_raise ArgumentError, ~r/has no choices/, fn ->
      CategoricalTPE.new(%{instruction: []})
    end

    tpe = CategoricalTPE.new(%{instruction: [:a]})

    assert_raise ArgumentError, ~r/keys do not match/, fn ->
      CategoricalTPE.observe(tpe, %{}, 1.0)
    end
  end

  defp sample_sequence(seed) do
    Enum.map_reduce(1..8, Sampling.new(seed), fn _, state -> Sampling.integer(1_000, state) end)
    |> elem(0)
  end
end
