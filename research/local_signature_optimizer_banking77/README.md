# Local SignatureOptimizer Banking77 program

This ordinary consumer gives `Imp.Optimizer.SignatureOptimizer` a retained,
MLX-fused Qwen Banking77 classifier and a local `llama3.2:3b` proposer. The
proposer sees sixteen training rows and produces two task-specific instructions.
Imp evaluates the original and both candidates only on eight validation rows;
the original program wins ties. The forty optimizer-held-out rows remain
unavailable until selection is final.

The run requires both proposal calls to parse without fallback and every
candidate instruction to reach the fused task model's rendered messages. It
then evaluates baseline and selected programs, writes the selected parameter
artifact, reconstructs trusted code in a fresh OS BEAM, reapplies the artifact,
and requires byte-identical selected predictions and errors.

Prerequisites:

- Ollama is running with `llama3.2:3b` digest
  `a80c4f17acd55265feec403c7aef86be0c25983ab279d83f3bcd3abbcb5b8b72`.
- `IMP_MLX_JOB` points to the retained verified completed MLX `TrainingJob`.
- The checkout contains `benchmarks/data/provider-training-banking77-v1.json`.

```sh
export IMP_MLX_JOB=/path/to/training-job.json
mix deps.get
mix run run.exs
```

One result can establish this public proposal, validation-selection, artifact,
and fresh-consumer lifecycle on one task/model. It cannot establish general
SignatureOptimizer effectiveness, upstream parity for this Imp-native
extension, or BEAM superiority.

The first frozen execution is retained in `exercised-stopped-result.json`. Both
proposal transports completed, but they collapsed to one distinct admitted
string: an explanatory JSON preamble rather than a trustworthy task
instruction. That string was genuinely rendered and evaluated on validation,
but the runner stopped before exposing held-out rows or writing a selected
artifact. Its apparent validation gain is therefore not promoted as optimizer
evidence. The run was not loosened, normalized, or repeated after observation.
