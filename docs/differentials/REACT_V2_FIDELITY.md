# ReAct Family And Code Execution Fidelity Audit

Current upstream reference: DSPy `3.3.1`, commit `638e155c`. The hash table
below records the earlier `3.3.0b1` differential authority; current-stable
behavior is additionally exercised by the repository's pinned 3.3.1 probes.

| Pinned authority | SHA-256 |
| --- | --- |
| `dspy/predict/react.py` | `41d47882f6c8200f0f23de69eda903d282bc56f8dcb1b466d8bdc0974f3b43f8` |
| `tests/predict/test_react.py` | `2880800214b46cd913a65ebec392ce44423d371e1cefdf7a7caa5a927ef38d54` |
| `dspy/predict/react_v2.py` | `69c1d48aceed67126379ffa047eba3814eba32660cdfcadf173f9ec0e1db7e93` |
| `tests/predict/test_react_v2.py` | `e3ccdb9b0c07900b6f3d6358f02a410ec384ebda7fa4a11995af939cdd201152` |
| `dspy/predict/code_act.py` | `a3261179299f4c52bf84199ac44b34d13f7186dc8b1b358ffe227504215723dc` |
| `tests/predict/test_code_act.py` | `8da89223fd6a640fd021d01a8e97a376d5e95a97735525a58a1c3e4e07fcc1f3` |
| `dspy/predict/program_of_thought.py` | `371e0fd5c229a10d07e0f00af07af9823f6845b0e2887f842303dea58e140545` |
| `tests/predict/test_program_of_thought.py` | `4914f0401e38287fe6125b6f028fac9d762f88503c78e08fc06ee334fd6240ba` |

## ReAct

`Imp.Predict.ReAct` retains its provider-native, fail-fast default and offers
`mode: :dspy_3_2_1` for upstream observation-and-extraction control flow. In the
upstream mode, failed and unknown tool calls become observations, `submit`
corresponds to upstream `finish`, and final outputs come from a separate
extraction pass. Both modes accept the pinned implementation's invocation-local
`max_iters` override and remove it before formatting task inputs.

The contracts are not identical. DSPy emits one action per iteration and
formats a flat trajectory through the active adapter. Imp accepts
provider-native parallel tool calls and stores a redacted event list. In DSPy
compatibility mode, action and extraction calls each receive at most three
attempts after a context-window error, dropping the oldest completed event
before each retry. Provider-native mode keeps Imp's deliberate fail-fast
policy instead of observation-and-continue.

Imp implements ReActV2 as a distinct module rather than an alias for the
existing fail-fast `Imp.Predict.ReAct`.

| Upstream behavior | Imp implementation | Evidence |
| --- | --- | --- |
| Original task inputs become optional after the first turn | Internal ReActV2 signature marks copied inputs optional and clears pending inputs after each turn | `test/react_v2_test.exs` multi-turn recovery case |
| History is structured rather than one growing trajectory string | `Imp.History` stores per-turn inputs, thought, typed calls, call results, and final fields | parallel, failure, serialization, and adapter replay tests |
| Parallel tool calls preserve IDs and execute all calls | Every missing ID receives `call_<turn>_<index>`; results retain the corresponding ID | parallel call test |
| Unknown tools and execution failures become observations | ReActV2 records error results and continues; existing ReAct remains fail-fast | recovery test |
| `submit` is reserved and validates final outputs | The name is reserved for every signature. A signature with several outputs, or one output that is not text, gets the upstream `submit` tool, built from the task JSON schema, with upstream's description and guidance text. A signature with exactly one output of type `:string` gets no `submit`: its answer is the prose the model writes when it stops calling tools (`termination_reason: :answered`), as in Anthropic's tool runner, the OpenAI Agents SDK, LangGraph's ReAct and Pydantic AI, and its guidance says to answer in plain text. Upstream needs `submit` because a signature can have several typed outputs; one text output does not | reserved-submit, missing-output and no-submit tests, `test/react_v2_request_shape_test.exs` |
| Empty calls, parse failure, context exhaustion, or budget exhaustion force one submit call | With `submit`, parse failure, empty calls and budget exhaustion still do: the final predictor call pins provider `tool_choice` to `submit` and clears `reasoning_effort`, matching the pinned call configuration. With one text output there is no `submit` to force, so every interruption makes one more request with the same tools and `tool_choice: "auto"` as every step (never `"none"`, which made models write the call they wanted as text in their own tool markup; a call made on it is not run and is named in `unexecuted_tool_calls`), and its text is the answer (`termination_reason: :last_text`, `termination_cause` naming the interruption); `:last_text_note` puts one line of host text in front of it, and a passed `Imp.Deadline` ends the run with `:deadline_exceeded` instead of making the request. Context exhaustion ends the run at once in both cases, since a further request would be refused the same way | forced-submit tests, `test/react_v2_last_text_test.exs`, `test/react_v2_last_request_wire_test.exs` |
| No upstream equivalent | `finish_on` names tools that end the turn with the outputs they carry, the shape Pydantic AI calls an output tool | `finish_on` tests |
| Prior calls replay as native assistant/tool messages | Chat adapter emits assistant `tool_calls` and matching tool-result messages by call ID | native history adapter test and ReqLLM tests |

Imp additionally applies its existing explicit tool policy to every call and
redacts stored history. These are deliberate production constraints, not claims
about upstream behavior.

Imp stores call results in a separate `tool_call_results` event field, while
DSPy nests results inside `ToolCalls`. The Chat adapter replays both as matched
assistant/tool messages by call ID, so this is an Elixir-native representation
difference rather than a provider-protocol difference.

## CodeAct

Imp matches the pinned bounded planner loop, parse/execution observations,
`finished` termination, final signature extraction, and invocation-local
`max_iters` override. The override is strictly validated before any LM call and
removed from planner inputs. Provider-free tests cover successful execution,
multi-output extraction, parse and runtime recovery, bounded exhaustion, and
control-input isolation.

Imp intentionally does not preload arbitrary functions into a persistent
Python interpreter. It evaluates a restricted Elixir expression language in
`Imp.Sandbox` and exposes policy-gated `Imp.Tool` calls as explicit actions.
Consequently, Python standard-library access, arbitrary Python snippets, and
interpreter state shared across iterations are unsupported rather than parity
claims. Tool denial and tool crashes also fail explicitly instead of becoming
Python execution observations.

## ProgramOfThought

Imp matches bounded error-conditioned regeneration, fenced-code extraction,
separate final-output extraction, multi-output signatures, and exact retry
accounting. Input containers are normalized before generation, preventing an
invalid field-pair list from spending a provider call. Trajectories and errors
are redacted before exposure.

The executable language remains the restricted BEAM sandbox, not Python with
`SUBMIT()`. When a sandbox value already validates against every declared
output, Imp returns it directly; pinned DSPy always invokes its final answer
generator. This is an explicit efficiency and validation deviation. Arbitrary
Python semantics and exact Python-interpreter error text therefore remain out
of scope until a separately isolated execution backend and matched campaign
justify supporting them.

## Remaining Evidence

The provider-free golden cases establish local control-flow contracts, not live
behavioral parity. A matched-model campaign is still required for ReAct action
selection and extraction quality, CodeAct task quality under the restricted
runtime, and ProgramOfThought regeneration/extraction quality.

The stable fidelity baseline is DSPy 3.3.1. ReActV2 is an exercised
Elixir-native equivalent in that baseline; the older 3.3.0b1 hashes remain a
historical differential rather than the current product authority.
