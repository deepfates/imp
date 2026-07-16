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
protocol -> run envelope -> candidate eligibility -> lane validator
         -> explicit immutable admission -> typed evidence facts
         -> claim requirements -> computed evidence state -> profile gate
```

Candidate eligibility reports source compatibility, recency when relevant,
environment compatibility, and rejection reasons. Admission is a separate,
durable operation: it verifies exact bytes, the declared pure protocol
validator, feature ownership, and evidence tier before installing an immutable
content-addressed artifact. Historical admitted evidence does not become
unadmitted when the current checkout or clock changes.

Filesystem mtime is never scientific provenance. It may only break ties between
otherwise valid disposable candidates. A newer malformed or ineligible run must
not mask an older eligible candidate, and neither candidate automatically
becomes admitted evidence.

Scratch runs belong outside admitted evidence and must never change a dashboard
merely because `tmp/` was cleaned. Accepted artifacts are immutable and bound
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

`benchmarks/results/` contains tracked pre-cutover records only. New writers,
dashboard defaults, and operator commands must use `runs/` or `checkpoints/`;
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
