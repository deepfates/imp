# Changelog

All notable Imp changes will be recorded here. Imp follows Semantic
Versioning once the first public package is released.

## Unreleased

### Changed

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
  docs to `docs/maintainers/GATES.md`.
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
- The evidence ladder is public: `docs/EVIDENCE.md` defines the C0–C5 rungs
  every claim in `benchmarks/claims.json` is graded on, with the live ledger
  counts. Nine new differential artifact families landed; every
  semantic-conformance claim in the ledger is now asserted ("asserted" is a
  maintainer attestation — `docs/EVIDENCE.md` reconciles it against what a
  fresh checkout computes from committed evidence alone).
- The README is a pyramid: claim, proof, install, the lifecycle in six
  stages, and a stage-by-stage table of the entire facade surface.

### Changed

- Packaged so that `{:imp, "~> 0.2.0"}` becomes the front door once the
  package is published to Hex (publication is still pending). Livebooks
  install from the local checkout when run inside the repository; their
  standalone fallback targets the Hex release and works once it is
  published.
- The documentation is now a reader-first book: the API guide teaches before
  it specifies, the conformance report against pinned upstream DSPy is a
  first-class user document (`docs/CONFORMANCE.md`), and the prior-art
  lineage is stated in daylight (`docs/PRIOR_ART.md`). Internal fidelity and
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
- `Imp.Agent` is internal: the packaged agent story is the react-family
  spectrum (`react`, `react_v2`, `avatar`, `code_act`, `rlm`) plus your own
  supervised Elixir around `Imp.Tool.call/2`. The module still ships and
  works, but it is no longer documented public API and may change freely.
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
- Agent event-sink crashes surface instead of disappearing, and missing
  context references are errors.

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
