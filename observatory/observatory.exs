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
    mode
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
        spend_usd: raw["spend_usd"],
        updated_at: raw["updated_at"] || System.system_time(:second)
      }
    else
      _ ->
        %{status: :idle, peers: %{}, trials: [], events: [], cells: [],
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

  @arms ~w(baseline gepa mipro_v2)
  @opt_arms ~w(gepa mipro_v2)
  @runtimes ~w(imp upstream)
  @spend_budget 40.0

  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(1000, self(), :tick)
    {:ok, assign(socket, state: Observatory.Source.get())}
  end

  def handle_info(:tick, socket) do
    {:noreply, assign(socket, state: Observatory.Source.get())}
  end

  # ---- helpers ------------------------------------------------------------

  defp fmt(nil), do: "–"
  defp fmt(x) when is_float(x), do: :erlang.float_to_binary(x, decimals: 3)
  defp fmt(x), do: to_string(x)

  defp seeds(state) do
    (Enum.map(state.cells, & &1.seed) ++ Enum.map(state.trials, & &1.seed))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp cell(state, rt, seed, arm),
    do: Enum.find(state.cells, &(&1.runtime == rt and &1.seed == seed and &1.arm == arm))

  defp peer_class(nil), do: "idle"
  defp peer_class(%{phase: "complete"}), do: "ok"
  defp peer_class(%{alive: true}), do: "run"
  defp peer_class(%{alive: false}), do: "bad"

  defp ago(nil, _now), do: "never"
  defp ago(t, now), do: "#{max(now - t, 0)}s ago"

  defp status_word(%{phase: "complete"}), do: "complete"
  defp status_word(%{alive: true}), do: "alive"
  defp status_word(%{alive: false}), do: "down"
  defp status_word(nil), do: "no signal"

  # trials for one arm, grouped by seed (sorted), each trial keeps order
  defp arm_trials(state, arm) do
    state.trials
    |> Enum.filter(&(&1.arm == arm))
    |> Enum.group_by(& &1.seed)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp event_class(:warning), do: "warn"
  defp event_class(:refusal), do: "bad"
  defp event_class(:error), do: "bad"
  defp event_class(:truncation), do: "warn"
  defp event_class(:seal), do: "ok"
  defp event_class(_), do: "info"

  defp hhmmss(nil), do: "--:--:--"

  defp hhmmss(unix) do
    unix |> DateTime.from_unix!() |> Calendar.strftime("%H:%M:%S")
  end

  # per-arm selection means from sealed cells: {arm, [{rt, mean}]}
  defp dotstrip(state) do
    for arm <- @arms do
      pts =
        for c <- state.cells, c.arm == arm, is_number(c.selection_mean),
            do: {c.runtime, c.seed, c.selection_mean}

      {arm, pts}
    end
  end

  # ---- render -------------------------------------------------------------

  def render(assigns) do
    assigns =
      assign(assigns,
        now: assigns.state.updated_at || System.system_time(:second),
        runtimes: @runtimes,
        arms: @arms,
        opt_arms: @opt_arms
      )

    ~H"""
    <div class="wrap">
      <h1>⚡ matched-campaign observatory</h1>
      <p class="sub">
        run <%= @state.status %> ·
        <%= Enum.count(@state.cells) %>/18 cells sealed ·
        updated <%= hhmmss(@state.updated_at) %>
      </p>

      <div class="statusrow">
        <div :for={rt <- @runtimes} class={"status " <> peer_class(@state.peers[rt])}>
          <b><%= rt %></b>
          <span title={"phase: " <> (get_in(@state.peers, [rt, Access.key(:phase)]) || "?")}>
            <%= status_word(@state.peers[rt]) %> ·
            last line <%= ago(get_in(@state.peers, [rt, Access.key(:last_line_at)]), @now) %>
          </span>
        </div>
        <div class="status spend" title={"recorded eval spend $" <> fmt(@state.spend_usd) <> " of ~$40 budget"}>
          <b>spend</b>
          <span>$<%= fmt(@state.spend_usd) %></span>
          <div class="meter">
            <div class="fill spendfill" style={"width:" <> fmt(Float.round(min((@state.spend_usd || 0.0) / 40.0, 1.0) * 100, 1)) <> "%"}></div>
          </div>
        </div>
      </div>

      <h2 id="phase-ticker">phase ticker</h2>
      <div class="phases">
        <div :for={rt <- @runtimes} class="phase">
          <span class={"rtlabel " <> rt}><%= rt %></span>
          <% p = @state.peers[rt] %>
          <span class="phasetext"><%= (p && p.phase) || "—" %></span>
          <%= case p && p.progress do %>
            <% {done, total} when total > 0 -> %>
              <div class="meter wide" title={"#{done}/#{total}"}>
                <div class={"fill " <> rt} style={"width:" <> fmt(Float.round(done / total * 100, 1)) <> "%"}></div>
              </div>
              <span class="prognum"><%= done %>/<%= total %></span>
            <% _ -> %>
              <span class="prognum dim">no progress signal</span>
          <% end %>
        </div>
      </div>

      <h2>trial strips <span class="note">(dot = one optimizer trial score, grouped by seed)</span></h2>
      <div :for={arm <- @opt_arms} class="trialarm">
        <div class="armhead"><%= arm %>
          <span class="note"><%= @state.trials |> Enum.count(& &1.arm == arm) %> trials</span>
        </div>
        <%= if arm_trials(@state, arm) == [] do %>
          <p class="empty">no trials yet</p>
        <% else %>
          <svg viewBox={"0 0 720 " <> to_string(30 + length(arm_trials(@state, arm)) * 34)} class="chart">
            <%= for {{seed, trials}, gi} <- Enum.with_index(arm_trials(@state, arm)) do %>
              <% y = 24 + gi * 34 %>
              <text x="8" y={y + 4} class="lbl">s<%= String.slice(seed, -2, 2) %></text>
              <line x1="60" y1={y} x2="700" y2={y} class="axis" />
              <%= for tick <- [0.0, 0.5, 1.0] do %>
                <line x1={60 + tick * 630} y1={y - 3} x2={60 + tick * 630} y2={y + 3} class="axis" />
              <% end %>
              <%= for t <- trials, is_number(t.score) do %>
                <circle cx={60 + t.score * 630} cy={y} r="5" class={"dot trialdot " <> t.runtime}>
                  <title><%= t.runtime %> <%= arm %> seed <%= seed %> trial <%= t.trial %>: <%= fmt(t.score) %></title>
                </circle>
              <% end %>
            <% end %>
          </svg>
        <% end %>
      </div>

      <h2 id="event-feed">event feed</h2>
      <ul class="events">
        <li :for={e <- Enum.take(@state.events, 15)} class={"event " <> event_class(e.kind)}>
          <span class="etime"><%= hhmmss(e.at) %></span>
          <span class="ekind"><%= e.kind %></span>
          <span class="ert"><%= e.runtime || "—" %></span>
          <span class="etext"><%= e.text %></span>
        </li>
        <li :if={@state.events == []} class="event info"><span class="etext">no events yet</span></li>
      </ul>

      <h2>cell grid</h2>
      <table class="grid">
        <tr><th></th><th :for={arm <- @arms} colspan="2"><%= arm %></th></tr>
        <tr><th>seed</th><%= for _ <- @arms do %><th>imp</th><th>up</th><% end %></tr>
        <tr :for={seed <- seeds(@state)}>
          <td class="seed"><%= String.slice(seed, -2, 2) %></td>
          <%= for arm <- @arms, rt <- @runtimes do %>
            <td class={if cell(@state, rt, seed, arm), do: "sealed", else: "pending"}
                title={"#{rt} #{seed} #{arm}"}>
              <%= case cell(@state, rt, seed, arm) do
                %{selection_mean: m} when is_number(m) -> fmt(m)
                %{} -> "✓"
                nil -> "·"
              end %>
            </td>
          <% end %>
        </tr>
        <tr :if={seeds(@state) == []}><td class="seed" colspan="7">no cells yet</td></tr>
      </table>

      <h2>selection means <span class="note">(dots = sealed cells; ±0.09 noise band around each runtime mean)</span></h2>
      <svg viewBox="0 0 720 190" class="chart">
        <%= for {{arm, pts}, i} <- Enum.with_index(dotstrip(@state)) do %>
          <% y = 40 + i * 50 %>
          <text x="8" y={y + 4} class="lbl"><%= arm %></text>
          <line x1="110" y1={y} x2="700" y2={y} class="axis" />
          <%= for tick <- [0.0, 0.25, 0.5, 0.75, 1.0] do %>
            <line x1={110 + tick * 590} y1={y - 4} x2={110 + tick * 590} y2={y + 4} class="axis" />
            <text :if={i == 2} x={110 + tick * 590} y={y + 22} class="tick"><%= tick %></text>
          <% end %>
          <%= for {rt, seed, mean} <- pts do %>
            <circle cx={110 + mean * 590} cy={y} r="7" class={"dot " <> rt}>
              <title><%= rt %> <%= arm %> seed <%= seed %>: <%= fmt(mean) %></title>
            </circle>
          <% end %>
          <% means = for rt <- Enum.uniq(for {rt, _, _} <- pts, do: rt) do
               vals = for {r, _, m} <- pts, r == rt, do: m
               {rt, Enum.sum(vals) / max(length(vals), 1)}
             end %>
          <%= for {rt, mu} <- means do %>
            <rect x={110 + mu * 590 - 1.5} y={y - 12} width="3" height="24" class={"mean " <> rt}>
              <title><%= rt %> mean: <%= fmt(mu) %></title>
            </rect>
            <rect x={110 + max(mu - 0.09, 0.0) * 590} y={y - 2}
                  width={min(0.18, 1.0 - max(mu - 0.09, 0.0)) * 590} height="4" class={"band " <> rt}>
              <title><%= rt %> ±0.09 noise band</title>
            </rect>
          <% end %>
        <% end %>
      </svg>
      <div class="legend">
        <span><i class="dot imp swatch"></i> imp</span>
        <span><i class="dot upstream swatch"></i> upstream (pinned DSPy)</span>
      </div>

      <h2>seal timeline</h2>
      <svg viewBox="0 0 720 120" class="chart">
        <% sorted = Enum.sort_by(@state.cells, & &1.mtime) %>
        <% t0 = case sorted do [] -> @now; [c | _] -> c.mtime end %>
        <% span = max(@now - t0, 60) %>
        <line x1="20" y1="100" x2="700" y2="100" class="axis" />
        <%= for {c, i} <- Enum.with_index(sorted) do %>
          <% x = 20 + (c.mtime - t0) / span * 660 %>
          <% y = 100 - (i + 1) * (80 / 18) %>
          <circle cx={x} cy={y} r="5" class={"dot " <> c.runtime}>
            <title><%= c.runtime %> <%= c.seed %> <%= c.arm %> sealed <%= hhmmss(c.mtime) %></title>
          </circle>
        <% end %>
        <text x="20" y="116" class="tick">start</text>
        <text x="660" y="116" class="tick">now</text>
      </svg>
    </div>
    <style>
      :root { color-scheme: dark; }
      body { background:#1a1a19; color:#fff; font: 14px/1.5 ui-monospace, monospace; margin:0; }
      .wrap { max-width: 780px; margin: 0 auto; padding: 24px 16px; overflow-x: hidden; }
      h1 { font-size: 18px; margin: 0 0 2px; }
      h2 { font-size: 14px; margin: 28px 0 8px; color:#c3c2b7; }
      .sub { color:#c3c2b7; margin: 0 0 16px; }
      .note { color:#8a897f; font-weight: normal; font-size: 12px; }
      .empty { color:#54534e; font-size:12px; margin:4px 0; }
      .statusrow { display:flex; gap:12px; flex-wrap:wrap; }
      .status { padding:8px 14px; border-radius:8px; background:#262625; display:flex; gap:10px; align-items:center;}
      .status.ok { outline:2px solid #199e70; }
      .status.bad { outline:2px solid #e66767; }
      .status.run { outline:2px solid #c98500; }
      .status.idle { outline:2px solid #3a3a38; }
      .status span { color:#c3c2b7; font-size:12px; }
      .meter { width:90px; height:8px; border-radius:4px; background:#3a3a38; overflow:hidden; }
      .meter.wide { width:180px; }
      .meter .fill { height:100%; border-radius:4px; }
      .fill.spendfill { background:#199e70; }
      .fill.imp { background:#3987e5; } .fill.upstream { background:#d95926; }
      .phases { display:flex; flex-direction:column; gap:8px; }
      .phase { display:flex; gap:12px; align-items:center; background:#212120; border-radius:8px; padding:8px 12px; flex-wrap:wrap; }
      .rtlabel { font-weight:bold; color:#c3c2b7; width:70px; }
      .phasetext { color:#c3c2b7; font-size:12px; min-width:200px; }
      .prognum { color:#8a897f; font-size:12px; }
      .prognum.dim { color:#54534e; }
      .trialarm { margin-bottom:10px; }
      .armhead { color:#c3c2b7; font-size:13px; margin:6px 0 2px; }
      ul.events { list-style:none; margin:0; padding:0; background:#212120; border-radius:10px; }
      .event { display:flex; gap:10px; padding:5px 12px; font-size:12px; border-bottom:1px solid #2b2b2a; }
      .event:last-child { border-bottom:none; }
      .etime { color:#8a897f; flex:none; }
      .ekind { flex:none; width:72px; }
      .ert { color:#8a897f; flex:none; width:64px; }
      .etext { color:#c3c2b7; overflow-wrap:anywhere; }
      .event.warn .ekind { color:#c98500; }
      .event.bad .ekind { color:#e66767; }
      .event.ok .ekind { color:#199e70; }
      .event.info .ekind { color:#8a897f; }
      table.grid { border-collapse: collapse; width:100%; }
      .grid th { color:#8a897f; font-weight:normal; font-size:12px; padding:4px; }
      .grid td { text-align:center; padding:6px 4px; border-radius:6px; font-size:12px; }
      .grid td.sealed { background:#24313f; color:#9fc7f2; }
      .grid td.pending { color:#54534e; }
      .grid td.seed { color:#8a897f; }
      svg.chart { width:100%; height:auto; background:#212120; border-radius:10px; margin-top:4px; }
      .axis { stroke:#3a3a38; stroke-width:1; }
      .lbl { fill:#c3c2b7; font-size:12px; }
      .tick { fill:#8a897f; font-size:10px; text-anchor:middle; }
      .dot.imp { fill:#3987e5; stroke:#1a1a19; stroke-width:2; }
      .dot.upstream { fill:#d95926; stroke:#1a1a19; stroke-width:2; }
      .trialdot { opacity:.85; }
      .mean.imp { fill:#3987e5; } .mean.upstream { fill:#d95926; }
      .band.imp { fill:#3987e5; opacity:.18; } .band.upstream { fill:#d95926; opacity:.18; }
      .legend { display:flex; gap:18px; margin-top:6px; color:#c3c2b7; font-size:12px; align-items:center;}
      .legend .swatch { display:inline-block; width:10px; height:10px; border-radius:50%; margin-right:5px; }
      i.dot.imp.swatch { background:#3987e5;} i.dot.upstream.swatch { background:#d95926;}
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
