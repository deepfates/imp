# Imp Evidence Handbook

This is the maintainer operating model for claims, authorities, protocols,
artifacts, and generated status.

## Authority Order

1. `benchmarks/claims.json` declares claim scope, target rung, and proof
   obligations.
2. `benchmarks/authorities.json` pins the strongest reference behavior.
3. `benchmarks/reproductions.json` declares executable protocols and artifact
   validators. It is an index, not proof.
4. Validated immutable artifacts provide evidence facts.
5. `mix benchmark.dashboard` computes evidence state and profile readiness.
6. `tk` owns unfinished work, dependencies, and priorities.

Documentation explains contracts and methods. It never overrides these
sources or caches current red/yellow/green state.

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
protocol -> run envelope -> lane validator -> typed evidence facts
         -> claim requirements -> computed evidence state -> profile gate
```

Admission reports independent dimensions: integrity, source compatibility,
recency when relevant, environment compatibility, evidence tier, and rejection
reasons. Filesystem mtime is not scientific provenance. A newer malformed or
rejected artifact must not mask an older admissible artifact.

Scratch runs belong outside admitted evidence and must never change a dashboard
merely because `tmp/` was cleaned. Accepted artifacts are immutable and bound
to protocol, authority revisions, source identity, model identity, data,
budgets, and payload digest. Historical pre-cutover artifacts retain their
original bytes and are labeled historical rather than rewritten.

## Operating Rules

1. Pin authority and protocol before paid execution.
2. Run provider-free semantic and budget preflights first.
3. Reject semantically inert campaigns before scaling spend.
4. Preserve all valid outcomes, including failures and negative results.
5. Keep provider/model changes as separate experimental conditions.
6. Use held-out selection and uncertainty appropriate to the unit of
   independence.
7. Require powered paired evidence for superiority.
8. Generate status; never hand-edit it into a registry or Markdown table.

Use `mix evidence.check` to validate registries and generated projections. Use
the profile commands in `docs/maintainers/RELEASE.md` to evaluate product or
telos readiness.
