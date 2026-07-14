defmodule RandomSearchPolicyTest do
  use ExUnit.Case, async: true

  alias Imp.Optimizer.RandomSearch
  alias Imp.Optimizer.Report
  alias Imp.Optimizer.SearchPolicy
  alias Imp.Optimizer.SearchPolicy.Sampling

  defp program do
    Imp.predict("question -> answer",
      lm: %{
        module: Imp.LM.Static,
        opts: [handler: fn _messages, _opts -> %{answer: "constant"} end]
      }
    )
  end

  defp trainset do
    Enum.map(1..12, fn index ->
      Imp.example(question: "question-#{index}", answer: "answer-#{index}")
      |> Imp.with_inputs(:question)
    end)
  end

  defp devset do
    [Imp.example(question: "dev", answer: "constant") |> Imp.with_inputs(:question)]
  end

  defp compile(seed) do
    optimizer =
      RandomSearch.new(Imp.Metrics.exact_match(:answer),
        candidates: 8,
        demos_per_candidate: 4,
        seed: seed
      )

    RandomSearch.compile(optimizer, program(), trainset(), devset())
  end

  defp sampled_demos(compiled) do
    compiled
    |> Report.fetch()
    |> Map.fetch!(:candidates)
    |> Enum.reject(&(&1.index == :baseline))
    |> Enum.map(fn candidate ->
      Enum.map(candidate.demos, &Imp.Example.get(&1, :question))
    end)
  end

  test "the same seed exactly replays candidates independently of process RNG" do
    :rand.seed(:exsss, {1, 2, 3})
    first = compile(812)

    :rand.seed(:exsss, {91_001, 72_002, 53_003})
    Enum.each(1..100, fn _ -> :rand.uniform() end)
    second = compile(812)

    assert sampled_demos(first) == sampled_demos(second)

    first_report = Report.fetch(first)
    second_report = Report.fetch(second)

    assert first_report.candidates == second_report.candidates
    assert first_report.metadata.search_policy == second_report.metadata.search_policy
    assert first_report.metadata.search_policy_id == "sampling"
    assert first_report.metadata.seed == 812
    assert Jason.encode!(first_report.metadata.search_policy)
  end

  test "different seeds change a sufficiently large candidate sample" do
    refute sampled_demos(compile(20)) == sampled_demos(compile(21))
  end

  test "the reported policy checkpoint loads and continues exactly" do
    report = compile(-17) |> Report.fetch()

    checkpoint =
      report.metadata.search_policy
      |> Jason.encode!()
      |> Jason.decode!()

    restored = SearchPolicy.load!(checkpoint)

    expected =
      Enum.reduce(1..8, SearchPolicy.new(Sampling, seed: -17), fn _candidate, policy ->
        {_shuffle, policy} = SearchPolicy.suggest(policy, {:shuffle, trainset()})
        policy
      end)

    {actual_shuffle, restored} = SearchPolicy.suggest(restored, {:shuffle, Enum.to_list(1..20)})
    {expected_shuffle, expected} = SearchPolicy.suggest(expected, {:shuffle, Enum.to_list(1..20)})

    assert actual_shuffle == expected_shuffle
    assert SearchPolicy.dump(restored) == SearchPolicy.dump(expected)
    assert report.metadata.seed == -17
  end

  test "seed must be an integer" do
    assert_raise ArgumentError, ~r/invalid value for :seed option: expected integer/, fn ->
      RandomSearch.new(Imp.Metrics.exact_match(:answer), seed: 1.5)
    end
  end
end
