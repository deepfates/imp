# Changelog

All notable Imp changes will be recorded here. Imp follows Semantic
Versioning once the first public package is released.

## Unreleased

The unpublished `0.3.0` candidate continues to receive corrections before its
first public tag. Since the initial release-candidate checkpoint, Artifact
fresh-process portability, finite Experiment error budgets, fixed repeated
outer evaluation with independent selection/test repetition counts, OpenRouter
request/evidence handling, and pinned MIPROv2 minibatch/Optuna fidelity have
been strengthened. Unequal outer repetition counts persist in backward-
compatible Experiment Result schema 4; the existing integer shorthand and
uniform-result schemas remain unchanged. Repository-only benchmark work added
independently recomputable Optimize Anything evidence and provider-free
MuSiQue readiness without adding those research surfaces to the Hex payload.
These changes remain part of the unpublished candidate until an owner-approved
release cut decides otherwise.

Signature fields can now use `type: :code` with explicit `language:` metadata.
Chat, JSON, and XML adapters emit language-aware guidance, render source inputs,
and return fenced or plain outputs as validated typed code values;
the type transports source but does not execute it.

Release hardening also keeps a report's known optimizer identity stable across
an Artifact round-trip, while leaving unknown extension identifiers as strings.
Whole-program `Imp.save!/2,3` now matches parameter and Experiment persistence
by writing through an exclusive, synced, mode-`0600` temporary file before
atomic replacement; demonstrations and other saved program state are no longer
created world-readable under a permissive process umask.
Strict provider streaming now fails with
`{:provider_stream_unsupported, module}` when a composed program exposes no
streamable predictor; local post-call chunking remains available when
`provider_stream: true` is omitted. The packaged guides use the current
`Imp.LM.Static.new/1` API and now include a complete signature type reference.

Programs can now expose described, constrained JSON-safe optimizer components
through paired `Imp.Module` callbacks. Predictor, playbook, ReAct tool, and
custom component values share one digest-guarded atomic application path;
generalized parameter artifacts revalidate them against freshly constructed
trusted code without persisting callbacks or runtime authority. Existing
predictor-only artifacts and GEPA's named instruction candidates remain
compatible. `Imp.ProgramParameters.values/1` and `apply_values/2` let structured
Optimize Anything candidates execute through that same contract, and
`Imp.Optimize.Anything.to_program_artifact/3` exports their selected state for
fresh trusted application.

Addressable `Imp.Run` execution now supports explicit, fail-closed authorization
for validated ReActV2 and RLM tool effects. Durable tool policy and schema
validation run before the per-execution decision; denial is observable to the
program, cancellation remains distinct, and callback failure, timeout, owner
death, or run cancellation cannot execute the effect or leave a decision task
alive. `Imp.Module.execute/3` is optional, shares each program's ordinary loop,
and refuses an authorization-bearing run for modules that do not support the
capability.

The persistent Playbook optimizer now has an ordinary reviewed-challenger
lifecycle. Training weaknesses are exposed as grounded row and trajectory
pairs; promotion requires separate disjoint promotion and audit lift; review
shows the decision, score deltas, usage, and exact identities; and completed
checkpoints have private atomic write/read helpers for verified fresh-runtime
restore. Compilation returns immutable state and never silently hot-promotes a
serving process.

Bounded live acceptance now covers the classical demonstration optimizers and
the instruction/rule family on the shipped support-routing task. Selected
BootstrapFewShot, RandomSearch, KNNFewShot, SignatureOptimizer, and InferRules
states are retained with disjoint evaluation, explicit provider budgets, and
fresh-process application. These are task-scoped product lifecycles, not broad
effectiveness or parity claims.

## 0.3.0 — 2026-07-31

Prepared as an unpublished internal release candidate. The exact candidate is
identified by its clean Git commit and built-package digest; tagging and Hex
publication remain owner actions.

### Added

- `Imp.Optimizer.Artifact` schema 3 now stores either trusted program
  parameters or canonical JSON values. Optimize Anything results export through
  that shared content-verified boundary and load in a fresh process without
  forcing value optimization through the program-shaped Experiment API.
- `Imp.Experiment.check/5` supports fixed repeated outer evaluation with mean
  aggregation. Repeated selection and test observations are persisted in
  backward-compatible Result schema 3; single-pass experiments remain schema 2.
- Pinned MIPROv2 can execute DSPy 3.2.1 program/data/few-shot-aware proposal
  grounding and Optuna 4.9.0 categorical modeled TPE, including durable resume
  across startup and modeled trials.
- `Imp.Experiment.check/5` now powers the packaged two-stage OTP deployment
  workflow end to end: disjoint selection/test evaluation, selected-artifact
  construction, checksummed `Result`/`Artifact` persistence, fresh-process
  loading, concurrent serving, hot reload, and failure containment. The
  packaged workflow is provider-free. Repository-only Banking77 research
  separately retains the honest negative case where GEPA regressed on
  validation, baseline was retained, and the selected artifact still served
  successfully after restart; its runner, data, results, and artifacts are not
  part of the package.
- Experiment evaluation cancellation at `max_errors` now returns redacted,
  structured row evidence with the failed stage, row identity/index, and
  underlying reason instead of collapsing the failure into an opaque optimizer
  error.
- `Imp.Optimizer.SignatureOptimizer` can target one explicitly named predictor
  in a multi-stage program with `predictor:`. Proposal grounding sees the full
  program, only the selected instruction changes, and missing or ambiguous
  targets fail before proposal or evaluation work.
- The packaged OTP deployment reference now includes a complete provider-free
  product workflow: typed declaration, disjoint evaluation, deterministic
  few-shot compilation across a real two-predictor pipeline, parameter
  inspection, checksummed artifact save/load and compatible hot reload, bounded
  concurrent serving, and crash/timeout
  containment. Its planted static-LM lift is labeled as lifecycle evidence,
  not optimizer effectiveness.
- A packaged provider-free ticket-router consumer now demonstrates the complete
  typed program → held-out evaluation → deterministic few-shot compilation
  lifecycle. The Hex clean-room gate copies it outside the package and runs it
  offline against the built artifact; its scripted 25% → 100% result is a
  teaching fixture, not a real-model effectiveness claim.
- `n=` multi-completion on `Imp.Predict.Predict` (DSPy `Predict(n=K)`):
  `config: [n: K]` asks the LM for K completions and fills
  `Imp.Prediction.completions` with all K parsed predictions (the first is
  the primary). Low or unset temperature bumps to 0.7 as upstream does. A
  parse failure on any completion fails the call loudly with the failing
  index, and an LM that ignores `:n` is a loud error. The req_llm client
  refuses `n > 1` explicitly (its canonical response carries only the first
  choice); `Imp.LM.Static` and custom clients support the list contract.
- Per-prediction LM usage ledger (DSPy `track_usage` /
  `Prediction.get_lm_usage()`): with the `:track_usage` setting on,
  predictions carry a per-model merged usage map, read via
  `Imp.Prediction.get_lm_usage/1`. The tracker (`Imp.Usage`) is
  per-process, so parallel runs report per-result usage.
- Per-call LM config on `Imp.Predict.Predict.call/3` (DSPy call-time
  `config={...}` and predicted-outputs `prediction=`): a keyword list merged
  over the program's config for that invocation only, without mutating the
  program; every entry reaches the LM request.

### Changed

- Finite `max_errors` is now an actual diagnostic budget across Experiment
  stages: `0` cancels on the first ordinary row failure, finite `N` retains
  score-zero diagnostics below `N` and cancels on the Nth, and `:infinity`
  retains all ordinary diagnostics. Typed operational-safety failures always
  remain fatal.
- **Breaking:** `Imp.optimize/3`, `/4`, and `/5` now return
  `{:ok, compiled_program}` or `{:error, reason}`, mirroring `Imp.train/4`.
  The old raising behavior lives on unchanged as `Imp.optimize!/3`, `/4`,
  and `/5`. Migration: rename `Imp.optimize(...)` to `Imp.optimize!(...)`
  to keep the exact previous semantics, or match on the tuple.
- **Breaking:** `Imp.Adapters.Types` (and its nested value structs such as
  `Imp.Adapters.Types.Image` and `Imp.Adapters.Types.ToolCall`) is renamed
  to `Imp.Adapter.Types`, folding the stray `adapters/` directory into
  `adapter/`. Migration: replace the `Imp.Adapters.` prefix with
  `Imp.Adapter.`.

### Fixed

- Typed route, cost, budget, transport, and cancellation failures now propagate
  through evaluation, optimizer facades, proposal, composition, and Optimize
  Anything instead of being converted into ordinary low-scoring candidates.
- Fresh-process parameter artifacts keep persisted identifiers as strings and
  resolve them only against the trusted live program vocabulary; loading no
  longer depends on incidental atoms in the writing VM.
- ReqLLM-backed programs expose a validated input byte envelope that is enforced
  before cache or transport and removed before provider option validation.
- Invalid pinned MIPROv2 search combinations fail before Experiment evaluation
  or model work, and nested JSON-safe Example values use recursively faithful
  DSPy/Python representation during proposal grounding.

### Deprecated

- Passing an LM as a `%{module: module, opts: keyword}` map or as a bare
  arity-2 function is deprecated. Both still work and now log one loud
  warning per VM. Use an LM struct (`Imp.LM.Static.new(opts)`,
  `Imp.req_llm/2`) or a plain LM module instead. Support for the
  deprecated shapes will be removed in a future release.

## 0.2.1 — 2026-07-18

### Changed

- The fidelity claim now says what is true. "Every conformance claim is
  differentially verified against pinned upstream" overstated: the
  conformance report tracks all surfaces with per-surface evidence and
  dispositions, and executable differentials against real DSPy 3.2.1 back
  the optimizer and adapter families specifically — not every row. README,
  `IMP_FOR_DSPY_USERS`, `EVIDENCE`, and the release notes now state that
  precisely, and it is a claim a skeptic can run.
- The README points keyless readers at the provider-free Livebooks and
  Learning Path step, so a reader with no API key sees a working path
  instead of an `OPENAI_API_KEY` error on the first example.
- `Imp.Optimizer.BootstrapFewShot` (0.2.0) plus `GRPO` and
  `BootstrapFinetune` now thread a teacher/rollout `timeout` to the
  trajectory runner, so slow environment-backed teachers are no longer
  killed at a fixed 5s with no recourse.

### Fixed

- `Imp.save!`/`Imp.load!` round-trip `config: [json_retries: 1]` and
  `json_fallback` (the README template program) — the keys survived the
  artifact as strings and `Predict.new` rejected them on load.
- GEPA reflection drives live again: the ReqLLM deadline cap no longer
  fabricates a `:connect_options` key that the provider option schema
  rejects.
- The reasoning-model `:max_tokens` → `:max_completion_tokens` rename is
  now a single debug line, pre-normalized so the request on the wire is
  unchanged (proven wire-neutral across models).
- A signature `list[...]` (DSPy's spelling) now suggests `array[...]`
  (Imp's), instead of the nearest scalar.
- Three order-dependent test flakes fixed at their synchronization windows
  without weakening any assertion; a global-settings leak that shifted
  optimizer digests across test modules is reset on exit.

### Internal (repository, not shipped)

- Documentation restructured: the API guide is a cookbook, deep operations
  material moved to `docs/OPERATIONS_REFERENCE.md`, and maintainer gate
  docs to the repository-only
  [maintainer gate reference](https://github.com/deepfates/imp/blob/main/docs/maintainers/GATES.md).
- CI gains an evidence-infrastructure lane, and `production.check` now runs
  `reproduction.check` so an optimizer source change without a matching
  evidence re-capture fails per-PR instead of drifting silently. The three
  differential artifacts made stale by the timeout changes were re-captured
  against real DSPy 3.2.1.

## 0.2.0 — 2026-07-17

Prepared as the first Hex release. Publication to hex.pm has not happened
yet (it remains a pending owner action), so until it does the package
installs from a source checkout, not from Hex.

### Added

- Streaming is now part of the `Imp` facade: `Imp.stream/3` returns an
  Enumerable of chunks from one program call, and `Imp.collect/3` joins a
  stream back into a string, returning `{:error, reason}` rather than partial
  output when any chunk fails. With `provider_stream: true` chunks arrive
  from the provider as it generates; otherwise the call runs once and the
  result is chunked locally. `Imp.Streaming.incremental_fields/2` stays as
  the lower-level parser.
- `Imp.Optimizer.BootstrapFewShot` accepts a `timeout:` option
  (`pos_integer` or `:infinity`, default unchanged at 5000ms) threaded to
  each teacher execution. The runner always enforced a timeout; callers can
  now raise it for slow teachers — agentic and environment-backed teachers
  routinely run for minutes. Found live by dogfooding.
- The source repository's
  [evidence ladder](https://github.com/deepfates/imp/blob/main/docs/EVIDENCE.md)
  defines the C0–C5 rungs every claim in `benchmarks/claims.json` is graded on,
  with the live ledger counts. Nine new differential artifact families landed;
  every semantic-conformance claim in the ledger is now asserted ("asserted"
  is a maintainer attestation — the evidence guide reconciles it against what
  a fresh checkout computes from committed evidence alone).
- The README is a pyramid: claim, proof, install, the lifecycle in six
  stages, and a stage-by-stage table of the entire facade surface.

### Changed

- Packaged so that `{:imp, "~> 0.2.0"}` becomes the front door once the
  package is published to Hex (publication is still pending). Livebooks
  install from the local checkout when run inside the repository; their
  standalone fallback targets the Hex release and works once it is
  published.
- The documentation is now a reader-first book: the API guide teaches before
  it specifies, the conformance report against pinned upstream DSPy remains a
  [repository audit document](https://github.com/deepfates/imp/blob/main/docs/CONFORMANCE.md),
  and the prior-art lineage is stated in daylight (`docs/PRIOR_ART.md`). Internal fidelity and
  evidence audits are repository-only — the package ships no
  `docs/internal/` files; `docs/ADVANCED.md` and `docs/OBSERVABILITY.md`
  are promoted user docs.
- Headline numbers cite committed evidence: the tutorial's optimizer lift is
  25–30% → 85% across three live repeats, from a content-addressed run
  artifact reproducible with one script (replacing an earlier unreproduced
  35% → 90%).
- `Imp.Optimizer.LabeledFewShot` demo selection is pinned deterministic
  (first k, matching pinned upstream), and `Imp.Datasets.split/2` shuffles
  with an explicit seed.
- The conformance report is byte-reproducible by its generator: repository-
  only link annotations are rendered package-aware instead of hand-edited.
- Breaking in 0.3: removed the disconnected `Imp.Agent` and
  `Imp.Agent.Runtime` APIs. The packaged agent story is the react-family
  spectrum (`react`, `react_v2`, `avatar`, `code_act`, `rlm`) plus ordinary
  supervised Elixir around `Imp.call/2` and `Imp.Tool.call/2`. The later
  experimental `Imp.Run` boundary was added only after ACP and executed-agent
  optimization supplied two real consumers; it does not restore a competing
  Agent program model.
- Breaking in 0.3: removed the misleading
  `Imp.Streaming.Messages.StatusMessageProvider` list accumulator. It never
  implemented DSPy's execution-stage provider contract. Use
  `StreamListener.on_status` for stream lifecycle and `:telemetry` handlers for
  causally linked module, LM, and tool progress.
- Five internal modules that carried `@moduledoc false` now have short,
  accurate moduledocs marked `Internal.`
- CI runs four parallel gates over a deterministic dependency cache warmed
  from the lockfile on every run, cutting merge latency to roughly the
  production gate alone.

### Fixed

- Batch requests no longer mangle messages silently: the ReqLLM client now
  accepts JSON-round-tripped (string-keyed) messages instead of flattening
  every batch conversation into a single user string that reported success.
- `Imp.subscribe_optimizer_progress/1` now receives real events: optimizer
  candidate evaluations emit `[:imp, :optimizer, :trial]` start/stop spans,
  which were documented as stable but never emitted.
- `Imp.Evaluate` timeouts are loud: a killed slow row logs a warning naming
  the budget and records an explicit failure score instead of silently
  scoring 0.0 inside search optimizers.
- The package contract gate actually runs in CI, and the two failures it had
  been hiding are fixed.
- Two dashboard runs in the same second can no longer silently overwrite the
  same evidence artifact; output paths are allocated exclusively.
## 0.1.0 — 2026-07-16

First tagged release (Git tag install; not yet published to Hex). The source
tree includes the Elixir-native programming model, provider boundary,
evaluation, optimization, tools, retrieval, persistence, Livebooks, and the
executable upstream-conformance ledger. The ledger remains the authority for
features that are not yet release-complete.

This release uses the Imp identity and repository throughout. It adds a
clean-room package proof, explicit LM rebinding for loaded programs, durable
GEPA seed checkpoints, recursive provider-native structured-output schemas, a
scoped v0.1 claims ledger, and fail-closed matched-provider RAG and tool-use
parity evidence.

Public releases will list user-visible additions, changes, fixes, security
updates, and any migration instructions in this file.
