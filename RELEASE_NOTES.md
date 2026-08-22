# Imp v0.3.0 — internal release candidate notes

Imp is DSPy for the BEAM: declare a language-model task as a typed Elixir
program, then test, measure, improve, and operate it like any other code.
Instead of maintaining prompt strings, you declare signatures — named, typed
inputs and outputs — and programs are ordinary Elixir values you can call,
evaluate against metrics, compile with optimizers, persist as checksummed
artifacts, and run under OTP supervision.

## Install

Not yet published to Hex — `{:imp, "~> 0.3.0"}` becomes the install line
once the package is published (an owner action still pending). Until then,
install from a source checkout:

```elixir
{:imp, path: "path/to/imp"}
```

The product manual, five Livebooks, provider-free tutorial, and deployment
example are bundled for HexDocs. Research evidence and maintainer procedures
remain in the source repository.

This source is an unpublished `0.3.0` internal candidate. It is not tagged and
does not claim a Hex release; the exact candidate is its clean Git commit plus
the SHA-256 of the built package. Public tagging and publication remain explicit
owner actions.

## Breaking changes from 0.2.1

- `Imp.optimize/3`, `/4`, and `/5` return `{:ok, program}` or
  `{:error, reason}`. Use the corresponding `Imp.optimize!` arity to retain the
  previous raising behavior.
- `Imp.Adapters.Types` and its nested structs moved to `Imp.Adapter.Types`.
  Replace the `Imp.Adapters.` prefix with `Imp.Adapter.`.

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
surface. The source repository's
[evidence guide](https://github.com/deepfates/imp/blob/main/docs/EVIDENCE.md)
and [conformance report](https://github.com/deepfates/imp/blob/main/docs/CONFORMANCE.md)
retain those research records separately from the packaged manual.
`Imp.Experiment.check/5` can repeat noisy selection independently from final
test estimation (`repetitions: [selection: n, test: m]`), selects on the
selection mean, preserves strict baseline ties, and persists the per-stage runs
and paired deltas. The original integer repetition form remains the uniform
shorthand.

Several scoped effectiveness results remain reviewable with source-repository
artifacts: the latest [ticket-routing tutorial](docs/TUTORIAL_TICKET_ROUTING.md)
run improves from 30–35% to 95–100% on held-out data across three live repeats,
for about 1.3 cents per repeat. The older retained run recorded 25–30% to 85%;
it remains historical evidence rather than the current tutorial result. On a
separately frozen matched TREC contract, Imp GEPA
improved
its baseline by `+0.4000` and cleared the preregistered noninferiority margin
against pinned DSPy GEPA; MIPROv2 improved its own baseline by `+0.1458`.
The committed compact scored-row inputs let a third party rerun the frozen
scoring and aggregation without publishing the 181 MB private provider traces.
The packaged [TREC case study](docs/CASE_STUDY_TREC.md) gives the exact
source-checkout command, input hashes, and limitations. The rows and research
program remain source-repository evidence rather than Hex runtime contents.
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
and contained failure using a provider-free support workflow. The source
repository separately retains real-model Banking77 research, including an
honest negative GEPA selection and successful fresh-service lifecycle; those
research data, runners, results, and artifacts are deliberately excluded from
the packaged example.

## Since v0.1.0

- Packaged for Hex with the product guides, five Livebooks, provider-free
  tutorial, and deployment example; research and internal audit material stay
  in the repository. Publication to hex.pm is still pending — until
  it happens, install from a source checkout.
- Documentation rebuilt reader-first: new README, Learning Path, tutorial with
  honest artifact-cited numbers, and DSPy-users mapping. The evidence ladder
  remains a repository audit surface rather than part of the packaged manual.
- Evidence campaign: nine new differential artifact families landed; every
  semantic-conformance claim in the ledger is now asserted (was 1 of 4).
  "Asserted" is a maintainer attestation, not a fresh-checkout replay — see
  the source repository's
  [evidence reconciliation](https://github.com/deepfates/imp/blob/main/docs/EVIDENCE.md)
  for what a clean clone can verify from committed evidence alone.
- Streaming promoted to the facade (`Imp.stream/3`, `Imp.collect/3`) with
  provider token streaming and an explicit local fallback. Setting
  `provider_stream: true` is strict: composed programs without a streamable
  predictor return a terminal unsupported-program error instead of replaying a
  completed response as if it were provider output.
- Known optimizer identities in `Imp.Optimizer.Report` retain their atom type
  after a checksummed Artifact write/read/apply cycle; unknown extension
  identifiers remain portable strings.
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

The candidate described by these notes has package version `0.3.0`; its tag and
Hex publication remain pending owner action.
