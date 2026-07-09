# Public Claim Inventory

`benchmarks/claims.json` is the machine-readable inventory of public DSEx
release claims. The benchmark dashboard evaluates that file alongside the
evidence lanes and adds a `public_claims` release-gate check.

The rule is simple: if a claim is release-blocking, the dashboard must be able
to trace it to fresh passing evidence before `mix benchmark.dashboard.full`
passes. Claims that are true only for a narrower path must say so in the claim
statement and in the linked docs.

## Shape

Each claim has:

- `id`: stable claim identifier.
- `statement`: the human-readable public claim.
- `category`: package, docs, parity, optimizer, performance, operations, or a
  similarly concrete release area.
- `surface`: the APIs or user stories covered by the claim.
- `claim_type`: feature completeness, conformance, live-provider proof,
  functional effectiveness, or performance.
- `comparison`: `dspy`, `dsex_native`, or a narrower comparison target.
- `release_blocking`: whether this claim blocks `benchmark.dashboard.full`.
- `sources`: docs, tests, fixtures, or papers that explain the claim.
- `requirements`: evidence rows the dashboard can evaluate.

Requirements currently point at dashboard lanes and name the required evidence
level:

```json
{
  "id": "live_matched_model.full",
  "kind": "live_parity",
  "lane": "live_matched_model",
  "evidence": "full",
  "threshold": "required live lanes satisfy their policies"
}
```

`"evidence": "full"` requires the lane to report `full_evidence: true`.
`"evidence": "passing"` is reserved for claims whose wording only promises
passing smoke or wiring evidence.

## Operating Loop

Run the dashboard before making release claims:

```sh
mix benchmark.dashboard
mix benchmark.dashboard.full
```

When `benchmark.dashboard.full` fails, the terminal error names both the
blocking lane requirements and the blocked public claims. That failure is the
work queue: either produce the missing evidence, narrow or remove the claim, or
mark a genuinely impossible external dependency as unavailable in the relevant
evidence artifact.

Do not add a marketing or README claim without adding or updating a row in
`benchmarks/claims.json`. Do not mark a claim non-blocking merely because the
evidence is inconvenient; use non-blocking claims only for future roadmap
language that is not presented as current product capability.
