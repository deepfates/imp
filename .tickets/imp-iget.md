---
id: imp-iget
status: in_progress
deps: [imp-xct8]
links: []
created: 2026-08-22T15:39:33Z
type: feature
priority: 0
assignee: deepfates
parent: imp-nenu
tags: [agents, optimizer, tools, safety]
---
# Optimize an executed agent safely through the ordinary Imp lifecycle

Build the real agent user story over existing ReAct/RLM/composed programs and optimizer machinery: action-aware task records and run reports, side-effect-safe evaluation, separate selection/test, selected component Artifact, and fresh operation. This replaces any implication that the JSON agent_config OA result proves actual Imp agent optimization.

## Acceptance Criteria

A public example optimizes an actually executed ReAct, RLM, or composed tool program against task outcomes plus expected/forbidden actions, completion, errors, turns, usage, and traces; tool effects use replay or sandbox by default and live execution fails closed unless explicitly authorized; learned work keeps disjoint selection/test; the selected Artifact applies to reconstructed trusted code and runs after a fresh process restart; a bounded natural live treatment succeeds meaningfully and failures/costs remain inspectable.


## Notes

**2026-08-22T19:33:01Z**

2026-08-22: In progress. The public packaged sandbox story and provider-free execution contract are implemented locally. A bounded dirty-tree live run used real ReActV2 tool execution plus ordered Imp.Run events, natural Claude Sonnet 4.6 component proposals, GPT-5.4 Mini task calls, disjoint 3/3/4 train-selection-test rows, parameter Artifact reload, and a fresh BEAM. Baseline heldout 0.90, selected 1.00, fresh 1.00; 3 reflection and 76 task requests, observed combined cost about USD 0.076. This is diagnostic until rerun from exact clean code. Sandbox/replay-default is demonstrated; generalized pre-effect authorization for external side effects is not, so the full ticket remains open.

**2026-08-22T19:37:38Z**

2026-08-22 clean result supersedes the prior dirty diagnostic: commit 788c971ce761b25ed6533bc179765d985b17d0fc, heldout baseline 0.95, selected 0.975, fresh-process case 1.0; 77 task requests / 65,376 input / 3,076 output / USD 0.062874 plus 3 reflection requests / 1,020 input / 563 output / USD 0.011505. All heldout rows chose the expected action with no provider/tool errors; selected lookup ended by forced_submit and therefore scored 0.9. Raw result/artifact hashes are recorded in docs/EVIDENCE.md but remain local until the commit is promoted and ordinary admission is possible. Remaining acceptance gap is explicit fail-closed authorization for non-sandbox external effects; do not generalize from this one-seed four-row treatment.
