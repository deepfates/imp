# Local InferRules Banking77 program

This ordinary consumer runs `Imp.Optimizer.InferRules` with the retained,
verified MLX-fused Qwen Banking77 classifier and a separate pinned local
`llama3.2:3b` rule model. Sixteen frozen training rows drive real
BootstrapFewShot and one natural rule-induction candidate; eight separate rows
select the source, protected bootstrapped baseline, or induced rules. The forty
untouched rows are opened only after InferRules returns its selected program.

The original source program is also a first-class selection candidate. An
earlier completed run proved why that matters: bootstrap plus induced rules
both scored `0.25` after the source had scored `0.625` on selection, and the
old two-candidate loop returned the regressed bootstrap. That immutable result
is retained in `exercised-pre-source-protection-result.json`; current Imp
protects the source ahead of both later candidates.

The example records the original source and compiled behavior separately,
requires a real rule transport and rendered selected instruction, saves the
selected program and completed training job, then reproduces the compiled
untouched outputs from a fresh OS BEAM against the exact fused artifact.

```sh
export IMP_MLX_JOB=/path/to/retained/training-job.json
mix run research/local_infer_rules_banking77/run.exs
```

One run can establish only this task/model lifecycle and outcome. It cannot
establish whole-loop DSPy equivalence, general InferRules effectiveness,
production reliability, or BEAM superiority.
