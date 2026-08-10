# Observatory v2 contract (feed <-> UI)

Two components, built in parallel, meeting at one boundary.

## Boundary: `Observatory.Feed`

File: `observatory/feed.exs` (defines `Observatory.Feed`, plain Elixir, no deps
beyond Jason). Started with:

    {:ok, pid} = Observatory.Feed.start_link(run_root: path, log_path: path_or_nil)

Public API (all reads cheap):

    Observatory.Feed.state(pid) :: %{
      status: :idle | :running | :complete | :stopped,
      peers: %{"imp" => peer(), "upstream" => peer()},
      trials: [trial()],          # newest last
      events: [event()],          # newest first, capped at 200
      cells: [cell()],            # sealed cells (as v1)
      spend_usd: float() | nil,
      updated_at: integer()       # unix seconds
    }

    peer()  :: %{alive: boolean(), phase: String.t() | nil,   # "seed 06 / mipro_v2 / compile"
                 progress: {done :: integer(), total :: integer()} | nil,
                 last_line_at: integer() | nil}
    trial() :: %{runtime: String.t(), seed: String.t(), arm: String.t(),
                 trial: integer(), score: float() | nil}
    event() :: %{at: integer(), runtime: String.t() | nil, kind:
                 :seal | :warning | :refusal | :truncation | :error | :phase | :info,
                 text: String.t()}
    cell()  :: %{runtime: String.t(), seed: String.t(), arm: String.t(),
                 mtime: integer(), selection_mean: float() | nil,
                 trial_scores: [float()] | nil}   # imp seals carry full trial reports

Sources the Feed must merge:
1. The run root: `sealed/*.json` (cell + imp trial reports — decode the
   `__imp_type__` encoding: maps have `entries` [k,v] lists, atoms have
   `value`) and `{imp,upstream}-result.json` for terminal status.
2. The coordinator log file (optional): tail for upstream tqdm lines
   (`GEPA Optimization:  80%|... | 64/80 [...s/rollouts]`), Elixir `Logger`
   lines (`[warning] ... killed row ...`, refusal phrases "can’t help"),
   Python tracebacks, and phase markers. Real format samples in
   `observatory/fixtures/*.log`.

Also deliver: `Observatory.Replay` in the same file —
`Observatory.Replay.start(feed_pid, speed: 60)` replays the completed pilot
(from `tmp/matched_gepa_mipro_ifbench_gepa014` sealed mtimes + trial reports)
as synthetic feed updates at `speed`x, so the UI can be demoed live without a
paid run. Acceptance: a driver script `observatory/feed_check.exs` that runs
Feed against the pilot root, prints the final state summary (18 cells, both
peers complete, >=24 imp trials with scores), then runs a 120x replay and
prints 3 mid-replay snapshots.

## UI: `observatory/observatory.exs` (v2, replaces v1 in place)

Phoenix Playground LiveView as in v1 (keep the dark style + palette:
imp #3987e5, upstream #d95926, ok #199e70, warn #c98500, bad #e66767).
Consumes ONLY `Observatory.Feed.state/1` (1s tick). Layout, top to bottom:
1. Status row: per-peer chip (alive/phase/last-seen), spend meter, cells n/18.
2. **Phase ticker**: current seed/arm/phase per peer + progress bar when known.
3. **Trial strip**: per optimizer arm (gepa, mipro_v2), a dot strip of trial
   scores appearing as they arrive (x = trial index within seed, grouped by
   seed; imp blue / upstream orange when available; upstream trial scores may
   be absent — render imp-only gracefully).
4. **Event feed**: last ~15 events, warnings/refusals/errors highlighted.
5. Verdict charts from v1 (cell grid, held-out dot strip with ±0.09 band,
   seal timeline) — keep, moved below the live section.
Acceptance: boots against the pilot root and renders all sections with real
data (trial strips filled from imp sealed reports); with Replay running the
live sections visibly update. No horizontal page scroll at 800px.

If the Feed isn't ready, develop against `observatory/fixtures/state-sample.json`
(same shape, provided) via a `--fixture` flag; integration swaps it out.
