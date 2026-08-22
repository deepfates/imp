---
id: imp-0du1
status: in_progress
deps: []
links: []
created: 2026-08-21T04:50:53Z
type: feature
priority: 1
assignee: deepfates
parent: imp-yme4
tags: [dspy, parity, upstream]
---
# Audit and implement the current stable DSPy semantic delta

Imp's existing conformance baseline predates current stable DSPy. Classify the current public DSPy documentation and exported code by observable user semantics, then implement or explicitly bound material gaps in the shared program/evaluate/optimize/deploy loop. Prioritize central semantics over Python mechanics and over downstream experimental breadth.

## Acceptance Criteria

A source-pinned current-stable inventory covers LM/configuration, signatures/adapters, Predict and composed Module behavior, tools/ReAct, evaluation, prompt optimizers, save/load, async/streaming/cache/usage, and production entry points; every material difference has an executable differential or an explicit intentional BEAM disposition; central supported paths are implemented and exercised through Imp's public API; experimental code/weight optimization is classified downstream and cannot substitute for prompt-program parity.


## Notes

**2026-08-22T13:39:54Z**

The owner ratified this as the first source-grounded dependency of the larger release objective on 2026-08-22. The current released target is DSPy 3.3.1 at peeled tag commit 638e155cf725236fe5d01b5332394a7bc128881d; 3.3.0 is now a predecessor, not the completion target. Complete the material stable inventory from the exact pinned source, docs, tests, examples, and release delta. Treat symbol presence as insufficient: every material user capability needs an executable semantic differential, a tested BEAM-native alternative, an explicit downstream/experimental disposition, or an owned implementation gap. Inspect current main for important fixes and impending concepts, but do not silently turn unreleased churn into a stable compatibility requirement.

**2026-08-22T15:37:49Z**

2026-08-22 exact-source audit against DSPy 3.3.1 commit 638e155c found the current evidence authority stale: setup_reference_test_env.sh and verify_dspy_current_target.py still require 3.3.0b1, while upstream_fidelity still treats 3.2.1/beta as current. Dependency order from primary code/tests: (1) repin/provision exact 3.3.1 authority; (2) implement shared missing-output defaults across Chat, JSON, XML, and ReActV2 submit; (3) replace old regex/top-level XML behavior with 3.3.1 nested XML semantics; (4) add MCP text/structured result normalization preserving explicit null/false/0/empty values and error-before-conversion; (5) rerun exact-stable differentials over otherwise-strong ReActV2/RLM/evaluation/GEPA/MIPRO/save-load/cache/usage/streaming; (6) prove resource-loading cannot be triggered by parsed/model data; (7) own experimental Flex/typed-LM/SandboxSerializable dispositions separately. Provider-free audit ran 99 focused tests, all passing; those prove current mechanisms, not the accepted stable target.

**2026-08-22T15:43:00Z**

Current-authority cutover progress: published DSPy 3.3.1 wheel independently materialized as 157 files with tree digest b9364d08e549a01fb87b37aa41ebca24c4dda58160dda13523fbc83323862c4b; tag 3.3.1 peels to accepted commit 638e155c. Repinned setup/current-target verifier and lock. Clean lock install initially falsified because DSPy 3.3.1 requires gepa[dspy]==0.1.4 while the old lock forced 0.1.1; corrected lock and GEPA checkout pin to v0.1.4 commit 8b0ce6cd. Disposable pip resolution then succeeded with DSPy 3.3.1. Full setup_reference_test_env remains environment-stopped before venv execution: the only discovered Deno is 2.3.6, but the already-declared RLM contract requires exact 2.8.3. This is an environment prerequisite, not a semantic pass/fail. Historical beta artifacts/configs remain unchanged; current differential scripts/tests still need deliberate migration.

**2026-08-22T15:52:56Z**

Implemented the first DSPy 3.3.1 semantic delta from exact commit 638e155c: one shared adapter completion pass now preserves present values by key presence, fills declared output defaults, inserts nil for omitted nullable/optional outputs, and leaves required omissions loud across Chat, JSON, and XML. Structured top-level optional: true is now honored; JSON Schema marks nullable properties with an explicit null union and excludes defaulted fields from required. ReActV2 deliberately does not apply adapter fallbacks: its submit schema now requires every output and execution validates/coerces all present values. BEAM disposition for Python default_factory: immutable literal defaults such as []/%{} provide fresh-value safety without persisting executable callbacks. Exact focused suite: 145 tests, 0 failures, including JSON roundtrip and all three adapters. Remaining 3.3.1 dependency: recursive XML semantics, then MCP result normalization and broader exact differentials.

**2026-08-22T16:15:05Z**

Implemented the second DSPy 3.3.1 adapter delta from exact source/tests: XML now uses Saxy instead of regex extraction; recursively renders/parses typed objects, lists of objects, repeated dictionary values, empty collections, nullable/defaulted fields, and structured unions; accepts legacy JSON inside the outer tag; escapes scalar closing tags; and rejects malformed XML, declarations, doctypes, and entities before parsing. Added portable map-schema :union/:any_of validation and JSON Schema export because union behavior belongs to the signature contract, not an XML special case. Focused adapter/schema/stream/persistence suite is green (145 tests in the broad focused command; exact XML tranche 136 tests). New runtime dependency saxy 1.6.1 is MIT and Hex audit reports no retired packages. Still open: package clean-room after clean commit, MCP normalization, and full exact-stable differential inventory.

**2026-08-22T16:34:00Z**

Implemented DSPy 3.3.1 MCP CallToolResult semantics from exact `dspy/utils/mcp.py` and `tests/utils/test_mcp.py`: HTTP, stdio, and Streamable HTTP clients now accept `result_mode: :text | :structured` (default text); structured mode preserves an explicitly present nil/false/0/empty value and falls back only on key absence; text mode returns one text block as a scalar, multiple as a list, and non-text blocks only when no text exists; MCP `isError` is converted to a tool error before result conversion. A narrow compatibility lane preserves legacy bare application values that are not CallToolResult envelopes. Focused MCP transport/import/recovery suite: 27 tests, 0 failures, 2 protocol-tagged exclusions. Remaining current-stable work is the broader exact differential inventory and explicit resource-loading/experimental dispositions; the package clean-room must be rerun because the earlier detached process lost its terminal verdict after completing dependency resolution and the provider-free tutorial.

**2026-08-22T16:39:00Z**

Clean packaged-consumer rerun at exact commit `d2ba314e` completed successfully with `--skip-release`: the built 0.3.0 tarball resolved and compiled Saxy plus all declared dependencies in isolated consumers; the provider-free tutorial improved 25% to 100%; separate writer and loader VMs passed; tamper rejection passed; and the final clean-room package proof exited 0 at `tmp/xml-mcp-clean-consumer`. This exercises the distributed dependency and ordinary Artifact lifecycle, not the still-open full current-stable inventory or an OTP release build.

**2026-08-22T16:47:00Z**

The exact reference environment is now runnable rather than merely specified. The repository already contained Deno 2.8.3 at `tmp/deno-2.8.3/deno`; placing it on PATH advanced setup and exposed that `setup_reference_test_env.sh` tried to fetch GEPA v0.1.4 commit `8b0ce6cd` from the distinct `gepa-ai/gepa-artifact` paper repository. The script now checks out released library source from `gepa-ai/gepa` into separate `tmp/gepa-current`, preserving the paper artifact authority. Clean setup then completed exact DSPy 3.3.1, GEPA 0.1.4, and Deno 2.8.3. The first exact RLM contract run correctly turned red because two sidecars still called the removed `max_iterations`/constructor `interpreter` API; migrated them to `max_iters` and DSPy 3.3.1's caller-owned interpreter call boundary. `mix benchmark.rlm.contract.check` now exits 0 (3 target-verifier tests, 16 campaign tests, real RLM budget-wrapper integration, and Imp T1 contract), and the two-row DSPy RLM smoke is 6/6 across direct, retrieval, and RLM arms. This is provider-free semantic/runtime evidence, not natural-model effectiveness.
