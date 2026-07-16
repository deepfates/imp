# Imp Release Procedure

This is the sole human release procedure for Imp. Executable gate definitions
live in `mix.exs` and their Mix task modules. Public claim scope and proof
obligations live in `benchmarks/claims.json`. The generated dashboard reports
current evidence; this document does not maintain a status snapshot.

## Product Standard

An Imp product release is a coherent BEAM-native programming system, not a
Python compatibility layer. Its declared product surface must install from an
immutable artifact, execute through public APIs, preserve typed program and
runtime contracts, avoid persisting credentials, survive save/load and BEAM
boundaries, expose operational failures, and teach the same path in its docs.

Product readiness and research completion are separate profiles. Publishing
the product does not authorize a comparative or paper claim. A red telos claim
blocks telos completion but does not falsify a narrower proven product claim.

## Candidate Gates

Run from a clean candidate commit:

```sh
scripts/setup_reference_test_env.sh
mix production.check
mix integration.check
mix protocol.check
mix package.check
mix livebook.execute.check
mix quality.check
```

Load the ignored local environment and run the candidate-bound live provider
gate:

```sh
set -a
. ./.env
set +a
LIVE_PROVIDER=1 mix live.check
```

Capture source-bound evidence and evaluate the product profile:

```sh
mix gate.package.evidence
mix gate.livebook.evidence
mix gate.protocol.evidence
mix gate.live_provider.evidence
mix benchmark.dashboard
mix benchmark.dashboard.ready
```

`profile_ready: true` means every blocking claim in the selected profile has
its declared evidence. It never means complete DSPy or paper parity.

## Publication

1. Freeze the exact verified commit and require a clean worktree.
2. Promote that commit to the default branch.
3. Verify that a branch-unspecified fresh clone identifies `:imp` and `Imp`.
4. Build the package from the promoted commit and rerun the clean consumer.
5. Tag `v0.1.0` and publish through the owner-approved distribution channel.
6. Replace mutable Git installation instructions with the immutable tag or
   package coordinate.
7. Generate the final dashboard from the tagged source and attach its digest
   to the release record; do not commit it as timeless status.

If any exact-candidate gate fails, the candidate is not ready. Narrow the claim
only when the product decision genuinely changes, never to obtain a green bit.

## Telos Completion

`mix benchmark.dashboard.telos.ready` evaluates the cumulative research
profile. Each accepted capability has a C0-C5 target in
`benchmarks/claims.json`. C1 conformance precedes effectiveness spend; C3 uses
held-out portfolios; C4 requires exact public authority; C5 requires powered
paired evidence. Unavailable exact authority remains an explicit C4 boundary
and does not prevent a separately named adapted C3 protocol.

All unfinished work and dependencies live in `tk`. Markdown must not carry a
parallel roadmap or progress table.
