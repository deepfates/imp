# Imp Release Procedure

This is the sole human release procedure for Imp. It intentionally calls the
same behavioral checks used during development; it does not create a second
layer of gate receipts or release profiles.

## Product Standard

An Imp product release is a coherent BEAM-native programming system, not a
Python compatibility layer. Its declared product surface must install from an
immutable artifact, execute through public APIs, preserve typed program and
runtime contracts, avoid persisting credentials, survive save/load and BEAM
boundaries, expose operational failures, and teach the same path in its docs.

Publishing the product does not authorize a comparative or paper claim.
Research results retain their own frozen contracts and artifacts.

The `0.3.0` product-completion chain has accounted for the material
current-stable DSPy surface, audited the contemporary Optimize Anything and Ax
concepts that belong in Imp, exercised every advertised product optimizer,
survived realistic composed multi-provider operation, and passed adversarial
cold-consumer completion. Those outcomes close the library-making milestone;
they do not waive the exact-candidate gates below. Publication now requires one
clean immutable candidate whose code, package, documentation, security posture,
and retained claims agree. The full paper-scale benchmark program is not a
prerequisite for this release.

## Convergence Standard

The release process exists to help finish the product. It must not become a
second product.

1. **Exercise the feature at its public boundary.** For a library feature, the
   strongest normal test installs or calls the public API and inspects its
   observable result. Private construction, module identity, and call graphs
   are diagnostics, not substitutes for that test.
2. **Keep one owner for each fact.** Git owns source identity, lockfiles own
   resolved dependencies, `tk` owns unfinished work, and an experiment artifact
   owns its frozen inputs and result. A generated view must not become another
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
- evaluate it and run every advertised optimizer family on a representative
  task through consistent public concepts and its defining mechanism;
- obtain an honestly selected result on data excluded from selection;
- write the selected parameter artifact, restart, load it, and reproduce the
  served behavior;
- compose named predictors and tools across materially different supported
  provider routes, including genuine incremental streaming where promised;
- cancel work and observe provider, parsing, metric, budget, and operational
  failures without leaked processes or credentials; and
- follow the same path in the canonical tutorial and API documentation without
  workshop context, maintainer-only fixtures, or oral guidance.

Each optimizer advertised as a product capability must have a credible
successful user story through its defining mechanism and public API. Failed
treatments remain visible and must drive diagnosis, but do not by themselves
complete a family. An integration may remain explicitly research-only when it
cannot meet that standard; it must not be presented as a finished product
optimizer. Counts, maturity rungs, package gates, and comparator receipts inform
that judgment; none can replace it.

For the present release, the root epic's dependency chain is the work ledger:
stable DSPy and OA/Ax source audits precede optimizer lifecycles; realistic
provider/OTP operation and those lifecycles precede the cold-consumer pass; the
cold-consumer pass precedes bounded live comparison; and only then are the
candidate gates rerun on the exact commit. A green predecessor candidate does
not bypass that order.

## Candidate Gates

Version `0.3.0` is released from the private immutable Git tag `v0.3.0`; it is
not published to Hex. A candidate or private source release is identified by
all three of:

- an exact clean Git commit;
- the SHA-256 of the unpacked/built Hex artifact produced from that commit;
- passing candidate gates from that same commit.

Package version alone is not release identity. Public repository visibility and
Hex publication remain separate owner actions.

Run from a clean candidate commit:

```sh
PYTHON=python3.12 scripts/setup_reference_test_env.sh
mix check
mix integration.check
mix protocol.check
mix package.check
mix livebook.execute.check
mix quality.check
mix dialyzer.check
```

Copy `.env.example` to an ignored `.env`, choose a model, add one provider key,
then run the candidate-bound live provider gate:

```sh
set -a
. ./.env
set +a
LIVE_PROVIDER=1 mix live.check
```

When compatibility with a pinned upstream is part of the release claim, also
provision that reference environment and run `mix differential.check`.
Individual benchmark commands remain available for the scientific questions
they were built to answer, but they are not aggregated into a release score.

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
7. Record the tag, package checksum, and publication destination in the release
   record.

If any exact-candidate gate fails, the candidate is not ready. Narrow the claim
only when the product decision genuinely changes, never to obtain a green bit.

## Research Completion

Research completion is judged from the question, frozen protocol, raw result,
and independently reproducible analysis for that study. It is not inferred
from the release checklist or from a cumulative repository score.

All unfinished work and dependencies live in `tk`. Markdown must not carry a
parallel roadmap or progress table.
