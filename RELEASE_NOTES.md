# Imp v0.2.1 — release notes

Imp is DSPy for the BEAM: declare a language-model task as a typed Elixir
program, then test, measure, improve, and operate it like any other code.
Instead of maintaining prompt strings, you declare signatures — named, typed
inputs and outputs — and programs are ordinary Elixir values you can call,
evaluate against metrics, compile with optimizers, persist as checksummed
artifacts, and run under OTP supervision.

## Install

Not yet published to Hex — `{:imp, "~> 0.2.0"}` becomes the install line
once the package is published (an owner action still pending). Until then,
install from a source checkout:

```elixir
{:imp, path: "path/to/imp"}
```

Documentation ships in the repository under `docs/` and will land on
hexdocs.pm with the Hex release.

The `v0.2.1` tag is the last named 0.2.x source candidate. Current `main`
contains additional unreleased changes, including the breaking changes listed
under `Unreleased` in `CHANGELOG.md`; it must not be published as a 0.2.x patch
without an explicit version disposition. Package checks on `main` establish
artifact and consumer integrity, not a release-version decision.

## What you are getting

Be precise about what kind of thing this release is, in three layers:

**Proven here, with receipts you can run.** A broad substantive DSPy 3.2.1
surface, realized natively: the signature DSL, program shapes from `predict`
through ReAct, CodeAct, and a sandboxed recursive controller, evaluation,
optimizers, retrieval, MCP, streaming, and persistence. Fidelity is a checked
per-surface claim, not a blanket promise that everything matches upstream. The
optimizer and adapter families carry executable differential tests that run
pinned DSPy 3.2.1 and compare their declared observations, backed by committed,
content-addressed evidence artifacts. The conformance report records a
differential, an Elixir-native equivalent, or an honest gap for each tracked
surface. See [Evidence](docs/EVIDENCE.md) for the C0–C5 ladder this is graded on
and [Conformance](docs/CONFORMANCE.md) for the per-surface table. Several scoped
effectiveness results ship with artifacts: the
[ticket-routing tutorial](docs/TUTORIAL_TICKET_ROUTING.md)'s router improves
from 25–30% to 85% on held-out data across three committed live runs, for
about a cent. On a separately frozen matched TREC contract, Imp GEPA improved
its baseline by `+0.4000` and cleared the preregistered noninferiority margin
against pinned DSPy GEPA; MIPROv2 improved its own baseline by `+0.1458`.
Neither result is a general optimizer-effectiveness claim.

**Borrowed honestly — with the gap named.** The optimization *algorithms'*
effectiveness evidence comes from their published literature (DSPy, MIPROv2,
SIMBA, GEPA) — which verified *those implementations on those tasks*. Imp's
differentials verify their named mechanics; they do not establish whole-loop
parity. The matched TREC result answers one outcome question, while most
optimizers still lack matched live outcomes.
That transfer question is tracked as open targets in the ledger, not assumed
away. What we can say from our own committed evidence: demonstration-based
compilation produces real held-out lift (the tutorial's result), and whether
any optimizer improves *your* task is a question Imp lets you answer in an
afternoon — signature, metric, held-out split, receipt.

**Promised, explicitly.** Our own matched-control effectiveness science —
multi-seed optimizer studies, paper-scale reproductions, matched-model
Imp-vs-DSPy comparisons — is the open research program, tracked as unasserted
target claims in the same public ledger. We do not assert what we have not
measured, and the ledger is the boundary between the two.

## What the BEAM adds

A model call is one more slow, fallible, concurrent effect: bounded supervised
evaluation fan-out, tools in isolated tasks under their own timeouts, scripted
deterministic testing with `Imp.LM.Static` through the same seams production
uses, compiled programs as checksummed artifacts with no secrets inside,
credentials bound at runtime, and redacted telemetry on every call, retry, and
tool step. The [deployment example](examples/deployment/README.md) is a complete OTP
application.

The packaged
[provider-free ticket router](examples/provider_free_ticket_router/README.md)
is the cold-start product proof: a separate consumer compiles a typed router,
measures a deterministic 25% baseline, attaches four reviewable demonstrations,
and measures 100% after compilation. Its scripted LM proves the package and
program/evaluation/optimizer lifecycle, not real-model effectiveness.

The packaged [OTP deployment example](examples/deployment/README.md) is the
release front door: an unpacked consumer runs a two-stage typed program through
disjoint selection and test splits, optimizer selection, checksummed result and
artifact persistence, fresh-process loading, concurrent serving, hot reload,
and contained failure. Its retained one-seed Banking77 run is deliberately
negative: GEPA's candidate regressed on validation, so the public experiment
boundary retained baseline; the selected artifact then completed untouched
evaluation and fresh-process concurrent service. That is real-model lifecycle
evidence, not GEPA effectiveness evidence.

## Since v0.1.0

- Packaged for Hex, with the full manual in the package (the package ships
  the guides, livebooks, and the deployment example; internal audit material
  stays in the repository). Publication to hex.pm is still pending — until
  it happens, install from a source checkout.
- Documentation rebuilt reader-first: new README, Learning Path, tutorial with
  honest artifact-cited numbers, DSPy-users mapping, and the public evidence
  ladder.
- Evidence campaign: nine new differential artifact families landed; every
  semantic-conformance claim in the ledger is now asserted (was 1 of 4).
  "Asserted" is a maintainer attestation, not a fresh-checkout replay — see
  the reconciliation in [docs/EVIDENCE.md](docs/EVIDENCE.md) for what a
  clean clone can verify from committed evidence alone.
- Streaming promoted to the facade (`Imp.stream/3`, `Imp.collect/3`) with
  provider token streaming and an honest local fallback.
- Two silent-failure bugs found and fixed the same day they were exposed by
  the claims census (batch message mangling; swallowed telemetry), plus
  loud-by-default evaluation timeouts and a threadable teacher timeout for
  `BootstrapFewShot` — that last one found live by our own dogfooding.
- `LabeledFewShot` selection semantics pinned deterministic;
  `Imp.Datasets.split/2` shuffle now seeded.
- CI rebuilt: four parallel gates, deterministic dependency cache.

## Expectations for 0.x

APIs may change before 1.0. Known flaky tests are ticketed and public in the
repository. The evidence ladder is the contract: if a page claims more than
its receipts support, that is a bug — file it.

The `Imp` facade and modules marked `stable` in `priv/public_api.json` are the
compatibility center. Optimizer and advanced modules are explicitly
experimental before 1.0: they are real implementations with public tests, but
their APIs may still converge with upstream semantics. A callable optimizer is
not thereby proven effective; the task-scoped results above are the evidence
boundary.

The last named candidate described by these notes is `v0.2.1`; publication to
Hex has not occurred.
