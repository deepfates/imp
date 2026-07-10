# Upstream Conformance

DSEx tracks upstream fidelity as executable product contracts, not as a list of
names found in source code or documentation. The authoritative ledger lives in
`DSEx.UpstreamFidelity`; the generated, maintainer-readable projection is the
[Executable Upstream Conformance Map](UPSTREAM_SURFACE_MAP.md).

## Baseline Policy

The release baseline is DSPy `3.2.1`, pinned to commit
`29448ae12756abdd14bd8796c819247ebb83673c` (annotated tag object
`27a8e2a134b0b8dbd2d7433ea67ffe9be627d376`). DSEx separately tracks DSPy
`3.3.0b1` at `b2829b7ae3b6e276ac6a8bef66a7ec519dbc923f` so prerelease work such as
the normalized BaseLM runtime, ReActV2, and the GEPA 0.1.1 result contract is
visible without silently changing the stable release target.

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

Paper-derived features also require the canonical reproduction protocol tracked
by `de-c7ui`. Unit tests can establish control-flow and data-contract semantics;
they cannot establish paper-level effectiveness.

## Ledger Contract

Every stable upstream surface belongs to exactly one MECE capability row. Each
row records:

- upstream names and pinned source locations;
- the DSEx modules that own the behavior;
- semantic invariants that an Elixir implementation must preserve;
- executable test, integration, live, or benchmark evidence;
- user-facing documentation;
- one of `conformant`, `elixir_native_equivalent`, or `gap`;
- a rationale for every Elixir-native equivalent;
- an open owner ticket for every gap.

`tracking` is reserved for prerelease upstream behavior and is not release
blocking until that behavior becomes stable or DSEx publicly adopts it.

A missing evidence file, missing DSEx module, unowned gap, or unexplained native
equivalent becomes `invalid_evidence`. Neither `gap` nor `invalid_evidence` can
pass the release gate. Symbol presence, prose, fixtures, and smoke artifacts do
not independently establish conformance.

## Commands

Generate JSON without asserting completion:

```sh
mix dsex.upstream_fidelity \
  --out tmp/upstream-fidelity/upstream-fidelity.json
```

Regenerate the checked-in readable projection:

```sh
mix dsex.upstream_fidelity \
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
programming contracts, basic modules, adapters, typed tools, refinement, and
evaluation rows are conformant. ReqLLM/process context and retrieval are
explicit Elixir-native equivalents. Multimodal quality, the ReAct family, RLM
research evidence, every optimizer family, runtime operations, observability,
persistence/deployment, the learning path, and release stewardship remain
blocking gaps.

The gate stays red until those rows are implemented and their evidence is
strong enough to change their disposition. Closing a ticket or adding a module
name does not change status by itself.
