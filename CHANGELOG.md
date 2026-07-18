# Changelog

All notable Imp changes will be recorded here. Imp follows Semantic
Versioning once the first public package is released.

## 0.2.0 — 2026-07-17

### Added

- Streaming is now part of the `Imp` facade: `Imp.stream/3` returns an
  Enumerable of chunks from one program call, and `Imp.collect/3` joins a
  stream back into a string, returning `{:error, reason}` rather than partial
  output when any chunk fails. With `provider_stream: true` chunks arrive
  from the provider as it generates; otherwise the call runs once and the
  result is chunked locally. `Imp.Streaming.incremental_fields/2` stays as
  the lower-level parser.

### Changed

- The documentation is now a reader-first book: the API guide teaches before
  it specifies, the conformance report against pinned upstream DSPy is a
  first-class user document (`docs/CONFORMANCE.md`), and the prior-art
  lineage is stated in daylight (`docs/PRIOR_ART.md`). Internal fidelity and
  evidence docs moved to `docs/internal/` and out of the package.
- Five internal modules that carried `@moduledoc false` now have short,
  accurate moduledocs marked `Internal.`
- CI caches compiled dependencies keyed on `mix.lock` and the exact
  OTP/Elixir versions, cutting recompile time from every run.

### Fixed

- Batch requests no longer mangle messages silently: the ReqLLM client now
  accepts JSON-round-tripped (string-keyed) messages instead of flattening
  every batch conversation into a single user string that reported success.
- `Imp.subscribe_optimizer_progress/1` now receives real events: optimizer
  candidate evaluations emit `[:imp, :optimizer, :trial]` start/stop spans,
  which were documented as stable but never emitted.

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
