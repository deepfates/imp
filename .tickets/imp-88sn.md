---
id: imp-88sn
status: open
deps: [imp-argb, imp-tg2z]
links: []
created: 2026-07-30T22:14:26Z
type: feature
priority: 0
assignee: deepfates
parent: imp-yme4
tags: [experiments, effectiveness, multi-stage, optimize-anything]
---
# Demonstrate current-source usefulness across different problems

Obstacle: Imp has one narrow historical positive matched result, several honest negative results, and strong lifecycle evidence, but not enough current-source evidence that its ordinary optimizer product is useful across materially different problem types. Answer that question with a small high-information portfolio, not a new campaign framework.

## Acceptance Criteria

Freeze a small current-source portfolio before provider calls. A realistic multi-stage language-model program materially improves its own baseline on source-disjoint untouched test data across enough seeds to expose instability, with at least three seeds, selection-only choice, and a reusable artifact that loads and serves in a fresh process. A genuinely proposer-generated non-prompt artifact mutation also improves untouched executable behavior. Each problem class uses its ordinary public optimizer lifecycle, and both converge on the shared portable Artifact and fresh-consumer boundary. Where a named algorithm has an upstream equivalent, matched arms receive the same information, opportunity, and budget. Report row and seed uncertainty separately, retain clean negative outcomes, and preserve enough raw evidence for independent recomputation. Unit fixtures, historical-source results, and harness completion cannot satisfy this ticket.

## Frozen portfolio design (provider authority: none)

This design binds inputs and opportunity before any new proposal or task-model
call. It uses the ordinary public lifecycles fixed in `3adeb10` and `4f386d8`;
it does not authorize a provider call or add an experiment coordinator.

### Multi-stage IFBench condition

- Authority: `gepa-ai/gepa-artifact@cbefbc1aa0f43dd39874ec4bf42211365dbda42e`.
  The exact result-blind source-index derivation and ordered row IDs are in
  `examples/matched_instruction_family_ifbench/data/receipt.json` (SHA-256
  `74282c868dde7c858a67c28218b8687d3b4213185b70c5f400c3d2d71a77e788`).
  Frozen files are train 16
  (`8d80f329bbab37a44fe2e2ea0ea8c7e69eeb976d8a8e51af5bcd4547b4221197`),
  selection 32
  (`f0c2d8e808e4783e496ecf189ead61fde4a1e80373ff85f3ea801883f68c7468`),
  and held-out 64
  (`49779533faa842decda93a1221ce7bae615af82403e33e380ab69d2abc84610d`).
  Train comes from `IFBench_train[300:600]`, selection
  from `IFBench_train[0:300]`, and held-out from independent
  `IFBench_test.jsonl`.
- These rows are source-disjoint and frozen, not globally unseen. Earlier
  terminal treatments exercised development/baseline paths, and the bytes are
  checked into this repository. Those treatments never reached held-out
  scoring. No prior result, call, selection, or artifact rolls forward.
- Program: an ordinary `Imp.Module` with named predictors
  `generate_response_module` (`query -> response`) then
  `ensure_correct_response_module` (`query, response -> final_response`),
  matching the authenticated stock-DSPy adaptation of the pinned task graph.
  Imp uses `Imp.Experiment.check/5` with
  `compare_baseline_on_test: true`; upstream uses stock DSPy 3.2.1 commit
  `29448ae12756abdd14bd8796c819247ebb83673c` plus authenticated GEPA 0.1.4
  commit `8b0ce6cd99a234f6b74daf37558a2ac0ce18f975` and
  `dspy.GEPA.compile` through the already-proven version bridge. Both receive
  identical ordered rows, messages, metric inputs, and semantic opportunity.
  The upstream arm is named a stock-DSPy-adapted task graph, not an unmodified
  paper artifact: its public GEPA adapter retains one ordered diagnostic slot
  for arbitrary evaluator failures without feeding those failures to
  reflection; ordinary-success transcripts and opportunity are unchanged.
- Seeds: `2026072705`, `2026072706`, `2026072707`. The only optimizer is GEPA.
  Each runtime uses `max_metric_calls: 80`, minibatch 8, and pinned legal
  completion of the current iteration: at most 120 evaluated examples, 12
  reflections, and 6 iterations per seed. Candidate selection is Pareto,
  module selection round-robin, acceptance strict improvement, selection all
  improvements, and merge disabled.
- Routes to revalidate immediately before calls: task
  `openai/gpt-5.4-mini` through the first-party OpenAI route; reflection
  `anthropic/claude-sonnet-4.6` through the first-party Anthropic route;
  `data_collection: deny`, no fallback, cache, retry, JSON fallback, or second
  transport. Task envelope is 4,096 input / 2,048 output tokens (6,144-token
  reservation), provider-default temperature, and the experiment seed;
  reflection is 16,384 input / 1,024 output tokens (17,408 input reservation
  including cache-write pricing), temperature 1.
- Per runtime/seed task ceiling is 624 two-stage transports: 64 baseline
  selection, 240 legal GEPA evaluation, 64 selected selection, 128 baseline
  held-out, and 128 selected held-out. Across two runtimes and three seeds that
  is 3,744 task transports and 72 reflection transports. Imp additionally
  permits four fresh-service probes per seed, each two-stage: 24 task
  transports. Total ceiling: 3,768 task and 72 reflection transports.
- `Experiment.check` must content-seal and successfully apply the selected Imp
  Artifact before held-out evaluation. After the completed Result contains the
  held-out outcomes, Result and Artifact are written mode 0600 and linked, then
  loaded into a freshly reconstructed trusted program in a new OS BEAM and
  served through the existing `ImpDeployment.ProgramServer` for four concurrent
  synthetic non-test probes. The applied candidate ID, both named instructions,
  runtime route options, and typed service success must survive reload.
- Primary outcome: per-seed paired held-out mean executable-constraint score.
  Success requires mean optimized-minus-baseline lift at least `0.05` and
  positive lift in at least two of three seeds. Report a row-paired bootstrap
  interval within each seed, then the three seed lifts, mean, median, range, and
  sign count separately. Secondary matched Imp-minus-DSPy GEPA uses a `-0.05`
  noninferiority margin and cannot substitute for Imp improving its own
  baseline.

### Structured Optimize Anything condition

- Ordinary entry is `Imp.Optimize.Anything.run/3` over the existing typed
  retry-controller seed, 8 training rows, and 6 selection rows. After selection,
  `Imp.Optimize.Anything.to_artifact/2` exports the existing Result without
  reevaluation or reselection. Only after Artifact write/read/value validation
  does the same task evaluator execute baseline and selected values on the new
  ordered test file
  `examples/local_optimize_anything_retry_policy/data/untouched-v2.jsonl`
  (6 rows; SHA-256
  `522245b0d7ec8d896c4b88c0475572a6325c2f25986d8b588d633bffa00590ff`).
- The new rows were frozen without evaluating a candidate. They are one fixed
  decision-table case for each distinct rule/boundary: non-retryable
  precedence, uncapped hint, capped hint, inclusive urgent limit, expired
  urgent limit, and exponential cap. That construction does not select rows by
  the prior Phi-4 artifact's scores. The previously observed
  `honor_server_hint` mutation is disclosed and receives no special row or
  acceptance credit; every proposer-generated map is scored over all six
  executable cases.
- Seeds: `2026073101`, `2026073102`, `2026073103`. Claude Sonnet 4.6 is the
  schema-required proposer through the first-party Anthropic route under the
  same 16,384-input / 1,024-output envelope, temperature 1, and
  `data_collection: deny` policy. Each seed makes exactly six round-robin
  component proposals, one per typed field, with strict-improvement admission,
  serial execution, no scripted strategy, cache, retry, fallback,
  normalization, or task-model call. Total ceiling: 18 reflection transports.
- Primary metric is exact executable correctness count out of six. Success
  requires at least two seeds to select a proposer-generated, non-seed artifact
  with positive exact-count lift and mean lift of at least one additional
  correct case. Report proximity score only as secondary. Each selected value
  Artifact must load in a fresh OS BEAM and reproduce the six ordered executable
  outputs exactly. This is an Imp structured-value extension, not an upstream
  text-map parity claim.

### Cost and interpretation

The hard execution bounds are 3,768 task plus 90 reflection transports, the
stated output-token limits, exact routes, and disabled retries/fallbacks. The
input-token figures are conservative reservation estimates for the frozen
prompts and call counts, not natively enforced input-token cutoffs. At the last
validated reservations (`$0.013824` task and `$0.08064` reflection), new spend
is at most `$59.346432`; using the existing conservative workshop bound
`<= $12.63276875`, aggregate worst case is `<= $71.97920075`. Routes, privacy,
capabilities, and prices must be checked again before any call.

A clean negative leaves this ticket open and falsifies usefulness only for the
named task/model/budget condition. A runtime, transport, identity, privacy, or
artifact failure is inconclusive scientific evidence and an owning product
defect. No seed, row, message, model, parser, budget, or acceptance rule changes
after results.

No new orchestration layer is required. After scientific approval, the two
existing example surfaces receive only thin invocation edits. The IFBench entry
constructs `Imp.Experiment.Data`, the two-predictor `Imp.Module`,
`Imp.Optimizer.GEPA`, and calls `Imp.Experiment.check`; it then uses
`Imp.Experiment.Result.write!`, `Imp.Optimizer.Artifact.write!/read!/apply`, and
`ImpDeployment.ProgramServer`. Its matched reference invokes the authenticated
`IFBenchCoT2StageModule` with public `dspy.GEPA.compile`. The OA entry remains
`examples/local_optimize_anything_retry_policy/run.exs`, calling
`Imp.Optimize.Anything.run`, `to_artifact`, Artifact `write!/read!/value`, and
the existing executable evaluator. Parent and fresh-OS modes remain separate
ordinary `mix run` invocations. No terminal treatment runner or historical
result is resumed.

## Frozen portfolio outcome (2026-07-30)

The structured Optimize Anything condition met its frozen criterion. Seeds
`2026073101` and `2026073102` each selected a proposer-generated candidate and
improved exact untouched execution from 3/6 to 5/6; seed `2026073103` retained
the baseline at 3/6. The mean exact-count lift was 4/3 cases with two positive
seeds. All three portable value artifacts loaded in fresh OS BEAM processes and
reproduced the six ordered executable outputs. The first seed's post-result
launcher initially stopped before fresh loading; commit `46ba37e` fixed only
that ordinary entry boundary, and the retained artifact was then loaded without
another proposal or test evaluation in the parent.

The IFBench condition completed all three Imp seeds and the three authenticated
stock-DSPy/GEPA reference seeds. Imp's selected-artifact causal lifts were
`+0.0390625`, `0`, and `+0.0546875`: two positive seeds, mean `+0.03125`, median
`+0.0390625`, and range `[0, +0.0546875]`. The within-seed row-paired empirical
bootstrap intervals were `[-0.0390625, 0.125]`, `[0, 0]`, and
`[-0.03125, 0.140625]`. The middle seed tied on selection and retained the
baseline; its same-program held-out replay changed from `0.484375` to
`0.515625`, which is recorded as provider nondeterminism rather than optimizer
lift. Every Imp Result/Artifact pair was written mode 0600 and passed the fresh
OS four-probe concurrent service check.

The reference runner originally treated the raw `dspy.GEPA.compile` return as
the deployed program even when it lost full-selection scoring. The immutable raw
outputs remain preserved. Applying the already-frozen strict outer selection
rule without model calls retained baseline for seeds `2026072705` and
`2026072706`; seed `2026072707` selected the GEPA return by score, but that
return's two named predictor instructions were identical to baseline, so its
causal lift by selected-artifact identity is also zero. Reference causal lifts
are therefore `0`, `0`, `0`; replay scores of raw or parameter-identical returns
are not optimization credit. The prospective runner now saves and evaluates the
GEPA return only when its full selection score strictly exceeds baseline, while
retaining the raw candidate result separately.

The primary IFBench requirement is not met because Imp's mean causal lift is
below `0.05`, despite two positive seeds. The observed matched mean difference
against the reference is `+0.03125`, above the secondary `-0.05` margin, but
that cannot substitute for own-baseline improvement. This ticket remains open.

Raw ordinary outputs and logs are retained under the existing ignored evidence
root `tmp/imp-88sn-usefulness-9916276-stopped/ifbench-66c0f1d-completed`;
the three immutable reference result SHA-256 values are
`05db774290857f840f82b31bff713f0c27cce3eab2f045f50eff3b0a66de0c0c`,
`62c3eb8920dd80c86a6f01b6c9fa7eb5cd9b0e4c813d29d3bc68efe3a6f53146`,
and `e490504cffe5b4df8beef0d28a7bfdc3872dae67138dabd746a3993d7af6fef0`.
Imp telemetry observed 1,590 task and 4 reflection transports inside the three
experiments plus 24 fresh-service task transports, each with one attempt. The
reference histories retain only a lower bound of 553 task and 6 reflection
calls costing `$1.31805105`; DSPy deep-copy histories prevent an exact reference
total. The frozen `$59.346432` reservation remains the conservative portfolio
upper bound; no exact total dollar claim is made.
