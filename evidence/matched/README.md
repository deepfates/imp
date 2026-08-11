# Sealed matched-campaign evidence

Durable archives of completed (or preregistered-stopped) matched imp-vs-DSPy
run roots, previously living only under gitignored `tmp/`. Each archive is the
entire run root: `sealed/*.json` cells, `{imp,upstream}-result.json` row-level
ledgers (the paired-analysis substrate), and any stop artifacts. Verify with
`shasum -a 256 -c SHA256SUMS`; unpack with `tar --zstd -xf <archive>` (they
extract to the original `tmp/`-relative directory name, so recomputation
scripts run unchanged against `tmp/<name>` after extracting there).

| Archive | What it is |
|---|---|
| `matched_gepa_mipro_ifbench_gepa014` | The completed 3-seed pilot (~$8): runtime row-level parity result (192 paired rows, p=0.164), noise-floor measurement, and the config-starvation discovery. Interpreted in `examples/matched_gepa_mipro_ifbench_gepa014/PREREGISTRATION.md`. |
| `matched_ifbench_rehearsal16k-stop1-provider503` | Rehearsal launch 1: both baselines sealed (upstream 0.792 reproducing the published 0.787), stopped by a provider 503 under the zero-retry rule. Addendum 1. |
| `matched_ifbench_rehearsal16k-stop2-envelope` | Rehearsal launch 2: immediate envelope-check stop caused by the retry fix uninstalling transport telemetry. Addendum 2. |
| `matched_ifbench_rehearsal16k-drill-sigterm` | Deliberate stop drill verifying the rescue path writes coherent artifacts on SIGTERM. |
| `...-stop3-optceiling` | GEPA reflection ceiling (24, estimated) exhausted at rollout 752/1200; measured need ~2.5/iteration → raised to 96. Addendum 3. |
| `...-stop4-preemptive`, `...-stop5-telemetry-upgrade`, `...-stop6-bluedots` | Operator-initiated stops to land audited ceiling fixes and live telemetry (both runners' snapshots, imp's GEPA callback scores). Addenda 4–5. |
| `...-stop7-commitdrift` | Launch-commit guard refused after the operator committed during a live run. Addendum 6. The repo-freeze rule dates from here. |
| **`...-stop8-mipro-fidelity`** | **The campaign's principal result so far**: BOTH GEPA arms sealed at source-faithful budget — imp champion 0.8542 vs upstream 0.8698 on selection, with both full trial ledgers. Stopped when imp's MIPROv2 declared its Optuna-startup fidelity boundary (≤9 trials). Addendum 7. |
| `...-stop9-costcache` | Died at GEPA 1120/1200 on 1.4e-6 USD of cost drift: OpenAI implicit prompt caching rounds cache-read line items below the absolute 1e-6 tolerance. Tolerance made relative. Addendum 8. |
| `...-stop10-sessioncrash` | Supervising process crashed at GEPA 800/1200; rescue path worked, nothing recoverable by design (`cache: false`, no checkpoint — gepa 0.1.4 parity). Addendum 9; detached launching adopted. |

Completed run roots get archived here at terminal as part of closing out each
campaign; the live root stays in `tmp/` while a run is in flight.
