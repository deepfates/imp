# Upstream Conformance

Imp tracks upstream fidelity as executable product contracts, not as a list of
names found in source code or documentation. The authoritative ledger lives in
`Imp.UpstreamFidelity`; the generated, maintainer-readable projection is the
[Executable Upstream Conformance Map](../CONFORMANCE.md).

## Baseline Policy

The declared compatibility baseline is DSPy `3.3.1`, pinned to commit
`638e155cf725236fe5d01b5332394a7bc128881d` (annotated tag object
`753ab03d9ee2919159e7d9e0c9f47f753845a8ff`). The published wheel's 157-file
source tree hashes to
`b9364d08e549a01fb87b37aa41ebca24c4dda58160dda13523fbc83323862c4b`.
The executable ledger also content-binds the 73-page public API inventory.

Historical DSPy `3.2.1`, `3.3.0b1`, and `3.3.0` differentials retain their
original authority; they are evidence about those exact treatments, not the
current baseline. The stable delta includes ReActV2, normalized LM envelopes,
resource loading, MCP and adapter corrections, and experimental Flex code
optimization. Imp implements or gives an explicit BEAM-native disposition for
the stable programming/runtime surface. Flex remains a named experimental
downstream gap: existing Optimize Anything code artifacts do not earn a
Flex-shaped public module without an ordinary sandboxed optimize/reload/serve
user story.

Standalone GEPA is versioned independently. Its current implementation
authority is release `v0.1.4` at
`8b0ce6cd99a234f6b74daf37558a2ac0ce18f975`; the exact `v0.1.1` checkout is
retained only as a historical executable differential.

When DSPy publishes a new stable release, updating the baseline is a reviewed
product change. The ledger must first account for every added, removed, or
changed upstream surface and give each one a semantic contract and owner.

The inventory is completed from pinned source, public documentation, tests,
examples, and release deltas—not from exported symbol names alone. For each
material surface, the audit must answer what a user can accomplish, which
observable invariants define success, and how Imp proves them. The disposition
is either an idiomatic public Imp implementation with an executable
differential, a deliberate BEAM-native alternative with a user-value test, an
explicit downstream/experimental boundary, or an owned missing capability.
Absence cannot be accepted merely because upstream's Python shape is unfamiliar
or inconvenient. Relevant gold data and provider conditions are acquired when
needed to falsify a semantic claim rather than collected as a speculative
corpus.

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

`tracking` is reserved for experimental or research-horizon behavior and is not
release blocking until Imp publicly adopts the corresponding product claim.

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
  --out docs/internal/../CONFORMANCE.md
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
source-faithful GEPA engine, Fast-Slow orchestration boundary, normalized LM
runtime, and learning path have executable product evidence. Their broader
paper-scale, audio, experimental Flex, external CISPO execution, and dominance
claims remain explicitly unmade where evidence is incomplete.
Instruction-optimizer matched campaigns are claim-specific gaps rather than
universal release blockers.

The weight-optimizer row has one narrow local result: a pinned Qwen2.5-0.5B MLX
SFT artifact on the frozen four-intent Banking77 subset improved untouched
40-row accuracy from 0.125 to 0.55 and macro-F1 from 0.0610 to 0.4561, then
reproduced byte-identical ordered predictions/errors after save/load and
fresh-process serving of the exact fused artifact.
Avatar and AvatarOptimizer provide bounded typed-action execution and
feedback-driven instruction optimization. BetterTogether
implements arbitrary named and repeated optimizer sequences, evaluates the
baseline and each successful prefix, selects the best validated prefix with
stable tie handling, returns the latest successful prefix without validation,
and stops on the first failed step.

That result does not imply general Imp or SFT effectiveness, GRPO, production
reliability, BEAM superiority, paid-provider training, or matched
Avatar/AvatarOptimizer/BetterTogether parity. Those remain explicit
claim-specific gaps until their own evidence exists.

The bounded product gate passed on the previously frozen clean candidate after
its package, persistence, deployment, documentation, and production audits. It
is a retained predecessor result, not a verdict that the current release
objective or latest-stable migration is complete. Claim-specific rows stay red
for their narrower claims without being converted into blanket package
failures. Closing a ticket or adding a module name does not change status by
itself.
