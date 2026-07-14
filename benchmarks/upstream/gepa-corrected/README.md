# Corrected GEPA comparator harness

The published GEPA artifact archive cannot support Imp's strict comparator
claim: its GEPA runs exceed their reported limits, MIPROv2 does not enforce a
runtime metric budget, baseline accounting is not phase-isolated, and the
archive contains only seed 0. Imp therefore keeps the published archive as an
audited historical input and runs fresh comparators from this explicit patch.

The patch adds phase-local metric accounting, pre-callback hard budget
reservation, atomic redacted run manifests, exact source-pin checks, and a
strict sidecar builder. It does not create benchmark results, infer missing
seeds, or turn configured budgets into observed counts.

Pinned sources are recorded in `PINNED_SOURCES.json`. The patch identity is:

```text
sha256:e3b0556f56d2b53c0278c6defeb8a75907d220090e90b16cd754ef2a2a858fa9
```

Create and verify an isolated checkout with:

```sh
scripts/setup_corrected_gepa_comparator.sh tmp/gepa-fresh-corrected
cd tmp/gepa-fresh-corrected
uv sync
```

Generate the required Baseline, MIPROv2-Heavy, and GEPA commands for seeds 0
and 1 only after the checkout tests pass. Real results must contain 36 run
manifests: six families, three optimizers, and two seeds. The sidecar builder
rejects synthetic, unpinned, incomplete, over-budget, or test-selected runs.

This is a correction layer over the named upstream commits. Evidence must cite
both those commits and the patch digest; it must not describe the resulting
tree as an unmodified upstream checkout.
