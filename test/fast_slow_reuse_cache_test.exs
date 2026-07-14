defmodule Imp.Training.FastSlow.ReuseCacheTest do
  use ExUnit.Case, async: true

  alias Imp.Training.FastSlow.{CachedTrajectory, Config, ReuseCache}

  test "claims exact problem-prompt tuples once and clears at the next cycle" do
    theta = digest("theta")
    first = trajectory(theta, output: %{"answer" => "a"})
    second = trajectory(theta, output: %{"answer" => "b"}, behavior_logprobs: [-0.3, -0.4])
    cache = ReuseCache.new!(0, theta, [second, first])
    assert cache |> ReuseCache.dump() |> ReuseCache.load!() == cache

    assert {:ok, claimed, cache} =
             ReuseCache.claim(cache, "problem-0", digest("input"), digest("prompt"))

    assert claimed.id == Enum.min([first.id, second.id])

    assert {:ok, _claimed, cache} =
             ReuseCache.claim(cache, "problem-0", digest("input"), digest("prompt"))

    assert :miss = ReuseCache.claim(cache, "problem-0", digest("input"), digest("prompt"))
    assert ReuseCache.next_cycle(cache, 1, digest("next")) == ReuseCache.new!(1, digest("next"))
  end

  test "valid-looking cache tampering fails its trajectory identity" do
    theta = digest("theta")
    dumped = ReuseCache.new!(0, theta, [trajectory(theta)]) |> ReuseCache.dump()
    tampered = put_in(dumped, ["entries", Access.at(0), "reward"], 0.0)

    assert_raise ArgumentError, ~r/identity is invalid/, fn -> ReuseCache.load!(tampered) end
  end

  test "requires exact policy generation and token-aligned old probabilities" do
    theta = digest("theta")

    assert_raise ArgumentError, ~r/policy generation/, fn ->
      ReuseCache.new!(1, theta, [trajectory(theta)])
    end

    assert_raise ArgumentError, ~r/trajectory is invalid/, fn ->
      trajectory(theta, response_mask: [1])
    end
  end

  test "different input or prompt identities never reuse a trajectory" do
    theta = digest("theta")
    cache = ReuseCache.new!(0, theta, [trajectory(theta)])

    assert :miss = ReuseCache.claim(cache, "problem-0", digest("other"), digest("prompt"))
    assert :miss = ReuseCache.claim(cache, "problem-0", digest("input"), digest("other"))
    assert length(ReuseCache.dump(cache)["entries"]) == 1
  end

  defp trajectory(theta, overrides \\ []) do
    defaults = [
      cycle: 0,
      theta_id: theta,
      problem_id: "problem-0",
      input_digest: digest("input"),
      prompt_digest: digest("prompt"),
      output: %{"answer" => "ok"},
      reward: 1.0,
      response_token_ids: [10, 11],
      response_mask: [1, 1],
      behavior_logprobs: [-0.1, -0.2]
    ]

    CachedTrajectory.new!(Keyword.merge(defaults, overrides))
  end

  defp digest(value), do: Config.digest(value)
end
