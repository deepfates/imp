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

## Convergence Standard

The release process exists to help finish the product. It must not become a
second product.

1. **Exercise the feature at its public boundary.** For a library feature, the
   strongest normal test installs or calls the public API and inspects its
   observable result. Private construction, module identity, and call graphs
   are diagnostics, not substitutes for that test.
2. **Keep one owner for each fact.** Git owns source identity, lockfiles own
   resolved dependencies, the claim ledger owns declared claims, `tk` owns
   unfinished work, and an experiment artifact owns its frozen inputs and
   result. A generated view may project those facts but must not become another
   editable registry.
3. **Separate product, compatibility, research, and external smoke checks.**
   Product tests cover ordinary use. Compatibility fixtures compare observable
   behavior with a coherent upstream environment. Research artifacts answer a
   frozen scientific question. Rare live checks prove the external boundary.
   Passing one category never stands in for another.
4. **Prefer reusable data-driven checks.** A new optimizer or task should add a
   fixture to a shared runner when possible. Do not copy a coordinator,
   bootstrap, result schema, or admission path for each treatment.
5. **Record minimal sufficient provenance.** A repository commit, dependency
   lock or upstream commit, data split digest, experiment configuration, and
   raw result normally suffice. Add finer-grained hashes only when Git or the
   lock cannot identify the semantic input.
6. **Delete superseded active machinery.** Historical results stay immutable,
   but their runners do not remain release architecture merely because the run
   once existed. New evidence infrastructure must retire more complexity than
   it adds.

### Release finish line

A candidate is coherent when a clean consumer can:

- install Imp and define a realistic multi-stage program;
- evaluate it and run the advertised supported optimizers through consistent
  public concepts;
- obtain an honestly selected result on data excluded from selection;
- write the selected parameter artifact, restart, load it, and reproduce the
  served behavior;
- cancel work and observe provider, parsing, metric, budget, and operational
  failures without leaked processes or credentials; and
- follow the same path in the canonical tutorial and API documentation.

Each advertised optimizer must be labeled **supported and proven**,
**supported with limited effectiveness evidence**, or **experimental** from
actual public behavior. Counts, maturity rungs, package gates, and comparator
receipts inform that judgment; none can replace it.

## Candidate Gates

Current `main` contains breaking changes after `0.2.1` while `mix.exs` still
uses `0.2.1` as development metadata. Until the owner chooses the next public
SemVer, an internal candidate is identified only by all three of:

- an exact clean Git commit;
- the SHA-256 of the unpacked/built Hex artifact produced from that commit;
- passing candidate gates from that same commit.

Do not call such a build a `0.2.1` release candidate, and do not change the
package version merely to make the gates green. A public version choice and
publication remain separate owner actions.

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
its declared evidence. It never means complete DSPy or paper parity, and it is
not sufficient by itself for product release: the finish line above must also
work through the ordinary consumer path.

## Publication

1. Freeze the exact verified commit and require a clean worktree.
2. Promote that commit to the default branch.
3. Verify that a branch-unspecified fresh clone identifies `:imp` and `Imp`.
4. Build the package from the promoted commit and rerun the clean consumer.
5. After the owner chooses the public SemVer, update release metadata coherently,
   tag that exact version, and publish through the owner-approved distribution
   channel.
6. Replace mutable Git installation instructions with the immutable tag or
   package coordinate.
7. Generate the final dashboard from the tagged source and attach its digest
   to the release record; do not commit it as timeless status.

If any exact-candidate gate fails, the candidate is not ready. Narrow the claim
only when the product decision genuinely changes, never to obtain a green bit.

## Research Completion

`mix benchmark.dashboard.telos.ready` evaluates the cumulative research
profile retained for compatibility with existing artifacts. Its C0-C5 terms
grade narrow claims; they are not product phases, priorities, or a mandate to
run every possible benchmark. C1 conformance should precede effectiveness
spend; C3 uses held-out data; C4 requires exact public authority; C5 requires
powered paired evidence. Unavailable exact authority narrows the research
claim and does not block a separately named useful product demonstration.

All unfinished work and dependencies live in `tk`. Markdown must not carry a
parallel roadmap or progress table.
