# Observatory.Feed — data half of the observatory v2 contract (see CONTRACT.md).
# Plain GenServer, no deps beyond Jason (assumed available via host Mix.install).
#
# Merges: run_root/sealed/*.json (cells + imp trial reports, __imp_type__
# decoded), {imp,upstream}-result.json (terminal status + spend), and an
# optional coordinator log tailed incrementally (position remembered,
# truncation/rotation resets).
#
# Also Observatory.Replay: replays a completed run's sealed timeline into a
# Feed as synthetic updates at `speed`x for live UI demos.

defmodule Observatory.Feed do
  use GenServer

  @poll_ms 1_000
  @event_cap 200

  # -- public API --------------------------------------------------------------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Cheap read of the merged state map (see CONTRACT.md for shape)."
  def state(pid), do: GenServer.call(pid, :state)

  @doc false
  # Replay support: put the feed in replay mode (polling suspended) and set
  # the whole public state synthetically. Used by Observatory.Replay.
  def replay_set(pid, public_state), do: GenServer.cast(pid, {:replay_set, public_state})

  @doc false
  def replay_release(pid), do: GenServer.cast(pid, :replay_release)

  # -- GenServer ---------------------------------------------------------------

  @impl true
  def init(opts) do
    run_root = Keyword.fetch!(opts, :run_root)
    log_path = Keyword.get(opts, :log_path)

    state = %{
      run_root: run_root,
      log_path: log_path,
      log_pos: 0,
      log_partial: "",
      replay: nil,
      # first poll swallows the whole existing log: chart points are kept, but
      # historical lines must NOT become events stamped with the current clock
      # (a restart would re-announce old failures as if they just happened)
      primed: false,
      known_cells: MapSet.new(),
      public: empty_public()
    }

    {:ok, poll(state), {:continue, :schedule}}
  end

  @impl true
  def handle_continue(:schedule, state) do
    Process.send_after(self(), :poll, @poll_ms)
    {:noreply, state}
  end

  @impl true
  def handle_call(:state, _from, state) do
    {:reply, current_public(state), state}
  end

  @impl true
  def handle_cast({:replay_set, public}, state) do
    {:noreply, %{state | replay: public}}
  end

  def handle_cast(:replay_release, state) do
    {:noreply, %{state | replay: nil}}
  end

  @impl true
  def handle_info(:poll, state) do
    Process.send_after(self(), :poll, @poll_ms)
    # keep polling the real root even in replay mode so releasing snaps back
    {:noreply, poll(state)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp current_public(%{replay: replay, public: public}), do: replay || public

  defp empty_public do
    %{
      status: :idle,
      peers: %{"imp" => empty_peer(), "upstream" => empty_peer()},
      trials: [],
      events: [],
      cells: [],
      spend_usd: nil,
      arm_summaries: [],
      optimizer_points: [],
      updated_at: System.os_time(:second)
    }
  end

  defp empty_peer, do: %{alive: false, phase: nil, progress: nil, last_line_at: nil}

  # -- polling -----------------------------------------------------------------

  defp poll(state) do
    now = System.os_time(:second)

    {cells, trials, seal_events, known_cells} = scan_sealed(state)
    results = read_results(state.run_root)
    {log_events, log_peers, log_points, log_pos, log_partial} = tail_log(state)
    log_events = if state.primed, do: log_events, else: []
    live = read_live(state.run_root)

    prev = state.public

    events =
      (Enum.reverse(seal_events) ++ Enum.reverse(log_events) ++ prev.events)
      |> Enum.take(@event_cap)

    peers =
      prev.peers
      |> merge_peers(log_peers, results, now)
      |> merge_live_peers(live, now)

    public = %{
      status: overall_status(results, cells, peers),
      peers: peers,
      trials: trials,
      events: events,
      cells: cells,
      spend_usd:
        results
        |> Map.values()
        |> Enum.map(fn r -> r && r.spend end)
        |> sum_or_nil()
        |> case do
          # no terminal results yet: sum the runners' live snapshots
          nil -> live |> Map.values() |> Enum.map(& &1["actual_cost"]) |> sum_or_nil()
          terminal -> terminal
        end,
      arm_summaries:
        results
        |> Map.values()
        |> Enum.flat_map(fn r -> (r && Map.get(r, :arm_summaries)) || [] end),
      optimizer_points:
        (Map.get(prev, :optimizer_points, []) ++ log_points) |> Enum.take(-800),
      updated_at: now
    }

    %{
      state
      | public: public,
        primed: true,
        known_cells: known_cells,
        log_pos: log_pos,
        log_partial: log_partial
    }
  end

  # -- live runner snapshots (run_root/live/*.json, written by the runners) ----

  defp read_live(run_root) do
    for runtime <- ["imp", "upstream"],
        path = Path.join([run_root, "live", "#{runtime}.json"]),
        {:ok, body} <- [File.read(path)],
        {:ok, decoded} <- [Jason.decode(body)],
        into: %{} do
      {runtime, decoded}
    end
  end

  # A fresh live snapshot is authoritative for a runner's phase and progress
  # (the imp runner logs nothing, so this is its ONLY live signal). Progress =
  # the current arm's used vs ceiling logical calls.
  defp merge_live_peers(peers, live, now) do
    Enum.reduce(live, peers, fn {runtime, snap}, acc ->
      age = now - (snap["updated_at"] || 0)
      phase = snap["phase"]

      existing = Map.get(acc, runtime)

      # upstream's tqdm-derived progress (rollouts) is finer than call counts;
      # only let the snapshot take over when the log signal is stale
      log_signal_fresh? =
        runtime == "upstream" and is_map(existing) and existing.progress != nil and
          is_integer(existing.last_line_at) and now - existing.last_line_at < 60

      if age > 45 or not is_map(phase) or log_signal_fresh? do
        acc
      else
        arm = phase["arm"]
        budget = snap["call_budgets"]["#{phase["seed"]}/#{arm}"]

        progress =
          with %{"counts" => counts, "ceiling" => ceiling} <- budget,
               used when is_integer(used) <- counts["total_logical"],
               total when is_integer(total) and total > 0 <- ceiling["total_logical"] do
            {used, total}
          else
            _ -> nil
          end

        label =
          [arm, phase["phase"]]
          |> Enum.reject(&is_nil/1)
          |> Enum.join(" / ")

        Map.update(
          acc,
          runtime,
          %{alive: true, phase: label, progress: progress, last_line_at: now},
          &%{&1 | alive: true, phase: label, progress: progress, last_line_at: now}
        )
      end
    end)
  end

  defp sum_or_nil(vals) do
    case Enum.filter(vals, &is_number/1) do
      [] -> nil
      nums -> Enum.sum(nums)
    end
  end

  # -- sealed cells ------------------------------------------------------------

  defp scan_sealed(state) do
    dir = Path.join(state.run_root, "sealed")
    now = System.os_time(:second)

    files =
      case File.ls(dir) do
        {:ok, fs} -> fs |> Enum.filter(&String.ends_with?(&1, ".json")) |> Enum.sort()
        _ -> []
      end

    cells =
      for f <- files,
          [_, runtime, seed, arm] <- [Regex.run(~r/^(imp|upstream)-(\d+)-(\w+)\.json$/, f)],
          cell = parse_cell(Path.join(dir, f), runtime, seed, arm),
          cell != nil do
        cell
      end
      |> Enum.sort_by(& &1.mtime)

    known = state.known_cells

    seal_events =
      for c <- cells, not MapSet.member?(known, cell_key(c)) do
        %{
          at: c.mtime || now,
          runtime: c.runtime,
          kind: :seal,
          text: "sealed #{c.runtime} #{c.seed}/#{c.arm}" <>
                  if(is_number(c.selection_mean),
                    do: " (mean #{Float.round(c.selection_mean * 1.0, 4)})",
                    else: "")
        }
      end

    trials =
      cells
      |> Enum.flat_map(&cell_trials/1)

    {cells, trials, seal_events, MapSet.new(cells, &cell_key/1)}
  end

  defp cell_key(c), do: {c.runtime, c.seed, c.arm}

  defp parse_cell(path, runtime, seed, arm) do
    with {:ok, body} <- File.read(path),
         {:ok, mtime} <- file_mtime(path),
         {:ok, decoded} <- Jason.decode(body) do
      decoded = decode_imp(decoded)
      {mean, trial_scores} = cell_scores(decoded, runtime)

      %{
        runtime: runtime,
        seed: seed,
        arm: arm,
        mtime: mtime,
        selection_mean: mean,
        trial_scores: trial_scores
      }
    else
      _ -> nil
    end
  end

  defp file_mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: m}} -> {:ok, m}
      err -> err
    end
  end

  defp cell_scores(%{"selection" => sel}, "upstream") do
    {sel["mean_constraint_score"], nil}
  end

  defp cell_scores(%{"payload" => payload}, "imp") do
    champ = get_in(payload, ["candidates", payload["champion_id"]]) || %{}
    report = champ["report"] || %{}

    trial_scores =
      case report["candidates"] do
        cands when is_list(cands) and cands != [] ->
          for c <- cands, is_number(c["score"]), do: c["score"] * 1.0

        _ ->
          nil
      end

    {champ["score"], trial_scores}
  end

  defp cell_scores(_, _), do: {nil, nil}

  # imp cells carry full per-trial reports; expand them into trial() entries.
  defp cell_trials(%{runtime: "imp", trial_scores: scores} = c) when is_list(scores) do
    scores
    |> Enum.with_index(1)
    |> Enum.map(fn {score, idx} ->
      %{runtime: "imp", seed: c.seed, arm: c.arm, trial: idx, score: score}
    end)
  end

  defp cell_trials(_), do: []

  # -- terminal results --------------------------------------------------------

  defp read_results(run_root) do
    for runtime <- ["imp", "upstream"], into: %{} do
      path = Path.join(run_root, "#{runtime}-result.json")

      value =
        with {:ok, body} <- File.read(path),
             {:ok, decoded} <- Jason.decode(body) do
          decoded = decode_imp(decoded)

          %{
            status: decoded["status"],
            spend: result_spend(decoded),
            arm_summaries: arm_summaries(decoded, runtime)
          }
        else
          _ -> nil
        end

      {runtime, value}
    end
  end

  # Per (seed, arm) analytic summary for the insight panels: split means,
  # zero decomposition (parse error / truncated / genuine constraint fail),
  # and - imp side - the trial ledger's champion + baseline objective.
  defp arm_summaries(decoded, runtime) do
    for seed_entry <- List.wrap(decoded["seeds"]),
        is_map(seed_entry),
        arm <- List.wrap(seed_entry["arms"]),
        is_map(arm) do
      rows = arm["rows"] || %{}

      %{
        runtime: runtime,
        seed: to_string(seed_entry["seed"]),
        arm: arm["arm"] || arm["name"],
        selection: split_stats(rows["selection"]),
        held_out: split_stats(rows["held_out"])
      }
    end
  end

  defp split_stats(rows) when is_list(rows) and rows != [] do
    scores = for r <- rows, is_number(r["score"]), do: r["score"]

    zeros =
      for r <- rows, r["score"] == 0.0 or r["score"] == 0 do
        cond do
          r["error"] not in [nil, false] -> :parse
          "length" in List.wrap(r["finish_reason"]) -> :trunc
          is_list(r["output_tokens"]) and Enum.any?(r["output_tokens"], &(is_integer(&1) and &1 >= 1024)) -> :trunc
          true -> :fail
        end
      end

    %{
      mean: if(scores != [], do: Enum.sum(scores) / length(scores)),
      n: length(rows),
      zeros: Enum.frequencies(zeros),
      ones: Enum.count(scores, &(&1 == 1.0))
    }
  end

  defp split_stats(_), do: nil

  defp result_spend(decoded) do
    costs =
      for seed_entry <- List.wrap(decoded["seeds"]),
          is_map(seed_entry),
          arm <- List.wrap(seed_entry["arms"]),
          is_map(arm),
          {_split, rows} <- Map.to_list(arm["rows"] || %{}),
          is_list(rows),
          row <- rows,
          is_map(row),
          c <- List.wrap(row["gateway_reported_cost"] || row["adapter_computed_cost"]),
          is_number(c) do
        c
      end

    case costs do
      [] -> nil
      cs -> Enum.sum(cs)
    end
  end

  defp merge_peers(prev_peers, log_peers, results, _now) do
    for runtime <- ["imp", "upstream"], into: %{} do
      prev = prev_peers[runtime] || empty_peer()
      from_log = log_peers[runtime] || %{}
      result = results[runtime]

      peer =
        prev
        |> Map.merge(from_log)
        |> then(fn p ->
          case result do
            %{status: "complete"} -> %{p | alive: false, phase: "complete", progress: nil}
            %{status: s} when is_binary(s) -> %{p | alive: false, phase: s}
            _ -> p
          end
        end)

      {runtime, peer}
    end
  end

  defp overall_status(results, cells, peers) do
    statuses = for {_rt, %{status: s}} <- results, do: s

    cond do
      statuses != [] and Enum.all?(["imp", "upstream"], &match?(%{status: "complete"}, results[&1])) ->
        :complete

      Enum.any?(statuses, &(&1 in ["stopped", "error", "failed"])) ->
        :stopped

      cells != [] or Enum.any?(peers, fn {_rt, p} -> p.alive end) ->
        :running

      true ->
        :idle
    end
  end

  # -- log tailing -------------------------------------------------------------
  # Remember byte position; on truncation/rotation (size < pos) reset to 0.

  defp tail_log(%{log_path: nil} = state), do: {[], %{}, [], state.log_pos, state.log_partial}

  defp tail_log(%{log_path: path, log_pos: pos, log_partial: partial}) do
    case File.stat(path) do
      {:ok, %{size: size}} ->
        pos = if size < pos, do: 0, else: pos

        case read_from(path, pos, size) do
          {:ok, chunk, new_pos} ->
            {lines, new_partial} = split_lines(partial <> chunk)
            {events, peers, points} = parse_log_lines(lines)
            {events, peers, points, new_pos, new_partial}

          _ ->
            {[], %{}, [], pos, partial}
        end

      _ ->
        {[], %{}, [], 0, ""}
    end
  end

  defp read_from(_path, pos, size) when size <= pos, do: {:ok, "", pos}

  defp read_from(path, pos, size) do
    case :file.open(path, [:read, :binary]) do
      {:ok, io} ->
        result =
          case :file.pread(io, pos, size - pos) do
            {:ok, data} -> {:ok, data, size}
            _ -> :error
          end

        :file.close(io)
        result

      _ ->
        :error
    end
  end

  defp split_lines(data) do
    parts = String.split(data, "\n")
    {complete, [last]} = Enum.split(parts, -1)
    # tqdm rewrites lines with \r; take the last carriage-return segment
    complete =
      complete
      |> Enum.map(fn line -> line |> String.split("\r") |> List.last() end)
      |> Enum.reject(&(&1 == ""))

    # a trailing partial line may still contain finished \r segments (tqdm)
    {cr_done, last} =
      case String.split(last, "\r") do
        [only] -> {[], only}
        segs -> {Enum.slice(segs, 0..-2//1) |> Enum.reject(&(&1 == "")), List.last(segs)}
      end

    {complete ++ cr_done, last}
  end

  @tqdm_re ~r/^(?<label>.+?):\s+(?<pct>\d+)%\|.*\|\s*(?<done>\d+)\/(?<total>\d+)/
  @logger_re ~r/\[(?<level>debug|info|warning|error)\]\s*(?<text>.*)$/
  @refusal_re ~r/can[’']t help|cannot help|refus/iu
  # dspy full-eval lines, e.g. "Average Metric: 26.83 / 32 (83.9%)" — every
  # optimizer candidate evaluation emits one; the percentage is the 0..1 score.
  @eval_re ~r/Average Metric: [\d.]+ \/ \d+ \((?<pct>[\d.]+)%\)/
  # GEPA's running champion, already 0..1: "Best score on valset: 0.8385"
  @best_re ~r/Best score on valset: (?<score>[\d.]+)/

  defp parse_log_lines(lines) do
    now = System.os_time(:second)

    Enum.reduce(lines, {[], %{}, []}, fn line, {events, peers, points} ->
      cond do
        captures = Regex.named_captures(@tqdm_re, line) ->
          # tqdm progress lines come from the upstream (python) worker
          done = String.to_integer(captures["done"])
          total = String.to_integer(captures["total"])
          phase = String.trim(captures["label"])

          peers =
            Map.update(
              peers,
              "upstream",
              %{alive: true, phase: phase, progress: {done, total}, last_line_at: now},
              &Map.merge(&1, %{alive: true, phase: phase, progress: {done, total}, last_line_at: now})
            )

          {events, peers, points}

        captures = Regex.named_captures(@logger_re, line) ->
          # Elixir Logger lines come from the imp worker
          text = String.trim(captures["text"])

          kind =
            cond do
              Regex.match?(@refusal_re, text) -> :refusal
              String.contains?(text, "truncat") -> :truncation
              captures["level"] == "error" -> :error
              captures["level"] == "warning" -> :warning
              true -> :info
            end

          peers =
            Map.update(
              peers,
              "imp",
              %{alive: true, last_line_at: now},
              &Map.merge(&1, %{alive: true, last_line_at: now})
            )

          events =
            if kind == :info and captures["level"] in ["debug", "info"] and not phase_line?(text) do
              events
            else
              [%{at: now, runtime: "imp", kind: kind, text: String.slice(text, 0, 200)} | events]
            end

          events = maybe_phase(events, peers, text)
          {events, peers, points}

        captures = Regex.named_captures(@best_re, line) ->
          point = %{at: now, runtime: "upstream", kind: :best,
                    score: String.to_float(captures["score"])}
          {events, peers, points ++ [point]}

        captures = Regex.named_captures(@eval_re, line) ->
          {pct, _} = Float.parse(captures["pct"])
          point = %{at: now, runtime: "upstream", kind: :eval, score: pct / 100.0}
          {events, peers, points ++ [point]}

        # Absorbed row-level failures: upstream's failure-preserving adapter
        # scores refusal/unparseable rows 0 and CONTINUES (max_errors
        # tolerance, by design). dspy logs a traceback per absorbed row, so
        # raw tracebacks would paint a healthy run red. Classify the known
        # tolerated shapes amber (:truncation renders warn); reserve :error
        # for lines outside that family (potentially fatal).
        # One absorbed row produces several matching traceback lines; emit only
        # the exception-message line ("...AdapterParseError: Adapter ...") so a
        # single tolerated failure reads as a single event.
        String.contains?(line, "AdapterParseError: ") or
            String.contains?(line, "dspy.utils.parallelizer: Error for Example") ->
          {[%{at: now, runtime: "upstream", kind: :truncation,
              text: "tolerated row failure (scored 0): " <> String.slice(line, 0, 140)} | events],
           peers, points}

        String.contains?(line, "AdapterParseError") ->
          {events, peers, points}

        String.starts_with?(line, "Traceback (most recent call last):") ->
          {events, peers, points}

        Regex.match?(~r/^\w[\w.]*(Error|Exception|Stop)\b.*:/, line) ->
          {[%{at: now, runtime: "upstream", kind: :error, text: String.slice(line, 0, 200)} | events],
           peers, points}

        phase_line?(line) ->
          {[%{at: now, runtime: nil, kind: :phase, text: String.slice(String.trim(line), 0, 200)} | events],
           peers, points}

        true ->
          {events, peers, points}
      end
    end)
  end

  defp maybe_phase(events, _peers, text) do
    if phase_line?(text) do
      [%{at: System.os_time(:second), runtime: "imp", kind: :phase, text: String.slice(text, 0, 200)} | events]
    else
      events
    end
  end

  defp phase_line?(text) do
    Regex.match?(~r/\b(seed \d+|compile|preflight|bootstrap|sealing|selection)\b/i, text) and
      not String.contains?(text, "\"")
  end

  # -- __imp_type__ decoding ---------------------------------------------------

  def decode_imp(%{"__imp_type__" => "map", "entries" => entries}) when is_list(entries) do
    for [k, v] <- entries, into: %{}, do: {decode_imp(k), decode_imp(v)}
  end

  def decode_imp(%{"__imp_type__" => "atom", "value" => value}), do: value

  def decode_imp(%{"__imp_type__" => "tuple", "items" => items}),
    do: Enum.map(items, &decode_imp/1)

  def decode_imp(%{"__imp_type__" => _} = other) do
    # unknown encoded type: decode its fields and keep the wrapper shape
    Map.new(other, fn {k, v} -> {k, decode_imp(v)} end)
  end

  def decode_imp(map) when is_map(map), do: Map.new(map, fn {k, v} -> {k, decode_imp(v)} end)
  def decode_imp(list) when is_list(list), do: Enum.map(list, &decode_imp/1)
  def decode_imp(other), do: other
end

defmodule Observatory.Replay do
  @moduledoc """
  Replays a completed run (sealed mtimes + imp trial reports) into a Feed as
  synthetic updates at `speed`x, so the UI can be demoed without a paid run.

      {:ok, replay} = Observatory.Replay.start(feed_pid, speed: 120)
      # optional: run_root: path (defaults to the pilot root)

  Stops itself (and releases the feed back to live polling) when the timeline
  is exhausted; `stop/1` stops early.
  """

  @default_root "tmp/matched_gepa_mipro_ifbench_gepa014"
  @tick_ms 250

  def start(feed_pid, opts \\ []) do
    speed = Keyword.get(opts, :speed, 60)
    run_root = Keyword.get(opts, :run_root, @default_root)
    timeline = build_timeline(run_root)

    pid = spawn_link(fn -> loop(feed_pid, timeline, speed, System.monotonic_time(:millisecond)) end)
    {:ok, pid}
  end

  def stop(pid), do: send(pid, :stop)

  @doc "Virtual seconds elapsed so far for a replay started at `started_ms`."
  def virtual_elapsed(started_ms, speed) do
    div((System.monotonic_time(:millisecond) - started_ms) * speed, 1000)
  end

  # timeline: %{t0: unix, span: seconds, cells: [cell], trials: [{at, trial}]}
  defp build_timeline(run_root) do
    dir = Path.join(run_root, "sealed")

    cells =
      case File.ls(dir) do
        {:ok, fs} ->
          for f <- Enum.sort(fs),
              [_, runtime, seed, arm] <- [Regex.run(~r/^(imp|upstream)-(\d+)-(\w+)\.json$/, f)],
              {:ok, body} <- [File.read(Path.join(dir, f))],
              {:ok, decoded} <- [Jason.decode(body)] do
            decoded = Observatory.Feed.decode_imp(decoded)
            {:ok, %{mtime: mtime}} = File.stat(Path.join(dir, f), time: :posix)

            {mean, trial_scores} =
              case runtime do
                "upstream" ->
                  {get_in(decoded, ["selection", "mean_constraint_score"]), nil}

                "imp" ->
                  payload = decoded["payload"] || %{}
                  champ = get_in(payload, ["candidates", payload["champion_id"]]) || %{}

                  ts =
                    case get_in(champ, ["report", "candidates"]) do
                      cands when is_list(cands) and cands != [] ->
                        for c <- cands, is_number(c["score"]), do: c["score"] * 1.0

                      _ ->
                        nil
                    end

                  {champ["score"], ts}
              end

            %{
              runtime: runtime,
              seed: seed,
              arm: arm,
              mtime: mtime,
              selection_mean: mean,
              trial_scores: trial_scores
            }
          end
          |> Enum.sort_by(& &1.mtime)

        _ ->
          []
      end

    t0 = cells |> Enum.map(& &1.mtime) |> Enum.min(fn -> 0 end)
    span = (cells |> Enum.map(& &1.mtime) |> Enum.max(fn -> 0 end)) - t0

    # trials arrive spread across the 20 minutes before their cell seals
    trials =
      for %{runtime: "imp", trial_scores: scores} = c <- cells, is_list(scores) do
        n = length(scores)
        window = min(1200, max(c.mtime - t0, n))

        scores
        |> Enum.with_index(1)
        |> Enum.map(fn {score, idx} ->
          at = c.mtime - div(window * (n - idx), max(n, 1))
          {at, %{runtime: "imp", seed: c.seed, arm: c.arm, trial: idx, score: score}}
        end)
      end
      |> List.flatten()
      |> Enum.sort_by(&elem(&1, 0))

    %{t0: t0, span: span, cells: cells, trials: trials}
  end

  defp loop(feed_pid, timeline, speed, started_ms) do
    receive do
      :stop ->
        Observatory.Feed.replay_release(feed_pid)
    after
      @tick_ms ->
        vt = timeline.t0 + virtual_elapsed(started_ms, speed)
        Observatory.Feed.replay_set(feed_pid, snapshot(timeline, vt))

        if vt >= timeline.t0 + timeline.span do
          # done: leave the final synthetic state showing, then release
          Observatory.Feed.replay_release(feed_pid)
        else
          loop(feed_pid, timeline, speed, started_ms)
        end
    end
  end

  defp snapshot(timeline, vt) do
    now = System.os_time(:second)
    cells = Enum.filter(timeline.cells, &(&1.mtime <= vt))
    trials = for {at, t} <- timeline.trials, at <= vt, do: t
    done? = vt >= timeline.t0 + timeline.span

    events =
      cells
      |> Enum.sort_by(& &1.mtime, :desc)
      |> Enum.take(200)
      |> Enum.map(fn c ->
        %{
          at: c.mtime,
          runtime: c.runtime,
          kind: :seal,
          text: "sealed #{c.runtime} #{c.seed}/#{c.arm}" <>
                  if(is_number(c.selection_mean),
                    do: " (mean #{Float.round(c.selection_mean * 1.0, 4)})",
                    else: "")
        }
      end)

    peers =
      for runtime <- ["imp", "upstream"], into: %{} do
        latest =
          cells |> Enum.filter(&(&1.runtime == runtime)) |> List.last()

        phase =
          cond do
            done? -> "complete"
            latest -> "seed #{String.slice(latest.seed, -2, 2)} / #{latest.arm} / sealed"
            true -> "starting"
          end

        {runtime,
         %{
           alive: not done?,
           phase: phase,
           progress: nil,
           last_line_at: if(latest, do: latest.mtime, else: nil)
         }}
      end

    %{
      status: if(done?, do: :complete, else: :running),
      peers: peers,
      trials: trials,
      events: events,
      cells: cells,
      spend_usd: nil,
      arm_summaries: [],
      updated_at: now
    }
  end
end
