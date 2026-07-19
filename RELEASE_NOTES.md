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

## What you are getting

Be precise about what kind of thing this release is, in three layers:

**Proven here, with receipts you can run.** The complete DSPy 3.2.1 surface,
realized natively: the signature DSL, program shapes from `predict` through
ReAct, CodeAct, and a sandboxed recursive controller, evaluation, fifteen
optimizers, retrieval, MCP, streaming, and persistence. "Faithful port" is a
checked claim, not a slogan — and checkable by you. The optimizer and adapter
families carry executable differential tests that run pinned DSPy 3.2.1 and
compare outputs, backed by committed, content-addressed evidence artifacts;
the conformance report tracks all surfaces with per-surface evidence and
dispositions — differential, Elixir-native equivalent, or honest gap. It is
not a blanket "everything matches upstream"; it is a per-surface ledger you
can audit. See [Evidence](docs/EVIDENCE.md) for the C0–C5 ladder this is
graded on and [Conformance](docs/CONFORMANCE.md) for the per-surface table. One complete
effectiveness result ships with its artifact: the
[ticket-routing tutorial](docs/TUTORIAL_TICKET_ROUTING.md)'s router improves
from 25–30% to 85% on held-out data across three committed live runs, for
about a cent, and you can rerun the experiment yourself.

**Borrowed honestly — with the gap named.** The optimization *algorithms'*
effectiveness evidence comes from their published literature (DSPy, MIPROv2,
SIMBA, GEPA) — which verified *those implementations on those tasks*. Imp's
differentials verify that our machinery matches the upstream mechanics; they
do not yet verify that matched machinery reproduces matched outcomes with
live models, and we have not measured that ourselves for most optimizers.
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
tool step. The [deployment example](examples/deployment) is a complete OTP
application.

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

Released from the v0.2.0 tag.
