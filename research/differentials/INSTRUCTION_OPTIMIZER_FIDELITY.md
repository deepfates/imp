# Instruction Optimizer Fidelity

Imp implements MIPROv2 and SIMBA as Elixir-native optimizer engines. Their
algorithms are derived from immutable upstream sources, while execution,
concurrency, random-state handling, and reporting use BEAM-native primitives.

The Mix commands in this document are maintainer gates run from an Imp source
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
the grounded proposer, but no dedicated MIPROv2 or SIMBA tests. Imp therefore
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

- `Imp.ProgramParameters` exposes stable named predictor lenses and functional
  updates for built-in and custom compositional programs.
- `Imp.Optimizer.TrajectoryRunner` produces normalized per-example prediction,
  trace, reward, feedback, metadata, and failure records.
- `Imp.Optimizer.Sampling` threads explicit `:rand` state through deterministic
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

Imp's BEAM-native program-aware proposer sends structural module, predictor, and
signature metadata by default. It does not read a compiled module's source file
implicitly. Consumers may explicitly opt into bounded module-source grounding or
supply bounded public text; the selected grounding mode is retained in effective
configuration. This is a privacy-preserving product deviation from DSPy's
automatic `inspect.getsource` behavior.

Grounded instruction proposals follow the released predictor-major decision
order. Proposal slot `j` for each named predictor starts from that predictor's
demo set `j`, then visits later and earlier sets cyclically, admitting only
bootstrapped trajectory demonstrations until the context limit is reached.
Slot zero renders no task demonstrations, matching the released special case.
Imp stores the bootstrap provenance as the internal `imp_augmented` example
field; it is unavailable through `Example.keys/items/values` and is stripped
from both proposal payloads and task-adapter rendering. Labeled examples remain
eligible for the categorical demo search but cannot silently replace the
trajectory evidence grounding an instruction proposal.

DSPy gives every predictor/proposal call a random `randint` rollout ID from one
shared Python RNG. Imp uses a collision-free predictor-major sequence derived
from the declared seed and records predictor index, proposal/demo-set index,
grounded-demo count, and rollout ID in the MIPRO report. That is a deliberate
BEAM RNG/replay difference; the proposal/demo evidence and search-space
topology, rather than incidental integer identity, are the shared contract.

For matched upstream comparisons, MIPROv2 also exposes an explicit
`proposer_fidelity: :dspy_3_2_1` path. It is intentionally narrower than the
default BEAM-native proposer: with program awareness disabled and data/tip
awareness enabled, it reproduces DSPy 3.2.1's three-call, 20-row dataset-summary
pipeline, dynamic ChatAdapter signatures, five non-empty released tips plus the
released no-tip choice, CPython MT19937 tip/rollout draws, one call per
instruction candidate, marker parsing, and candidate-zero baseline overwrite.
When few-shot awareness is enabled, each proposal consumes the same ordered
demo arm searched later by Optuna. When program awareness is enabled, the
consumer must provide bounded explicit program text; Imp then performs DSPy's
program-description and module-description calls before each instruction call.
Independent DSPy public compiles match the complete message tapes and rollout
IDs for both provider-free fixtures. Imp stores only the text digest and byte
count in reports/checkpoint compatibility, so source text cannot leak into
durable metadata and drift is rejected before LM calls. Structured-response
substitution remains rejected rather than silently claimed as parity.

The public compile path reproduces DSPy's ordered few-shot arm construction.
In a real few-shot run it retains zero-shot, labels-only, unshuffled-bootstrap,
and shuffled-bootstrap candidates; uses CPython-compatible shuffle, `randint`,
and `sample` streams; and adds one demo categorical variable after each named
predictor's instruction variable. An independently executed DSPy 3.2.1 public
compile matches the complete ordered demo contents for the provider-free
fixture, and an independent Optuna 4.9.0 run matches the resulting joint
instruction/demo startup schedule. Trial-atomic checkpoints retain those demo
candidates and resume without proposal or bootstrap replay.

DSPy's zero-shot mode still performs its otherwise surprising bootstrap before
proposal and then discards the demos. For six candidates over 20 rows it
constructs the zero arm plus five bootstrap rounds, advances the same CPython
RNG through four shuffle/size decisions, and stops each round when its accepted
demo target is met. With an always-accepting metric this is nine task calls
before nine prompt calls (three summary plus six proposal); with no accepted
examples the bounded bootstrap maximum is 100 task calls. Calls, failures,
budgets, cache effects, and RNG advancement remain observable and are therefore
still matched rather than optimized away.

The fidelity path matches DSPy when an ordinary later summary-batch call fails:
it stops extending the observations and asks the summarizer to use the prefix
already accumulated. Budget, route, cost, transport, and cancellation guards
remain fatal rather than entering that ordinary fallback. The sealed matched
runner also validates MIPRO optimizer marker envelopes before DSPy's broader
data-aware construction fallback, so malformed first-summary output cannot
silently remove information on only one arm. GEPA reflection parse retry remains
the pinned algorithm's own two-attempt behavior rather than being recast as an
operational guard.

DSPy delegates this stage to Optuna's multivariate `TPESampler`; Imp's default
uses a native joint categorical Parzen implementation with explicit immutable
random state. The engines share search-space, observation, and promotion
contracts, not identical trial sequences from the same integer seed. That
default remains an algorithm-native comparison and any equivalence or
superiority claim requires a decision-tape differential plus T3 effectiveness
evidence.

The pinned DSPy 3.2.1 matched path is narrower and explicit. With the default
Optuna startup count of ten, an inserted baseline, and nine objective trials,
Optuna never enters modeled TPE: every suggestion comes from its NumPy
`RandomState` categorical startup sampler. Imp's
`:dspy_3_2_1_optuna_4_9_0_startup` search fidelity reproduces that one-hot
uniform/argmax stream, parameter order, and completed-trial count exactly,
persists the full MT19937 state, and refuses a tenth objective trial rather
than substituting Imp's Parzen model. Source-bound tests independently execute
Optuna 4.9.0 for all three sealed comparison seeds. This startup-only result is
not general Optuna TPE parity.

For ordinary runs that must continue beyond startup,
`:dspy_3_2_1_optuna_4_9_0` implements Optuna 4.9.0's multivariate categorical
TPE mechanism: the 10%/25-trial good-set split, chronological kernel order,
categorical Parzen kernels with a unit prior, 24 expected-improvement
candidates, and independent NumPy-compatible startup and modeled RNG streams.
Its checkpoint contains both MT19937 states and every ordered observation, so
resume does not replay trials or restart the surrogate. Independent Optuna
execution matches the complete startup and the first modeled opportunity for
one- and two-predictor spaces; longer trajectories may choose a different
member of an algebraically tied acquisition set because Erlang and NumPy reduce
floating-point likelihoods differently. The report therefore marks exact
trial-sequence parity false for modeled runs and names that tie boundary. This
is a numerical tie-breaking deviation, not a different information flow,
surrogate, candidate budget, or selection rule.

Pinned DSPy turns an evaluation exception into score zero and continues the
study. The matched Imp mode does the same for ordinary task/adapter failures.
Operational budget, route, cost, transport, or cancellation guards use
`Imp.OperationalSafetyError` and remain fail-closed instead of being
silently admitted as a poor candidate.

DSPy's bootstrap utility hashes repeated calls and deterministically chooses an
earlier or final call. Imp retains the eligible calls for each predictor and
uses a deterministic SHA-256-derived choice. This preserves stable multi-call
selection on the BEAM, but it is not Python's exact hash/RNG sequence. Exact
cross-runtime sampler-sequence parity remains explicitly false.

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
8. registration of every genuinely mutated generated candidate, including
   worse ones; unlike pinned DSPy, an unchanged source returned by a skipped or
   irrelevant strategy is not registered as fake search progress;
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

Captured MIPROv2 and SIMBA metrics cross that boundary only with an explicit
string-keyed `metric_identity` containing JSON-safe `id`, `version`, and
`config`. Checkpoints bind the id and version plus the canonical config digest,
never the executable closure or raw config. Public `&Module.function/2` metrics
derive stable module/name/arity identity. Anonymous metrics without a declared
identity remain available for complete in-process optimization, but those runs
are explicitly non-durable and expose no resume checkpoint.

Resume validates a run-configuration digest covering the program/predictor shape,
resolved datasets, search configuration, and relevant runtime identities. For
MIPROv2 and SIMBA, this includes each predictor's LM, adapter, demos, config,
and dynamic binding policy (after applying MIPROv2's `task_lm`); observations
from a paused study cannot therefore be resumed under a different task model,
parser, or call policy. Live callback
captures remain intentionally excluded so equivalent callbacks can acquire fresh
process handles or credentials. Validation then
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
  Imp.Optimizer.SIMBA.compile(simba, program, trainset, final_set,
    max_steps: 2,
    checkpoint_fn: persist
  )

resume_state = checkpoint_path |> File.read!() |> Jason.decode!()

Imp.Optimizer.SIMBA.compile(simba, program, trainset, final_set,
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

From an Imp source checkout, run T1 with:

```bash
mix benchmark.instruction_optimizer.contract.check
```

The task validates DSPy `3.3.0b1` and all six pinned source hashes before it
compares effective budgets, demo arms, grounded-demo rotation, released
minibatch study numbering, categorical shape, SIMBA bucket ordering and
percentiles, winning-history selection, rollout IDs, tied-rule handling, and
demo-eviction invariants. Its artifact explicitly records exact
sampler-sequence parity, paper-protocol completion, and full optimizer parity
as false.

The source-derived implementation and local contracts do not by themselves
prove T1, T2, or T3. The upstream fidelity row remains red when the matched DSPy
artifact is missing, stale, or failing. “Parity or better” additionally requires
T3 evidence; a cleaner BEAM architecture is not a substitute for measured
optimizer quality.

## Matched Paid Preflight

Always render the deterministic no-network plan before a paid run:

```bash
mix imp.benchmark.instruction_optimizer_experiment \
  --manifest benchmarks/config/instruction-optimizer-aime-economical-preflight-haiku45-v1.json \
  --env-file .env \
  --runtime both \
  --python tmp/dspy-parity-venv/bin/python \
  --dspy-pythonpath tmp/dspy-current-target \
  --out benchmarks/runs/instruction-optimizer-experiment \
  --plan
```

The plan validates the pinned dataset and source identities, prints the exact
prefix counts, arms, model, seed, per-arm ceilings, and two-runtime worst-case
aggregate exposure, and records `network_calls: 0`. Manifest validation rejects
the run before credential lookup when any calculated aggregate dimension
exceeds `preflight.max_aggregate`.

The one-seed AIME preflight runs both native Imp and pinned DSPy from one
manifest:

```bash
mix imp.benchmark.instruction_optimizer_experiment \
  --manifest benchmarks/config/instruction-optimizer-aime-economical-preflight-haiku45-v1.json \
  --env-file .env \
  --runtime both \
  --python tmp/dspy-parity-venv/bin/python \
  --dspy-pythonpath tmp/dspy-current-target \
  --out benchmarks/runs/instruction-optimizer-experiment
```

The economical preflight binds Claude Haiku 4.5 to the
provider-specific ReqLLM and
LiteLLM identifiers, all three AIME split hashes, seed, arm order, optimizer
options, DSPy `3.3.0b1`, Optuna `4.9.0`, and independent per-arm request,
input-token, output-token, and USD ceilings. It uses prefix limits `6/3/3` and
a maximum two-runtime exposure of `480` requests and `$4.50`.
The orchestrator derives one Imp
campaign and one all-arm DSPy campaign and refuses to merge incomplete or
identity-mismatched artifacts.

One seed was run live. Both runtimes completed every arm without failures. Baseline, MIPROv2, and
SIMBA each scored `2/3` on that runtime's frozen test split, so this establishes
live sampled execution and accounting but not optimizer lift or T3 parity.

Each arm is evaluated on the frozen test split and compared with that runtime's
baseline. The dev leader is descriptive only: MIPROv2 already uses dev as its
optimizer validation set, so this protocol does not select a global winner.
Imp optimizer checkpoints and both runtimes' committed evaluation rows resume.
Pinned DSPy MIPROv2 and SIMBA do not expose compatible internal compile
checkpoints; an interrupted upstream compile fails closed and requires a new
campaign identity. The resulting artifact is costed T2/research-preflight
evidence, not multi-seed T3 effectiveness or full optimizer parity. Runtime
artifacts include scores, actual request/token/USD usage, phase and row wall
time, the seed, and explicit failure lists.
