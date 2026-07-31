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

> **Superseded scientific interpretation:** the source-exact scorer audit at
> the end of this ticket invalidates the MIPRO outcome and leaves the Imp GEPA
> lift/noninferiority conclusions unverified for pinned IFBench. The raw values
> below remain immutable historical observations of the scorer used then.

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

## Provider-free IFBench mechanism diagnosis

The common baseline instructions were exactly `Respond to the query` for
`generate_response_module` (SHA-256 `03d6fa0c...a4314`) and `Ensure the response
is correct and adheres to the given constraints. Your response will be used as
the final response.` for `ensure_correct_response_module` (SHA-256
`9f0bfae5...e0f3`). The exact full optimized strings remain in each retained
Artifact; the hashes and descriptions below make their identity reviewable
without duplicating several pages of prompt text here.

| Imp seed | Named-predictor mutation | Selection baseline -> optimized | Test baseline -> selected | Retained failures | GEPA path |
|---|---|---:|---:|---|---|
| `2026072705` | generator unchanged; corrector replaced by the detailed seven-step constraint verifier (`7e749879...2c18`) | `0.755208 -> 0.895833` | `0.492188 -> 0.531250` | selection 0/0; baseline test 0; selected test 1 strict parse failure (`missing_output_fields: [:response]`, row index 22); no retained evaluator exception | 96 metric calls, 2 reflections, 2 archive candidates: the first reflected proposal did not enter the archive; the second was accepted and became champion |
| `2026072706` | neither predictor changed | `0.848958 -> 0.848958` | `0.484375 -> 0.515625` replay of baseline | no retained selection/test failure | 88 metric calls, 1 reflection, 2 archive candidates: one proposal was admitted from its minibatch but lost full-validation selection, so compile returned baseline; an earlier parent batch advanced without reflection, but the retained Result does not preserve its skip reason |
| `2026072707` | generator replaced by a detailed constraint-following instruction (`cfb3de5e...b87b`); corrector unchanged | `0.807292 -> 0.817708` | `0.484375 -> 0.539063` | selection 0/0; baseline test 1 strict parse failure (`missing_output_fields: [:response]`, row index 45); selected test 0; no retained evaluator exception | 80 metric calls, 1 reflection, 2 archive candidates: the proposal was admitted and became champion |

Only four Imp reflections occurred because the pinned finite
`max_metric_calls: 80` is the semantic stopper, not a promise of twelve
reflections. Each seed first spent 32 metric calls on full validation. Every
iteration then spent an 8-row parent minibatch; perfect sampled work can skip
reflection, while an admitted child also incurs its 8-row minibatch and a
32-row full validation. Seed 1 legally completed its second started iteration
at 96 calls, seed 2 at 88, and seed 3 at 80, then stopped. This is the intended
GEPA 0.1.4 stopping envelope and explains why the theoretical cap of 12
reflections was not approached.

The public Experiment result preserves selected programs, final selection/test
rows, and telemetry, but not the attached optimizer Report. Consequently the
accepted/non-admitted path above is recoverable from candidate-count and
progress transitions, while rejected proposal text and optimization-time row
failure categories are not in the retained Result. That is an observability
gap; it is not evidence that an evaluator failure changed selection. All final
Imp selection/test diagnostics that were retained were strict adapter parse
failures, not scorer exceptions.

The authenticated stock-DSPy/GEPA arm had the same 80-call semantic opportunity
and made 2, 3, and 1 reflection calls by seed. Its optimizer log shows:

- `2026072705`: a generator proposal lost its minibatch (`6.1667 < 7.0`); a
  correction-stage proposal won (`5.25 -> 6.75`) and became GEPA's internal
  best, but fresh outer selection scored it `0.692708` against baseline
  `0.744792`, so the deployed artifact is baseline.
- `2026072706`: three proposals (generator, corrector, generator) all lost their
  minibatches; compile returned baseline. Fresh outer selection was
  `0.729167` against baseline `0.770833`, also retaining baseline.
- `2026072707`: a generator proposal won its minibatch (`6.5 -> 6.75`), but full
  validation kept program index 0 as best. The raw compile return therefore has
  both baseline instructions. Its fresh selection replay scored `0.848958`
  against `0.791667`, so the strict outer rule mechanically chooses that return,
  but selected parameter identity is still baseline and causal lift is zero.

Reference failures were diagnostic score-zero rows: baseline/candidate
selection parse counts were `2/6`, `2/3`, and `2/0`; baseline/candidate test
counts were `10/8`, `10/10`, and `11/10`. All were `AdapterParseError` except
one retained `IndexError` evaluator failure in both seed-2 baseline/candidate
test replays and one in seed-3 candidate test. Thus all three outer-selected
reference causal lifts are zero: seeds 1 and 2 select baseline, and seed 3
selects a parameter-identical return. Raw candidate test improvements are not
selection-authorized optimizer effects.

### Diagnosis boundary

- **A — expected pinned-GEPA limitation:** with a 32-row validation set and an
  80-call semantic budget, full evaluations dominate the budget. Imp obtained
  only one or two actual reflections per seed, each mutating one named
  component. Stock GEPA showed the same low-opportunity pattern and local
  minibatch/full-validation reversals. This budget can test lifecycle and a
  small number of mutations, but it is weak evidence about reflective search.
- **B — Imp product/algorithm defect:** no retained trace shows the engine
  mutating the wrong component, violating strict admission, or exceeding the
  pinned stopper. The concrete product gap is that `Experiment.Result` does not
  retain the optimizer Report, so proposal rejection reasons and
  optimization-time diagnostics were lost after an otherwise successful public
  run. The already-fixed outer-reference selection bug was in the example, not
  the Imp GEPA engine. Neither gap explains the low causal lift.
- **C — experiment-design limitation:** task-model nondeterminism is large
  relative to the measured lift. Imp seed 2 replayed the identical baseline at
  `+0.03125`; stock GEPA's internal and fresh selection rankings also reversed.
  Row bootstrap intervals condition on one generated response and therefore do
  not measure this provider/seed noise. Strict structured parsing was useful
  but asymmetric failure frequency further reduced matched power. The rows are
  source-disjoint for this run, not globally unseen.

### MIPRO design challenge and disposition

The earlier MIPRO recommendation was directionally useful but not launchable.
It had not named or hashed a new split, and its `~5,200` task-call estimate
counted only the MIPRO arms plus Imp fresh-service probes. It omitted the
baseline evaluations required to claim improvement over an own baseline.

#### Source-row lineage

The source authorities remain IFBench train SHA-256
`a5ec13223a93879b7172da783d54669d5873dc4632b57fd6d961730c9679fc8c`
(14,971 rows) and test SHA-256
`11c3d683dcc7f4908a4d3cacd05c9a8bbd5484af2f8fde969e7abe2b8bad3e34`
(294 rows). Every `matched_gepa_mipro_ifbench*` generation and the completed
`matched_instruction_family_ifbench` run resolve to the same 16/32/64 receipt;
they are repeated exposure of one row set, not additional independent sets.
The only other repository-owned source-derived IFBench execution is
`local_gepa_ifbench_cross_task`, which used train indices `300..315`, train-file
development indices `0..23`, and test indices `0..47`. Comparing
`(source-file, source-index)`, not the examples' locally renamed IDs, gives a
conservative exposed union of 75 train-file rows and 94 test-file rows. The
complements contain 14,896 train-file rows and 200 test-file rows. Repository
reference inspection found no third source-derived IFBench split; synthetic
compatibility vectors do not add source rows.

This proves that a new disjoint split *can* be constructed, but not that the
previously proposed split was disjoint: no exact indices, ordered rows, or
digests were ever frozen. Before any call, a result-blind derivation must select
only from those complements and bind the ordered bytes. Such a condition tests
row-level transfer within IFBench and a different optimizer mechanism. It is
not cross-task MIPRO generalization. The ticket's cross-problem evidence would
still come from composing that realistic LM condition with the already-positive
structured Optimize Anything condition.

#### Correct call decomposition

For one runtime and one seed on 16 train / 32 selection / 64 test rows, the
ordinary public lifecycle requires:

- 64 task transports for baseline selection (32 rows, two predictors);
- zero task transports for demonstration bootstrap because both demo limits are
  zero;
- 11 optimizer transports: three dataset-summary calls for 16 rows at batch
  size 10, then four grounded instruction proposals for each of two predictors;
- 64 task transports for MIPRO's internal full-validation baseline;
- 512 task transports for eight non-minibatch categorical trials over all 32
  validation rows and both predictors;
- 64 task transports for the optimized program's outer selection evaluation;
- 128 task transports for baseline test and 128 for selected test.

That is 960 task plus 11 optimizer transports per runtime/seed, before fresh
service. Three seeds across Imp and DSPy therefore require 5,760 task and 66
optimizer transports; Imp's four two-stage fresh-service probes per seed add 24
task transports. The corrected full ceiling is **5,784 task + 66 optimizer**,
or `$85.280256` at the last `$0.013824` / `$0.08064` reservation rates. The old
matched runner's looser 864-call MIPRO ceiling plus its separate 192-call
baseline arm would instead reserve 6,360 task calls; neither accounting supports
the earlier 5,208-call claim.

#### What the observations would mean

- **MIPRO mechanism advantage:** at least two Imp seeds select a genuinely
  changed named-predictor instruction/demo combination, mean causal test lift is
  at least `0.05`, and the three-seed sign/dispersion report remains favorable.
  That would show task-specific advantage over the low-opportunity GEPA result,
  not general MIPRO superiority.
- **Task-model noise:** parameter-identical selected artifacts replay at
  materially different scores, or observed score movement is comparable to
  same-program replay movement without stable mutation/sign evidence. Those
  replays are noise estimates, never optimizer credit.
- **General optimizer failure on this condition:** both implementations finish
  their proposal/search opportunity cleanly yet select baseline or fail the
  frozen own-baseline criterion across the three seeds. If stock DSPy succeeds
  while Imp fails under matched opportunity, the result instead points to an
  Imp semantic/product gap; if Imp succeeds and DSPy fails, it is a scoped
  algorithm-native outcome requiring mechanism inspection, not automatic
  superiority.

#### Cheaper predeclared staging

Run all three fixed **Imp** seeds first through `Imp.Experiment.check`, Artifact,
and `ProgramServer`: 2,904 task transports (including 24 fresh-service calls)
plus 33 optimizer transports, at most `$42.806016`. Do not stop after a lucky or
unlucky individual seed. Stop the scientific condition only for an owning
runtime/safety/artifact defect, or after all three Imp seeds if the frozen
own-baseline criterion fails; in the latter case the matched arm cannot rescue
the primary claim and is disproportionate. If and only if Imp passes, run all
three stock-DSPy seeds unchanged: 2,880 task plus 33 optimizer transports, at
most another `$42.474240`. No seed, row, threshold, parser, route, or opportunity
may change between stages.

Spend is not presently exact. The completed portfolio reports 1,614 Imp task
and four reflection transports, a `$1.31805105` retained upstream lower bound,
and several explicitly bounded but not exactly metered earlier calls. The last
conservative workshop aggregate was `<= $71.97920075`, but that figure includes
the completed portfolio's full reservation and is not an actual bill. Adding
stage one mechanically would make that deliberately loose upper bound
`<= $114.78521675`, above the approximately `$100` target; adding the full
matched condition would make it `<= $157.25945675`. Actual spend is certainly
lower, but cannot be manufactured from deep-copy-truncated upstream histories.
Provider authority should therefore require a current account-level usage
reconciliation sufficient to show stage-one headroom, not another local ledger.

No coordinator, manifest, or harness is needed. The Imp stage is the ordinary
two-predictor `MIPROv2` -> `Experiment.check` -> `Result`/`Artifact` -> fresh
`ProgramServer` path. The reference stage is stock DSPy 3.2.1 MIPROv2 with the
already-authenticated task-graph adaptation and the same outer selection rule.

**Recommendation: RUN A CHEAPER PREDECLARED DESIGN.** Freeze exact complement
rows and digests, reconcile current provider spend, then run the three-seed Imp
stage first. If it passes, the exact earned claim is: *on one newly
source-disjoint IFBench split, under the frozen GPT-5.4 Mini / Claude Sonnet
4.6, four-candidate/eight-trial condition, current Imp MIPROv2 improved its
two-stage program over its own baseline by mean at least `0.05` with at least
two positive seeds and produced a reusable fresh-served artifact.* Only a
completed second stage may add a stock-DSPy matched-semantics/noninferiority
claim. A clean negative earns no effectiveness claim and remains a decisive
task/model/budget falsification.

### Stage 1 provider-free checkpoint

The result-blind complement split is now frozen without inspecting a model
outcome. Its receipt is
`examples/matched_instruction_family_ifbench/data/mipro_stage1/receipt.json`
(SHA-256
`52b1138ccf4b2dbf906b054874a3ff6d394e3b4de9c5fe5aa3466e81a7b45555`).
It binds both prior-exposure sources by path and digest and records every exact
zero-based source index. The selected coordinates are disjoint from the full
75-row train-source and 94-row test-source exposed unions described above.
Frozen bytes are:

- train 16: `b13952a222105c4072d4528043ef14079ad616fe8214ad686a94bac490b67d39`;
- selection 32:
  `f4cb93127ea64a57202dc1ece29c5aac438c685f3de9a84ac8b653aa24c1123c`;
- held-out 64:
  `9bf6e8ce65e3dcea5f9ae5537884381caaedb68f3f925208e98f98fcfcc77dbb`.

The existing `matched_instruction_family_ifbench/usefulness.exs` ordinary entry
now accepts `IMP_88SN_CONDITION=mipro_stage1`. It constructs the real public
two-predictor `MIPROv2`, calls `Experiment.check` with baseline-on-test enabled,
writes/reads the linked `Result` and selected `Artifact`, then invokes the same
fresh-OS `ProgramServer` path. There is no coordinator, manifest, ledger,
dashboard, or separate result type. Provider-disabled execution binds seeds
`2026072705/06/07`, four instruction candidates, eight full categorical trials,
zero demos, selection before held-out, strict baseline-on-tie selection, three
complete seeds without score-based stopping, and the 2,904 task + 33 optimizer
Stage 1 ceiling. The criterion remains mean causal held-out lift `>= 0.05` with
at least two positive seeds. Stage 2 has no runnable change and remains dormant
unless Stage 1 passes.

Provider accounting was queried read-only at `2026-07-31T06:19:30Z`; no
completion endpoint was called. The current OpenRouter key reports
`$7.673042175` daily usage and `$17.345262735` cumulative/monthly usage. Those
are verified provider usage totals for the key, not exact workshop attribution.
The account credits endpoint also reports `$1644.044485242` lifetime account
usage, which plainly includes unrelated history and is excluded from workshop
arithmetic.

Three spend views are therefore retained separately:

1. **Verified provider usage:** `$7.673042175` today on the current key;
   `$17.345262735` cumulative on that key.
2. **Defensible workshop lower bound:** `$4.83706155`, the sum of distinct
   retained exact amounts `$3.13862325` (TREC), `$0.38038725` (terminal IFBench
   v1), and `$1.31805105` (completed current IFBench reference lower bound).
3. **Conservative unknown-inclusive current upper:** `$18.182906735`, current
   key cumulative usage plus the coordinator's approximately `$0.837644`
   Behold usage as though it were separate. This may double-count but does not
   substitute prior call reservations for bills.

At current rates, adding Stage 1's `$42.806016` maximum to that third figure
gives a realistic aggregate exposure of `<= $60.988922735`, under the
approximately `$100` target. Exact routes, provider identities, privacy deny,
prices, no-retry/no-fallback settings, and current key usage still require one
immediate read-only preflight before provider authority. A contradiction or
material rise near the target returns for review; it does not change the split,
seeds, budget, or criterion.

### Stage 1 terminal runtime stop

The authorized run from exact clean `2a444d7` passed the immediate account and
route/privacy/price preflight unchanged, then stopped during seed `2026072705`
inside MIPRO setup. One Claude Sonnet dataset-summary call completed. Before a
second summary transport, the public pinned-DSPy proposer renderer attempted
`to_string/1` on an IFBench `kwargs` list containing maps and raised. MIPRO had
not evaluated its internal baseline or a trial; Experiment had completed the
baseline-selection stage in memory but emitted no completed Result. No test row
was read, no Artifact was built, no fresh service ran, and seeds `2026072706/07`
never started. This is an owning public MIPRO nested-value rendering defect, not
an optimizer outcome; the frozen primary is unevaluated and Stage 2 remains
dormant.

The exact retained log is
`examples/matched_instruction_family_ifbench/exercised-stopped-mipro-stage1.log`
(SHA-256
`009bc7fc3578c165e7691b7eea1972c18b4ea8cdc1dd7e0ff6355939848d1485`).
Current-key usage moved from `$17.345262735` to `$17.459159985` during the run,
a `$0.11389725` aggregate delta. Experiment source order proves all 32 baseline
selection rows were attempted before optimize; the two-stage graph therefore
made between 32 and 64 task transports, depending on whether a first-stage
parse failure prevented its paired correction call. The failed result retained
no telemetry with which to narrow that interval. MIPRO source order proves
exactly one optimizer transport: its first dataset-summary call returned before
local rendering of the second batch failed. The account endpoint does not
provide a request ID, so the dollar delta is reported as observed run-window
key usage rather than manufactured per-request precision. The outer zsh wrapper
subsequently failed to print Mix's exit status because it assigned the reserved
`status` variable; that happened after Mix returned and did not cause or alter
the preserved optimizer failure.

### Stage 1 owning product repair

The stopped run above remains terminal and byte-identical. The pinned proposer
now recursively renders the JSON-safe value domain used by ordinary Examples:
CPython string and finite-float spelling, integers, booleans/`None`, ordered
lists, and nested objects. `Jason.OrderedObject` carries source insertion order
where JSON object order must survive the BEAM; the ordinary IFBench loader now
uses that representation for nested objects. Unsupported structs, tuples,
functions, references, and non-string object keys fail with the exact example
path before any proposer transport.

The provider-free two-predictor public MIPRO compile differential now compares
all dataset-summary and proposal messages against DSPy 3.2.1 on nested
IFBench-shaped rows, enters one categorical search trial, JSON-round-trips its
checkpoint, and resumes without replaying setup. The pinned first-batch repr
SHA-256 is `beb5d329babc820d5901d25f834748b6ee2e2b4afbb0aad2583734f9cd592a3f`;
the complete prompt-message transcript SHA-256 is
`391087e66b3663a659a1e349d2845413e009036f68dea9a0a9af4095ab20202a`.
Simple scalar-only transcripts remain byte-identical. The repair also corrects
previously non-crashing but wrong scalar spellings (quotes/control escapes and
Python float exponent form), so its semantic effect is intentionally not
limited only to values that formerly raised.

The existing provider-disabled zsh invocation now uses `exit_code` rather than
zsh's reserved `status` parameter. This is an ordinary shell regression, not a
new runner.

A read-only key query after the repair reported `$7.794994425` daily and
`$17.467214985` cumulative usage on the current OpenRouter key; no completion
endpoint was called. Keeping the earlier conservative treatment of Behold's
approximately `$0.837644` as separate gives an unknown-inclusive current upper
of `$18.304858985`. A clean successor under the unchanged `$42.806016` Stage 1
ceiling would therefore expose at most `$61.110874985`, still below the
approximately `$100` workshop target. This is headroom arithmetic, not provider
authority or an exact attribution of historical usage.

### Stage 1 successor terminal runtime stop

The authorized successor from exact clean `52b252f` passed its immediate
route/provider/price/privacy and current-usage preflight, then stopped during
seed `2026072705` in pinned MIPRO bootstrap. One retained bootstrap trajectory
had an error and the frozen `max_errors: 0` configuration raised before dataset
summary/proposal completion or categorical search. The ordinary Experiment had
already evaluated baseline selection in memory, but emitted no Result; no
held-out row was read, no Artifact or fresh service was created, and seeds
`2026072706/07` did not start. This is an inconclusive runtime/treatment failure,
not a MIPRO outcome, and Stage 2 remains dormant.

The exact tracked log is
`examples/matched_instruction_family_ifbench/exercised-stopped-mipro-stage1-successor.log`
(SHA-256
`562007203bad0040f92549c871ab57b7a23d6fa9fb065b92efc10ba7037649d0`).
The failed Experiment result retained only the aggregate bootstrap error, not
the underlying row/adapter diagnostic or telemetry, so exact transport counts
cannot be reconstructed. Source order proves all 32 baseline-selection rows
were attempted and at least one bootstrap trajectory ran. Current-key usage
moved from `$17.467214985` to `$17.571419235` during the run, an observed-window
delta of `$0.10420425`; it is not manufactured per-request attribution. Adding
the separately conservative approximately `$0.837644` Behold amount gives a
current unknown-inclusive workshop upper of `$18.409063235`.

The stop also falsified one part of the frozen safety arithmetic. Pinned DSPy
MIPRO still executes three bootstrap arms when both retained-demo limits are
zero, then discards those demos after the calls advance shared RNG. With four
candidates and 16 train rows, that is at most 48 two-stage trajectories, or 96
task transports per seed. The declared 2,904-task Stage 1 ceiling incorrectly
counted zero bootstrap transports. The source-correct outer ceiling would have
been 3,192 task plus 33 optimizer transports, `$46.787328` at the frozen rates;
against the post-stop current upper it would expose at most `$65.196391235`.
This correction does not reinterpret the stopped run or authorize another one.

For this stop, source order bounds task transports to 32--64 baseline-selection
transports plus 1--96 bootstrap transports; no optimizer-summary/proposal
transport occurred because bootstrap precedes dataset grounding. The missing
underlying trajectory diagnostic and telemetry prevent a narrower honest count.

### Zero-demo MIPRO owning review

The two stopped logs above remain byte-identical and no provider or held-out
call was made during this review. An executable pinned-DSPy 3.2.1 vector now
runs the ordinary public zero-demo `MIPROv2.compile` configuration on nested
IFBench-shaped examples. It establishes all of the following rather than
inferring them from method names:

- DSPy constructs four candidate demo sets: the true zero-shot arm and three
  real bootstrap arms (`-2`, `-1`, `0`). The bootstrap outputs are passed into
  instruction proposal as `task_demos`; only after proposal are demos removed
  from the categorical search by setting `demo_candidates=None`.
- With `max_errors=0`, the first program `ValueError`, adapter
  `AdapterParseError`, or metric `RuntimeError` is re-raised before any prompt
  model call. The deterministic vector observed respectively 0, 2, and 1 task
  LM calls; the exception type and complete underlying message were preserved.
- Imp performs the same three bootstrap arms, uses their accepted traces for
  proposal grounding, and discards demos from zero-shot search. Skipping this
  work would change both proposal information and shared RNG opportunity; it is
  not a compatible optimization. A future explicitly named BEAM-native
  zero-bootstrap mode could make that trade, but pinned `:dspy_3_2_1` cannot.

The reproduced Imp defect was narrower and real: after `TrajectoryRunner`
retained the row error, `UpstreamBootstrap.enforce_error_budget!/2` replaced it
with one aggregate `RuntimeError`. `Imp.Optimizer` then retained only that
message. The public path now uses the existing `Imp.EvaluationCancelledError`
boundary. Direct MIPRO compile still aborts on the first failure; `Imp.optimize`
and `Experiment.check` return a redacted structured reason containing stage
`mipro_bootstrap`, content-bound row identity and local index, bootstrap-arm
candidate identity, the underlying cause, completed predictor calls, and
logical/transport attempts when the adapter supplied them. Raw example rows are
not returned. Operational-safety errors continue to bypass this containment.

This cannot recover the successor's exact failed row. Its trajectory held the
original error and response metadata only in BEAM memory. The aggregate was
raised before bootstrap metadata, checkpoint, optimizer report, Experiment
Result, Artifact, or telemetry was written; the ordinary example then persisted
only the aggregate stack trace. There is no retained provider response from
which to reconstruct the parser input. The only honest stopped-run bound remains
32--64 baseline task transports plus 1--96 bootstrap task transports, zero
optimizer transports, and the observed account-window delta `$0.10420425`.

The corrected legal source maximum is 48 bootstrap trajectories per seed
(three arms by sixteen rows), hence 96 two-stage task transports per seed and
288 across the three seeds. On an all-accepted clean path, the frozen RNG asks
for 7/8/8 trajectories, or only 14/16/16 two-stage transports; rejected rows can
raise realized work to the legal maximum. The provider-disabled ordinary entry
now reports the source-correct total ceiling of 3,192 task plus 33 optimizer
transports. At the frozen prices that is `$46.787328`, and against the last
observed conservative workshop upper `$18.409063235` would expose at most
`$65.196391235`. This is reservation arithmetic, not a bill or authority.

Classification:

- **Required pinned behavior:** three bootstrap arms, bootstrap traces informing
  proposals, demos excluded from zero-shot categorical search, and immediate
  first-failure abort at `max_errors=0`.
- **Imp semantic/product defect:** replacing the first cause and row/candidate
  context with an aggregate error. This is repaired without changing scoring,
  opportunity, or treatment configuration.
- **Avoidable work:** none within the pinned profile. The work is discardable
  only if proposal information and RNG compatibility are also deliberately
  surrendered.
- **Potential BEAM-native deviation:** an explicitly distinct zero-bootstrap
  profile could trade proposal grounding for lower cost. It is not implemented
  here and would not satisfy DSPy 3.2.1 MIPRO compatibility.

**Recommendation: redesign the frozen question (`b`), not a third successor.**
The product observability defect is fixed, but the retained run gives no basis
to claim its first provider parse/program/metric failure was transient or
corrected. Under the now-proven pinned semantics, `max_errors=0` intentionally
makes any one of up to 48 bootstrap trajectories terminal. Re-running the same
question would merely gamble that the unknown failure does not recur. A future
result-blind design may choose and freeze a nonzero diagnostic error budget as
a different scientific question, retaining score-zero failures and the same
rows/seeds/models/criterion; its legal outer cost remains `$46.787328`. Until
that design is justified, MIPRO usefulness on this condition is unmeasured and
Stage 2 remains dormant.

### Separately frozen diagnostic-10 revision

The provider-disabled successor is now explicitly identified as
`dspy-3.2.1-default-max-errors-10`. It changes only MIPRO's error policy from
the terminal runs' `0` to the ordinary pinned DSPy 3.2.1 default `10`, plus the
already-corrected 3,192-task/33-optimizer safety ceiling. Rows and source
coordinates, ordered split bytes and digests, seeds, task/optimizer models and
routes, four candidates, eight full trials, messages, token limits, selection
and held-out criterion, Artifact/Result linkage, and fresh `ProgramServer`
service are unchanged. This is a different frozen scientific question; neither
terminal run is resumed or reinterpreted.

Pinned source and executable behavior agree:

- `dspy.settings.max_errors` is `10`; MIPRO resolves `None` to that value and
  passes it to each zero-demo `BootstrapFewShot` arm and the shared `Evaluate`.
- Bootstrap counts failures per arm. One ordinary metric failure was contained,
  the arm continued, all four candidate demo sets were constructed, and compile
  reached the optimization boundary. The tenth failure re-raised its original
  `RuntimeError` immediately, after exactly ten task calls and before any prompt
  call.
- Candidate/full validation uses DSPy `Evaluate(failure_score=0.0)`. Fewer than
  ten program/parser/metric exceptions occupy ordered score-zero rows. At the
  tenth, `Evaluate` cancels; MIPRO's `eval_candidate_program` contains that
  evaluation as a whole-candidate score `0.0`. It does not turn the exception
  into instruction advice.
- In the frozen configuration `fewshot_aware_proposer=false`, bootstrap outputs
  are not rendered into proposal `task_demos`; the calls remain required for
  pinned call-graph/RNG opportunity and the zero-demo candidates are discarded
  before categorical search. More generally, Imp admits only successful
  trajectories as demos. Failed trajectories remain diagnostics and never
  become proposal evidence.
- Route, cost, privacy, transport, budget, and cancellation failures use
  `Imp.OperationalSafetyError`; deterministic public execution proves the first
  such bootstrap failure escapes immediately after one call, outside the
  numeric error budget.

Imp already carries a contained bootstrap failure into both ordered
`metadata.bootstrap.errors` and top-level `Report.errors`, setting report status
to `:with_errors`; the provider-free review confirms it cannot appear as an
error-free optimizer result. One ordinary failure followed by success completed
public MIPRO search and the outer `Experiment.check` lifecycle. Ten
bootstrap failures produced the structured redacted cancellation fixed in
`380b284`. Ten failures in each full candidate evaluation produced candidate
score zero, twenty ordered diagnostics across baseline and one trial, and
retained the baseline instruction rather than selecting a failed candidate.
The all-success two-predictor task and prompt transcripts remain byte-identical
to pinned DSPy with the explicit value `10`.

Call arithmetic has two distinct views. Under an all-accepted bootstrap, the
frozen RNG schedules 7/8/8 trajectories across the three seeds, adding
14/16/16 two-stage task transports to the former 2,904-call calculation. The
clean-path expectation is therefore **2,950 task + 33 optimizer transports**, a
`$43.441920` reservation at the frozen rates. Rejected-but-nonexceptional rows
can exhaust all sixteen rows in each of three arms, so the legal source maximum
remains **3,192 task + 33 optimizer**, `$46.787328`. The finite error budget can
only stop work earlier; it does not justify lowering the safety ceiling.

A read-only OpenRouter key query on 2026-07-31 reported `$17.573773485`
cumulative/monthly usage and `$7.901552925` daily usage. Treating the coordinator's
approximately `$0.837644` Behold amount as separately additive gives a
conservative current workshop upper of `$18.411417485`. Clean-path aggregate
exposure is therefore `<= $61.853337485`; worst-case exposure is
`<= $65.198745485`, below the approximately `$100` target. These figures do not
manufacture attribution for unknown historical calls.

**Recommendation: RUN the revised question.** The value `10` is upstream's
documented ordinary default, not a threshold selected from the two stopped
outcomes. Provider-free execution proves it contains isolated diagnostics,
halts pathological bootstrap failure, preserves successful opportunity, keeps
operational guards fatal, and cannot credit a failed candidate. A completed
three-seed negative remains decisive; another owning runtime or artifact stop
would instead falsify current MIPRO product readiness. Stage 2 remains dormant
regardless until Stage 1 satisfies its unchanged primary criterion.

### Diagnostic-10 seed 1: portability repair and scorer diagnosis

The diagnostic-10 run is terminal and inconclusive. Seed `2026072705` completed
selection and held-out evaluation (`0.328125 -> 0.3697916667` on selection;
`0.53125 -> 0.5625` on the recorded Imp metric), then its fresh process failed
while decoding the selected Artifact. Seeds 2/3 and Stage 2 did not start. The
retained bytes remain unchanged: run log `44d2e830...`, Result `3ed95c51...`,
and Artifact `65131e49...`.

The Artifact failure was generic, not MIPRO-specific. Schema-2/3 parameter
snapshots and attached reports encoded identifier atoms and restored them with
`binary_to_existing_atom/2`; a fresh VM failed first on `metric_error`. A scan
of this exact Artifact found 104 distinct tagged atom names, 82 of which were
absent without incidental optimizer-module loading. Artifact restoration now
keeps persisted predictor, signature/demo/config, report, error, and metadata
identifiers as strings and resolves only names present in the trusted live
program. It never creates an atom from Artifact bytes. The exact retained
champion now applies to a freshly reconstructed two-stage program; its
canonical parameter snapshot equals the retained candidate after only the
legacy name-tag-to-string normalization, and a deterministic local two-stage
probe executes. Original provider outputs cannot be reproduced provider-free,
so this proves exact selected parameter state and executable application, not
provider-response replay. An unpacked-package test additionally uses predictor,
field, demo, and report names absent from the fresh VM and proves they remain
uninterned through write/read/apply/call.

The 48 optimizer diagnostics reveal a separate scientific defect. The frozen
loader intentionally retained `kwargs` as `Jason.OrderedObject` values so the
DSPy 3.2.1 proposer saw insertion-ordered Python-like data. The Imp IFBench
metric's `strip_nil_values/1` accepted ordinary maps but did not unwrap that
representation. Its later clauses therefore saw no rule arguments: keyword
rules fell through to the misleading "unsupported" catch-all and
`nth_paragraph - 1` raised arithmetic failure.

The exact failures are deterministic:

- bootstrap's first shuffled arm (`internal_seed=-2`) failed at trajectory
  indices 0/4/6: train sources `000345` (`keywords:existence`), `000343`
  (`length_constraints:nth_paragraph_first_word`), and `000372`
  (`keywords:existence`);
- nine full candidate evaluations each failed selection indices 9, 10, 14, 29,
  and 30: sources `000084`/`000179`/`000109` (existence), `000234`
  (nth-paragraph arithmetic), and `000214` (forbidden words). That is 27
  existence, 9 arithmetic, and 9 forbidden-word diagnostics, plus the three
  bootstrap diagnostics.

Pinned upstream IFBench evaluation on the retained outer baseline/optimized
outputs accepts all five row/rule shapes without exceptions. Per-row scores are
`[1, 1, .5, 1, 1]` for baseline and `[1, 1, .5, 1, 2/3]` for optimized. Feeding
the same values to Imp with ordinary maps yields those same five scores; feeding
the frozen ordered representation reproduces all five recorded failures. The
rows are valid and the outputs are ordinary task outcomes. The defect is the
Imp scorer/ordered-data adapter boundary. Internal outputs for the 45 trial
diagnostics were reduced to scores/errors before the report and are not
retained, so they cannot be independently replayed; the failure precedes their
response-dependent checks.

More importantly, re-scoring all retained selection outputs with the pinned
scorer gives baseline `0.7916666667` and optimized `0.75`, reversing the frozen
Imp selection. Thus the recorded `+.03125` held-out difference is descriptive
for the implemented Imp metric, but it is not an interpretable MIPRO lift for
the intended pinned-IFBench question. Repairing Artifact portability alone
does not preserve that scientific question. **Continuation recommendation:
do not start seeds 2/3.** Repair and validate the scorer representation boundary
as a product change, then pose any future run as a separately frozen condition;
do not reuse this seed as a scientific outcome or silently rescore it.

## Source-exact scorer ownership correction (2026-07-31)

The scorer audit found two distinct representation errors at the Imp boundary.
MIPRO's pinned proposer input correctly retained nested JSON objects as
`Jason.OrderedObject`, but the Elixir scorer treated those objects as missing
rule arguments. Separately, `language:response_language` used an English-only
native fallback even though pinned IFBench uses `langdetect`. The scorer now
recursively copies ordered JSON values into ordinary maps only for evaluation,
leaving proposer order and source rows unchanged, and delegates language
detection through the existing pinned Python bridge. Unknown rules still fail
closed. The ordinary IFBench entry binds that bridge before provider authority
and evaluates train/selection support provider-free; held-out scoring remains
after artifact selection.

Provider-free comparison now agrees exactly with the pinned scorer on 337
source-derived constraint instances covering every frozen GEPA/MIPRO row and
80 rule families. The independent registry fixture covers all 83 active rule
ids with a passing response and the pinned blank-response failure boundary.
No unsupported frozen rule remains. This is exact agreement on the frozen
source-derived and constructed boundary corpus, not a proof over every possible
response string.

The scientific reach is narrower than the earlier portfolio prose implied:

- The terminal diagnostic-10 MIPRO seed remains **invalid as an optimizer
  outcome**. Source-exact rescoring gives selection `0.7916666667 -> 0.75`, so
  pinned selection retains baseline, not the stored optimized artifact. The
  corresponding retained held-out outputs rescore `0.5390625 -> 0.578125`, but
  held-out cannot authorize selection and the optimizer itself ran against the
  faulty scorer. Its runtime diagnostics and the generic Artifact portability
  repair remain valid product evidence.
- The completed three-seed Imp GEPA run predates ordered-object loading, so it
  is not affected by that representation bug. It did, however, run without the
  source-exact non-English language bridge. Re-scoring only the retained final
  rows gives selection `0.770833 -> 0.911458`, `0.864583 -> 0.864583`, and
  `0.822917 -> 0.833333`; baseline/selected held-out gives
  `0.507812 -> 0.53125`, `0.484375 -> 0.515625`, and
  `0.484375 -> 0.5390625`. Final outer choices happen to remain unchanged, but
  optimization-time scores and reflection feedback were different from pinned
  IFBench. Therefore the earlier `+0.0390625/0/+0.0546875` causal-lift claim,
  its intervals, mean, and matched noninferiority conclusion are **unverified
  for pinned IFBench** and must not support imp-88sn. The stored scores remain
  an immutable description of the implemented scorer at that commit.
- The local IFBench V1/V2 and matched v1/v2/v3/GEPA-0.1.4 stops retain valid
  operational facts (format, transport, workflow, stop location, held-out
  barrier). Any Imp numeric IFBench score produced without the pinned language
  bridge is unverified as an exact benchmark score. None of those stopped runs
  supplies an optimizer-effectiveness conclusion.
- Authenticated stock-DSPy/GEPA outputs imported
  `gepa_artifact.benchmarks.IFBench.ifbench_metric` directly. Their raw scores
  and all-zero outer-selected causal lifts are unaffected. The matched
  Imp-minus-upstream conclusion is not valid because the Imp side was not using
  the same scorer. TREC, Banking77, and Optimize Anything evidence use other
  metrics and are unaffected.

**Strategic recommendation:** stop using IFBench for the next full-telos swing.
The scorer boundary is now suitable for a separately frozen future rerun, but
IFBench has already consumed substantial integration effort and still mixes
strict-format noise with optimizer signal. Choose a different realistic
multi-stage task with a compact, natively executable metric for the next
current-source usefulness condition; retain IFBench as a pinned compatibility
regression rather than immediately paying to re-freeze it.

## Next usefulness task recommendation (provider authority: none)

**Recommend Banking77; do not continue IFBench or introduce another task
adapter.** This is a design recommendation only. It freezes no new row, starts
no model, and does not authorize provider use.

Three existing candidates were compared:

- **Banking77 is the only candidate that meets the product shape without new
  infrastructure.** The packaged deployment example already owns a public
  two-stage `analyze_intent -> classify_route` program, exact label accuracy,
  `Experiment.check`, linked `Result`/`Artifact`, and fresh concurrent
  `ProgramServer` service. Both stages can do real work: the analyzer extracts
  payment state and evidence; the router distinguishes eight already-declared
  intents spanning card-payment state, transfers, exchange, physical cards,
  and source-of-funds verification. The route instruction must disclose that
  semantic mapping. A secret opaque-code mapping would manufacture baseline
  weakness rather than test useful optimization.
- **TREC is worse for this question.** Its successful matched GEPA/MIPRO result
  is a one-predictor classifier. Turning it into a genuinely two-stage program
  would create a new task graph merely to revisit a task that already supplies
  Imp's only positive matched evidence, rather than testing a missing product
  claim on a different realistic problem.
- **The packaged support-router fixture is worse scientifically.** It has the
  right two-stage deployment lifecycle, but only eight synthetic rows and a
  scripted LM whose planted demonstration rule guarantees the improvement. It
  is a strong feature test and cannot answer real-model usefulness across
  seeds.

### Source-disjoint condition that can be frozen result-blind

The two pinned Banking77 snapshots currently retained in the repository expose
240 unique source coordinates: 160 train and 80 test rows spanning eight
labels. Every tracked Banking77 optimizer example resolves to those snapshots;
results may repeat rows but do not add a third source dataset. The proposed
source authority is the already-pinned `PolyAI/banking77` revision
`796a4623935746f71378f0ebd435635a8ce08e50`, whose train/test parquet digests
are already recorded in `grpo-usefulness-banking77-v1.json`.

If approved, derive 24 train, 24 selection, and 48 test rows from all eight
declared labels: 3/3/6 per label. Before choosing any row, exclude
the full retained exposure union by both `(source split, source index)` and
normalized utterance digest across the `796a...` and `90d4...` snapshots. Then
order the remaining rows by SHA-256 of the committed seed, split, label id, and
normalized-text digest, using raw-text digest and source index only as collision
tie-breakers. This is deterministic, balanced, independent of model outcome,
and uses the source train split for train/selection and the source test split
only for untouched test. At freeze time the derivation must also scan retained
ignored experiment roots for any additional source coordinate or text digest;
any hit joins the exclusion set. No difficulty filtering or row replacement is
allowed.

This condition has plausible headroom without pathological row selection: the
eight intents include naturally confusable cases, but their meanings and route
mapping are given to the program. Prior Banking77 runs establish that this task
family is nontrivial and learnable; they do not predict this new split's
outcome. If the strong baseline saturates, that is a clean lack-of-opportunity
result, not a reason to choose harder rows.

### Compact staged MIPRO design

Use the existing two-predictor module, exact route accuracy, GPT-5.4 Mini task
LM, Claude Sonnet 4.6 proposal LM, and seeds `2026072705/06/07`. Configure
pinned DSPy-3.2.1 MIPRO semantics with three instruction/demo candidates, six
full categorical trials, two startup trials, at most two bootstrapped and two
labeled demos per predictor, batch size 10, `max_errors: 10`, serial calls,
cache/retry/fallback/JSON fallback disabled, and strict selection improvement
(tie retains baseline). MIPRO therefore gets grounded dataset summaries,
predictor-specific instructions, joint demo choices, and adaptive categorical
search rather than instruction-only mutation.

For one Imp seed the conservative legal ceiling is 680 task transports:
48 outer baseline-selection, 48 bootstrap, 48 internal baseline-selection,
288 for six trials, 48 outer optimized-selection, 192 for paired baseline and
selected test, and 8 for four fresh two-stage service probes. Dataset grounding
and proposals add at most 10 optimizer transports (four summary plus three per
predictor). All three seeds are therefore bounded by **2,040 task + 30 optimizer
transports**. At the last Banking77 reservation rates (`$0.007104` and
`$0.08064`) that is **at most `$16.91136` new spend**, about one third of the
abandoned IFBench Stage-1 ceiling. These are conservative per-call reservations,
not an input-token hard cap; route, privacy, price, and current workshop usage
must be revalidated before authority.

Run all three Imp seeds before interpreting the condition. Selection alone
chooses the artifact; `compare_baseline_on_test: true` evaluates baseline and
selected on the same ordered untouched rows only after the selected Artifact
is built and applied. Each Result/Artifact must reload into a freshly
reconstructed program and serve four concurrent non-test probes. Report
within-seed paired row intervals and the three seed lifts/dispersion/sign count
separately. Success requires mean held-out accuracy lift `>= 0.05` and positive
lift in at least two seeds. Parameter-identical replay movement is noise, not
optimizer credit.

Only if Imp passes should a stock-DSPy 3.2.1 MIPRO arm run with the same task
messages, rows, seeds, candidates, demos, trials, error policy, and outer
selection rule. Its maximum is 2,016 task + 30 optimizer transports
(`$16.740864` at the same reservations); it adds matched semantic evidence but
cannot rescue a failed Imp own-baseline result. No coordinator, manifest,
dashboard, ledger, or new result type is needed: the Imp arm is the existing
`MIPROv2 -> Experiment.check -> Result/Artifact -> ProgramServer` path, and a
later matched arm must first prove its ordinary DSPy module renders the same
two-stage messages provider-free.

The exact claim on success is limited to: *on one source-disjoint, eight-intent
Banking77 split under the named models, three seeds, and compact MIPRO budget,
current Imp MIPRO improved its two-stage program over its own baseline and
produced a reusable fresh-served artifact.* A clean negative earns no
effectiveness claim. A runtime, safety, persistence, or artifact failure is an
inconclusive product defect. IFBench remains only a pinned provider-free
compatibility/scorer regression and receives no further provider work.

## Banking77 MIPRO Stage 1 frozen checkpoint

Scientific review expanded the recommended condition from four to all eight
Banking77 labels already declared by Imp's two retained source snapshots. This
is still one exact-label task, not eight separately selected tasks. No model
outcome was inspected while deriving the complement.

The pre-selection exposure scan at parent commit `79daf9b` read 85 unique
Banking77-related JSON records: 63 tracked files and 22 ignored retained-result
or temporary files, including package copies. Every file parsed. The union is
exactly 240 source coordinates (160 train, 80 test) and 240 normalized utterance
digests across eight labels. Ignored roots added no coordinate or text outside
the tracked union. Normalization is Unicode NFKC, casefold, whitespace collapse,
and strip. The complete file hashes, source IDs, coordinates, and normalized
digests are retained inside the frozen public dataset; there is no unread-file
residual uncertainty.

The result-blind derivation uses pinned `PolyAI/banking77` revision
`796a4623935746f71378f0ebd435635a8ce08e50`. Its train parquet is 10,003 rows,
295,235 bytes, SHA-256 `4526edfa...e0390`; its test parquet is 3,080 rows,
92,969 bytes, SHA-256 `535fc96c...410be`. The combined canonical source
description has SHA-256 `5b242094...6d00`. After excluding every exposed
coordinate and normalized text, remaining rows are ordered by
`sha256(imp-88sn-banking77-mipro-v1:split:label-id:normalized-text-digest)`;
raw-text digest and source index are collision tie-breakers only. Per label the
first three source-train rows become train, the next three become selection,
and the first six source-test rows become test. No difficulty or baseline
filter is present.

The frozen file is
`examples/deployment/data/banking77-mipro-stage1.json`, SHA-256
`4934ebc54b06614343461c2fe79c7ca4807892c1b645cbb30790e945dcb2c34a`;
its canonical payload SHA-256 is `040d6628...dafe`. Ordered split hashes are:

- train 24 (3 per label): `ec42891d...1e44`;
- selection 24 (3 per label): `3312228c...5ddd`;
- untouched test 48 (6 per label): `dc921b77...e502`.

`ImpDeployment.Banking77Pipeline` is the existing deployment example's exact
analyzer-then-router program extracted into its package. The retained GEPA
Artifact still applies to the default program. This condition configures eight
typed routes and discloses their real meanings: fee charged, payment not
recognized, declined transfer, exchange rate, physical card, pending payment,
reverted payment, and source-of-funds verification. The analyzer must produce
intent evidence without choosing a route; the router consumes that evidence
and the original utterance. Both named predictors are visible and mutable
through `Imp.Module`; the metric is native exact route accuracy.

The thin ordinary entry is `examples/deployment/banking77_mipro.exs`. It uses
only public `MIPROv2 -> Experiment.check -> Result/Artifact -> ProgramServer`
surfaces. Seeds remain `2026072705/06/07`; settings are three instruction/demo
candidates, six full categorical trials with two startup trials, at most two
bootstrapped plus two labeled demos, pinned DSPy proposer and modeled Optuna
TPE search, `max_errors: 10`, serial calls, no cache/retry/fallback/JSON
fallback, strict validation selection, paired baseline/selected test on the
identical 48 rows, schema-3 Artifact, and four fresh concurrent two-stage
probes. The stock-DSPy arm remains absent and dormant.

Per seed the legal task maximum is 680: 48 outer baseline-selection, 48
bootstrap, 48 internal baseline, 288 across six trials, 48 outer optimized
selection, 192 paired test, and 8 fresh service. Grounding costs four optimizer
calls and the two predictors receive three proposals each, for 10 optimizer
calls. Across three seeds the legal ceiling is **2,040 task + 30 optimizer**.
Non-bootstrap task work is fixed at 632 per seed; the single calling bootstrap
arm can finish after two accepted examples (4 two-stage transports) or scan all
24 rows (48), so completed clean usage has an outcome-dependent range of
1,908..2,040 task transports rather than a fabricated point estimate. At the
last validated reservations, `2,040 * $0.007104 + 30 * $0.08064 = $16.91136`.
This is a reservation maximum, not an input-token hard cap.

Before calls, the primary remains mean own-baseline held-out accuracy lift
`>= 0.05` with positive causal lift in at least two of three seeds. Forty-eight
rows give `1/48 = 0.020833` resolution, so the threshold requires an average
gain of at least 2.4 correct rows and needs no revision. Selection alone chooses
the Artifact. Parameter-identical baseline/selected programs receive zero
causal lift regardless of replay score movement. Report row-paired intervals
within each seed and seed dispersion/sign count separately.

Provider-disabled execution succeeds from the source example and unpacked Hex
package, constructing the 24/24/48 `Experiment.Data`, both named predictors,
the exact MIPRO configuration, and the call plan without a key or network.
Focused MIPRO/Experiment/Artifact tests pass (34 tests), public surface passes
(44/44), and full `package.check` passes (13 contract tests plus clean-room
compile/release/workflow/fresh-load/provider-disabled entry). The entry contains
no IFBench bridge, ledger, coordinator, manifest, dashboard, or new result
schema.

Read-only OpenRouter key status at `2026-07-31` reports `$9.797824425` daily
usage and `$19.470044985` cumulative/monthly usage, with `$480.529955015` of the
account limit remaining. Those are verified key totals, not guaranteed workshop
attribution. Even conservatively assigning the whole monthly total to the
workshop and adding the Stage-1 maximum gives `$36.381404985`, below the
approximately `$100` workshop target.

**Launch recommendation: RUN STAGE 1 after the required immediate live
route/provider/privacy/price/no-retry preflight.** The exact claim on success is:
*on one source-disjoint eight-intent Banking77 condition, under GPT-5.4 Mini,
Claude Sonnet 4.6, three frozen seeds, and the stated compact budget, current Imp
MIPRO improved its real two-stage program over its own baseline by mean at
least 0.05 with at least two positive seeds and produced reusable fresh-served
Artifacts.* A clean negative is valid and leaves the ticket open. A runtime,
safety, persistence, or fresh-service failure is inconclusive. No provider
authority was used at this checkpoint.

## Banking77 modeled-MIPRO revision

The two attempted six-trial conditions are terminal, inconclusive product
failures and remain byte-for-byte preserved. Their configuration combined
`search_fidelity: :dspy_3_2_1_optuna_4_9_0` with `startup_trials: 2`, which is
not a valid pinned Optuna-4.9 modeled-search opportunity. Product repair
`a6e9000` now rejects that known-invalid combination before bootstrap,
selection, evaluator, or LM work.

The separately named `imp-88sn-banking77-mipro-modeled-v2` revision changes
only the search opportunity: `startup_trials: 10` and 15 objective trials.
The internal baseline is Optuna's first completed observation, so objective
trials 1--9 use startup-random suggestions and trials 10--15 are six modeled
multivariate categorical-TPE suggestions. Rows, dataset and split hashes,
seeds, models, routes, three instruction candidates, two bootstrapped plus two
labeled demo limits, `max_errors: 10`, native exact-label metric, selection
rule, paired test, Artifact, and fresh concurrent service remain unchanged.

Per seed the legal task ceiling is 1,112: 48 outer baseline selection, up to 48
bootstrap, 48 internal baseline, 720 across 15 trials, 48 optimized selection,
192 paired baseline/selected test, and 8 fresh service. Four grounding calls
plus three proposals for each of two predictors remain 10 optimizer calls.
Across three seeds the legal ceiling is **3,336 task + 30 optimizer**, or
`3,336 * $0.007104 + 30 * $0.08064 = $26.118144` at the frozen reservation
rates. Clean completed task usage is outcome-dependent in the range
3,204--3,336 because bootstrap may accept two rows after four transports or
scan all 24 rows.

The primary is unchanged: mean held-out own-baseline accuracy lift `>= 0.05`
and positive causal lift in at least two of three seeds. Same-program replay
movement is zero causal lift. Passing can earn only a task/model/budget-specific
current-source modeled-MIPRO claim; a clean negative is valid. Stock DSPy stays
dormant pending a separate decision.

### Modeled-MIPRO Stage 1 result

Exact clean `f0c34ff` completed all three Imp seeds through the ordinary
`MIPROv2 -> Experiment.check -> Result/Artifact -> fresh ProgramServer` path.
Seed 1's outer shell returned after completion because the operator used zsh's
reserved variable `status`; seeds 2 and 3 continued in the same private root
without rerunning seed 1 or changing any treatment input.

The frozen per-seed outcomes are:

- `2026072705`: selection `0.875 -> 0.958333`; optimized selected; held-out
  `0.895833 -> 0.979167`; causal lift `+0.083333`.
- `2026072706`: selection tied `0.916667 -> 0.916667`; baseline selected;
  causal lift `0`. Its two same-program held-out evaluations were `0.916667`
  and `0.854167`; that difference is provider nondeterminism, not optimizer
  harm or benefit.
- `2026072707`: selection `0.916667 -> 0.958333`; optimized selected; held-out
  `0.854167 -> 0.895833`; causal lift `+0.041667`.

The sign criterion passed at two positive seeds out of three, but mean causal
lift was `0.041667`, below the frozen `0.05` threshold. **The primary did not
pass.** Stock DSPy therefore remains dormant. This is a clean, task/model/budget
specific negative for the preregistered headline, not evidence that MIPRO is
generally ineffective.

Every seed completed 15 candidates: objective trials 1--9 were startup-random
and 10--15 were modeled TPE. The internally selected optimizer candidates came
from startup trials 4, 3, and 2 respectively; modeled trials executed but did
not displace those winners. Bootstrap accepted two examples per seed after
three, two, and two program attempts. Optimizer reports retained 7, 17, and 14
diagnostics; outer selection retained 0, 2, and 0 errors, while paired test
evaluations retained `(1,0)`, `(0,3)`, and `(2,2)` baseline/selected errors.
No error exhausted `max_errors: 10`, and no operational-safety failure occurred.

The ordinary path performed 535, 534, and 534 logical two-stage program
evaluations and 10 optimizer calls per seed. The corresponding conservative
task-transport ceilings were 1,070, 1,068, and 1,068 (3,206 total); exact task
transport counts are not persisted when a first-stage parse failure prevents
the second stage. OpenRouter key usage moved from `$19.504255485` immediately
before launch to `$21.345753735` afterward, an observed key-level delta of
`$1.84149825`; that is the strongest retained cost evidence, not a fabricated
per-response ledger.

All three mode-0600 Result/Artifact pairs loaded and served four concurrent
fresh-process two-stage calls. Their SHA-256 pairs (Result, Artifact) are:

- seed 1: `f5d4594f3e2e6aaf72981dd8d0f2d1b54b5a66ac5c5a44249ea4b36d20dc4109`,
  `38079ae7344f83fc7c64b3b5d80c82074d19ada975a6058f477ddee4fc518491`;
- seed 2: `9e1ab86037bc49a297ff17d48ad3440f07acf5f64a4e57b694bc290a5758a5d6`,
  `5034170cce55749096db656cb7a19a2ac74e9256205740ec102c93be24a94b26`;
- seed 3: `f5e7f918c62baf78bdfefcba4a61224d2f62d8f1154d7c2af583172754056e68`,
  `4bbaef67dfb520d39f3590b0d8a5a2faefaa690fe8053e928aa9827d47f81c49`.

The private retained root is
`benchmarks/results/banking77-mipro-modeled-v2-f0c34ff`; predecessor roots and
logs remain unchanged.

### Provider-free modeled-MIPRO postmortem

This postmortem reads only the retained Result/Artifact/log bytes. It makes no
new model call and does not revise the frozen result.

**Selected programs and paired rows.** Parameter tuples below are ordered as
`[analyzer instruction, analyzer demos, router instruction, router demos]`.

- Seed `2026072705` deployed startup-random trial 4, tuple `[0,1,1,2]`.
  Analyzer instruction 0 is the baseline text (SHA-256
  `1e9aba8fb83a0a8470efe3e30bfee7bc81c184ecccd8d003b80f7ffb3f1c0818`)
  with labeled demos `banking77-796a-train-4019` and
  `banking77-796a-train-4074`. Router instruction 1 is
  proposal SHA-256
  `cbccc37be34a688a1556eaf523c41e203b30facfb2b9adb57fb6c0f89a43f6d2`
  with augmented fee examples “How come I was charged an extra fee when paying
  with the card?” and “When do i get charged a fee for using the card?”. On
  selection it gained `banking77-796a-train-4046` and
  `banking77-796a-train-4040`, with no loss. On test it gained
  `banking77-796a-test-1255`, `banking77-796a-test-1254`,
  `banking77-796a-test-1258`, and `banking77-796a-test-2012`, with no loss; the
  last gain replaced a baseline parse failure.
- Seed `2026072706` deployed **baseline**, not raw optimizer winner
  startup-random trial 3 (`[1,1,1,0]`), because outer selection tied. The
  deployed analyzer/router are instruction 0 with no demos, hashes
  `1e9aba8fb83a0a8470efe3e30bfee7bc81c184ecccd8d003b80f7ffb3f1c0818` and
  `c22115fb3db42920b18026a57c4c4e634336304b7646fde3a69fd45be79153fa`.
  Optimized selection gained `banking77-796a-train-4046` and
  `banking77-796a-train-4040` but lost `banking77-796a-train-2550` and
  `banking77-796a-train-296` to parse failures: net zero. The two evaluations
  of the selected baseline on test gained `banking77-796a-test-2100` in the
  replay but lost `banking77-796a-test-1113`, `banking77-796a-test-1255`,
  `banking77-796a-test-1258`, and `banking77-796a-test-2090`: net minus three
  rows.
  This is same-program replay noise, so causal lift remains exactly zero.
- Seed `2026072707` deployed startup-random trial 2, tuple `[2,2,1,1]`.
  Analyzer proposal SHA-256 is
  `2ba0ab2f2dff993c9d10a180a6f904152e810a56a0ec221a0854adf9c4de410f`
  with augmented examples “Please tell me why I would have to pay a fee for a
  recent payment. Thanks.” and “How come I was charged an extra fee when paying
  with the card?”. Router proposal SHA-256 is
  `33b18b3fb855a581e941247c125c2f08f172014a17243ae24db77b442614d570`
  with labeled demos `banking77-796a-train-2606` and
  `banking77-796a-train-5620`. Selection gained
  `banking77-796a-train-5591` and `banking77-796a-train-6779` and lost
  `banking77-796a-train-4040`: net plus one. Test gained
  `banking77-796a-test-1112`, `banking77-796a-test-1113`,
  `banking77-796a-test-1278`, and `banking77-796a-test-2108`, and lost
  `banking77-796a-test-1631` and `banking77-796a-test-2004`: net plus two.

**Diagnostics.** The 7/17/14 optimizer diagnostics are ordinary strict-adapter
failures, not proposal, route, safety, or optimizer exceptions. Seed 1 has one
bootstrap missing-`route` failure, then two missing-`evidence` and four
missing-`route` candidate-evaluation failures. Seeds 2 and 3 have no bootstrap
failure; candidate evaluation retained respectively 3/14 and 3/11
missing-`evidence`/missing-`route` failures. Every candidate still evaluated the
same ordered 24 rows with failures scored zero, all 15 trials completed, and no
evaluation exhausted `max_errors: 10`. The failures therefore changed
candidate scores but did not reduce search opportunity or selection-row
comparability. The report retains stage and row index but not trial/candidate
identity on non-bootstrap diagnostics, so exact per-candidate attribution is
not recoverable from the immutable result; that is an observability limitation,
not evidence of a search failure. Outer selection/test diagnostics remain
separately attached to their exact rows.

**Modeled opportunity.** The internal baseline was observation 1. Optuna's
`n_startup_trials: 10` therefore made objective trials 1--9 startup-random and
10--15 modeled. In tuple order above, the modeled acquisition sequences were:

- seed 1: `t10 [0,1,1,2]/1.0`, `t11 [0,1,1,2]/.9583`,
  `t12 [1,1,2,2]/.9583`, `t13 [0,1,1,1]/1.0`,
  `t14 [2,0,1,2]/1.0`, `t15 [0,2,2,2]/.9583`;
- seed 2: `t10 [1,1,1,0]/1.0`, `t11 [1,1,1,1]/.9167`,
  `t12 [1,1,1,0]/1.0`, `t13 [2,2,1,0]/.9167`,
  `t14 [2,1,1,0]/.9583`, `t15 [1,1,0,0]/.9167`;
- seed 3: `t10 [2,2,1,1]/.9167`, `t11 [2,0,2,0]/.9167`,
  `t12 [2,1,1,0]/.9583`, `t13 [2,0,1,2]/.9167`,
  `t14 [2,2,2,0]/1.0`, `t15 [2,0,0,1]/.7083`.

Each modeled phase repeated two startup assignments and tried four new joint
assignments. Startup plus baseline covered every categorical level for all four
parameters; modeled acquisition concentrated on the better observed levels but
still introduced four new combinations per seed. Repeated categorical choices
are legal Optuna TPE behavior. All 18 modeled suggestions received complete
24-row objectives, so they had a fair execution opportunity, although six
modeled trials cover only a compact fraction of the 81-combination space. The
pinned provider-free Optuna 4.9 differential passes 18/18 and confirms the
startup boundary and first Bayesian trial. Imp deliberately reports exact
startup parity but not whole modeled-sequence identity because later equal
floating acquisition values use documented BEAM tie-breaking. No new mismatch
was reproduced here.

**Stability and classification.** Outer selection margins were +2 rows, tie,
and +1 row. The only exact same-program test replay moved by -3/48 (`-0.0625`),
and duplicate internal assignments varied by up to 1/24 in seed 1 and 2/24 in
seed 3 (seed 2's duplicates were stable). That noise is material relative to
the observed mean `+0.041667`; it prevents a stronger magnitude claim, but the
predeclared identity rule still makes the frozen decision unambiguous. This is
classification **C**: the intended MIPRO mechanisms executed correctly and the
best selection-admitted artifacts produced a task-specific two-positive-seed
signal whose mean stayed below the frozen bar. It is not a reproduced
product/search defect (A), and neither limited modeled coverage alone (B) nor
noise (D) can turn the failed primary into a pass.

The result satisfies the three-seed, realistic two-stage, source-disjoint
selection/test, modeled-search, portable Artifact, and fresh concurrent service
parts of `imp-88sn`. It does not satisfy that ticket's required material mean
multi-stage lift; the already-positive non-prompt OA half cannot substitute for
it. It likewise does not satisfy `imp-yme4`'s release-defining improved example
or breadth of useful optimizer behavior. The remaining telos gap is primarily
**algorithm usefulness on a realistic multi-stage LM program**; evaluation
robustness is a material secondary uncertainty, and breadth remains open.

**Single recommendation:** accept this as an early modeled-MIPRO
mechanism/lifecycle milestone while keeping `imp-88sn` and `imp-yme4` open. Do
not run another immediate paid MIPRO benchmark; the next usefulness portfolio
should be predeclared later rather than tuned around this condition.

## Provider-free evaluation-robustness review

This review is grounded in the retained modeled-MIPRO outputs and current public
source. It makes no provider call and does not revise the terminal result.

### Current behavior and the reproduced gap

`Imp.Evaluate` executes each ordered row once and returns one arithmetic mean,
one row list, and one error list. `Imp.Experiment.check/5` evaluates baseline
selection once, runs the optimizer, evaluates optimized selection once, and
admits the optimized program only when that one score is strictly higher. It
then builds and successfully applies the selected Artifact before optional
baseline-test and selected-test evaluation. `Experiment.Result` schema 2 can
durably retain those rows and diagnostics, while `Optimizer.Report` can retain
optimizer-specific observations. Artifact and `ProgramServer` preserve and
serve the selected program; neither is an evaluation policy.

There is no first-class fixed-repetition or noisy-objective contract. Manually
duplicating examples is not an adequate public substitute: `Experiment.Data`
correctly rejects duplicate source identities within or across splits, while
inventing per-repetition identities would hide that the observations are paired
repeats of the same source row. Optimizer reports are flexible enough to record
duplicates, but do not provide a common outer selection policy or durable
paired summary.

The retained evidence makes this product gap material:

- the exact same deployed baseline program moved from `44/48` to `41/48` on a
  second held-out evaluation, a `3/48 = 0.0625` swing;
- identical internal MIPRO parameter assignments moved by as much as `2/24 =
  0.083333` across observations; and
- seed 3's selected-artifact causal lift was only `2/48 = 0.041667`.

Noise can therefore change an optimizer's observation history and modeled
acquisition, reverse the outer baseline-versus-optimized selection decision,
or make a post-selection test difference look larger or smaller than the
program effect. Strict outer selection protects important but narrower facts:
test rows cannot choose the Artifact, a selection tie retains baseline, and a
retained-baseline identity makes causal lift zero even when a replay score
moves. It does **not** prevent a lucky optimized pass from displacing baseline
or an unlucky optimized pass from rejecting a better program. Artifact
integrity, fresh-process serving, and operational-safety propagation are not
made uncertain by score noise.

### Established comparators

- Pinned DSPy 3.2.1 (`29448ae`) `Evaluate` performs one `ParallelExecutor`
  pass and returns the mean over that pass. MIPRO gives Optuna one scalar per
  objective trial. DSPy's AIME tutorial repeats the 30-row AIME 2025 set five
  times “for statistical stability,” but this is caller-side dataset
  duplication, not a reusable paired selection/result contract. DSPy also
  caches LM calls by default; turning cache off exposes the nondeterminism that
  matters here.
- Pinned Optuna 4.9.0 accepts one scalar observation per trial. Its TPE sampler
  models repeated categorical assignments as separate observations; it does
  not aggregate replicates on the caller's behalf. Fixed repeated evaluation
  and aggregation therefore belong to the objective owner, not the sampler.
- Imp's pinned Ax 23 differential covers six other product vectors and provides
  no authority for noisy-objective behavior. As a non-authoritative current
  product comparator, Ax checkout `394a16a` now exposes `runsPerTask`, defaults
  it to one, averages fixed repeats, and multiplies its metric-call budget by
  the repeat count. That is useful corroboration for the small pattern below,
  not a claim of pinned Ax parity.

### Recommendation: implement one bounded public robustness slice

Add fixed repetitions to the existing evaluation/Experiment boundary, without
changing any optimizer algorithm:

```elixir
Imp.Experiment.check(program, optimizer, data, metric,
  evaluation_options: [
    repetitions: 3,
    aggregation: :mean,
    max_errors: 10
  ]
)
```

The exact bounded semantics should be:

1. `repetitions` is a positive integer, default `1`; `aggregation` is only
   `:mean` in this slice, also the default. Each repetition evaluates the exact
   same ordered row identities. No adaptive racing, early winner stopping, or
   confidence-threshold policy is added.
2. Baseline and candidate results are paired by repetition ordinal and row
   identity. Selection compares their aggregate means and retains baseline on
   a tie exactly as today. Each completed repetition has identical row
   cardinality; a cancelled or incomplete repetition fails the stage instead
   of contributing a biased partial mean. Operational-safety failures remain
   immediately fatal.
3. The existing error policy applies independently to each repetition. Calls
   and legal budgets multiply deterministically by `repetitions`; retry and
   provider transport behavior do not change.
4. The public evaluation/result view retains the ordered per-repetition scores,
   aggregate mean, minimum, maximum, and raw ordered rows/errors when
   `include_rows: true`. Experiment additionally retains ordered paired
   candidate-minus-baseline deltas and positive/tie/negative counts so the
   admission decision is reproducible. This is a descriptive dispersion
   summary, not a confidence interval or statistics framework.
5. Existing singular `score` continues to mean the value used for selection.
   Default one-pass callers preserve their behavior. Durable Result writing
   will require one backward-compatible schema evolution for the optional
   repetition summary; readers must continue to accept schemas 1 and 2.
   Artifacts keep only the aggregate selected score and their existing Result
   linkage—raw repeats belong in Result, not Artifact.

This composes with every optimizer because `Experiment.check` owns the final
family-independent baseline/candidate admission. Optimizers continue to own
their internal search evaluations and reports; this slice does not silently
change GEPA, MIPRO, SIMBA, COPRO, OA, or training objectives. The same narrow
fixed-repeat evaluator can be opted into by an optimizer later, but internal
replication is explicitly outside this first slice. `Artifact.apply`,
fresh-process loading, and `ProgramServer` need no API change.

One provider-free public feature test should use an ordinary two-stage program
and shipped optimizer whose deterministic test LM supplies a noisy sequence.
On the identical ordered validation rows, the first observation favors the
inferior baseline, while three fixed observations give baseline scores
`[1, 0, 0]` and optimized scores `[0, 1, 1]`. The default one-pass check must
retain baseline; `repetitions: 3` must select the optimized program with means
`1/3` and `2/3`, persist the three paired observations and exact multiplied
row count, build/apply the selected Artifact, and reproduce its behavior after
fresh-process load. A separate assertion makes an incomplete repetition fail
without selection. These assertions test user-visible selection and lifecycle,
not internal task scheduling.

Migration impact is deliberately small: no existing call changes; one new
evaluation option, additive result visibility, and a compatible durable-reader
update. This capability would make outer admission and reported comparisons
more robust. It would not rehabilitate the terminal Banking77 result, prove an
optimizer useful, or by itself remove noisy observations inside optimizer
search. Those remain separate scientific and algorithm-specific questions.

### Outer-repetition implementation checkpoint

The bounded slice above is implemented provider-free. `Experiment.check/5`
accepts positive `evaluation_options[:repetitions]` and only `:mean`
aggregation, validates both before bootstrap or executable work, repeats every
outer selection/test stage over the identical ordered rows, selects on the mean,
and retains baseline on a tie. The existing Evaluate error budget applies to
each run; an incomplete run fails its stage and operational safety remains
fatal.

The default and explicit `repetitions: 1` paths retain the ordinary in-memory
behavior and schema-2 durable shape. Repeated checks use Result schema 3 solely
to add one redacted `repetitions` block: ordered run index/score/row/error
counts, aggregate scores, paired candidate-minus-baseline deltas, and exact
outer row-evaluation opportunity. Detailed rows/errors remain opt-in. Schemas 1
and 2 remain readable, and Artifact/ProgramServer require no change.

A provider-free public two-stage `LabeledFewShot` feature test demonstrates the
user behavior: one pass retains a baseline favored by its first noisy sample;
three fixed repeats score baseline `[1,0,0]`, optimized `[0,1,1]`, select the
better expected optimized program, write/read the linked Result and Artifact,
and apply/call it in a fresh OS BEAM. Separate tests cover aggregate ties,
pre-side-effect validation, per-repetition diagnostics, cancellation, immediate
operational-safety escape, deterministic opportunity multiplication, redacted
persistence, and schema-1/2 compatibility.

This closes only outer admission robustness. Optimizer-internal objectives and
search observations remain single-pass unless that optimizer explicitly owns a
different policy. The implementation does not alter or rehabilitate the
terminal Banking77 evidence.

## Closure-frontier disposition at `54d4a9b`

- **Freeze before calls — satisfied for the retained conditions.** OA,
  IFBench, and Banking77 inputs, splits, seeds, routes, budgets, and criteria
  were fixed before their calls; stopped and negative outcomes remain
  immutable. This procedural fact does not make an invalid scorer scientific
  evidence.
- **Realistic multi-stage LM lift across at least three seeds — open.** Banking77
  modeled MIPRO exercised the ordinary two-stage public lifecycle and produced
  causal lifts `+0.083333`, `0`, and `+0.041667`, mean `+0.041667`; it cleanly
  failed the frozen `>= 0.05` primary. IFBench Imp effectiveness is
  invalid/unverified because its scorer representation was wrong. Outer fixed
  repetitions now protect future final admission but do not change either
  retained result.
- **Proposer-generated non-prompt usefulness — satisfied.** The typed OA
  retry-policy run selected non-seed mutations in two of three seeds, improved
  genuinely new untouched executable cases by mean `4/3`, and reproduced the
  portable selected values in fresh OS processes.
- **Ordinary lifecycle and shared portable consumer boundary — satisfied.**
  Program conditions use Experiment/Result/Artifact/ProgramServer; OA uses its
  native run/result/evaluator lifecycle and `to_artifact`; both load through
  portable Artifact without a fake common optimizer wrapper.
- **Matched equivalent opportunity — partially satisfied.** Provider-free
  semantic gates are current, but the IFBench Imp scorer invalidates its matched
  effectiveness conclusion and Banking77 DSPy Stage 2 correctly remained
  dormant after Imp failed. A future successful named-algorithm condition still
  needs its predeclared matched arm when a coherent equivalent exists.
- **Uncertainty, negatives, and recomputation — partially satisfied.** OA and
  Banking77 retain per-seed outcomes and raw ordinary results; Banking77 exposes
  the observed same-program `3/48` replay movement and duplicate-assignment
  variation up to `2/24`. The new Result repetition summary can retain future
  paired outer observations. It has not generated new effectiveness evidence,
  and optimizer-internal noisy objectives remain single-pass.

The minimum closure is therefore one thing: a predeclared current-source
realistic multi-stage LM condition, at least three fixed seeds, selection-only
choice using fixed outer repetitions, material mean own-baseline lift with the
predeclared positive-seed rule, a portable selected Artifact, and fresh
concurrent service. The already-passing OA half supplies the different
non-prompt problem class. If the named optimizer has a coherent pinned
equivalent, its matched arm follows only after Imp passes its own-baseline
criterion; matched noninferiority cannot replace own-baseline lift.

**Single next tranche: later run a bounded, predeclared multi-problem usefulness
portfolio through existing ordinary tasks and APIs.** Provider-free preparation
may inspect at most two existing candidates other than Banking77 and IFBench and
must choose one only if it already has meaningful work in both named stages, a
native deterministic metric, auditable source-disjoint unused rows, and enough
data for three fixed seeds. Freeze rows, optimizer opportunity, fixed outer
repetitions, error policy, models, routes, costs, and the material-lift rule
before calls. The executable portfolio is the retained positive OA condition
plus that one LM condition—no new experiment framework or immediate provider
authority.

Stop before calls if no existing task meets those constraints without a new
adapter or previously exposed test reuse. Once launched later, complete all
three seeds; a clean miss remains negative and ends this tranche without task,
seed, threshold, or optimizer shopping. A product/safety/artifact failure stops
the condition for repair and is not an optimizer outcome.

Optimizer-internal repetition is not next because no incorrect defining
mechanism is currently reproduced, outer admission now handles the release
decision, and changing internal objectives would broaden algorithms before the
missing product phenomenon is measured. Release/docs work is not next because
the clean package and teaching path already pass; prose and runner retirement
cannot earn the open usefulness criterion. They become a short reconciliation
only after a valid scientific outcome exists.

## Existing-task choice after outer-repetition support (`54d4a9b`)

This is a provider-free choice between the only two candidates authorized for
inspection, not a data freeze or launch authorization. The repository's current
code, retained results, ignored local roots, and history support **HotPotQA** and
reject GSM8K for this tranche.

### GSM8K — rejected because the existing program is not multi-stage

- Reusable pieces are real but incomplete for this ticket. Public
  `Imp.Datasets.GSM8K` loads the rows and its metric performs deterministic
  numeric-answer equality. The retained campaign programs are
  `Imp.chain_of_thought("question -> answer")` and a ReAct loop with the safe
  calculator tool. The generic Experiment, Artifact, and ProgramServer
  lifecycle could carry either selected program.
- Neither existing program is a named solve-then-verify/extract module. CoT is
  one optimizable predictor; ReAct can make multiple turns but remains one
  agent/tool loop rather than two independently meaningful named stages. There
  is no existing GSM8K verifier/extractor component for MIPRO or GEPA to alter.
  Choosing GSM8K would therefore require a new task module, contrary to this
  review's reuse-only boundary.
- The native metric is suitable and prior results show both a strong-model
  ceiling (`0.90/0.925` zero-shot CoT) and weaker-model headroom
  (`0.725/0.75`), but those are task-wide historical observations, not probes
  of future rows and not evidence for a multi-stage optimizer.
- Exposure is conservatively complete for the locally materialized 120-row
  source: campaign train/dev/test coordinates `0..59`, `60..79`, and `80..119`
  were used across CoT, weak-model MIPRO, ReAct, and calculator runs. The source
  file SHA-256 is
  `c5401ed9d5d510cc714a5baeef88b21252f933f37bc08fba232a85e145c9d339`;
  the SHA-256 of the ordered `index:sha256(normalized question)` exposure list
  is `b686e1a34e9dfdc5b092be7f1bb6e015c057042a7ec5935d97cba5ef2ae89bd1`.
  The pinned 1,319-row source has a large complement, but rows alone cannot
  supply the missing program mechanism.

### HotPotQA — recommended

- The benchmark tree demonstrates that four named stages are appropriate, but
  it is not a package-consumer API. The owning public example now defines the
  compact consumer program `ImpDeployment.HotPotQAPipeline`: `summarize1`,
  `create_query_hop2`, `summarize2`, and `final_answer`. It uses only
  `Imp.Module`, `Imp.predict`, `Imp.memory`, `Imp.retrieve`, Experiment,
  Artifact, and the generic ProgramServer; no `bench/` module or task-specific
  `lib/` code is imported.
- Every row supplies only its question and distractor context. The program
  builds an in-BEAM memory for that row, retrieves twice, and passes each named
  stage's output to the next stage. The answer is never a program input. The
  source-exact HoVer BM25S/Python integration is deliberately not part of this
  Imp-own-baseline condition.
- Prior task-wide evidence supplies result-independent headroom only. On the
  old 100-row campaign, one-predictor RAG scored mean F1 `0.3818/0.3853`, while
  labeled few-shot RAG scored `0.5171/0.5005`. This neither predicts the new
  four-stage baseline nor permits choosing future rows by difficulty.
- Conservative local exposure excludes distractor validation coordinates
  `0..99` in full. Within that source, model calls are directly retained for
  demo rows `0..3` and test rows `50..89`; the broader exclusion also covers
  every row named by the historical train/dev/test declaration. The source
  SHA-256 is
  `a213e77d88287804081105c24a46fa04ab66fc29a26019cc4f0fcd571fce7fb3`.
  The ordered normalized-question digest root for `0..99` is
  `b3cff1363610bfed4af63ed52c93ac65c42e78566a4fd74a918826deeb9feb0f`;
  the narrower directly-called `0..3,50..89` root is
  `1fe83bca7a6912f07418c7637f8c01ca64db165f8bb2b9a3b4ef6e27d07a4f16`.
  Separately, the provider-free fullwiki retrieval differential used
  coordinates `0..9`, and four retained live parity runs used fullwiki
  coordinates `700..715`. Those live artifacts retain exact coordinates but
  not source question bytes, so their content digests cannot be reconstructed
  from current local files. A later freeze must exclude those coordinates and
  reject normalized-question collisions across configs before selecting any
  row. This is the disclosed residual uncertainty, not permission to treat the
  rows as unseen.
- The pinned validation source has 7,405 rows. Excluding the known ranges leaves
  far more than the required fixed split, but the full bytes are not currently
  materialized. A later result-blind freeze may use the existing fetch path on
  distractor rows after coordinate `99`, remove `700..715` and every retained
  normalized-text digest match, then choose by a committed content-hash rule.
  No row is selected or inspected in this review.

### Frozen HotPotQA GEPA condition (`9608121` successor)

The source is `hotpotqa/hotpot_qa`, config `distractor`, validation split, at
revision `1908d6afbbead072334abe2965f91bd2709910ab`. The pinned Parquet SHA-256
is `c20b638ca82b21d04fe12e14ff417ad05153d4d215a65de54497fca4e972f7c6`;
the pinned dataset-card SHA-256 is
`3cfab003a856275d3198b031c6b2ac46c63178fb462a4123705f652b71b22813`,
which declares CC-BY-SA-4.0. Exact provenance, coordinates, normalized-question
digests, and the derivation rule live beside the rows in
`examples/deployment/data/hotpotqa-gepa/receipt.json`.

Before choosing rows, tracked and ignored retained evidence was scanned by
exact question and by SHA-256 of Unicode-NFKC/case-folded/whitespace-collapsed
question text. Distractor coordinates `0..99` and `700..715` were excluded in
full; the latter also conservatively covers the retained fullwiki `700..715`
exposure. The scan found no normalized source collision outside those 116
rows. From the complement, the fixed seed `imp-88sn-hotpotqa-gepa-v1` ranks by
SHA-256 over seed, declared question type, normalized-question digest, and
source ID. Per-type rank order is consumed without viewing model outputs into
train `6 bridge + 2 comparison`, selection `6 + 2`, and test `18 + 6`.
Frozen file SHA-256 values are:

- train: `0f52607fe7259a8b84930c43bcd5ae575cc0c2050c9dae4dd52ba7feaf69c302`;
- selection: `c5feada568c9c796745c274f4c3a65ea7636f6adac2a597b3f722b5059d3f9e5`;
- test: `6550b57d5a72e191b328c17e1d03074b0c0c233877f26b9f910beaa290bf6792`;
- receipt: `3ca2955ec517fa070b4f43e54c1f340b2c7cd3a54b52afc5c3d23daf75e04032`.

The native metric is HotPot F1, with normalized exact match secondary. A
provider-free comparison over all 40 gold answers under exact, upper-case,
article-prefixed, and extra-token outputs plus six normalization/special-label
boundaries compared 166 cases against pinned DSPy 3.2.1
`dspy.evaluate.metrics.hotpot_f1_score` with zero F1 or EM mismatches (case-input
SHA-256 `b05033d7b0aab0a5d7de24691314a1b8965eeee31227fd356639c32dfcdd7c19`).
There is no Python scorer or external retrieval boundary in the condition.

Seeds are `2026080101`, `2026080102`, and `2026080103`. Outer baseline and
optimized selection, baseline test, and selected test each use three fixed
repetitions over identical ordered rows, arithmetic-mean aggregation,
`max_errors: 10`, and score-zero diagnostics. GEPA's internal objective remains
single-pass. Selection is strict with baseline retained on an aggregate tie;
the schema-3 selected Artifact is applied before test access, persisted with
the Result, loaded by a fresh OS BEAM, and served for four concurrent synthetic
four-stage probes.

**Named deviation:** this Imp-own-baseline question uses the explicit
BEAM-native `module_selector: :all`, not pinned GEPA 0.1.4 round-robin and not a
matched-upstream condition. Pinned round-robin is incompatible with guaranteed
four-component opportunity at this small budget: after the initial 8-row
validation, three rejected 4-row parent/child iterations consume the semantic
32-call budget before the fourth component rotates. `:all` gives each of the
four named predictors proposal opportunity together. A deterministic public
execution selected a candidate in which all four instructions changed, used 32
optimizer metric examples and 8 reflection calls, wrote/read/applied the
Artifact, and passed the fresh concurrent service. The same observed trajectory
made 896 main-process task calls; adding 16 fresh-service calls gives the
expected 912. The generic 8/4/32 stopper envelope remains semantic 32, legal
44, at most 12 reflections and 6 iterations; the legal per-seed task ceiling is
therefore `4 * (24 + 44 + 24 + 72 + 72 + 4) = 960`.

The original Static-LM capture measured 1,376 `o200k_base` task tokens
(5,028 UTF-8 bytes) and 19,505 reflection tokens (83,895 bytes). The repaired
real ReqLLM provider-disabled path measures 5,099 task bytes and 83,942
reflection bytes. The frozen reservations remain 8,192 input / 512 output for
the task model and 32,768 input / 1,024 output for reflection. Imp has no
packaged tokenizer that can enforce those model-specific token counts without
a new dependency, so the reusable live guard is explicit instead: 8,192
rendered-content bytes for task calls and 131,072 bytes for reflections. The
token figures own conservative pricing/capacity reservation; the byte figures
own pretransport operational safety. At the last validated route
prices (`$0.75/$4.50` and `$3/$15` per million input/output tokens), the legal
three-seed reservation is:

`2,880 * $0.008448 + 36 * $0.113664 = $28.422144`.

This is a conservative reservation from hard call/output limits and the frozen
input envelopes, not actual spend or provider authority. Immediately before a
launch, the exact OpenAI GPT-5.4 Mini and Anthropic Claude Sonnet 4.6 routes,
privacy deny, no fallback/retry/cache, capabilities, prices, and workshop usage
must be revalidated.

The primary remains mean paired held-out HotPot F1 own-baseline lift at least
`0.05` and positive causal lift in at least two of three seeds. Report EM
secondarily, per-seed row-paired uncertainty separately from the three seed
lifts, and same-program replay as zero causal lift. A clean miss is a narrow
negative for this task/model/budget and leaves this ticket open; a runtime,
safety, persistence, Artifact, or service failure is inconclusive product
evidence. Because this condition intentionally uses the BEAM-native all-module
selector, it earns no pinned-GEPA parity or matched-upstream claim.

**Recommendation: RUN after live preflight.** The frozen ordinary entry is
`examples/deployment/hotpotqa_gepa.exs`; provider-disabled execution completed
the complete public Experiment/GEPA/Result/Artifact/fresh-ProgramServer
lifecycle. No benchmark module, scorer bridge, coordinator, manifest, ledger,
dashboard, or new result schema is involved.

### Zero-call live stop and reusable input-envelope repair

The first authorized live attempt stopped during seed `2026080101` before any
provider transport or scientific outcome. `max_input_tokens` had been passed
as if it were a ReqLLM generation option; ReqLLM 1.17.1 rejected it locally.
OpenRouter account usage was unchanged at `$21.345753735`, seeds 2/3 never
started, and no Result or Artifact existed. The immutable private log SHA-256
is `b84182441d5d4b3dd922a604cb0e74ccbc192535e0d225b19c2062c91bf86a45`.

The owning repair adds an Imp-owned `input_envelope` at the public ReqLLM
client boundary. It validates a positive byte guard plus optional token
reservation at construction, measures rendered message content before cache or
transport, raises typed `OperationalSafetyError(kind: :budget)` when exceeded,
and removes the option before ReqLLM parsing/provider translation. Saved
ReqLLM programs round-trip the strict allowlisted shape. No-envelope callers
retain their prior behavior.

The provider-disabled HotPot entry now uses the actual ReqLLM parser and Req
adapter for task, reflection, and fresh-service calls rather than `Imp.LM.Static`.
Its full deterministic execution again changed all four predictors, used 32
metric examples and 8 reflections, selected/wrote/read/applied the Artifact,
and passed fresh concurrent service. This exonerates the repaired wrapper and
preserves the frozen opportunity. A fresh from-scratch successor is
scientifically valid because the stopped attempt made zero transports and no
selection/test observation, but it still requires separate launch disposition;
the repair does not authorize a relaunch.
