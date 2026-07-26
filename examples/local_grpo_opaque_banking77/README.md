# Opaque-route GRPO Banking77 front door

This ordinary consumer example asks whether local GRPO can learn a mapping that
the base prompt does not disclose. The program accepts a real Banking77 card
payment utterance and must return exactly one of four opaque route codes:
`R17`, `R42`, `R68`, or `R93`. Neither the signature nor its instruction says
what any code means. Supervision reaches the policy only through model-generated
groups and the exact-route reward.

The treatment is frozen before any execution:

- `Qwen/Qwen2.5-0.5B-Instruct` revision
  `7ae557604adf67be50417f59c2c2f167def9a775`, Apache-2.0, through the existing
  pinned CPython 3.12 / TRL 1.6.0 / Transformers 4.57.6 / PEFT 0.18.1 /
  PyTorch 2.10.0 MPS-only worker;
- the first 18 rows of each route are training data (72), the last two are
  validation-only (8), and the existing frozen 40-row test split is kept out
  of optimization and checkpoint selection;
- four ordinary generated completions per prompt group, exact semantic rewards,
  seed `20260725`, greedy validation and evaluation, and strict JSON decoding
  with no fallback;
- the prior corrected treatment's documented TRL defaults: learning rate
  `1.0e-6`, `beta: 0.0`, DAPO loss, group reward scaling, and the contract's
  fixed rank-8 `q_proj`/`v_proj` LoRA configuration;
- `38` updates at width four. Imp deliberately preserves DSPy/mmGRPO's pinned
  full-batch padding: each 72-row schedule has 76 source slots, so two complete
  schedules contain 152 prompt groups. The runner requires every source row at
  least twice, exactly 64 rows twice and eight rows three times. This is not an
  assertion of two unpadded epochs.

Every accepted update is bound to the versioned durable protocol and checkpoint.
The worker must restore LoRA, optimizer, scheduler, Trainer and MPS RNG state,
and the runner verifies all 38 content-addressed step artifacts. Validation
chooses the highest-scoring trained checkpoint with the earliest checkpoint
winning ties. A separate stable rule compares that selected trained checkpoint
with the base on the eight validation rows; the 40 frozen test labels cannot
affect either selection.

After selection, the runner evaluates both base and selected-trained arms on the
same frozen test rows so the task-specific learned effect is visible. It saves
the exact verified `TrainingJob` and a portable program, stops the deployment,
loads and rebinds them in a fresh OS BEAM, and requires the chosen arm's ordered
predictions and errors plus artifact identity to be byte-identical. Each stage
is atomically retained before a later acceptance check can fail.

The run requires the already-installed environment and model snapshot. It does
not install, download, call a provider, normalize malformed outputs, or retry a
scientific treatment:

```sh
export IMP_GRPO_OPAQUE_OUTPUT=/tmp/imp-local-grpo-opaque-banking77
export IMP_TRL_PYTHON=/path/to/pinned-venv/bin/python
export IMP_TRL_MODEL=/path/to/pinned-qwen-snapshot
mix run examples/local_grpo_opaque_banking77/run.exs
```

`IMP_GRPO_OPAQUE_DEFINE_ONLY=1` loads the definition without preflight, model,
worker, or output activity. A stopped run may be continued only through
`IMP_GRPO_OPAQUE_RESUME=1` against its exact retained runner, contract, data,
checkpoint, and completed stages.

## What a completed run can and cannot establish

A positive result would show task/model-specific learned behavior on this
frozen opaque-label problem, real multi-group/multi-step local GRPO, durable
checkpoint selection, deployable artifact use, and fresh-process reproduction.
A neutral or negative result remains valid. One run cannot establish general
GRPO or mmGRPO effectiveness, parity with DSPy beyond the pinned scheduler and
public lifecycle contracts, production reliability, or BEAM superiority. The
40 test rows have appeared in earlier Imp work, so they are optimizer-held-out
here but not globally untouched research data.

The retained run in `exercised-result.json` is a complete neutral result. All
38 official updates changed trainable tensors; 37 steps had non-uniform rewards
and 36 had non-zero group-relative advantages. Nevertheless, every trained
checkpoint scored the same 0.25 validation accuracy as base, and base and the
selected step-one trained artifact both scored 0.475 accuracy / 0.45758
macro-F1 / zero errors on the frozen forty rows. Stable selection retained
base, and fresh OS execution reproduced its exact artifact identity and ordered
outputs byte-for-byte. This establishes that the full ordinary usefulness path
can return an honest non-win; it does not establish learned improvement.

## Fresh-label usefulness treatment

`usefulness-v1-treatment.json` binds the same public runner, exact Qwen
revision, TRL 1.6/MPS/LoRA backend, 38-step two-padded-schedule budget, opaque
route prompt, exact semantic reward, validation-only selection, and fresh-OS
artifact lifecycle to a new source-frozen Banking77 slice. It changes no model
or trainer setting.

The data snapshot is `benchmarks/data/grpo-usefulness-banking77-v1.json`. It is
derived from `PolyAI/banking77` revision
`796a4623935746f71378f0ebd435635a8ce08e50` (CC-BY-4.0; original parquet files
388,204 bytes combined). Before any base or trained prediction, four label ids
were selected by a declared SHA-256 ordering after excluding the predecessor's
four labels: declined transfer, getting a physical card, verifying source of
funds, and exchange rate. Their semantic names remain audit metadata and never
enter the model prompt; they map to the same opaque `R17/R42/R68/R93` outputs.
Within each source label, a second declared SHA-256 ordering freezes 18 train,
2 validation, and 10 held-out rows, for disjoint 72/8/40 splits.

Run the no-model preflight or the complete treatment with the already-installed
pinned local worker/model:

```sh
export IMP_GRPO_OPAQUE_TREATMENT_CONFIG="$PWD/examples/local_grpo_opaque_banking77/usefulness-v1-treatment.json"
export IMP_BANKING77_DATA="$PWD/benchmarks/data/grpo-usefulness-banking77-v1.json"
export IMP_GRPO_OPAQUE_OUTPUT=/new/empty/output

IMP_GRPO_OPAQUE_PREFLIGHT_ONLY=1 mix run examples/local_grpo_opaque_banking77/run.exs
# or, from a different new output path:
mix run examples/local_grpo_opaque_banking77/run.exs
```

This is a one-task/one-model usefulness measurement. A positive result cannot
establish general GRPO effectiveness or parity; a neutral or negative result
cannot establish GRPO ineffectiveness. No source label, row, reward, prompt,
seed, optimizer setting, selection rule, or test metric may change after base
evaluation begins.

The immutable run in `exercised-usefulness-v1-result.json` completed all 38
official TRL/MPS updates. Every update changed trainable tensors, all 38 had
non-uniform semantic rewards, and 37 had non-zero group-relative advantages.
Every trained checkpoint nevertheless tied base at 0.25 validation accuracy,
so stable selection retained base. Base and trained then tied on the frozen
forty at 0.40 accuracy / 0.28129 macro-F1 / two parse errors; fresh OS
execution reproduced the selected base artifact and ordered results
byte-for-byte. This is a complete neutral result on one fresh-label slice, not
evidence of useful learning, general GRPO/mmGRPO effectiveness, parity,
production reliability, or BEAM superiority.

## Disclosed-semantics treatment

`semantic-v1-treatment.json` defines a separate ordinary classification
treatment over the same source-frozen 72/8/40 rows. Unlike the opaque-label
treatments, its instruction discloses the meaning of each route code. The
model, official TRL 1.6 defaults, LoRA shape, 38-step schedule, exact semantic
reward, validation-only arm selection, and frozen test boundary are unchanged.
The instruction digest is retained in preflight so a resumed job cannot cross
the information boundary.

This condition asks whether the completed GRPO engine can improve a small,
learnable real classification task; it does not ask the policy to infer a
secret permutation. Exact-route reward still requires the semantically correct
class, so returning valid JSON or a well-formed route token alone cannot earn
reward. Run it once from a new output directory with the existing cached model
and worker:

```sh
export IMP_GRPO_OPAQUE_TREATMENT_CONFIG="$PWD/examples/local_grpo_opaque_banking77/semantic-v1-treatment.json"
export IMP_BANKING77_DATA="$PWD/benchmarks/data/grpo-usefulness-banking77-v1.json"
export IMP_GRPO_OPAQUE_OUTPUT=/new/empty/output
mix run examples/local_grpo_opaque_banking77/run.exs
```

That exact condition is preserved as
`exercised-trec-semantic-v1-stopped-result.json` and must not be resumed. It
stopped after three real updates, before trained selection or test, because the
instruction incorrectly mapped `R42` to entity and `R68` to human; the frozen
dataset legend is `R17=DESC`, `R42=HUM`, `R68=LOC`, `R93=NUM`. Entity is not in
the slice. The partial run is not a usefulness result.

The trained arm is deployed only if it beats base on the eight validation
rows. A completed positive, neutral, or negative result remains specific to
this task, model, seed, and budget.

The first execution is preserved in
`exercised-semantic-v1-stopped-result.json` and must not be resumed or
reinterpreted. It stopped after 29 real MPS updates, before trained selection or
test, because the frozen `R42` gloss said “obtain a physical card” while all
thirty `R42` source utterances ask about locating, receiving, or setting a card
PIN. The partial run proves no semantic usefulness outcome.

`trec-semantic-v1-treatment.json` is a distinct source-disjoint natural-task
condition, not a continuation of that stopped run. It uses the already-local
CogComp/TREC coarse split (24 train, 8 validation, 40 official-test rows),
discloses the four answer-type meanings, and binds a separate 14-step contract.
The pinned TRL 1.6 LoRA recipe uses learning rate `1e-5`; four model-generated
completions and exact coarse-class rewards still drive every group. The same
validation-only arm rule, artifact verification, fresh-process rebind, and
frozen-test boundary apply. Run it with:

```sh
export IMP_GRPO_OPAQUE_TREATMENT_CONFIG="$PWD/examples/local_grpo_opaque_banking77/trec-semantic-v1-treatment.json"
export IMP_GRPO_DATA="$PWD/benchmarks/data/simba-trec-coarse-v1.json"
export IMP_TRL_CONTRACT="$PWD/priv/trl_worker/qwen-trec-14-step-contract.json"
export IMP_GRPO_OPAQUE_OUTPUT=/new/empty/output
mix run examples/local_grpo_opaque_banking77/run.exs
```

## Source-guided TREC usefulness treatment

`trec-source-guided-v1-treatment.json` and
`trec-source-guided-v1-data.json` freeze a later, correctly labeled treatment
over real TREC questions that excludes every source row used by the SIMBA TREC
fixture. It uses 64 train rows, 32 validation rows, and 40 official-test rows,
balanced across `DESC`, `HUM`, `LOC`, and `NUM`. Those meanings never appear in
the model prompt: the policy sees only the opaque routes `R17/R42/R68/R93`, so
valid formatting alone cannot earn the externally computed semantic reward.

The immutable result is
`exercised-trec-source-guided-v1-result.json`. Thirty-three official TRL/MPS
updates consumed 66 prompt groups with eight ordinary model-generated
completions per group. All 33 updates changed trainable tensors and 31 had
non-uniform rewards. Validation selected step five: accuracy improved from
`0.21875` to `0.3125` and macro-F1 from `0.08974` to `0.21008`. On the held-out
40 rows, however, the selected artifact regressed from `0.25` to `0.225`
accuracy and from `0.10204` to `0.09783` macro-F1, with zero parse errors in
both arms. The predeclared positive rule therefore failed. The trained artifact
still saved, loaded, served, and reproduced its ordered predictions and errors
byte-for-byte in a fresh OS BEAM.

This is a real ordinary-usefulness measurement and a negative result for one
task, model, seed, and budget. It proves the multi-group/multi-step product and
artifact lifecycle execute; it does not prove useful GRPO learning in general,
GRPO/mmGRPO parity, production reliability, or BEAM superiority.
