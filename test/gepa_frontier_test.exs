defmodule Imp.Optimizer.GEPA.FrontierTest do
  use ExUnit.Case, async: true

  alias Imp.Optimizer.GEPA.{Frontier, Result}

  test "instance policy tracks complementary primary-score winners per example" do
    candidates = [
      {:a, result([1.0, 0.0])},
      {:b, result([0.0, 1.0])},
      {:dominated, result([0.5, 0.0])}
    ]

    assert Frontier.mapping(candidates, :instance) == %{
             {:instance, 0} => MapSet.new([:a]),
             {:instance, 1} => MapSet.new([:b])
           }

    assert Frontier.candidate_ids(candidates, :instance) == [:a, :b]
  end

  test "objective policy averages each reported objective across examples" do
    candidates = [
      {:balanced,
       result([0.1, 0.1], [
         %{quality: 0.8, safety: 0.6},
         %{quality: 0.6, safety: 1.0}
       ])},
      {:quality,
       result([0.9, 0.9], [
         %{quality: 1.0, safety: 0.3},
         %{quality: 0.8, safety: 0.5}
       ])}
    ]

    assert Frontier.mapping(candidates, :objective) == %{
             {:objective, :quality} => MapSet.new([:quality]),
             {:objective, :safety} => MapSet.new([:balanced])
           }

    assert Frontier.candidate_ids(candidates, :objective) == [:balanced, :quality]
  end

  test "objective means use only examples that report an objective" do
    candidates = [
      {:sparse, result([0.0, 0.0], [%{quality: 1.0}, %{}])},
      {:dense, result([0.0, 0.0], [%{quality: 0.8}, %{quality: 0.8}])}
    ]

    assert Frontier.candidate_ids(candidates, :objective) == [:sparse]
  end

  test "hybrid policy combines tagged primary and objective dimensions" do
    candidates = [
      {:primary, result([1.0, 0.0], [%{safety: 0.0}, %{safety: 0.0}])},
      {:objective, result([0.5, 0.5], [%{safety: 1.0}, %{safety: 1.0}])}
    ]

    assert Frontier.mapping(candidates, :hybrid) == %{
             {:instance, 0} => MapSet.new([:primary]),
             {:instance, 1} => MapSet.new([:objective]),
             {:objective, :safety} => MapSet.new([:objective])
           }

    assert Frontier.candidate_ids(candidates, :hybrid) == [:objective, :primary]
  end

  test "hybrid policy requires objectives just like upstream state initialization" do
    candidates = [
      {:left, result([1.0, 0.0])},
      {:right, result([0.0, 1.0])}
    ]

    assert_raise ArgumentError, ~r/requires objective scores for candidate :left/, fn ->
      Frontier.mapping(candidates, :hybrid)
    end
  end

  test "cartesian policy preserves per-example objective specialists" do
    candidates = [
      {:specialist, result([0.0, 0.0], [%{quality: 1.0}, %{quality: 0.0}])},
      {:generalist, result([0.0, 0.0], [%{quality: 0.6}, %{quality: 0.6}])}
    ]

    assert Frontier.candidate_ids(candidates, :objective) == [:generalist]

    assert Frontier.mapping(candidates, :cartesian) == %{
             {:cartesian, 0, :quality} => MapSet.new([:specialist]),
             {:cartesian, 1, :quality} => MapSet.new([:generalist])
           }

    assert Frontier.candidate_ids(candidates, :cartesian) == [:generalist, :specialist]
  end

  test "frontier keys preserve evaluation-policy validation identities" do
    result =
      Result.new([nil, nil], [0.2, 0.8],
        objective_scores: [%{quality: 0.3}, %{quality: 0.9}],
        metadata: %{validation_ids: [4, 9]}
      )

    assert Frontier.mapping([{:candidate, result}], :instance) == %{
             {:instance, 4} => MapSet.new([:candidate]),
             {:instance, 9} => MapSet.new([:candidate])
           }

    assert Map.keys(Frontier.mapping([{:candidate, result}], :cartesian)) |> Enum.sort() == [
             {:cartesian, 4, :quality},
             {:cartesian, 9, :quality}
           ]
  end

  test "ties and sampling are deterministic" do
    candidates = [
      {"z", result([1.0, 0.0])},
      {"a", result([1.0, 1.0])}
    ]

    assert Frontier.candidate_ids(candidates, :instance) == ["a"]

    seed = fn -> :rand.seed_s(:exsss, {4, 5, 6}) end

    draw = fn rng ->
      Enum.map_reduce(1..20, rng, fn _, rng ->
        Frontier.sample(candidates, :instance, rng)
      end)
    end

    assert draw.(seed.()) == draw.(seed.())
  end

  test "empty candidates produce an empty frontier and sampling remains explicit" do
    assert Frontier.mapping([], :instance) == %{}
    assert Frontier.candidate_ids([], :instance) == []

    assert_raise ArgumentError, "cannot sample from an empty GEPA Pareto frontier", fn ->
      Frontier.sample([], :instance, :rand.seed_s(:exsss, {1, 2, 3}))
    end
  end

  test "rejects unknown policies and malformed candidate collections" do
    assert_raise ArgumentError, ~r/GEPA frontier policy must be one of/, fn ->
      Frontier.mapping([], :unknown)
    end

    assert_raise ArgumentError, ~r/must be a list/, fn ->
      Frontier.mapping(%{}, :instance)
    end

    assert_raise ArgumentError, ~r/must be \{candidate_id, %Result\{\}\} tuples/, fn ->
      Frontier.mapping([{:candidate, %{scores: [1.0]}}], :instance)
    end
  end

  test "rejects duplicate IDs and allows sparse policy-selected score sets" do
    assert_raise ArgumentError, "GEPA frontier candidate IDs must be unique", fn ->
      Frontier.mapping([{:same, result([1.0])}, {:same, result([0.0])}], :instance)
    end

    assert Frontier.mapping(
             [
               {:full, result([1.0, 0.0])},
               {:short, Result.new([nil], [1.0], metadata: %{validation_ids: [9]})}
             ],
             :instance
           ) == %{
             {:instance, 0} => MapSet.new([:full]),
             {:instance, 1} => MapSet.new([:full]),
             {:instance, 9} => MapSet.new([:short])
           }
  end

  test "rejects malformed primary scores and aggregate scores" do
    non_numeric = %Result{outputs: [], scores: [:bad], aggregate_score: 0.0}
    non_numeric_aggregate = %Result{outputs: [], scores: [1.0], aggregate_score: :bad}

    assert_raise ArgumentError, ~r/must have a numeric scores list/, fn ->
      Frontier.mapping([{:bad, non_numeric}], :instance)
    end

    assert_raise ArgumentError, ~r/must have a numeric aggregate score/, fn ->
      Frontier.mapping([{:bad, non_numeric_aggregate}], :instance)
    end
  end

  test "objective policies require aligned, named numeric objective scores" do
    assert_raise ArgumentError, ~r/requires objective scores for candidate :missing/, fn ->
      Frontier.mapping([{:missing, result([1.0])}], :objective)
    end

    unaligned = result([1.0, 0.0], [%{quality: 1.0}])

    assert_raise ArgumentError, ~r/objective scores must align with its scores/, fn ->
      Frontier.mapping([{:unaligned, unaligned}], :hybrid)
    end

    invalid = result([1.0], [%{123 => :high}])

    assert_raise ArgumentError, ~r/maps with atom or string names and numeric values/, fn ->
      Frontier.mapping([{:invalid, invalid}], :cartesian)
    end
  end

  test "objective policies reject candidates without any reported objective" do
    assert Frontier.mapping([{:empty, result([1.0], [%{}])}], :objective) == %{}
  end

  defp result(scores, objective_scores \\ nil) do
    Result.new(List.duplicate(nil, length(scores)), scores, objective_scores: objective_scores)
  end
end
