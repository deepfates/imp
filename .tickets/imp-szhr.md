---
id: imp-szhr
status: closed
deps: [imp-juni]
links: []
created: 2026-08-22T13:38:33Z
type: task
priority: 1
assignee: deepfates
parent: imp-yme4
tags: [live, evidence, release]
---
# Run bounded representative live comparisons for release

After the product lifecycles and cold-consumer path are sound, run a bounded set of representative live comparisons that can falsify whether central optimizer behaviors work under realistic conditions. Match a coherent pinned upstream where a release claim implies comparison, preserve raw outcomes and honest negatives, and avoid the enormous paper-scale suite.

## Acceptance Criteria

The retained set spans materially different mechanisms, tasks, and at least two relevant provider conditions; each learned treatment uses separate selection and untouched evaluation data; comparative lanes use coherent pinned upstream behavior when the claim requires it; enough rows or repeats are used to expose obvious brittleness without pretending to establish universal superiority; outcomes, parse and transport failures, budgets, actual costs, source/data hashes, and fresh-state application are independently recomputable; negative results remain visible and lead to defect, treatment, scientific-negative, or uncertainty classification.

## Notes

**2026-08-22T21:34:17Z**

Bounded release comparison set completed after product/cold-consumer cutover. New live run at 88d61a9c8ee1e70af929de9d5445fb317ce74040: shipped support-routing LabeledFewShot on OpenRouter GPT-5.4 Mini, three uncached repeats over disjoint 20-train/20-test rows, baseline .50/.35/.30 -> optimized .95/1.00/.95, 120 single-attempt transports, zero row errors, 42,888 input + 1,477 output tokens, actual evaluation cost /bin/zsh.038819, followed by a 4/4 concurrent fresh-OS Artifact service at /bin/zsh.001683. Artifact 9d7e299b... is content-addressed and tests recompute its dataset, budgets, cache, and fresh-service contract. This run falsified the old published baseline ceiling; docs and claim text are repaired to .30-.50 rather than hiding the miss. The current compact pinned-DSPy TREC recomputation also passed exactly: Imp GEPA +.4000, Imp MIPROv2 +.1458, Imp-minus-DSPy GEPA -.0083 across retained scored rows and source-clustered inference. Breadth comes from already-retained landing runs, not new spending: natural OpenRouter instruction/rule, SIMBA, ensemble, and classical lifecycles; schema-v2 OA across retry code, agent config, and scheduling ($.082421/44 calls); local Ollama/MLX COPRO heldout +.075 with fresh application; and local SIMBA/GRPO plus Banking77/HotPot negatives. Every learned lane used a selection barrier and separate heldout/untouched data; result files retain source/data identities, raw row/error summaries, budgets/costs where provider-priced, and fresh-state receipts. Negatives remain classified: local SIMBA correctly retained baseline after validation regression; GRPO validation lift reversed on heldout (scientific negative); Banking77 missed its preregistered lift threshold (scientific negative); HotPot's atomic treatment regressed (treatment design); classic ReAct live miss is model adherence under its documented fail-fast contract. No paper-scale rerun was needed or authorized. This set falsifies obvious application, provider, selection, persistence, and matched-semantics failures without claiming universal superiority.
