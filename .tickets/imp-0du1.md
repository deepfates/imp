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

**2026-08-22T17:10:00Z**

Adversarial exact-stable probes falsified three more central behaviors. First, a crafted saved trajectory could decode an `Imp.Adapter.Types.File` carrying a host path and later cause adapter/provider conversion to read that path. Trajectory serialization now rejects deferred file paths in both directions while preserving data-backed files; this closes the demonstrated durable-artifact authority chain, while ordinary resource construction and explicit eager factories remain an open inventory item. Second, a ReqLLM cache hit replayed provider usage metadata, so one miss plus one hit counted tokens twice; hits now return an immutable result envelope marked `cache_hit: true` with empty usage. Third, Imp's ReAct truncation guard dropped a trajectory containing exactly one completed tool call, whereas DSPy 3.3.1 treats it as non-truncatable and retains it for extraction. The boundary is now `<= 4` keys and a public regression proves the lookup observation reaches extraction and final history. These are product defects, not scientific negatives. Formatting, warnings-as-errors, and the combined ReAct/resource/cache slice passed with one property and 105 tests.

**2026-08-22T17:20:00Z**

The exact 3.3.1 probes for portable state, timeout behavior, MIPRO grounded-proposer decisions, and the RLM operational artifact preserve their prior observable contracts; only their stale beta version assertions and RLM live-campaign guard remained. Migrated those current-target lanes to 3.3.1. The historical instruction-optimizer artifact remains pinned to 3.3.0b1 and commit `b2829b7` by design until its source hashes and dispositions are regenerated; it is not being relabeled as current evidence by assertion edits alone.

**2026-08-22T17:50:00Z**

Completed the stable eager-resource boundary from DSPy 3.3.1 rather than merely blocking the demonstrated exploit. Image and Audio now have explicit eager local/HTTP(S) factories with finite timeouts and injected-request tests; File has eager path/bytes factories plus filename and pre-uploaded file-ID semantics. Ordinary typed values and provider formatting perform no host reads. Existing `%File{path: ...}` values fail with migration guidance, while prior safe trajectory wires remain loadable and malicious path wires fail closed. The ReqLLM conversion seam now decodes typed base64 exactly once into the raw bytes ReqLLM expects; the prior path could double-encode in-memory image/file data. Negative probes cover deferred paths, non-HTTP URLs, unbounded timeouts, wrong media types, and no provider invocation. Focused resource/upstream/ReqLLM/persistence coverage passes 130 tests plus one property; docs, five Livebooks, public-surface manifest, operations stress, multimodal serialized transport, evidence-authority generation, and doctests pass. The broad dirty-tree run correctly exposed and repaired two stale consumers: the multimodal runner still constructed a deferred path and operations stress required byte-identical cache-hit metadata; the deployment example lock also lacked Saxy, and both provider-disabled deployment stories now pass independently. A final broad run is reserved for the clean commit because four benchmark tests intentionally reject a dirty candidate. Native typed reasoning and telemetry lineage remain separate open stable gaps.

**2026-08-22T18:05:00Z**

Clean commit `dd961cdf` passed the broad default suite: 53 doctests, 9 properties, 2,833 tests, zero failures, 11 explicit skips, and 170 excluded live/evidence/protocol cases. This closes the eager-resource slice against the ordinary repository surface; it does not establish live multimodal quality or complete the remaining stable inventory. Next dependency is the stable typed native-reasoning contract, followed by BEAM telemetry lineage/inert callback-setting disposition.

**2026-08-22T17:21:53Z**

Implemented the DSPy 3.3.1 explicit native Reasoning contract at commit 1a17a89b. Direct source reread falsified an initial assumption that all ChainOfThought results became typed: stable DSPy still defaults rationale_field_type to str, so Imp preserves the ordinary string default and adds source-faithful rationale_field/rationale_field_type customization. With type :reasoning, LM-registry capability drives removal from the rendered/schema contract, per-call effort overrides configured effort, default is low, nil disables native mode, and returned thinking is restored as an inert typed value. Unsupported LMs use the same typed value through prompt-generated text. Multi-completion metadata remains paired per result; absent promised thinking fails loudly; Reasoning implements String.Chars and JSON-encodes only its content. Provider-free negative probes cover capable/incapable/opt-out/configured effort/multi-completion/custom-field precedence, and the real ReqLLM+LLMDB Anthropic seam passes. Focused cross-surface run passed 378 tests. Clean broad run reached 53 doctests, 9 properties, 2,841 tests with one failure: an API-guide literal assertion split by Markdown wrapping; after repairing the sentence, the 32-test documentation contract passed. This is strong repository-wide semantic evidence, not a live provider response proof. Remaining stable dependency: telemetry lineage and the inert callbacks setting.
