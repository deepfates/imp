# Local COPRO Banking77 program

This ordinary consumer gives `Imp.Optimizer.COPRO` a retained, verified
MLX-fused Qwen Banking77 classifier and a local `llama3.2:3b` proposal model.
COPRO asks the proposal model for one JSON instruction candidate, then scores
that candidate and the original instruction on the same sixteen training rows.
That is deliberate: pinned DSPy 3.2.1 COPRO selects on its trainset and does not
use a separate validation set.

Only after COPRO has selected a program does the runner open the forty
optimizer-held-out rows. It evaluates the original and selected programs,
writes the selected named-parameter artifact, reconstructs trusted program code
in a fresh OS BEAM, reapplies the artifact, and requires byte-identical selected
predictions and errors from the exact fused model artifact.

The run fails unless the proposer returns exactly one JSON object with an
instruction and output prefix, both the proposal and baseline receive all
sixteen train evaluations, the proposed instruction reaches every one of its
task calls, and every task/proposal call is one uncached transport with retries
disabled.

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

One run can exercise standalone COPRO proposal, trainset selection, parameter
application, and fresh-consumer behavior on one task/model. A positive result
would not establish general COPRO effectiveness, whole-optimizer parity, or
BEAM superiority. The forty rows are optimizer-held-out for this example, not
globally untouched: earlier Imp work has used the same retained dataset.

The first frozen execution is retained in
`exercised-pre-fenced-json-fix-stopped-result.json`. The local proposer returned
a Markdown-fenced JSON candidate, but COPRO's raw fallback parser admitted the
opening fence delimiter as instruction `"```"`. That invalid candidate really
ran through sixteen fused-model calls and lost to baseline `50.0%` to `56.25%`;
the runner then stopped before held-out evaluation or artifact creation. COPRO
now decodes the enclosed JSON or rejects an invalid fence before task work. The
stopped score is parser-defect evidence, not optimizer effectiveness evidence.

The unchanged continuation after that parser repair is retained separately in
`exercised-post-fenced-json-fix-duplicate-stopped-result.json`. The enclosed
JSON decoded correctly, but it repeated the baseline instruction and changed
only COPRO's deprecated, non-rendered output prefix. Both pairs scored `56.25%`
on the pinned trainset and source order retained baseline. Because no task
instruction changed, the consumer again stopped before held-out rows rather
than presenting inert metadata churn as prompt optimization. No third model
pass was made.

The current separately named condition is
`local-copro-banking77-structured-v1`. It uses COPRO's public
`proposal_response_format: :required` option, which sends the exact one-item
instruction/prefix schema and validates it before task evaluation. This is a
source-correct proposal transport contract, not extraction or normalization of
either stopped response. It keeps the same retained fused task artifact,
`llama3.2:3b` proposer and digest, sixteen training rows, forty held-out rows,
metric, breadth, depth, temperature, call budget, and one-attempt settings. A
duplicate, neutral, or worse candidate remains a valid negative result and
cannot be replaced or retried.

That condition is retained in
`exercised-structured-duplicate-stopped-result.json`. The schema-constrained
call returned a valid object, but its instruction was again byte-identical to
the baseline and only the non-rendered prefix changed to `Route:`. Baseline and
candidate each completed all sixteen fused-model evaluations and tied at
`56.25%`; the runner then stopped before held-out access or artifact creation.
This proves the strict proposal transport works. It remains neither a genuine
prompt mutation nor a COPRO effectiveness result, and it will not be rerun or
substituted with a different proposer after observing the outcome.

The current separately identified condition is
`local-copro-banking77-objective-correct-v2`. Source review after v1 found that
Imp's proposal envelope omitted pinned DSPy COPRO's semantic instruction to
produce an improved, creative task instruction and, for later depths, to use
ordered score history to propose something better. Commit `2cc83b7` restored
those source-owned objectives without exposing train answers or forcing
uniqueness. V2 changes only that repaired proposal prompt: task/proposer models
and digests, 16/40 rows, schema, metric, breadth/depth/temperature, call budget,
and one-attempt policy remain unchanged. It executes once and may still retain
baseline or stop without held-out access.

The immutable V2 execution is retained in
`exercised-objective-correct-v2-stopped-result.json`. The proposal was a real
instruction mutation, improved COPRO's sixteen-row train selection score from
`56.25%` to `62.5%`, and reached all sixteen candidate calls. On the forty
optimizer-held-out rows, the selected program improved accuracy from `47.5%`
to `55.0%` and macro-F1 from `0.3333` to `0.4651`, with no parse errors.

The selected parameter artifact initially exposed a product bug: artifact
compatibility rejected COPRO's source-owned final-output-prefix mutation.
Commit `bd3e19b` now permits only output-prefix and instruction changes while
keeping field names, kinds, types, constraints, descriptions, metadata, and
input prefixes exact. The continuation loaded that artifact, served the exact
fused model in a fresh OS BEAM, rendered the selected instruction for all forty
single-attempt calls, and produced no parse errors. It nevertheless differed
on one ordered prediction, so the byte-identical lifecycle acceptance failed
and the run remains stopped. The retained evidence cannot decide whether that
single-row difference came from MLX backend state/numerics or an unobserved
wire difference. The parent-process held-out lift is task-specific evidence;
it is not general or multi-seed COPRO effectiveness, full parity, production
reliability, or BEAM superiority.
