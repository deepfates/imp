# Local GRPO Banking77 program

This example runs Imp's public GRPO training lifecycle against the bundled,
pinned local TRL worker. It uses one real Banking77 training prompt, four
ordinary model-generated rollouts from Qwen2.5-0.5B-Instruct, externally
computed semantic rewards, and one official TRL LoRA optimizer update on MPS.
It then compares the exact base and trained policies on frozen selection and
untouched test rows, saves the content-verified training job and portable
program, and reproduces the trained test outputs from a fresh OS BEAM.

The run requires the already-installed pinned environment and model snapshot:

- CPython 3.12, TRL 1.6.0, Transformers 4.57.6, PEFT 0.18.1, PyTorch 2.10.0;
- `Qwen/Qwen2.5-0.5B-Instruct` revision
  `7ae557604adf67be50417f59c2c2f167def9a775`;
- Apple Silicon MPS with CPU fallback disabled.

By default the example uses the verified local paths created by Imp's TRL
setup work. They may be supplied explicitly without changing the frozen task:

```sh
export IMP_TRL_PYTHON=/path/to/pinned-venv/bin/python
export IMP_TRL_MODEL=/path/to/pinned-qwen-snapshot
export IMP_GRPO_OUTPUT=/tmp/imp-local-grpo-banking77
mix run examples/local_grpo_banking77/run.exs
```

The data identities, 16/8/40 train/selection/test split, seed, prompt,
four-rollout group, reward, and optimizer settings are fixed in `run.exs`.
Selection may honestly retain the base policy, and a uniform-reward group may
honestly produce a no-op update. One completed run can establish only the
task/model-specific result it records; it cannot establish general GRPO
effectiveness, mmGRPO parity, production reliability, or BEAM superiority.

The retained exercised run in `exercised-result.json` is deliberately negative:
all four ordinary rollouts were malformed under the strict typed adapter, so
the semantic rewards were uniformly `-1`, TRL computed zero advantages and
loss, and the LoRA tensors did not change. Selection retained base; base and
trained both scored `0.025` accuracy and `0.04545` macro-F1 with 39 parse errors
on the untouched 40 rows. A fresh OS BEAM reproduced the selected base outputs
byte-for-byte. This is useful evidence that the lifecycle admits a truthful
no-signal update, not evidence that GRPO is ineffective.

The current default is a lightweight one-group/one-step JSON-adapter run. To
exercise the durable multi-group/multi-step backend across four frozen source
rows per step, select the pinned contract and matching public optimizer
width/budget:

```sh
export IMP_TRL_CONTRACT="$PWD/priv/trl_worker/qwen-two-step-contract.json"
export IMP_GRPO_TRAIN_STEPS=2
export IMP_GRPO_TRAIN_WIDTH=4
export IMP_GRPO_OUTPUT=/tmp/imp-local-grpo-banking77-two-step
mix run examples/local_grpo_banking77/run.exs
```

Each step consumes four ordered source-bound prompt groups with four completions
per group. Step two must resume the exact step-one adapter, optimizer,
scheduler, Trainer state, and MPS RNG; repeated one-step jobs are not accepted
as an equivalent trajectory.

The retained two-group/two-step acceptance is summarized in
`exercised-multistep-result.json`. Both official steps completed and global
state advanced `0 -> 1 -> 2`; the final artifact contains the full chain and
its trained predictions reproduced byte-for-byte from a fresh OS BEAM. All
four prompt groups still produced uniform malformed-output rewards, so the
result remains a no-signal lifecycle proof rather than learned usefulness.

A later free-generation treatment used four prompt groups per step and the
strict Imp-native `SingleField` adapter. Its immutable negative result is
`exercised-single-field-result.json`: Qwen consistently emitted labelled text
such as `route (R17)` rather than the declared exact value, so all rewards were
zero, both steps were truthful no-ops, and base was retained. The current
ordinary runner uses the public JSON adapter, which was selected independently
before that result and keeps free autoregressive training rather than
substituting a choice-normalized policy for GRPO.

The corresponding immutable JSON-adapter treatment is
`exercised-json-multistep-result.json`. Its first official step produced valid
JSON samples, non-uniform semantic rewards and group-relative advantages, and
changed the LoRA tensors. Its second step's samples were all malformed. The
final trained policy tied base on frozen selection (`0.875` accuracy) and
untouched test (`0.725` accuracy), so stable selection honestly retained base
and a fresh OS BEAM reproduced it byte-for-byte. This establishes ordinary
model-generated semantic signal and weight-changing lifecycle mechanics, but
the neutral held-out result is neither a GRPO win nor a general optimizer loss.
The run did not retrospectively select its step-one checkpoint.

The current runner defines a separate, prospective defaults treatment rather
than altering either retained result. With the two-step contract and width four
environment shown above, it keeps the same model revision, JSON adapter,
16/8/40 rows, seed, four rollouts per group, prompt, token envelope, and task
metric, while using pinned TRL 1.6.0's documented `learning_rate: 1.0e-6` and
`loss_type: :dapo` defaults (`beta: 0.0`, group reward scaling). It predeclares
earliest-on-tie selection among trained checkpoints using only the eight
selection rows, then performs the existing base-versus-selected comparison
before opening the untouched 40 rows. The default output directory is
`model-generated-banking77-json-defaults-v1`. This treatment must be interpreted
independently whether positive, neutral, negative, or stopped; it is not a
retry or reinterpretation of `exercised-json-multistep-result.json`.

That treatment completed and is preserved in
`exercised-json-defaults-result.json`, but its internal checkpoint comparison is
invalid. Step one again produced real semantic signal and changed tensors; step
two again collapsed to malformed samples. The worker had remained in training
mode after `GRPOTrainer.train()`, so its immediate validation calls did not
match the later inference-mode deployment of the saved step-one artifact. The
internal scores were both `0.0`, while ordinary deployment scored base and the
selected step-one artifact identically at `0.875` on selection and `0.725` on
untouched test, with zero parse errors. Base was retained and reproduced fresh.
The worker now brackets all generation in eval mode and restores prior trainer
mode afterward. The completed run was not rerun; it is lifecycle/training and
neutral external-evaluation evidence, not valid checkpoint-selection or GRPO
effectiveness evidence.

The runner now names a separate post-fix treatment,
`model-generated-banking77-json-post-eval-mode-v1`. It changes no task,
model, split, seed, prompt, sampling envelope, reward, step/group width,
optimizer setting, selection rule, or untouched metric from the documented
defaults treatment. Its sole treatment boundary is execution after the
generation-mode repair above, so validation and deployment both observe the
same inference-mode policy. The prior artifact remains immutable. This new run
must still be read as one task/model result: even a positive held-out outcome
would not establish general GRPO effectiveness, mmGRPO parity, production
reliability, or BEAM superiority.

The immutable result is `exercised-post-eval-mode-result.json` (SHA-256
`7a80fb5ddeab50df8011f151ac2bd2684fe8e570da4d98b0293f3fc1b91b2b98`).
Both steps produced non-uniform semantic rewards and advantages and changed
the LoRA tensors. Step one and step two each scored `0.875` on selection, so
earliest-on-tie retained step one; the trained arm then tied base on selection
and untouched test (`0.725` accuracy, `0.71289` macro-F1, zero parse errors),
so the outer rule retained base. Fresh OS execution reproduced the selected
base outputs byte-for-byte. The exact run used source commit `b93ad6d`, runner
SHA-256 `a358c0cdcc65f09405bb9fb5edab46a862b5baf0a94791be530c35a55651107c`,
and two-step contract SHA-256
`b09fa6c4acefa26ccaa9a4bd045dca853c9e9f572b0801bccd92cd3946245fcf`.
This is a valid neutral held-out result, not useful learned behavior.

New executions fail before preflight if their output directory is non-empty,
bind the exact runner and contract digests, and derive the fresh-process arm
only from the persisted selection stage.

The current prospective ordinary-usefulness condition is
`model-generated-banking77-json-two-padded-epochs-v1`. It keeps the corrected
adapter, inference-mode generation, model revision, 16/8/40 rows, seed, prompt,
four completions per semantic group, exact-route reward, TRL defaults, and
validation/untouched metrics from the neutral post-fix run. Its only research
change is a ten-step budget at four source groups per step: two complete
twenty-slot schedules under the pinned mmGRPO padding rule. Validation chooses
the earliest trained checkpoint, then the stable outer comparison may still
retain base. The condition is frozen before execution; neutral or negative
behavior remains valid and will not trigger prompt, reward, normalization,
model, or hyperparameter adjustment.

If the caller stops after a durable GRPO checkpoint, resume the same treatment
without repeating base evaluation or an accepted optimizer update:

```sh
export IMP_GRPO_RESUME=1
mix run examples/local_grpo_banking77/run.exs
```

Resume verifies the retained data, schedule, model, contract, preflight, and
base-stage bytes before reconciling the same session. Fresh-process
reproduction verifies that preflight without rewriting it.
