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

The default remains the retained one-group/one-step run. To exercise the
bundled durable multi-group/multi-step backend without changing the task,
select an explicit pinned contract and matching public optimizer width/budget:

```sh
export IMP_TRL_CONTRACT="$PWD/priv/trl_worker/qwen-two-step-contract.json"
export IMP_GRPO_TRAIN_STEPS=2
export IMP_GRPO_TRAIN_WIDTH=2
export IMP_GRPO_OUTPUT=/tmp/imp-local-grpo-banking77-two-step
mix run examples/local_grpo_banking77/run.exs
```

Each step consumes two ordered source-bound prompt groups with four completions
per group. Step two must resume the exact step-one adapter, optimizer,
scheduler, Trainer state, and MPS RNG; repeated one-step jobs are not accepted
as an equivalent trajectory.

The retained two-group/two-step acceptance is summarized in
`exercised-multistep-result.json`. Both official steps completed and global
state advanced `0 -> 1 -> 2`; the final artifact contains the full chain and
its trained predictions reproduced byte-for-byte from a fresh OS BEAM. All
four prompt groups still produced uniform malformed-output rewards, so the
result remains a no-signal lifecycle proof rather than learned usefulness.
