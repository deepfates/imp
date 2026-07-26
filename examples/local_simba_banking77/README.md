# Local SIMBA Banking77 program

This ordinary consumer example runs `Imp.Optimizer.SIMBA` against a real local
program. The task LM is the retained MLX-fused Qwen Banking77 classifier and a
local `llama3.2:3b` supplies reflection advice. SIMBA samples the classifier at
temperature, creates and evaluates non-identity demonstration or reflective
rule mutations on sixteen training rows, and selects between the baseline and
search history on eight validation rows. The forty untouched rows are
unavailable until selection.

The validation winner may honestly be the baseline. The example still requires
that a real instruction or demonstration mutation reached the fused task model
during search; a candidate count or reflection response alone is not
sufficient. It then writes the
selected parameter-only artifact, reconstructs the trusted program in a fresh
OS BEAM, applies that artifact, and requires byte-identical untouched
predictions and errors.

Prerequisites:

- Ollama is running with `llama3.2:3b` digest
  `a80c4f17acd55265feec403c7aef86be0c25983ab279d83f3bcd3abbcb5b8b72`.
- `IMP_MLX_JOB` points to the retained, verified completed MLX `TrainingJob`.
- The checkout contains `benchmarks/data/provider-training-banking77-v1.json`.

```sh
export IMP_MLX_JOB=/path/to/training-job.json
mix deps.get
mix run run.exs
```

This one task/model run establishes an operational SIMBA mutation, validation,
artifact, and fresh-consumer lifecycle. A neutral or negative selected outcome
does not establish general SIMBA effectiveness, DSPy parity, or BEAM
superiority.

The first frozen rule-only execution is preserved in
`exercised-rule-only-stopped-result.json`. Both sampled task rollouts agreed
within every example, so SIMBA had no eligible better/worse contrast and
correctly produced no reflection candidate. The runner stopped before opening
the untouched test set. The ordinary workflow now enables SIMBA's full public
demonstration-plus-rule strategy set; the stopped predecessor remains unchanged.
That predecessor result is not mutation or effectiveness evidence.

The completed full-strategy result is preserved in `exercised-result.json`.
One real appended demonstration improved the search minibatch from `0.50` to
`0.75` but regressed on validation from the baseline's `0.625` to `0.375`, so
SIMBA correctly retained baseline. Baseline and selected then both scored
`0.475` accuracy and `0.3333` macro-F1 with zero errors on the untouched forty
rows, and the selected artifact reproduced byte-identically in a fresh OS
BEAM. This is operational lifecycle evidence and an honest overfit rejection,
not a general effectiveness result.
