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
