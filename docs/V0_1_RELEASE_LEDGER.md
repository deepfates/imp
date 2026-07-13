# DSEx v0.1 Release Ledger

This document records the currently proven product core and the active gaps on
the path to the DSEx telos. Passing the product-core gates does not complete the
release while fidelity and effectiveness claims remain red.

All Mix gate commands and evidence paths in this ledger are for maintainers
working from a DSEx source checkout. Package consumers use the public API and
do not receive repository-only release or benchmark tasks.

Historical verification: 2026-07-12 at commit
`c6540c707be932cfecf65ef14c57b7d190326eb4`. The current optimizer, RLM,
GEPA, persistence, and evidence changes are not covered by those results. Every
row below is a last-known baseline until the complete gate set is rerun against
the exact release candidate commit.

## Last-Known v0.1 Baseline

| Claim | Scope | Evidence |
| --- | --- | --- |
| Installable package | The unpacked Hex artifact compiles in a clean Mix consumer and exposes the documented facade. | `mix package.check`: 8 tests, 0 failures; package build passed. |
| Core programming model | Typed signatures, Predict, structured adapters, examples, metrics, evaluation, and deterministic optimizers execute through public APIs. | `mix production.check`: 53 doctests, 5 properties, 588 tests, 0 failures. |
| Provider boundary | ReqLLM-backed calls, structured output, streaming, tools, orchestration, and provider errors use explicit credentials and normalized results. | `LIVE_PROVIDER=1 mix live.check`: 9 tests, 0 failures. |
| Portable supported programs | Predict, ChainOfThought, ProgramOfThought, and memory-backed RAG save without secrets, load, accept an explicit `DSEx.with_lm/2` rebind, and execute. | Persistence tests plus the clean-room package workflow. |
| Local service boundaries | Local HTTP, MCP, retriever, and provider-compatible training protocols execute through injectable boundaries. | `mix integration.check`: 9 tests; `mix protocol.check`: 5 tests. |
| Documentation artifact | Shipped Livebooks validate and ExDoc builds from the release source. | `mix production.check`: 5 Livebooks passed and docs generated. |
| Quality baseline | Release sources compile without warnings, configured Credo checks pass, and dependencies have no known retired/security advisories. | `mix production.check`; `mix quality.check`. |

These claims establish an Elixir-native product contract. They do not claim
that every implementation is behaviorally identical to Python DSPy.

## Active Telos Gaps

The APIs below are usable and deterministically tested, but their effectiveness,
fidelity, or external-service behavior remains unfinished and release-blocking:

- advanced optimizers: COPRO, MIPROv2, SIMBA, GEPA, GRPO, BootstrapFinetune,
  BetterTogether, and optimize-anything flows;
- RLM, CodeAct, ProgramOfThought, and agent control loops beyond their local
  safety and data contracts;
- provider-compatible training clients without a paid end-to-end training job;
- multimodal encoding primitives without a live quality claim;
- external retriever and external MCP deployments beyond local protocol proof.

The following completion claims remain active until their dedicated evidence
gates pass:

- full or comprehensive DSPy parity;
- faithful MIPROv2, SIMBA, or GEPA algorithm/result parity;
- full six-family GEPA paper replication;
- paper-scale RLM effectiveness or long-context parity;
- DSEx performance superiority over DSPy;
- live multimodal reasoning quality;
- a real paid training lifecycle including trained-model rebinding;
- ReActV2 parity and complete live CodeAct equivalence;

The GEPA item is explicitly red under the current evidence contract when rows
only repeat configured metric-call budgets or choose a best seed from test
scores. Full/source-fidelity evidence requires observed runtime counts, affirmed
limit enforcement, concrete counter provenance, and predeclared, dev-selected,
or aggregate seed reporting that never uses test scores for selection. Such
artifacts can still be retained as smoke or operator evidence, but cannot close
the parity claim.

`benchmarks/claims.json`, `mix benchmark.dashboard.full`, and
`mix upstream_fidelity.check` remain the authorities for those stronger claims.
They are expected to stay red until the corresponding implementation and
evidence work is complete.

## Remaining Release Decisions

The candidate is not publishable until these repository decisions are closed:

1. Choose the final package/repository name and update `:app`, package name,
   source links, installation instructions, and namespace policy together.
2. Make the repository public at the chosen release location or document a
   private distribution channel.
3. Review and commit the release diff, then rerun the proven v0.1 gates from the
   exact candidate commit.
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

Research and parity gates are required telos evidence. Product-core gates alone
cannot authorize completion.
