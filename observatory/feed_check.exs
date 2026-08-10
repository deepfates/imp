# Acceptance driver for Observatory.Feed / Observatory.Replay (CONTRACT.md).
# Run: elixir observatory/feed_check.exs [run_root]

Mix.install([{:jason, "~> 1.4"}])

Code.require_file("feed.exs", __DIR__)

defmodule FeedCheck do
  def run(run_root) do
    IO.puts("== feed_check: #{run_root} ==\n")

    {:ok, feed} = Observatory.Feed.start_link(run_root: run_root)
    # let two poll cycles land
    Process.sleep(2_200)

    state = Observatory.Feed.state(feed)
    summarize(state)

    checks = [
      {"18 cells sealed", length(state.cells) == 18},
      {"imp peer complete", state.peers["imp"].phase == "complete"},
      {"upstream peer complete", state.peers["upstream"].phase == "complete"},
      {"overall status :complete", state.status == :complete},
      {">=24 imp trials with numeric scores",
       Enum.count(state.trials, &(&1.runtime == "imp" and is_number(&1.score))) >= 24}
    ]

    IO.puts("\nchecks:")

    for {name, ok?} <- checks do
      IO.puts("  [#{if ok?, do: "PASS", else: "FAIL"}] #{name}")
    end

    unless Enum.all?(checks, fn {_, ok?} -> ok? end) do
      IO.puts("\nfeed_check FAILED")
      System.halt(1)
    end

    IO.puts("\n== replay at 120x ==")
    {:ok, replay} = Observatory.Replay.start(feed, speed: 120, run_root: run_root)

    growth =
      for {delay_ms, i} <- Enum.with_index([4_000, 10_000, 16_000], 1) do
        Process.sleep(delay_ms - if(i == 1, do: 0, else: Enum.at([4_000, 10_000], i - 2)))
        s = Observatory.Feed.state(feed)
        n_cells = length(s.cells)
        n_trials = length(s.trials)

        IO.puts(
          "snapshot #{i} (t+#{div(delay_ms, 1000)}s real / ~#{div(delay_ms * 120, 1000)}s replay): " <>
            "status=#{s.status} cells=#{n_cells}/18 trials=#{n_trials} " <>
            "imp=#{inspect(s.peers["imp"].phase)} upstream=#{inspect(s.peers["upstream"].phase)}"
        )

        {n_cells, n_trials}
      end

    Observatory.Replay.stop(replay)

    growing? =
      growth == Enum.sort(growth) and List.first(growth) != List.last(growth)

    IO.puts("  [#{if growing?, do: "PASS", else: "FAIL"}] cells/trials grow over replay time")

    if growing? do
      IO.puts("\nfeed_check PASSED")
    else
      IO.puts("\nfeed_check FAILED")
      System.halt(1)
    end
  end

  defp summarize(state) do
    imp_trials = Enum.filter(state.trials, &(&1.runtime == "imp" and is_number(&1.score)))

    IO.puts("status:      #{state.status}")

    for rt <- ["imp", "upstream"] do
      p = state.peers[rt]
      IO.puts("peer #{String.pad_trailing(rt, 9)} alive=#{p.alive} phase=#{inspect(p.phase)}")
    end

    IO.puts("cells:       #{length(state.cells)} sealed")

    for rt <- ["imp", "upstream"] do
      means =
        for c <- state.cells, c.runtime == rt, is_number(c.selection_mean), do: c.selection_mean

      IO.puts(
        "  #{String.pad_trailing(rt, 9)} #{length(means)} cells, selection means " <>
          "#{Float.round(Enum.min(means), 3)}..#{Float.round(Enum.max(means), 3)}"
      )
    end

    IO.puts("trials:      #{length(state.trials)} total, #{length(imp_trials)} imp with scores")

    by_arm = Enum.group_by(imp_trials, & &1.arm)

    for {arm, ts} <- Enum.sort(by_arm) do
      scores = Enum.map(ts, & &1.score)

      IO.puts(
        "  #{String.pad_trailing(arm, 9)} #{length(ts)} trials, scores " <>
          "#{Float.round(Enum.min(scores), 3)}..#{Float.round(Enum.max(scores), 3)}"
      )
    end

    IO.puts("events:      #{length(state.events)} (newest: #{inspect(List.first(state.events)[:text])})")
    IO.puts("spend_usd:   #{inspect(state.spend_usd)}")
  end
end

default_root =
  Path.expand("../tmp/matched_gepa_mipro_ifbench_gepa014", __DIR__)

FeedCheck.run(Enum.at(System.argv(), 0) || default_root)
