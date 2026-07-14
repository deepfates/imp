# Imp v0.1 Release Ledger

This document records the proven product contract and the stronger claims that
remain gated independently. A red research or parity claim prohibits that
claim; it does not make the honestly scoped product unshippable.

All Mix gate commands and evidence paths in this ledger are for maintainers
working from an Imp source checkout. Package consumers use the public API and
do not receive repository-only release or benchmark tasks.

The release-candidate gate is rerun from the exact candidate commit before an
owner-authorized identity cutover. Historical artifacts remain evidence for
their narrow claims, not substitutes for the current deterministic gate.

## Last-Known v0.1 Baseline

| Claim | Scope | Evidence |
| --- | --- | --- |
| Installable package | The exact built Hex artifact compiles in a clean Mix consumer, round-trips portable programs across separate BEAM VMs, rejects tampering, and assembles a probed deployment release. | `mix package.check`; package and deployment contract tests. |
| Core programming model | Typed signatures, Predict, structured adapters, examples, metrics, evaluation, agents, RLM, and canonical optimizers execute through public APIs. | `mix production.check`; public-surface and lifecycle tests. |
| Provider boundary | ReqLLM-backed calls, structured output, streaming, tools, orchestration, and provider errors use explicit credentials and normalized results. | `LIVE_PROVIDER=1 mix live.check`: 9 tests, 0 failures. |
| Portable supported programs | Predict, ChainOfThought, ProgramOfThought, and memory-backed RAG save without secrets, load, accept an explicit `Imp.with_lm/2` rebind, and execute. | Persistence tests plus the clean-room package workflow. |
| Local service boundaries | Local HTTP, MCP, retriever, and provider-compatible training protocols execute through injectable boundaries. | `mix integration.check`; `mix protocol.check`. |
| Documentation artifact | Shipped Livebooks validate and ExDoc builds from the release source. | `mix production.check`: 5 Livebooks passed and docs generated. |
| Quality baseline | Release sources compile without warnings, configured Credo checks pass, and dependencies have no known retired/security advisories. | `mix production.check`; `mix quality.check`. |

These claims establish an Elixir-native product contract. They do not claim
that every implementation is behaviorally identical to Python DSPy.

## Claim-Specific Gaps

The following work remains valuable, tracked, and red for its corresponding
claim. It is not part of the scoped product release gate:

The following completion claims remain active until their dedicated evidence
gates pass:

- full or comprehensive DSPy parity;
- faithful MIPROv2, SIMBA, or GEPA algorithm/result parity;
- full six-family GEPA paper replication;
- paper-scale RLM effectiveness or long-context parity;
- Imp performance superiority over DSPy;
- broad multimodal and audio reasoning quality beyond the admitted image/PDF lane;
- a real paid training lifecycle including trained-model rebinding;
- ReActV2 parity and complete live CodeAct equivalence;

The GEPA item is explicitly red under the current evidence contract when rows
only repeat configured metric-call budgets or choose a best seed from test
scores. Full/source-fidelity evidence requires observed runtime counts, affirmed
limit enforcement, concrete counter provenance, and predeclared, dev-selected,
or aggregate seed reporting that never uses test scores for selection. Such
artifacts can still be retained as smoke or operator evidence, but cannot close
the parity claim.

`benchmarks/claims.json` remains the authority for claim scope.
`mix benchmark.dashboard.full` is the v0.1 profile gate, while
`mix benchmark.dashboard.telos.full` is the explicit gate for broader telos
research claims. `mix imp.upstream_fidelity --require-conformant` is the
product-conformance gate and passes while only explicitly non-blocking claim
gaps remain.

## Remaining Release Decisions

The candidate is ready for the owner-controlled cutover once the exact-commit
gate passes. Publication then requires:

1. Choose the final package/repository name and update `:app`, package name,
   source links, installation instructions, and namespace policy together.
2. Make the repository public at the chosen release location or document a
   private distribution channel.
3. Apply the atomic identity migration and rerun the proven v0.1 gates from the
   exact renamed candidate commit.
4. Tag `v0.1.0` and replace Git-main installation instructions with the chosen
   published package or pinned Git tag instructions.

These are release-management blockers, not missing runtime implementations.

## Gate Policy

The v0.1 product gate is:

```sh
mix production.check
mix integration.check
mix protocol.check
mix package.check
mix quality.check
LIVE_PROVIDER=1 mix live.check
```

Research and parity gates authorize only the stronger claims they name. They
remain first-class work without silently expanding the v0.1 product contract.
