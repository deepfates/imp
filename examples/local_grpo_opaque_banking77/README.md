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
