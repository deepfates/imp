# Local RandomSearch / BootstrapRS Banking77 program

This ordinary consumer runs `Imp.Optimizer.RandomSearch` against the retained,
verified MLX-fused Qwen Banking77 classifier and uses a separate pinned local
`llama3.2:3b` program as the real bootstrap teacher. Sixteen training rows are
available to the optimizer, eight separate rows rank the fixed DSPy-style
zero-shot, labels-only, unshuffled-bootstrap, and shuffled-bootstrap schedule,
and forty frozen rows are opened only after validation returns a winner.

The example rejects a cheap bootstrap façade. A teacher answer must pass the
same route metric, become an `augmented` demonstration, and appear in the
canonical messages rendered for a fused task-model candidate call. It also
requires one transport per logical call, saves the selected program and its
completed `TrainingJob`, then loads and serves both in a fresh OS BEAM with
exact artifact identity and byte-identical ordered predictions/errors.

Set `IMP_MLX_JOB` to the retained completed Banking77 job:

```sh
export IMP_MLX_JOB=/path/to/training-job.json
mix run examples/local_random_search_banking77/run.exs
```

The retained run generated four metric-accepted augmented demonstrations and
rendered them in 24 of 32 fused candidate-evaluation calls. Validation honestly
selected zero-shot: scores were 62.5% zero-shot, 50% shuffled bootstrap, and
25% for labels-only and unshuffled bootstrap. The selected program scored
0.475 accuracy / 0.33333 macro-F1 / zero errors on the frozen forty rows and
reproduced byte-for-byte after a fresh OS restart.

This establishes a real local-teacher RandomSearch/BootstrapRS lifecycle and
honest rejection of worse demo candidates. It does not establish general
effectiveness, exact Python RNG parity, production reliability, or BEAM
superiority. These forty rows have appeared in earlier local optimizer work,
so they are optimizer-held-out here but are not globally untouched research
evidence.
