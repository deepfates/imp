#!/usr/bin/env elixir
# Live observatory for matched campaign runs.
#
#   elixir observatory/observatory.exs [RUN_ROOT]
#
# Defaults to the gepa014 pilot root. Tails the run directory once a second
# (works across the peer OS processes, which only communicate via disk),
# renders sealed cells, selection/held-out scores, spend, and a seal
# timeline as a Phoenix LiveView at http://localhost:4004.

Mix.install([
  {:phoenix_playground, "~> 0.1"},
  {:jason, "~> 1.4"}
])

defmodule Observatory.Scan do
  @moduledoc "One pass over a run root -> plain map of everything drawable."

  def scan(root) do
    sealed = Path.join(root, "sealed")

    cells =
      case File.ls(sealed) do
        {:ok, files} ->
          for f <- files, String.ends_with?(f, ".json") do
            [runtime, seed, arm] =
              f |> String.trim_trailing(".json") |> String.split("-", parts: 3)

            %{
              runtime: runtime,
              seed: seed,
              arm: arm,
              mtime: File.stat!(Path.join(sealed, f), time: :posix).mtime,
              selection: sealed_selection(Path.join(sealed, f), runtime)
            }
          end

        _ ->
          []
      end

    results =
      for runtime <- ["imp", "upstream"], into: %{} do
        path = Path.join(root, "#{runtime}-result.json")

        {runtime,
         case File.read(path) do
           {:ok, body} -> parse_result(body, runtime)
           _ -> nil
         end}
      end

    %{
      root: root,
      now: System.system_time(:second),
      cells: Enum.sort_by(cells, & &1.mtime),
      results: results
    }
  end

  defp sealed_selection(path, "upstream") do
    with {:ok, body} <- File.read(path),
         {:ok, %{"selection" => sel}} <- Jason.decode(body) do
      %{mean: sel["mean_constraint_score"], parse_errors: sel["parse_errors"]}
    else
      _ -> nil
    end
  end

  defp sealed_selection(path, "imp") do
    with {:ok, body} <- File.read(path),
         {:ok, %{"payload" => payload}} <- Jason.decode(body) do
      champ = payload["candidates"][payload["champion_id"]] || %{}
      %{mean: champ["score"], parse_errors: nil}
    else
      _ -> nil
    end
  end

  defp parse_result(body, _runtime) do
    case Jason.decode(body) do
      {:ok, decoded} ->
        arms =
          for seed_entry <- decoded["seeds"] || [],
              arm <- seed_entry["arms"] || [] do
            rows = arm["rows"] || %{}

            %{
              seed: to_string(seed_entry["seed"]),
              arm: arm["arm"] || arm["name"],
              held_out: split_summary(rows["held_out"]),
              selection: split_summary(rows["selection"]),
              spend: split_spend(rows)
            }
          end

        %{status: decoded["status"], error: summarize_error(decoded["error"]), arms: arms}

      _ ->
        nil
    end
  end

  defp summarize_error(nil), do: nil
  defp summarize_error(err), do: err |> to_string() |> String.slice(0, 120)

  defp split_summary(nil), do: nil

  defp split_summary(rows) do
    scores = for r <- rows, is_number(r["score"]), do: r["score"]

    if scores == [] do
      nil
    else
      %{
        mean: Enum.sum(scores) / length(scores),
        n: length(rows),
        zeros: Enum.count(scores, &(&1 == 0.0)),
        ones: Enum.count(scores, &(&1 == 1.0)),
        scores: scores
      }
    end
  end

  defp split_spend(rows) do
    for {_split, rs} <- rows, is_list(rs), r <- rs, reduce: 0.0 do
      acc ->
        case r["gateway_reported_cost"] || r["adapter_computed_cost"] do
          c when is_number(c) -> acc + c
          cs when is_list(cs) -> acc + Enum.sum(for x <- cs, is_number(x), do: x)
          _ -> acc
        end
    end
  end
end

defmodule Observatory.Live do
  use Phoenix.LiveView

  @seeds ~w(2026072705 2026072706 2026072707)
  @arms ~w(baseline gepa mipro_v2)
  @runtimes ~w(imp upstream)

  def mount(_params, _session, socket) do
    root = Application.get_env(:observatory, :root)
    if connected?(socket), do: :timer.send_interval(1000, self(), :tick)
    {:ok, assign(socket, data: Observatory.Scan.scan(root), root: root)}
  end

  def handle_info(:tick, socket) do
    {:noreply, assign(socket, data: Observatory.Scan.scan(socket.assigns.root))}
  end

  defp cell(data, runtime, seed, arm) do
    Enum.find(data.cells, &(&1.runtime == runtime and &1.seed == seed and &1.arm == arm))
  end

  defp arm_result(data, runtime, seed, arm) do
    case data.results[runtime] do
      %{arms: arms} -> Enum.find(arms, &(&1.seed == seed and &1.arm == arm))
      _ -> nil
    end
  end

  defp fmt(nil), do: "–"
  defp fmt(x) when is_float(x), do: :erlang.float_to_binary(x, decimals: 3)
  defp fmt(x), do: to_string(x)

  defp total_spend(data) do
    for {_rt, res} <- data.results, res, arm <- res.arms, reduce: 0.0 do
      acc -> acc + (arm.spend || 0.0)
    end
  end

  defp status_class(data, runtime) do
    case data.results[runtime] do
      %{status: "complete"} -> "ok"
      %{status: "stopped"} -> "bad"
      nil -> if data.cells == [], do: "idle", else: "run"
      _ -> "run"
    end
  end

  # score dot-strip SVG: one row per arm, imp vs upstream dots per seed + mean tick
  defp dotstrip(data, split) do
    for arm <- @arms do
      pts =
        for rt <- @runtimes, seed <- @seeds,
            r = arm_result(data, rt, seed, arm),
            s = r && Map.get(r, split),
            s != nil,
            do: {rt, s.mean}

      {arm, pts}
    end
  end

  def render(assigns) do
    ~H"""
    <div class="wrap">
      <h1>⚡ matched-campaign observatory</h1>
      <p class="sub"><%= @root %> · <%= Enum.count(@data.cells) %>/18 cells sealed · recorded eval spend $<%= fmt(total_spend(@data)) %></p>

      <div class="statusrow">
        <div :for={rt <- ["imp", "upstream"]} class={"status " <> status_class(@data, rt)}>
          <b><%= rt %></b>
          <span><%= case @data.results[rt] do
            %{status: s, error: nil} -> s
            %{status: s, error: e} -> "#{s}: #{e}"
            nil -> "running (no result file yet)"
          end %></span>
        </div>
      </div>

      <h2>cell grid</h2>
      <table class="grid">
        <tr><th></th><th :for={arm <- ["baseline", "gepa", "mipro_v2"]} colspan="2"><%= arm %></th></tr>
        <tr><th>seed</th><%= for _ <- 1..3 do %><th>imp</th><th>up</th><% end %></tr>
        <tr :for={seed <- ["2026072705", "2026072706", "2026072707"]}>
          <td class="seed"><%= String.slice(seed, -2, 2) %></td>
          <%= for arm <- ["baseline", "gepa", "mipro_v2"], rt <- ["imp", "upstream"] do %>
            <td class={if cell(@data, rt, seed, arm), do: "sealed", else: "pending"}>
              <%= case cell(@data, rt, seed, arm) do
                %{selection: %{mean: m}} when is_number(m) -> fmt(m)
                %{} -> "✓"
                nil -> "·"
              end %>
            </td>
          <% end %>
        </tr>
      </table>

      <h2>held-out means <span class="note">(dots = seeds; ±0.09 noise band shown per measured floor)</span></h2>
      <svg viewBox="0 0 720 190" class="chart">
        <%= for {{arm, pts}, i} <- Enum.with_index(dotstrip(@data, :held_out)) do %>
          <% y = 40 + i * 50 %>
          <text x="8" y={y + 4} class="lbl"><%= arm %></text>
          <line x1="110" y1={y} x2="700" y2={y} class="axis" />
          <%= for tick <- [0.0, 0.25, 0.5, 0.75, 1.0] do %>
            <line x1={110 + tick * 590} y1={y - 4} x2={110 + tick * 590} y2={y + 4} class="axis" />
            <text :if={i == 2} x={110 + tick * 590} y={y + 22} class="tick"><%= tick %></text>
          <% end %>
          <%= for {rt, mean} <- pts do %>
            <circle cx={110 + mean * 590} cy={y} r="7" class={"dot " <> rt}>
              <title><%= rt %> <%= arm %>: <%= fmt(mean) %></title>
            </circle>
          <% end %>
          <% means = for {rt, _} <- Enum.uniq_by(pts, &elem(&1, 0)) do
               vals = for {r, m} <- pts, r == rt, do: m
               {rt, Enum.sum(vals) / max(length(vals), 1)}
             end %>
          <%= for {rt, mu} <- means, pts != [] do %>
            <rect x={110 + mu * 590 - 1.5} y={y - 12} width="3" height="24" class={"mean " <> rt}>
              <title><%= rt %> mean: <%= fmt(mu) %></title>
            </rect>
            <rect x={110 + max(mu - 0.09, 0.0) * 590} y={y - 2} width={min(0.18, 1.0 - max(mu - 0.09, 0.0)) * 590} height="4" class={"band " <> rt} />
          <% end %>
        <% end %>
      </svg>
      <div class="legend">
        <span><i class="dot imp swatch"></i> imp</span>
        <span><i class="dot upstream swatch"></i> upstream (pinned DSPy)</span>
      </div>

      <h2>seal timeline</h2>
      <svg viewBox="0 0 720 120" class="chart">
        <% t0 = case @data.cells do [] -> @data.now; [c | _] -> c.mtime end %>
        <% span = max(@data.now - t0, 60) %>
        <line x1="20" y1="100" x2="700" y2="100" class="axis" />
        <%= for {c, i} <- Enum.with_index(@data.cells) do %>
          <% x = 20 + (c.mtime - t0) / span * 660 %>
          <% y = 100 - (i + 1) * (80 / 18) %>
          <circle cx={x} cy={y} r="5" class={"dot " <> c.runtime}>
            <title><%= c.runtime %> <%= c.seed %> <%= c.arm %></title>
          </circle>
        <% end %>
        <text x="20" y="116" class="tick">start</text>
        <text x="660" y="116" class="tick">now</text>
      </svg>
    </div>
    <style>
      :root { color-scheme: dark; }
      body { background:#1a1a19; color:#fff; font: 14px/1.5 ui-monospace, monospace; margin:0; }
      .wrap { max-width: 780px; margin: 0 auto; padding: 24px 16px; }
      h1 { font-size: 18px; margin: 0 0 2px; }
      h2 { font-size: 14px; margin: 28px 0 8px; color:#c3c2b7; }
      .sub { color:#c3c2b7; margin: 0 0 16px; }
      .note { color:#8a897f; font-weight: normal; font-size: 12px; }
      .statusrow { display:flex; gap:12px; }
      .status { padding:8px 14px; border-radius:8px; background:#262625; display:flex; gap:10px; align-items:center;}
      .status.ok { outline:2px solid #199e70; }
      .status.bad { outline:2px solid #e66767; }
      .status.run { outline:2px solid #c98500; }
      .status span { color:#c3c2b7; font-size:12px; }
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
      .mean.imp { fill:#3987e5; } .mean.upstream { fill:#d95926; }
      .band.imp { fill:#3987e5; opacity:.18; } .band.upstream { fill:#d95926; opacity:.18; }
      .legend { display:flex; gap:18px; margin-top:6px; color:#c3c2b7; font-size:12px; align-items:center;}
      .legend .swatch { display:inline-block; width:10px; height:10px; border-radius:50%; margin-right:5px; }
      i.dot.imp.swatch { background:#3987e5;} i.dot.upstream.swatch { background:#d95926;}
    </style>
    """
  end
end

root =
  case System.argv() do
    [r | _] -> Path.expand(r)
    [] -> Path.expand("tmp/matched_gepa_mipro_ifbench_gepa014", File.cwd!())
  end

Application.put_env(:observatory, :root, root)
IO.puts("observatory watching #{root}")
PhoenixPlayground.start(live: Observatory.Live, port: 4004)
