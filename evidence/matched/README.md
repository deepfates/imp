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

Completed run roots get archived here at terminal as part of closing out each
campaign; the live root stays in `tmp/` while a run is in flight.
