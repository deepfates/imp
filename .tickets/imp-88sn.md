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
