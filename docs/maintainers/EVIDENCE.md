# Imp Evidence Handbook

This is the maintainer operating model for authorities, protocols, and retained
scientific or compatibility artifacts.

## Authority Order

1. Code, tests, and public documentation own ordinary product behavior.
2. `benchmarks/authorities.json` pins external reference behavior.
3. `benchmarks/reproductions.json` indexes executable protocols and artifact
   validators. It is an index, not proof.
4. Validated immutable artifacts provide evidence facts.
5. `benchmarks/claims.json` scopes unusually broad, comparative, or scientific
   statements when a simple behavioral test is insufficient.
6. `tk` records unfinished work, dependencies, and priorities.

No generated dashboard sits above these sources, and no aggregate score decides
whether a release's documented user stories work.

## Evidence Rungs

```text
C0  API exists
C1  Behavioral conformance against a pinned authority
C2  Real operational execution
C3  Held-out effectiveness
C4  Exact paper reproduction
C5  Powered comparative advantage
```

A claim is complete at its declared rung, authority, and scope. Smoke output,
symbol presence, and scripted fixtures cannot authorize effectiveness. A C3
result cannot excuse a C1 semantic mismatch.

## Artifact Lifecycle

```text
question -> protocol -> bounded run -> validator -> retained result
         -> interpretation at the result's exact scope
```

Candidate eligibility reports source compatibility, recency when relevant,
environment compatibility, and rejection reasons. Admission is a separate,
durable operation: it verifies exact bytes, the declared pure protocol
validator, feature ownership, and evidence tier before installing an immutable
content-addressed artifact. Historical admitted evidence does not become
unadmitted when the current checkout or clock changes.

An immutable admitted result does not expire because a clock advances. Reuse it
only after loading the content-addressed selection from the reproduction
registry and running its pure protocol validator. A current product assertion
still needs a current behavioral check when relevant.

Filesystem mtime is never scientific provenance. It may only break ties between
otherwise valid disposable candidates. A newer malformed or ineligible run must
not mask an older eligible candidate, and neither candidate automatically
becomes admitted evidence.

Scratch runs belong outside admitted evidence. Accepted artifacts are immutable and bound
to protocol, authority revisions, source identity, model identity, data,
budgets, and payload digest. Historical pre-cutover artifacts retain their
original bytes and are labeled historical rather than rewritten.

```text
benchmarks/config/              committed protocol inputs
benchmarks/evidence/admitted/  committed content-addressed evidence
benchmarks/evidence/archive/   committed historical and negative evidence
benchmarks/runs/                ignored disposable executions
benchmarks/checkpoints/         ignored resumable state
tmp/                            replaceable build and cache material
```

`benchmarks/results/` contains tracked pre-cutover records only. New writers
and operator commands must use `runs/` or `checkpoints/`;
release evidence moves into `evidence/admitted/` only through explicit
admission.

Admit a validated run explicitly. The command copies its exact bytes to the
content-addressed store and atomically updates the selected feature records:

```console
mix imp.evidence.admit \
  --artifact benchmarks/runs/example.json \
  --protocol protocol_id \
  --tier t2 \
  --features feature_id,second_feature_id
```

Each feature keeps its highest-tier admission as `admitted_evidence`. A valid
lower-tier artifact from another declared protocol is retained under
`supporting_evidence` instead of replacing that primary record. This is
intentional: source-conformance and effectiveness artifacts can support
different claims, and admitting one must neither discard nor inflate the
other. Every primary and supporting record is content-addressed and replayed
through its pure protocol validator.

## Operating Rules

1. Pin authority and protocol before paid execution.
2. Run provider-free semantic and budget preflights first.
3. Reject semantically inert campaigns before scaling spend.
4. Preserve all valid outcomes, including failures and negative results.
5. Keep provider/model changes as separate experimental conditions.
6. Use held-out selection and uncertainty appropriate to the unit of
   independence.
7. Require powered paired evidence for superiority.
8. Do not maintain aggregate red/yellow/green counts. Record the conclusion in
   the owning result, product documentation, or ticket.
9. Keep scientific admission out of normal product architecture. A public
   feature test should remain useful if its implementation is replaced while
   preserving behavior. Source-bound receipts belong to the narrow
   compatibility or research lane that needs them.
10. Provider API keys may be used only with public or explicitly cleared data.
    Every paid run must accept an explicit maximum, retain provider-reported
    cost, and report it to the workshop coordinator. The current workshop
    ceiling is owner policy outside this repository and must not be copied here
    as a timeless dollar amount. Do not transmit bulk private corpora, print or
    persist keys, or treat spend authority as permission to publish results.

Use the protocol's own validator or reproduction command for research evidence.
Use `docs/maintainers/RELEASE.md` for product release checks.
