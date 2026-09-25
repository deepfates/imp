# Local GEPA Banking77 program

This example exercises Imp's ordinary reusable-program path with real local
models. A Llama 3.2 analyzer produces evidence, a retained MLX-fused Qwen
classifier consumes the utterance and that evidence, and GEPA proposes new
instructions for both named predictors using 16 training and 8 selection rows.
Only after selection does the example evaluate the untouched 40-row Banking77
test set. It writes the selected parameter artifact and stage results as they
complete, then reconstructs the trusted program in a fresh OS BEAM, restarts
the exact fused artifact, applies the parameters, and requires byte-identical
selected predictions and errors.

Prerequisites:

- Ollama is running with `llama3.2:3b` digest
  `a80c4f17acd55265feec403c7aef86be0c25983ab279d83f3bcd3abbcb5b8b72`.
- `IMP_MLX_JOB` points to a verified completed `Imp.Clients.TrainingJob`
  checkpoint for a locally available MLX artifact.
- The source checkout still contains
  `benchmarks/data/provider-training-banking77-v1.json` (or set
  `IMP_BANKING77_DATA`).

Run it from this directory:

```sh
export IMP_MLX_JOB=/path/to/saved-job.json
export IMP_GEPA_OUTPUT=/tmp/imp-local-gepa-banking77
mix deps.get
mix run run.exs
```

The run is deliberately small: one all-component GEPA proposal, its two named
component reflections, and fixed train/selection/test identities. A neutral or
negative selected result is valid; GEPA retains the baseline when the proposal
does not improve selection. This example establishes an operational local
program/artifact lifecycle for the exact models and rows used. It does not
establish general GEPA effectiveness, paper-family parity, or BEAM superiority.
