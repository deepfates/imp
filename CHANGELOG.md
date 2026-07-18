# Changelog

All notable Imp changes will be recorded here. Imp follows Semantic
Versioning once the first public package is released.

## 0.2.0 — 2026-07-17

First Hex release.

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
  semantic-conformance claim in the ledger is now asserted.
- The README is a pyramid: claim, proof, install, the lifecycle in six
  stages, and a stage-by-stage table of the entire facade surface.

### Changed

- Installs from Hex: `{:imp, "~> 0.2.0"}` is the front door; the immutable
  Git tag remains the pinned alternative. Livebooks install from the local
  checkout when run inside the repository and from the Hex release when
  opened standalone.
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
