# Instruction Optimizer Fidelity

DSEx implements MIPROv2 and SIMBA as Elixir-native optimizer engines. Their
algorithms are derived from immutable upstream sources, while execution,
concurrency, random-state handling, and reporting use BEAM-native primitives.

The Mix commands in this document are maintainer gates run from a DSEx source
checkout; they are not package-consumer commands.

## Pinned Authorities

- DSPy repository: <https://github.com/stanfordnlp/dspy>
- DSPy immutable release: `3.3.0b1`, commit `b2829b7`
- MIPROv2 paper, revision 2: <https://arxiv.org/abs/2406.11695v2>

| Authority | Path at `b2829b7` | SHA-256 |
| --- | --- | --- |
| MIPROv2 engine | `dspy/teleprompt/mipro_optimizer_v2.py` | `6bf7632836d3a54ab0da3f38a8f1963813472312e9c0e3f2ff19b4377af407f3` |
| Shared optimizer utilities | `dspy/teleprompt/utils.py` | `218c38c25dde75aab9b1d452a15c75687c2e1842d7157dcc6c695f5adbcaf182` |
| BootstrapFewShot | `dspy/teleprompt/bootstrap.py` | `0a588f11f09a358a5306540cc42401d905073c9452e54d32348b13d12bbb1255` |
| Grounded proposer | `dspy/propose/grounded_proposer.py` | `c9900b74c0997410f915f2a470d39dcd9d55c1fa8b9cdf35799915ec0b1617e3` |
| SIMBA engine | `dspy/teleprompt/simba.py` | `4de72e1d0cb1cd30a180569c21973c41fa272c3ebb82a365e3f307986ab67a55` |
| SIMBA strategies | `dspy/teleprompt/simba_utils.py` | `ed745647ffcfcf4090e5d5b5489cd0b13ebfff1d38a22559563f4f606b31fb2c` |

The pinned DSPy tree contains adjacent tests for bootstrap trace behavior and
the grounded proposer, but no dedicated MIPROv2 or SIMBA tests. DSEx therefore
treats released engine source as the control-flow authority and maintains its
own differential contract corpus rather than implying upstream test coverage
that does not exist.

The released source is authoritative for operational control flow. The MIPROv2
paper and its seven-program benchmark lineage are authoritative for research
claims and effectiveness protocols. SIMBA is currently specified primarily by
its released implementation and DSPy documentation; local or live lift is not
described as paper replication in the absence of a primary SIMBA paper.

## Shared BEAM Primitives

The optimizers share only mechanisms that are semantically common:

- `DSEx.ProgramParameters` exposes stable named predictor lenses and functional
  updates for built-in and custom compositional programs.
- `DSEx.Optimizer.TrajectoryRunner` produces normalized per-example prediction,
  trace, reward, feedback, metadata, and failure records.
- `DSEx.Optimizer.Sampling` threads explicit `:rand` state through deterministic
  shuffle, categorical, softmax, percentile, and Poisson operations.

MIPROv2 owns its categorical TPE study. SIMBA owns its population, variability
buckets, and introspective strategies. They are not forced into a generic
optimizer state machine.

## MIPROv2 Contract

The implementation performs:

1. metric-filtered teacher trajectory bootstrapping;
2. predictor-specific candidate demo sets;
3. program-, data-, demo-, and tip-aware instruction proposal;
4. independent instruction and demo categorical variables per named predictor;
5. seeded joint categorical Parzen search with the baseline inserted as an
   observation;
6. exact objective trial budgets;
7. seeded minibatch evaluation and the released `3.3.0b1` periodic
   full-evaluation cadence, promoting by average combination score; and
8. winner selection exclusively from full validation evaluations.

Reports preserve effective configuration, parameter assignments, trial kind,
full-evaluation history, call accounting, seed, upstream release, and commit.

DSPy delegates this stage to Optuna's multivariate `TPESampler`; DSEx uses a
native joint categorical Parzen implementation with explicit immutable random
state. The engines are expected to share the search-space, observation, and
promotion contracts, not identical trial sequences from the same integer seed.
Any claim that the native search is equivalent or better therefore requires a
recorded decision-tape differential plus T3 effectiveness evidence.

DSPy's bootstrap utility hashes repeated calls and deterministically chooses an
earlier or final call. DSEx currently retains one call per predictor and chooses
the final call. This is a declared native deviation until a cross-runtime hash
fixture proves the exact selection rule.

## SIMBA Contract

The implementation performs:

1. seeded shuffled mini-batch traversal;
2. repeated rollout sampling from a score-weighted top population that always
   retains the baseline;
3. variability ranking by max-minus-min reward, maximum reward, and
   max-minus-average reward;
4. 10th/90th-percentile strategy eligibility;
5. stochastic demo eviction;
6. successful trajectory demo extraction or better/worse trajectory reflection;
7. predictor-specific rule appending;
8. unconditional registration of generated candidates, including worse ones;
9. winning-history subsampling; and
10. final full-dataset validation of the selected history.

Reports preserve population score histories, batch indices, bucket ranks,
candidate identities, trajectory and evaluation accounting, final candidates,
seed, upstream release, and commit.

## Durable Run-Level Resume

Both optimizers return their latest JSON-safe checkpoint in
`report.metadata.resume_state` and accept it on a later compile invocation as
`resume_state:`. A synchronous arity-one `checkpoint_fn:` can persist each
completed boundary. Reports set `metadata.resumed` when the invocation loaded a
checkpoint and set `metadata.run_status` to `:paused` or `:complete`.

MIPROv2's `compile/5` accepts `max_trials:`, the maximum number of **new**
objective trials for that invocation. It emits once after bootstrapping,
instruction proposal, and baseline evaluation, then after every completed
trial. Resume restores proposal artifacts, categorical policy and observations,
RNG state, full-evaluation history, counters, and errors. Setup and completed
trials are not repeated. A trial is the atomic boundary, so interruption during
a minibatch or promoted full evaluation retries that entire trial.

SIMBA's `compile/5` accepts invocation-level `max_steps:` independently of the
optimizer's total `max_steps`. It emits the initial state, every completed search
step, and every completed finalist evaluation. Resume restores population and
winning-program snapshots, policy and random state, minibatch order/cursor,
logs, counters, errors, and finalist progress. Completed steps and finalist
evaluations are not repeated; interrupted in-flight step or finalist evaluation
work is retried. Finalist evaluation starts only after the configured total
search-step budget has been reached.

For either optimizer, `max_trials: 0` or invocation-level `max_steps: 0` can
load and return an already paused boundary without advancing search. The
returned checkpoint remains resumable across later invocations; the configured
total budget, not the per-invocation cap, determines completion.

### Rebinding And Trust Boundary

Checkpoints contain data, not executable runtime state. Functions, processes,
ports, references, and live LM clients are not restored from the payload.
MIPROv2 reconstructs candidate programs from the supplied runtime program plus
checkpointed instruction/demo choices. SIMBA applies checkpointed instructions
and demos to the supplied runtime program. The current optimizer metric and the
program/optimizer LM callbacks therefore provide the executable behavior after
resume; closure captures such as process handles or credentials may be rebound
without embedding them in the artifact.

Resume validates a compatibility digest covering the program/predictor shape,
resolved datasets, search configuration, and relevant runtime identities, then
validates a SHA-256 payload checksum and structural invariants. A different
dataset, program shape, or search budget is rejected. These checks detect
mismatch and accidental corruption; they are not keyed signatures, proof of
origin, encryption, or authorization to consume untrusted input. A checkpoint
may contain instructions, demos, model outputs, scores, and errors. Hosts must
treat it as sensitive, accept it only from trusted runs, and implement atomic
durable storage inside `checkpoint_fn:` when process-crash recovery is required.

```elixir
checkpoint_path = Path.join(System.tmp_dir!(), "simba-run.json")

persist = fn checkpoint ->
  temporary_path = checkpoint_path <> ".tmp"
  File.write!(temporary_path, Jason.encode!(checkpoint))
  File.rename!(temporary_path, checkpoint_path)
end

paused =
  DSEx.Optimizer.SIMBA.compile(simba, program, trainset, final_set,
    max_steps: 2,
    checkpoint_fn: persist
  )

resume_state = checkpoint_path |> File.read!() |> Jason.decode!()

DSEx.Optimizer.SIMBA.compile(simba, program, trainset, final_set,
  resume_state: resume_state,
  checkpoint_fn: persist
)
```

## Evidence Tiers

- **T0 local behavior:** deterministic unit and failure contracts.
- **T1 matched control flow:** a pinned DSPy sidecar emits the same effective
  configuration, search-space shape, batch schedule, bucket ordering, candidate
  ancestry, evaluation schedule, and final-rank invariants.
- **T2 live operation:** real prompt/task providers execute optimization with
  positive usage accounting and persistable reports.
- **T3 effectiveness:** pinned datasets, multiple seeds, held-out results,
  metric-call and token budgets, cost, wall time, and uncertainty demonstrate
  lift against baseline and upstream comparators.

From a DSEx source checkout, run T1 with:

```bash
mix benchmark.instruction_optimizer.contract.check
```

The task validates DSPy `3.3.0b1` and all six pinned source hashes before it
compares effective budgets, demo arms, grounded-demo rotation, released
minibatch study numbering, categorical shape, SIMBA bucket ordering and
percentiles, winning-history selection, rollout IDs, tied-rule handling, and
demo-eviction invariants. Its artifact keeps exact sampler-sequence parity,
paper-protocol completion, and full optimizer parity false.

The source-derived implementation and local contracts do not by themselves
prove T1, T2, or T3. The upstream fidelity row remains red when the matched DSPy
artifact is missing, stale, or failing. “Parity or better” additionally requires
T3 evidence; a cleaner BEAM architecture is not a substitute for measured
optimizer quality.

## Matched Paid Preflight

The one-seed AIME preflight runs both native DSEx and pinned DSPy from one
manifest:

```bash
mix dsex.benchmark.instruction_optimizer_experiment \
  --manifest benchmarks/config/instruction-optimizer-aime-matched-preflight.json \
  --runtime both \
  --python tmp/dspy-parity-venv/bin/python \
  --dspy-pythonpath tmp/dspy-current-target \
  --out benchmarks/results
```

The manifest binds the logical model to the provider-specific ReqLLM and
LiteLLM identifiers, all three AIME split hashes, seed, arm order, optimizer
options, DSPy `3.3.0b1`, Optuna `4.9.0`, and independent per-arm request,
input-token, output-token, and USD ceilings. The orchestrator derives one DSEx
campaign and one all-arm DSPy campaign and refuses to merge incomplete or
identity-mismatched artifacts.

Each arm is evaluated on the frozen test split and compared with that runtime's
baseline. The dev leader is descriptive only: MIPROv2 already uses dev as its
optimizer validation set, so this protocol does not select a global winner.
DSEx optimizer checkpoints and both runtimes' committed evaluation rows resume.
Pinned DSPy MIPROv2 and SIMBA do not expose compatible internal compile
checkpoints; an interrupted upstream compile fails closed and requires a new
campaign identity. The resulting artifact is costed T2/research-preflight
evidence, not multi-seed T3 effectiveness or full optimizer parity.
