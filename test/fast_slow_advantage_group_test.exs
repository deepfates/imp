defmodule DSEx.Training.FastSlow.AdvantageGroupTest do
  use ExUnit.Case, async: true

  alias DSEx.Training.FastSlow.{AdvantageGroup, Config, Rollout}

  test "normalizes one question-level group across all prompt populations" do
    rollouts = complete_group([0.0, 0.25, 0.75, 1.0])
    group = AdvantageGroup.new!(rollouts, "group-0", 0, 4, 2)

    assert group.mean_reward == 0.5
    assert_in_delta group.std_reward, :math.sqrt(0.15625), 1.0e-12
    assert Enum.map(group.members, & &1["prompt_index"]) == [0, 1, 0, 1]
    assert Enum.sum(Enum.map(group.members, & &1["advantage"])) |> abs() < 1.0e-10
    assert AdvantageGroup.dump(group)["problem_id"] == "problem-0"
  end

  test "zero-variance rewards produce zero advantages" do
    group = complete_group([0.5, 0.5, 0.5, 0.5]) |> AdvantageGroup.new!("group-0", 0, 4, 2)

    assert group.std_reward == 0.0
    assert Enum.all?(group.members, &(&1["advantage"] == 0.0))
  end

  test "rejects per-prompt fragments, out-of-range reward, and policy provenance drift" do
    rollouts = complete_group([0.0, 0.25, 0.75, 1.0])

    assert_raise ArgumentError, ~r/incomplete or inconsistent/, fn ->
      AdvantageGroup.new!(Enum.take(rollouts, 2), "group-0", 0, 4, 2)
    end

    claimed = rollout(0) |> Rollout.claim("claim") |> elem(1)

    assert_raise ArgumentError, ~r/between zero and one/, fn ->
      Rollout.complete!(claimed, "claim", %{"answer" => "x"}, 1.1, %{})
    end

    assert_raise ArgumentError, ~r/identity or state is invalid/, fn ->
      rollout(0, behavior_policy_id: String.duplicate("f", 64))
    end
  end

  defp complete_group(rewards) do
    rewards
    |> Enum.with_index()
    |> Enum.map(fn {reward, index} ->
      rollout = rollout(index)
      {:ok, rollout} = Rollout.claim(rollout, "claim-#{index}")
      Rollout.complete!(rollout, "claim-#{index}", %{"answer" => index}, reward, %{})
    end)
  end

  defp rollout(index, overrides \\ []) do
    theta_id = String.duplicate("a", 64)

    defaults = [
      cycle: 0,
      group_id: "group-0",
      problem_id: "problem-0",
      group_size: 4,
      member_index: index,
      prompt_index: rem(index, 2),
      theta_id: theta_id,
      prompt_revision: 1,
      dataset_indices: [0],
      input_digest: Config.digest(%{"problem" => 0}),
      behavior_policy_id: theta_id,
      sampling_config_digest: Config.digest(%{"temperature" => 0.7}),
      behavior_logprobs: [-0.1, -0.2]
    ]

    Rollout.new!(Keyword.merge(defaults, overrides))
  end
end
