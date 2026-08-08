---
id: imp-7aah
status: open
deps: [imp-kejs]
links: []
created: 2026-08-07T17:07:55Z
type: task
priority: 1
assignee: deepfates
parent: imp-yme4
tags: [live, testing, providers]
---
# Run and gate on live provider suite (mix live.check)

172 live-provider tests are excluded by default and have never run in CI; all real-model behavior is verified only by manual paid runs. Livebook live cells self-gate (print reminder without key) so 'livebooks run offline' does not cover them.

## Acceptance Criteria

mix live.check executed with real keys, failures triaged; documented as a required pre-benchmark gate.


## Notes

**2026-08-07T17:56:16Z**

MAJOR CORRECTION (owner pushback, verified): 'live tests never run' is FALSE. Live runs are abundantly evidenced: admitted artifacts benchmarks/evidence/admitted/instruction_live (2026-07-15) and multimodal_live (2026-07-13), paid TREC matched runs, 3 committed live tutorial runs, LiveBench baselines, live.log files, sustained git history of live-provider coverage. TRUE narrow claim: live-tagged tests are excluded from all CI aliases; live.check covers only test/live_provider_test.exs + live_provider_e2e_test.exs (~15 tests of 4 live-tagged files); no gate-evidence-*.json currently in tree, so live-smoke status AT CURRENT HEAD is unrecorded. Rescope: run 'mix gate.live_provider.evidence' fresh at the campaign commit as preflight; excluded-count is 195 total across all tags, not 172 live.

**2026-08-08T01:11:39Z**

RUN at HEAD (2026-08-08): first recorded gate-evidence artifact tmp/gate-evidence/gate-evidence-live_provider_smoke-20260808T011119Z.json — status failing: 12/15 pass, 3 failures = ReAct/CodeAct unknown_tool on OpenRouter route + README-hero test hard-requiring OPENAI_API_KEY. Filed as imp-<new> bug; core provider path (predict/CoT/RAG/history/refine) verified live. Gate goes green when that bug closes or an OpenAI key is provisioned for the native route.
