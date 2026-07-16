# Upstream Conformance

Imp tracks upstream fidelity as executable product contracts, not as a list of
names found in source code or documentation. The authoritative ledger lives in
`Imp.UpstreamFidelity`; the generated, maintainer-readable projection is the
[Executable Upstream Conformance Map](UPSTREAM_SURFACE_MAP.md).

## Baseline Policy

The release baseline is DSPy `3.2.1`, pinned to commit
`29448ae12756abdd14bd8796c819247ebb83673c` (annotated tag object
`27a8e2a134b0b8dbd2d7433ea67ffe9be627d376`). Imp separately tracks DSPy
`3.3.0b1` at `b2829b7ae3b6e276ac6a8bef66a7ec519dbc923f` so prerelease work such as
the normalized BaseLM runtime, ReActV2, and the GEPA 0.1.1 result contract is
visible without silently changing the stable release target.

Standalone GEPA is versioned independently. Its current implementation
authority is release `v0.1.4` at
`8b0ce6cd99a234f6b74daf37558a2ac0ce18f975`; the exact `v0.1.1` checkout is
retained only as a historical executable differential.

When DSPy publishes a new stable release, updating the baseline is a reviewed
product change. The ledger must first account for every added, removed, or
changed upstream surface and give each one a semantic contract and owner.

## Source Lineage

- DSP and DSPy: `arXiv:2212.14024`, `arXiv:2310.03714`, and
  <https://github.com/stanfordnlp/dspy>
- DSPy Assertions: `arXiv:2312.13382`
- MIPROv2: `arXiv:2406.11695`
- GEPA: `arXiv:2507.19457` and <https://github.com/gepa-ai/gepa>
- Recursive Language Models: `arXiv:2512.24601`
- optimize_anything: `arXiv:2605.19633`
- Learning, Fast and Slow: `arXiv:2605.12484v2`

Paper-derived features also require the canonical reproduction protocol tracked
by `de-c7ui`. Unit tests can establish control-flow and data-contract semantics;
they cannot establish paper-level effectiveness.

## Ledger Contract

Every stable upstream surface belongs to exactly one MECE capability row. Each
row records:

- upstream names and pinned source locations;
- the Imp modules that own the behavior;
- semantic invariants that an Elixir implementation must preserve;
- executable test, integration, live, or benchmark evidence;
- user-facing documentation;
- one of `conformant`, `elixir_native_equivalent`, or `gap`;
- a rationale for every Elixir-native equivalent;
- an open owner ticket for every gap.

`tracking` is reserved for prerelease or research-horizon behavior and is not
release blocking until that behavior becomes stable or Imp publicly adopts a
corresponding product claim.

A missing evidence file, missing Imp module, unowned gap, or unexplained native
equivalent becomes `invalid_evidence`. Every gap remains visible and owned, but
only rows marked as product release blockers fail the product gate. A
claim-specific gap instead prohibits the corresponding fidelity, parity, or
effectiveness claim until its evidence passes. Symbol presence, prose, fixtures,
and smoke artifacts do not independently establish conformance.

## Commands

Generate JSON without asserting completion:

```sh
mix imp.upstream_fidelity \
  --out tmp/upstream-fidelity/upstream-fidelity.json
```

Regenerate the checked-in readable projection:

```sh
mix imp.upstream_fidelity \
  --format markdown \
  --out docs/UPSTREAM_SURFACE_MAP.md
```

Run the release-blocking conformance gate:

```sh
mix upstream_fidelity.check
```

That command is expected to fail while any blocking ledger row remains a gap.
Its failure lists stable capability ids, which lead directly to evidence and
owner tickets in the generated map.

## Current Frontier

The generated map is the current source of truth. At this writing, the core
programming contracts, basic modules, adapters, typed tools, refinement,
evaluation, runtime operations, observability, and persistence/deployment rows
are conformant. ReqLLM/process context, retrieval, and the ReAct family are
explicit Elixir-native equivalents. ReAct specifically uses provider-native
function calls, a reserved `submit` tool, and fail-fast tool errors rather than
claiming DSPy's action-field, finish-tool, observation-and-continue semantics.

Multimodal image and native-PDF quality, the BEAM-native RLM controller,
source-faithful GEPA engine, Fast-Slow orchestration, and the learning path have
executable product evidence. Their broader paper-scale, audio, external CISPO,
and dominance claims remain explicitly unmade where evidence is incomplete.
Instruction-optimizer matched campaigns are claim-specific gaps rather than
universal release blockers.

The weight-optimizer row is conformant after the canonical MLX-LM campaign
proved exact base/adapter identity, real LoRA training, held-out lift from 0.15
to 0.85 accuracy, official fusion, and save/load-equivalent fused output.
Avatar and AvatarOptimizer provide bounded typed-action execution and
feedback-driven instruction optimization. BetterTogether
implements arbitrary named and repeated optimizer sequences, evaluates the
baseline and each successful prefix, selects the best validated prefix with
stable tie handling, returns the latest successful prefix without validation,
and stops on the first failed step.

That disposition does not imply paid-provider training, GRPO effectiveness, or
matched Avatar/AvatarOptimizer/BetterTogether parity. Those remain explicit
claim-specific gaps until their campaigns pass.

The product gate is conformant after the clean-checkout package, persistence,
deployment, documentation, and production audits passed.
Claim-specific rows stay red for their narrower claims without falsely making
the whole package unshippable. Closing a ticket or adding a module name does not
change status by itself.
