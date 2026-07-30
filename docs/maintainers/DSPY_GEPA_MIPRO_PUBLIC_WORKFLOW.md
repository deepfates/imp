# DSPy 3.2.1 GEPA/MIPRO public-workflow compatibility

This is a provider-free integration boundary, not a benchmark, treatment, or
parity claim. The executable authority is
`scripts/dspy_optimizer_public_workflow_gate.py`; its regression invokes the
same command from `test/dspy_optimizer_public_workflow_gate_test.exs`.

## Version ownership

DSPy 3.2.1 at `29448ae12756abdd14bd8796c819247ebb83673c`
declares the exact dependency `gepa[dspy]==0.0.27`. Its `GEPA` documentation
states that `gepa_kwargs` is passed directly to `gepa.optimize`; DSPy does not
own or translate those keys. GEPA 0.0.27 and 0.1.1 do not expose
`acceptance_criterion`. The option first appears in GEPA 0.1.2 and is present in
the pinned 0.1.4 source at
`8b0ce6cd99a234f6b74daf37558a2ac0ce18f975`.

The stopped IFBench v3 treatment mixed those two distinct truths: it named GEPA
0.1.4 as an authority but executed DSPy 3.2.1's locked GEPA 0.0.27 environment.
Passing `acceptance_criterion: "strict_improvement"` therefore failed exactly
at the transparent pass-through boundary.

The source-correct bridge does not remove that option or infer that an older
default is equivalent. Before importing either package, it authenticates both
commits and prepends the GEPA 0.1.4 source to DSPy 3.2.1's environment. It then
requires the complete 0.1.4 optimizer signature. The exact DSPy 3.2.1 source
commit retains stale `dspy.__version__ == "3.2.0"` module metadata; the bridge
records that upstream packaging discrepancy and relies on the exact commit and
3.2.1 package lock.

## GEPA effective configuration

The gate invokes the real public `dspy.GEPA(...).compile(...)` entry, the real
DSPy adapter with only the accepted ordered-failure repair, and the real GEPA
0.1.4 optimizer. It uses 16 synthetic train rows, 32 separate validation rows,
two named predictors, deterministic task/reflection LMs, and no held-out or
provider authority.

| Intended option | Public route | Effective behavior |
| --- | --- | --- |
| one legal iteration envelope | explicit semantic budget | exactly 80 metric calls, including legal completion |
| reflection minibatch 8 | `GEPA.reflection_minibatch_size` | 8 |
| Pareto parent selection | `GEPA.candidate_selection_strategy` | `pareto` |
| round-robin component selection | `GEPA.component_selector` | `round_robin`; both predictors remain addressable |
| strict improvement | `gepa_kwargs.acceptance_criterion` | exact `strict_improvement` in GEPA 0.1.4 |
| all accepted improvements | `gepa_kwargs.selection_strategy` | explicit `AllImprovements` instance |
| merge disabled | `GEPA.use_merge` | false |
| optimizer LM | DSPy stripped-LM adapter wrapper | real default reflection proposal path; no custom proposer shortcut |
| skip perfect rows / perfect score | direct GEPA values | true / 1.0 |
| one evaluation thread | DSPy adapter | 1 |
| failure score | DSPy adapter | 0.0 |
| detailed result | DSPy result projection | present |
| seed | DSPy to GEPA | 2026072705 |
| durable run directory | `GEPA.log_dir` to `optimize.run_dir` | created, completed, then cleaned |
| lifecycle callback | `gepa_kwargs.callbacks` | start/end, iteration, selection, sampling, evaluation, reflection, proposal, acceptance, budget, state-save, Pareto and valset events observed |
| semantic stopper | `gepa_kwargs.stop_callbacks` | invoked twice without truncating the legal completion |
| dataset/program shape | `GEPA.compile` | 16 train / 32 validation / two predictors |

The public compile completed with two candidates. Strict improvement accepted a
real named-predictor instruction mutation, the selected program saved as JSON,
and a fresh trusted two-stage program loaded byte-equivalent predictor state.
The owned run directory and scoped adapter were restored/removed.

The same aggregate gate also runs the existing exhaustive failure comparison:
ordinary stock and repaired-adapter transcripts, rendered messages, reflection
records, and public compile opportunity are byte-identical. All 120 orderings
of success, empty parse, partial parse, program exception, and metric exception
retain 600 ordered slots. Parse failures enter reflection only under DSPy's
existing explicit opt-in; arbitrary program/metric exceptions remain scored
diagnostics and never become instruction advice.

## MIPROv2 effective configuration

The MIPRO arm invokes the real DSPy 3.2.1 public constructor and compile path,
including proposal setup and the complete Optuna search rather than replacing
`_optimize_prompt_parameters` with a fixture.

| Intended option | Public route | Effective behavior |
| --- | --- | --- |
| `auto: nil` | constructor | honored |
| four instruction candidates | constructor -> observed bootstrap/proposal phase inputs | four candidates per predictor |
| eight trials | `compile.num_trials` -> observed optimizer input and trial log | eight Optuna trials after the separately evaluated default program |
| no minibatching | observed optimizer phase input | false; every trial uses the full selection set |
| zero selected bootstrapped/labeled demos | observed bootstrap phase inputs and selected program | selected program is zero-shot; DSPy still makes its documented bootstrap calls to inform proposal, then discards those demos before search |
| program-aware proposer false | observed proposal phase input | false |
| data-aware / tip-aware true | observed proposal phase inputs | true / true |
| few-shot-aware false | observed proposal phase input | false |
| data view batch 10 | observed proposal phase input | 10 |
| one thread | observed live `Evaluate` | 1 |
| `max_errors: 0` | observed live `Evaluate` | aborts each failing `Evaluate`, but outer MIPRO contains that ordinary abort as score zero |
| seed | constructor + compile + Optuna | 2026072705 |
| startup trials 10 | Optuna `TPESampler` default | effective but implicit external default |
| callbacks / stopper | MIPRO public API | unsupported and not part of the sealed MIPRO configuration |
| dataset/program shape | `MIPROv2.compile` | 16 train / 32 validation / two predictors |

The complete deterministic run made 11 prompt-model calls and 590 task-model
calls, completed all eight Optuna trials, saved the selected JSON state, loaded
it into a fresh trusted two-stage program, and cleaned its temporary artifact.
A malformed typed task output raises `AdapterParseError`. An ordinary metric
exception is different: `max_errors: 0` cancels the inner evaluation, but
DSPy's MIPRO `eval_candidate_program` catches that `Exception` and returns
score zero; the gate observes this across default and trial evaluations. The
matched DSPy 3.2.1 treatment preserves this candidate-local containment
exactly. This is not Imp's general error default.

Operational safety is deliberately outside that containment boundary. The
production treatment's typed route, model identity, privacy, transport,
attempt, token, cost, and budget guards raise `OperationalSafetyAbort`, which
inherits directly from `BaseException`. The aggregate gate loads that actual
type and drives it through the public MIPRO compile path: it escapes on the
first guarded metric call and is never converted to candidate score zero. Such
operational failures remain fatal and make a treatment incomplete rather than
scored.

Run the complete gate with:

```sh
tmp/dspy-parity-venv/bin/python \
  scripts/dspy_optimizer_public_workflow_gate.py \
  --dspy-root tmp/dspy-3.2.1 \
  --gepa-root tmp/gepa-v0.1.4
```

This work does not authorize or define a successor to the permanently stopped
v3 treatment. It proves only that the pinned public workflows and their exact
option/failure boundaries can finish without a model provider.
