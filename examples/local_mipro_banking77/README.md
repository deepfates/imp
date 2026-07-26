# Local MIPROv2 Banking77 program

This ordinary consumer example optimizes a real retained MLX-fused Qwen
classifier with `Imp.Optimizer.MIPROv2`. A local Llama 3.2 model proposes two
grounded instruction candidates; MIPROv2 evaluates two categorical trials on
eight selection rows after using sixteen training rows for proposal context and
demo bootstrapping. The untouched forty-row test set is unavailable to search.

After selection, the example evaluates both baseline and selected programs on
the untouched rows, writes a parameter-only optimizer artifact, reconstructs
the trusted program in a fresh OS BEAM, reapplies the artifact, and requires
byte-identical selected predictions and errors. Every completed stage is
written atomically before its acceptance checks.

Prerequisites:

- Ollama is running with `llama3.2:3b` digest
  `a80c4f17acd55265feec403c7aef86be0c25983ab279d83f3bcd3abbcb5b8b72`.
- `IMP_MLX_JOB` points to a verified completed MLX `TrainingJob` for the local
  fused Banking77 artifact.
- The source checkout contains
  `benchmarks/data/provider-training-banking77-v1.json`, or
  `IMP_BANKING77_DATA` points to that exact dataset.

```sh
export IMP_MLX_JOB=/path/to/saved-job.json
mix deps.get
mix run run.exs
```

This small run can establish that the public MIPROv2 workflow uses real task
and proposal models, selects only on validation, and yields a reusable program.
Its task/model-specific held-out result cannot establish general MIPROv2
effectiveness, exact Optuna sampling parity, or BEAM superiority.
