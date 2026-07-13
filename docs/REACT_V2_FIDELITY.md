# ReActV2 Fidelity Audit

Upstream reference: DSPy `3.3.0b1`, commit `b2829b7`,
`dspy/predict/react_v2.py`.

DSEx implements ReActV2 as a distinct module rather than an alias for the
existing fail-fast `DSEx.Predict.ReAct`.

| Upstream behavior | DSEx implementation | Evidence |
| --- | --- | --- |
| Original task inputs become optional after the first turn | Internal ReActV2 signature marks copied inputs optional and clears pending inputs after each turn | `test/react_v2_test.exs` multi-turn recovery case |
| History is structured rather than one growing trajectory string | `DSEx.History` stores per-turn inputs, thought, typed calls, call results, and final fields | parallel, failure, serialization, and adapter replay tests |
| Parallel tool calls preserve IDs and execute all calls | Every missing ID receives `call_<turn>_<index>`; results retain the corresponding ID | parallel call test |
| Unknown tools and execution failures become observations | ReActV2 records error results and continues; existing ReAct remains fail-fast | recovery test |
| `submit` is reserved and validates final outputs | Constructor rejects user `submit`; the generated submit tool uses the task JSON schema | reserved-submit and missing-output tests |
| Empty calls, parse failure, context exhaustion, or budget exhaustion force one submit call | The final predictor call pins provider `tool_choice` to `submit` | forced-submit test |
| Prior calls replay as native assistant/tool messages | Chat adapter emits assistant `tool_calls` and matching tool-result messages by call ID | native history adapter test and ReqLLM tests |

DSEx additionally applies its existing explicit tool policy to every call and
redacts stored history. These are deliberate production constraints, not claims
about upstream behavior.

The stable fidelity baseline remains DSPy 3.2.1. ReActV2 is prerelease tracking
implemented from the pinned 3.3.0b1 source because the release goal explicitly
requires this surface; it does not silently move unrelated DSEx contracts to the
prerelease baseline.
