# SIMBA on an opaque TREC router

This ordinary local example asks SIMBA to improve a four-service question
router. The data is a frozen balanced slice of human-labeled CogComp/TREC:
24 calibration-train rows and eight separate validation rows come from the
official training source, while forty held-out rows come from the disjoint
official TREC-10 source. The public prompt exposes only the internal route
codes `R17/R42/R68/R93`; their TREC coarse meanings are available to the
optimizer only through real task outcomes and any demonstrations or rules it
creates.

Both task trajectories and reflection use the pinned local `llama3.2:3b`
Ollama model with cache and retries disabled. SIMBA runs three public search
steps, validates the full finalist ladder on the eight validation rows, and
keeps baseline on ties. Only after selection does the runner score baseline
and selected programs on the frozen forty. It saves the source program and
selected parameter artifact, loads both in a fresh OS BEAM, and requires the
same model/runtime identity and byte-identical ordered selected results.

```sh
mix deps.get
IMP_SIMBA_TREC_PREFLIGHT_ONLY=1 mix run run.exs
mix run run.exs
```

The runner atomically writes every completed stage to
`$IMP_SIMBA_TREC_OUTPUT` (default `/tmp/imp-local-simba-trec`). A positive
result would be one task/model mutation and held-out-usefulness result. A
baseline selection or held-out regression is an equally valid negative result.
Neither outcome establishes general SIMBA effectiveness, full DSPy parity,
production reliability, or BEAM superiority.

The immutable first run is retained in `exercised-result.json`. SIMBA created
one real demonstration mutation and rendered it in 26 task calls across 96
single-attempt optimization transports. Baseline and mutation both scored zero
on validation, so stable selection retained baseline. All forty baseline and
selected held-out calls then failed the strict typed contract: `llama3.2:3b`
emitted shortened markers such as `[[ R42 ]]` instead of the rendered
`[[ ## route ## ]]` field. The selected baseline artifact still saved, loaded,
and reproduced all ordered errors byte-for-byte in a fresh OS BEAM. This is a
complete operational run but an incomplete usefulness measurement; it does not
establish a selected SIMBA mutation or task quality.
