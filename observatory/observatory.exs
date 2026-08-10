#!/usr/bin/env elixir
# Live observatory for matched campaign runs (v2 UI).
#
#   elixir observatory/observatory.exs [RUN_ROOT] [--fixture] [--log PATH]
#
# Renders the state shape defined in observatory/CONTRACT.md as a Phoenix
# LiveView at http://localhost:4004. If observatory/feed.exs exists it is
# loaded and Observatory.Feed drives the page; otherwise (or with --fixture)
# the page renders observatory/fixtures/state-sample.json, re-read from disk
# each tick so edits show live.

Mix.install([
  {:phoenix_playground, "~> 0.1"},
  {:jason, "~> 1.4"}
])

defmodule Observatory.Source do
  @moduledoc """
  Adapter over the contract boundary. `get/0` always returns the contract's
  state map (atom keys, atom status/kinds) or an :error placeholder.
  """

  @fixture Path.expand("fixtures/state-sample.json", __DIR__)

  def init(opts) do
    feed_file = Path.expand("feed.exs", __DIR__)

    mode =
      cond do
        opts[:fixture] ->
          {:fixture, @fixture}

        File.exists?(feed_file) ->
          Code.require_file(feed_file)

          {:ok, pid} =
            apply(Observatory.Feed, :start_link,
              [[run_root: opts[:root], log_path: opts[:log]]])

          {:feed, pid}

        true ->
          {:fixture, @fixture}
      end

    :persistent_term.put(:observatory_source, mode)
    :persistent_term.put(:observatory_expected_cells, expected_cells(opts[:root]))
    mode
  end

  # Denominator for the header cell counter, derived from THIS run's contract
  # (seeds x ceiling arms x 2 runtimes) by the examples/<run-basename>/ naming
  # convention; nil (no denominator shown) when no contract is found.
  def expected_cells(nil), do: nil

  def expected_cells(root) do
    path = Path.join(["examples", Path.basename(root), "contract.json"])

    with true <- File.exists?(path),
         {:ok, body} <- File.read(path),
         {:ok, contract} <- Jason.decode(body),
         seeds when is_list(seeds) and seeds != [] <- contract["seeds"],
         arms when is_map(arms) and map_size(arms) > 0 <-
           get_in(contract, ["execution", "call_ceilings"]) do
      length(seeds) * map_size(arms) * 2
    else
      _ -> nil
    end
  end

  def get do
    case :persistent_term.get(:observatory_source) do
      {:feed, pid} -> apply(Observatory.Feed, :state, [pid])
      {:fixture, path} -> load_fixture(path)
    end
  end

  defp load_fixture(path) do
    with {:ok, body} <- File.read(path),
         {:ok, raw} <- Jason.decode(body) do
      %{
        status: atomize(raw["status"], ~w(idle running complete stopped)a, :idle),
        peers:
          for {name, p} <- raw["peers"] || %{}, into: %{} do
            {name,
             %{
               alive: p["alive"] == true,
               phase: p["phase"],
               progress:
                 case p["progress"] do
                   [d, t] when is_integer(d) and is_integer(t) -> {d, t}
                   _ -> nil
                 end,
               last_line_at: p["last_line_at"]
             }}
          end,
        trials:
          for t <- raw["trials"] || [] do
            %{runtime: t["runtime"], seed: t["seed"], arm: t["arm"],
              trial: t["trial"], score: t["score"]}
          end,
        events:
          for e <- raw["events"] || [] do
            %{at: e["at"], runtime: e["runtime"],
              kind: atomize(e["kind"], ~w(seal warning refusal truncation error phase info)a, :info),
              text: e["text"]}
          end,
        cells:
          for c <- raw["cells"] || [] do
            %{runtime: c["runtime"], seed: c["seed"], arm: c["arm"],
              mtime: c["mtime"], selection_mean: c["selection_mean"],
              trial_scores: c["trial_scores"]}
          end,
        arm_summaries: [],
        spend_usd: raw["spend_usd"],
        updated_at: raw["updated_at"] || System.system_time(:second)
      }
    else
      _ ->
        %{status: :idle, peers: %{}, trials: [], events: [], cells: [], arm_summaries: [],
          spend_usd: nil, updated_at: System.system_time(:second)}
    end
  end

  defp atomize(s, allowed, default) when is_binary(s) do
    Enum.find(allowed, default, &(Atom.to_string(&1) == s))
  end

  defp atomize(_, _, default), do: default
end

defmodule Observatory.Live do
  use Phoenix.LiveView

  # Insight-first redesign: every panel answers a question on a shared 0..1
  # score axis with explicit references. Ink goes to data; boxes are gone.

  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(1000, self(), :tick)
    {:ok, assign(socket, state: Observatory.Source.get())}
  end

  def handle_info(:tick, socket) do
    {:noreply, assign(socket, state: Observatory.Source.get())}
  end

  # ---- data shaping --------------------------------------------------------

  defp fmt(nil), do: "–"
  defp fmt(x) when is_float(x), do: :erlang.float_to_binary(x, decimals: 3)
  defp fmt(x), do: to_string(x)

  defp fmt2(nil), do: "–"
  defp fmt2(x) when is_number(x), do: :erlang.float_to_binary(x * 1.0, decimals: 2)

  defp sx(score), do: 120 + score * 560

  # ---- live optimization section -------------------------------------------

  defp live_points(state), do: Map.get(state, :optimizer_points, [])

  # dashed reference: the sealed upstream baseline selection mean, if present
  defp live_base(state) do
    state.cells
    |> Enum.find(&(&1.runtime == "upstream" and &1.arm == "baseline"))
    |> case do
      %{selection_mean: m} when is_number(m) -> m
      _ -> nil
    end
  end

  defp lx(_i, n) when n <= 1, do: 40
  defp lx(i, n), do: 40 + i / (n - 1) * 710

  defp ly(score), do: 130 - score * 110

  defp best_path(points) do
    n = length(points)

    points
    |> Enum.with_index()
    |> Enum.filter(fn {pt, _i} -> pt.kind == :best end)
    |> Enum.map_join(" ", fn {pt, i} -> "#{lx(i, n)},#{ly(pt.score)}" end)
  end

  defp summ(state, rt, seed, arm) do
    Enum.find(state.arm_summaries || [], &(&1.runtime == rt and &1.seed == seed and &1.arm == arm))
  end

  defp seeds(state) do
    ((state.arm_summaries || []) |> Enum.map(& &1.seed)) ++ Enum.map(state.cells, & &1.seed)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp mean(xs) do
    case Enum.filter(xs, &is_number/1) do
      [] -> nil
      ys -> Enum.sum(ys) / length(ys)
    end
  end

  # verdict rows: {arm, %{rt => {mean, [seed_means]}}, delta}
  defp verdict(state) do
    for arm <- ~w(baseline gepa mipro_v2) do
      per_rt =
        for rt <- ~w(imp upstream), into: %{} do
          pts = for seed <- seeds(state), s = summ(state, rt, seed, arm), s.held_out, do: s.held_out.mean
          {rt, {mean(pts), pts}}
        end

      delta =
        case {per_rt["imp"], per_rt["upstream"]} do
          {{i, _}, {u, _}} when is_number(i) and is_number(u) -> i - u
          _ -> nil
        end

      {arm, per_rt, delta}
    end
  end

  # slopes: [{rt, seed, arm, sel, held}]
  defp slopes(state) do
    for rt <- ~w(imp upstream), seed <- seeds(state), arm <- ~w(baseline gepa mipro_v2),
        s = summ(state, rt, seed, arm),
        s.selection && s.held_out,
        is_number(s.selection.mean) and is_number(s.held_out.mean) do
      %{rt: rt, seed: seed, arm: arm, sel: s.selection.mean, held: s.held_out.mean}
    end
  end

  # Sealed cells whose held-out leg doesn't exist yet: show their selection
  # means on the left axis DURING the run (otherwise the only numbers the
  # campaign has produced so far are invisible in every chart), skipping any
  # already covered by a full slope.
  defp pending_selections(state, slopes) do
    covered = MapSet.new(slopes, &{&1.rt, &1.seed, &1.arm})

    for c <- state.cells,
        is_number(c.selection_mean),
        not MapSet.member?(covered, {c.runtime, c.seed, c.arm}) do
      %{rt: c.runtime, seed: c.seed, arm: c.arm, sel: c.selection_mean}
    end
  end

  # imp trials per {arm, seed} with the imp baseline selection mean as reference
  defp trial_rows(state) do
    for arm <- ~w(gepa mipro_v2), seed <- seeds(state) do
      ts = for t <- state.trials, t.arm == arm, t.seed == seed, is_number(t.score), do: t.score
      base = case summ(state, "imp", seed, "baseline") do
        %{selection: %{mean: m}} -> m
        _ -> nil
      end
      {arm, seed, ts, base}
    end
  end

  # health: pooled held-out outcome composition per {rt, arm}
  defp health(state) do
    for rt <- ~w(imp upstream), arm <- ~w(baseline gepa mipro_v2) do
      sums =
        for seed <- seeds(state), s = summ(state, rt, seed, arm), s.held_out, reduce: %{n: 0, ones: 0, parse: 0, trunc: 0, fail: 0} do
          acc ->
            z = s.held_out.zeros || %{}
            %{acc | n: acc.n + s.held_out.n, ones: acc.ones + s.held_out.ones,
              parse: acc.parse + Map.get(z, :parse, 0), trunc: acc.trunc + Map.get(z, :trunc, 0),
              fail: acc.fail + Map.get(z, :fail, 0)}
        end
      {rt, arm, sums}
    end
  end

  defp event_class(:warning), do: "warn"
  defp event_class(:refusal), do: "bad"
  defp event_class(:error), do: "bad"
  defp event_class(:truncation), do: "warn"
  defp event_class(:seal), do: "ok"
  defp event_class(_), do: "info"

  defp hhmmss(nil), do: "--:--:--"

  # local wall-clock, not UTC — this is a local dashboard
  defp hhmmss(unix) do
    {{_y, _mo, _d}, {h, m, sec}} =
      unix
      |> DateTime.from_unix!()
      |> DateTime.to_naive()
      |> NaiveDateTime.to_erl()
      |> :calendar.universal_time_to_local_time()

    :io_lib.format("~2..0B:~2..0B:~2..0B", [h, m, sec]) |> IO.iodata_to_binary()
  end

  defp running?(state), do: state.status == :running

  # ---- render --------------------------------------------------------------

  def render(assigns) do
    st = assigns.state
    assigns =
      assign(assigns,
        verdict: verdict(st), slopes: slopes(st), pending: pending_selections(st, slopes(st)),
        trial_rows: trial_rows(st),
        health: health(st), seeds: seeds(st), running: running?(st),
        live_points: live_points(st), live_base: live_base(st),
        best_path: best_path(live_points(st)),
        imp_live: Map.get(st, :imp_trials, []),
        now: st.updated_at || System.system_time(:second))

    ~H"""
    <div class="wrap">
      <header>
        <h1>matched-campaign observatory</h1>
        <p class="sub">
          <span class={"st " <> to_string(@state.status)}><%= @state.status %></span>
          · <%= Enum.count(@state.cells) %><%= case :persistent_term.get(:observatory_expected_cells, nil) do
              nil -> ""
              n -> "/#{n}" end %> cells
          · $<%= fmt(@state.spend_usd) %> recorded
          · <%= hhmmss(@state.updated_at) %>
          <%= for rt <- ["imp", "upstream"], p = @state.peers[rt] do %>
            · <b><%= rt %></b> <%= (p && p.phase) || "—" %><%= case p && p.progress do
                {d, t} -> " #{d}/#{t}"
                _ -> "" end %>
          <% end %>
        </p>
      </header>

      <section :if={@running}>
        <h2>live optimization <span class="q">is the search moving right now?</span></h2>
        <%= for rt <- ["imp", "upstream"], p = @state.peers[rt] do %>
          <div class="peerline">
            <span class={"peername " <> rt}><%= rt %></span>
            <span class="peerphase"><%= (p && p.phase) || "idle" %></span>
            <%= case p && p.progress do %>
              <% {d, t} -> %>
                <span class="pbar"><span class="pfill" style={"width:#{round(d / max(t, 1) * 100)}%"}></span></span>
                <span class="pnum"><%= d %>/<%= t %> · <%= round(d / max(t, 1) * 100) %>%</span>
              <% _ -> %>
                <span class="pnote"><%= if rt == "imp",
                  do: "no live telemetry — ledger discloses at seal",
                  else: "no progress line yet" %></span>
            <% end %>
          </div>
        <% end %>
        <%= if @live_points != [] or @imp_live != [] do %>
          <svg viewBox="0 0 760 150" class="chart">
            <%= for tick <- [0.0, 0.5, 1.0] do %>
              <line x1="40" y1={ly(tick)} x2="750" y2={ly(tick)} class="grid" />
              <text x="8" y={ly(tick) + 4} class="tick"><%= tick %></text>
            <% end %>
            <%= if is_number(@live_base) do %>
              <line x1="40" y1={ly(@live_base)} x2="750" y2={ly(@live_base)} class="baseref" />
              <text x="748" y={ly(@live_base) - 4} class="tick" text-anchor="end">baseline <%= fmt(@live_base) %></text>
            <% end %>
            <%= for {pt, i} <- Enum.with_index(@live_points), pt.kind == :eval do %>
              <circle cx={lx(i, length(@live_points))} cy={ly(pt.score)} r="3" class="seed upstream">
                <title>candidate eval <%= fmt(pt.score) %> at <%= hhmmss(pt.at) %></title>
              </circle>
            <% end %>
            <%= if @best_path != "" do %>
              <polyline points={@best_path} class="bestline" />
            <% end %>
            <%= for {pt, i} <- Enum.with_index(@imp_live) do %>
              <circle cx={lx(i, length(@imp_live))} cy={ly(pt["score"])} r="3"
                class={"seed imp" <> if(pt["kind"] == "best", do: " champ", else: "")}>
                <title>imp valset eval <%= fmt(pt["score"] * 1.0) %> (iteration <%= pt["iteration"] %>)</title>
              </circle>
            <% end %>
          </svg>
          <p class="note">orange dots = upstream candidate evals (parsed live) · blue dots = imp valset evals (engine callback), ringed = new best · green line = upstream best-so-far · dashed = sealed upstream baseline · each series indexes its own x; compare shapes, not columns</p>
        <% end %>
      </section>

      <section>
        <h2>held-out verdict <span class="q">is imp matching upstream?</span></h2>
        <svg viewBox="0 0 760 190" class="chart">
          <%= for tick <- [0.0, 0.25, 0.5, 0.75, 1.0] do %>
            <line x1={sx(tick)} y1="18" x2={sx(tick)} y2="158" class="grid" />
            <text x={sx(tick)} y="172" class="tick"><%= tick %></text>
          <% end %>
          <%= for {{arm, per_rt, delta}, i} <- Enum.with_index(@verdict) do %>
            <% y = 40 + i * 46 %>
            <text x="8" y={y + 4} class="lbl"><%= arm %></text>
            <% {umean, _} = per_rt["upstream"] %>
            <%= if is_number(umean) do %>
              <rect x={sx(max(umean - 0.09, 0.0))} y={y - 9} width={(min(umean + 0.09, 1.0) - max(umean - 0.09, 0.0)) * 560} height="18" class="noise">
                <title>upstream mean ±0.09 measured noise</title>
              </rect>
            <% end %>
            <%= for rt <- ["imp", "upstream"], {m, pts} = per_rt[rt] do %>
              <%= for p <- pts do %>
                <circle cx={sx(p)} cy={y} r="3.5" class={"seed " <> rt}><title><%= rt %> seed: <%= fmt(p) %></title></circle>
              <% end %>
              <%= if is_number(m) do %>
                <rect x={sx(m) - 2} y={y - 12} width="4" height="24" class={"mn " <> rt}>
                  <title><%= rt %> <%= arm %> mean <%= fmt(m) %></title>
                </rect>
              <% end %>
            <% end %>
            <text x="740" y={y + 4} class={"delta " <> if(is_number(delta) and abs(delta) > 0.09, do: "hot", else: "")}>
              Δ<%= if is_number(delta), do: (if delta >= 0, do: "+", else: "") <> fmt2(delta), else: "–" %>
            </text>
          <% end %>
        </svg>
        <p class="cap"><i class="sw swimp"></i>imp&nbsp;&nbsp;<i class="sw swup"></i>upstream (pinned DSPy) · thick tick = 3-seed mean · small dots = seeds · gray band = ±0.09 same-program noise around upstream · Δ beyond band would matter</p>
      </section>

      <section>
        <h2>selection → held-out <span class="q">did optimization transfer?</span></h2>
        <svg viewBox="0 0 760 240" class="chart">
          <text x="200" y="16" class="tick">selection</text>
          <text x="560" y="16" class="tick">held-out</text>
          <%= for tick <- [0.25, 0.5, 0.75, 1.0] do %>
            <% ty = 220 - tick * 190 %>
            <line x1="200" y1={ty} x2="560" y2={ty} class="grid" />
            <text x="180" y={ty + 3} class="tick"><%= tick %></text>
          <% end %>
          <%= for s <- @slopes do %>
            <% y1 = 220 - s.sel * 190 %>
            <% y2 = 220 - s.held * 190 %>
            <line x1="200" y1={y1} x2="560" y2={y2}
              class={if s.arm == "baseline", do: "slope base", else: "slope " <> s.rt}>
              <title><%= s.rt %> <%= s.seed %> <%= s.arm %>: <%= fmt(s.sel) %> → <%= fmt(s.held) %></title>
            </line>
            <circle :if={s.arm != "baseline"} cx="560" cy={y2} r="3" class={"seed " <> s.rt} />
          <% end %>
          <%= for pnd <- @pending do %>
            <circle cx="200" cy={220 - pnd.sel * 190} r="4" class={"seed " <> pnd.rt}>
              <title><%= pnd.rt %> <%= pnd.seed %> <%= pnd.arm %> selection: <%= fmt(pnd.sel) %> (held-out pending)</title>
            </circle>
            <text x="192" y={220 - pnd.sel * 190 + 4} class="tick" text-anchor="end"><%= pnd.arm %></text>
          <% end %>
        </svg>
        <p class="cap">gray = baselines (the transfer cost of the split itself) · colored = optimizer champions; a colored line falling steeper than gray = selection win that evaporated</p>
      </section>

      <section>
        <h2>trials vs baseline <span class="q">did the search beat baseline on its own terms? (imp ledger; upstream seals no trial scores)</span></h2>
        <svg viewBox="0 0 760 250" class="chart">
          <%= for {{arm, seed, ts, base}, i} <- Enum.with_index(@trial_rows) do %>
            <% y = 32 + i * 36 %>
            <text x="8" y={y + 4} class="lbl"><%= arm %> s<%= String.slice(seed, -2, 2) %></text>
            <line x1="120" y1={y} x2="680" y2={y} class="grid" />
            <%= if is_number(base) do %>
              <line x1={sx(base)} y1={y - 10} x2={sx(base)} y2={y + 10} class="baseref">
                <title>imp baseline selection mean <%= fmt(base) %></title>
              </line>
            <% end %>
            <%= for {t, j} <- Enum.with_index(ts) do %>
              <circle cx={sx(t)} cy={y} r={if t == Enum.max(ts, fn -> nil end), do: 5, else: 3.5}
                class={"seed imp" <> if(t == Enum.max(ts, fn -> nil end), do: " champ", else: "")}>
                <title>trial <%= j + 1 %>: <%= fmt(t) %></title>
              </circle>
            <% end %>
            <text :if={ts == []} x="400" y={y + 4} class="tick">no trials yet</text>
          <% end %>
        </svg>
        <p class="cap">vertical dash = that seed's baseline score on the same objective · ringed dot = champion · dots left of the dash never justified selection</p>
      </section>

      <section>
        <h2>instrument health <span class="q">can the means be trusted?</span></h2>
        <div class="healthgrid">
          <%= for {rt, arm, h} <- @health, h.n > 0 do %>
            <div class="hrow">
              <span class="lbl"><span class={"rttag " <> rt}><%= rt %></span> <%= arm %></span>
              <div class="hbar" title={"#{h.n} rows: #{h.ones} perfect · #{h.fail} constraint-fail zeros · #{h.trunc} truncated zeros · #{h.parse} parse-error zeros"}>
                <div class="seg ones" style={"width:#{h.ones / h.n * 100}%"}></div>
                <div class="seg mid" style={"width:#{max(h.n - h.ones - h.parse - h.trunc - h.fail, 0) / h.n * 100}%"}></div>
                <div class="seg fail" style={"width:#{h.fail / h.n * 100}%"}></div>
                <div class="seg trunc" style={"width:#{h.trunc / h.n * 100}%"}></div>
                <div class="seg parse" style={"width:#{h.parse / h.n * 100}%"}></div>
              </div>
              <span class="hnum"><%= h.parse + h.trunc %> artifact zeros</span>
            </div>
          <% end %>
        </div>
        <div class="legend">
          <span><i class="sw ones"></i>perfect</span><span><i class="sw mid"></i>partial</span>
          <span><i class="sw fail"></i>constraint fail</span><span><i class="sw trunc"></i>truncated (cap)</span>
          <span><i class="sw parse"></i>parse error</span>
        </div>
        <p class="cap">truncated + parse zeros are instrument artifacts, not model skill — they moved cell means by ±0.05–0.10 in the pilot</p>
      </section>

      <section :if={@running or @state.events != []}>
        <h2>event feed</h2>
        <div class="feed">
          <div :for={e <- Enum.take(@state.events, 10)} class={"ev " <> event_class(e.kind)}>
            <span class="t"><%= hhmmss(e.at) %></span>
            <span class="k"><%= e.kind %></span>
            <span class="rt"><%= e.runtime %></span>
            <span class="tx"><%= e.text %></span>
          </div>
        </div>
      </section>
    </div>
    <style>
      :root { color-scheme: dark; }
      body { background:#161615; color:#eee; font: 13px/1.45 ui-monospace, monospace; margin:0; }
      .wrap { max-width: 800px; margin: 0 auto; padding: 20px 16px 60px; overflow-x:hidden; }
      header h1 { font-size: 16px; margin: 0; letter-spacing:.5px;}
      .sub { color:#a5a49b; margin: 4px 0 8px; }
      .sub b { color:#eee; }
      .st.complete { color:#199e70; } .st.running { color:#c98500; } .st.stopped { color:#e66767; }
      h2 { font-size: 13px; margin: 26px 0 4px; color:#eee; }
      .q { color:#8a897f; font-weight: normal; font-style: italic; }
      .cap { color:#8a897f; font-size: 11px; margin: 2px 0 0; }
      svg.chart { width:100%; height:auto; display:block; }
      .grid { stroke:#2e2e2c; stroke-width:1; }
      .tick { fill:#8a897f; font-size:10px; text-anchor:middle; }
      .lbl { fill:#c3c2b7; font-size:11px; }
      .noise { fill:#8a897f; opacity:.16; }
      .seed.imp { fill:#3987e5; } .seed.upstream { fill:#d95926; }
      .seed { opacity:.75; }
      .seed.champ { stroke:#fff; stroke-width:1.5; opacity:1; }
      .mn.imp { fill:#3987e5; } .mn.upstream { fill:#d95926; }
      .delta { fill:#c3c2b7; font-size:12px; text-anchor:end; }
      .delta.hot { fill:#e66767; }
      .slope { stroke-width:1.5; opacity:.8; fill:none; }
      .slope.imp { stroke:#3987e5; } .slope.upstream { stroke:#d95926; }
      .slope.base { stroke:#575650; stroke-width:1; opacity:.7; }
      .baseref { stroke:#c3c2b7; stroke-width:1.5; stroke-dasharray:3 2; }
      .peerline { display:flex; align-items:center; gap:10px; margin:6px 0; }
      .peername { width:76px; font-weight:bold; }
      .peername.imp { color:#3987e5; } .peername.upstream { color:#d95926; }
      .peerphase { color:#c3c2b7; min-width:170px; }
      .pbar { flex:1; height:8px; background:#2e2e2c; border-radius:4px; overflow:hidden; }
      .pfill { display:block; height:100%; background:#c98500; border-radius:4px; transition:width 1s linear; }
      .pnum { color:#a5a49b; min-width:130px; text-align:right; }
      .pnote { color:#8a897f; font-style:italic; flex:1; }
      .bestline { stroke:#199e70; stroke-width:2; fill:none; }
      .note { color:#8a897f; margin:4px 0 0; }
      .healthgrid { display:flex; flex-direction:column; gap:5px; margin-top:6px; }
      .hrow { display:flex; align-items:center; gap:10px; }
      .hrow .lbl { width:150px; color:#c3c2b7; font-size:11px; }
      .rttag.imp { color:#3987e5; } .rttag.upstream { color:#d95926; }
      .hbar { flex:1; display:flex; height:12px; border-radius:3px; overflow:hidden; background:#222; }
      .seg.ones { background:#199e70; } .seg.mid { background:#2e6b52; }
      .seg.fail { background:#575650; } .seg.trunc { background:#c98500; } .seg.parse { background:#e66767; }
      .hnum { width:110px; text-align:right; color:#8a897f; font-size:11px; }
      .legend { display:flex; gap:14px; margin-top:6px; color:#a5a49b; font-size:11px; flex-wrap:wrap;}
      .sw { display:inline-block; width:9px; height:9px; border-radius:2px; margin-right:4px; }
      .sw.swimp{background:#3987e5}.sw.swup{background:#d95926}.sw.ones{background:#199e70}.sw.mid{background:#2e6b52}.sw.fail{background:#575650}.sw.trunc{background:#c98500}.sw.parse{background:#e66767}
      .feed { display:flex; flex-direction:column; gap:2px; margin-top:4px; }
      .ev { display:flex; gap:10px; font-size:11px; color:#a5a49b; }
      .ev .t { color:#8a897f; } .ev .k { width:70px; }
      .ev.ok .k { color:#199e70; } .ev.warn .k { color:#c98500; } .ev.bad .k { color:#e66767; }
      .ev .tx { color:#c3c2b7; }
    </style>
    """
  end
end

{args, positional} =
  Enum.split_with(System.argv(), &String.starts_with?(&1, "--"))

root =
  case positional do
    [r | _] -> Path.expand(r)
    [] -> Path.expand("tmp/matched_gepa_mipro_ifbench_gepa014", File.cwd!())
  end

log =
  case Enum.drop_while(System.argv(), &(&1 != "--log")) do
    ["--log", path | _] -> Path.expand(path)
    _ -> nil
  end

mode = Observatory.Source.init(fixture: "--fixture" in args, root: root, log: log)

case mode do
  {:fixture, path} -> IO.puts("observatory rendering fixture #{path}")
  {:feed, _} -> IO.puts("observatory watching #{root} via Observatory.Feed")
end

PhoenixPlayground.start(live: Observatory.Live, port: 4004)
