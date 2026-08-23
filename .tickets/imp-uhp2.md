---
id: imp-uhp2
status: closed
deps: [imp-7yim]
links: []
created: 2026-08-22T13:38:12Z
type: feature
priority: 0
assignee: deepfates
parent: imp-yme4
tags: [providers, streaming, tools, operations]
---
# Exercise realistic composed programs across providers and OTP failures

Exercise the product as a real BEAM application: composed named predictors and tools, materially different live provider routes, streaming where supported, bounded work, persistence, restart, concurrency, supervision, and observable failure. Repair ordinary-path defects rather than treating transport demos or isolated unit seams as completion.

## Acceptance Criteria

At least two materially different supported provider routes execute representative composed programs; named predictor updates and tool calls survive composition; supported streaming is genuinely incremental and unsupported cases fail loudly; budgets, usage, retries, timeouts, cancellation, provider errors, and partial failures are observable and bounded; selected state persists without credentials and reloads after a fresh process restart; concurrent supervised service preserves isolation and recovery; tests include adversarial failure injection without relying on maintainer-only machinery.

## Notes

**2026-08-22T21:28:13Z**

Operational cutover at f121ded41561732663d0691b727132192e346dc2 (2026-08-22): current provider-free adversarial suite passed 67/67 across deployment_reference, production_hardening, incremental streaming, Run/Execution authorization+cancellation, parallel execution, and failure containment. The packaged examples/deployment ordinary workflow passed selection 0.25->1.0, untouched 1.0, parameter-only Artifact, fresh OS restart, four concurrent calls, killed worker containment, timeout containment, and post-failure service recovery. Live OpenRouter GPT-5.4 Mini suite passed typed Predict/CoT, genuine streaming, MCP-backed ReAct tool use, orchestration, ProgramOfThought, CodeAct, ReActV2, RLM, and RLM sub-LM (10/11); classic fail-fast ReAct alone returned missing_output_fields after the model failed to submit, retained here as a bounded treatment/model-adherence negative rather than rerun into green. Local Ollama llama3.2:3b independently passed typed decode and genuine 12-chunk provider streaming. Finally, a parameter Artifact with both named predictors was read/applied to a fresh SupportPipeline, rebound analyze->local Ollama and route->OpenRouter, and returned beacon/high with stages [:analyze,:route], six trace events, and usage entries for both models. Credentials were recovered only into process environment and never stored. This satisfies the operational capability; remaining release work is cold-consumer and bounded comparison, not more runtime machinery.

**2026-08-23T02:20:00Z**

Post-closure classification correction: repeated final-candidate probing reproduced classic ReAct's absent structured submit 2/5 times, so the earlier model-adherence label was too weak. Commit 29e6b673 repairs the provider-native terminal contract with one forced submit and loud failure if it remains invalid; the targeted live path then passed 5/5 and the complete live gate passed 15/15. This supersedes the classification without erasing the original 10/11 observation.
