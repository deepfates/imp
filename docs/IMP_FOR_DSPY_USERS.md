# Imp for DSPy users

You know DSPy. This page maps what you know onto Imp, names what is
deliberately different on the BEAM, and marks what is tracked rather than
done. Imp follows DSPy 3.2.1 — not loosely. The few-shot and weight
optimizer families and the adapters carry executable differential tests that
run real DSPy 3.2.1 in a sidecar and compare arm to arm; other surfaces are
held by behavioral conformance tests or are deliberate Elixir-native
equivalents, and two surface groups are marked as honest gaps (missing
exact-reproduction evidence or declared algorithmic deviations). A shared DSPy
name means that Imp implements the same user capability and identifies the
pinned upstream mechanism; it does **not** by itself promise identical Python
control flow or results. Each family is classified as conformant,
Elixir-native, or a gap by the conformance table and its linked fidelity page.
Imp-only behaviors normally carry Imp-only names
(`Imp.Adapter.PlanFirst`, `Imp.Retrievers.KNN`).

## The mapping

| You write in DSPy | You write in Imp |
| --- | --- |
| `dspy.Signature` / `"q -> a"` | `Imp.signature("q -> a")` — same string DSL, types included (`enum[...]`, lists, numbers) |
| `dspy.Predict(sig)` | `Imp.predict(sig, lm: lm)` |
| `dspy.ChainOfThought` | `Imp.chain_of_thought/2` |
| `dspy.ReAct(sig, tools=[...])` | `Imp.react(sig, tools, tool_policy: [...])` — tool policy is explicit |
| `dspy.Example` / `.with_inputs` | `Imp.example/1` / `Imp.with_inputs/2` |
| `dspy.Prediction` | `%Imp.Prediction{}` — read fields with `Imp.get/2` |
| `dspy.Evaluate` | `Imp.evaluate/4` — returns score plus per-example rows |
| `metric(gold, pred, trace)` | Two- or three-arity function, or `Imp.exact_match(:field)` |
| `optimizer.compile(program, trainset=...)` | `Imp.optimize!(program, optimizer, trainset)` |
| `LabeledFewShot`, `BootstrapFewShot`, `BootstrapRS` | Same names, `Imp.Optimizer.*` |
| `KNNFewShot` | Same name, same semantics: per-call embedding retrieval (required `vectorizer:`) plus a metric/teacher-driven BootstrapFewShot over the neighbors, proven against real DSPy by a deterministic-embedder differential |
| `COPRO`, `SIMBA`, `MIPROv2`, `GEPA` | Same names; GEPA takes `Prediction`-shaped score+feedback metrics |
| `BootstrapFinetune`, `GRPO`, `Ensemble`, `BetterTogether`, `Avatar` | Same capability families, with explicit BEAM-native contracts: local MLX SFT belongs to `BootstrapFinetune`; `GRPO` requires an explicit reinforcement trainer and can use the bundled local TRL/MPS backend; `Ensemble` returns one normalized `Prediction` and isolates failed children; `Avatar` uses a bounded typed-action runtime and separate finisher |
| `program.save(path)` / `load` | `Imp.save!/2` / `Imp.load!/1` — checksummed JSON artifact, never credentials |
| `dspy.configure(lm=...)` | `Imp.configure(lm: ...)` sets a supervised node-local default; explicit `lm:` per program is the recommended style |
| `dspy.context(lm=...)` | `Imp.context([lm: ...], fn -> ... end)` — process-scoped |
| `dspy.inspect_history()` | `Imp.trace/2` and `Imp.Observability.status/1` — redacted by default |
| `dspy.LM("openai/gpt-...")` (LiteLLM) | `Imp.req_llm("openai:gpt-...")` ([ReqLLM](https://hex.pm/packages/req_llm) providers) |
| `DummyLM` in tests | `Imp.LM.Static` — scripted fields, everything else runs for real |

## What is deliberately different

**Defaults are supervised and scopeable.** Imp has a `configure/1` like DSPy
does, but the default lives in a supervised OTP process, and `Imp.context/2`
gives you a process-local override stack for a request or a test. The
recommended style is still an explicit `lm:` on the program, because explicit
seams are why swapping `Imp.LM.Static` into tests requires no patching.

**Supervision is the execution model, not an add-on.** Evaluation fan-out,
tool execution, and sandboxed code all run in bounded, supervised workers.
A slow provider call returns a timeout instead of hanging your program; a
crashed interpreter restarts. The [deployment example](../examples/deployment/README.md)
is a complete OTP application, not a snippet.

**The sandboxes are Elixir.** `ProgramOfThought`, `CodeAct`, and RLM execute
model-written code in a budgeted, allowlisted Elixir evaluator under
supervision — the BEAM equivalent of DSPy's Python interpreter and
experimental WASM sandbox, with process isolation as the safety boundary.

**Artifacts are strict.** Saved programs are checksummed and never contain
credentials; you rebind the live model at load time. This is the same
save/load story as DSPy with the operational edges sharpened.

**Some shared optimizer names are native adaptations, not compatibility
modes.** `Avatar` adds explicit policy, timeout, observation, and finisher
boundaries; `AvatarOptimizer` validates the rewritten candidate before keeping
it rather than installing a rewrite from its predecessor score;
`Ensemble` normalizes child output and failure handling into an Imp
`Prediction`; and weight optimizers use explicit asynchronous trainer artifacts
instead of mutating a Python LM object. These are intentional public semantics.
Their source-bound tests cover named shared observations, not whole-loop parity
or comparative superiority.

## What is not identical

Imp's conformance program tracks 26 upstream surface groups against DSPy
3.2.1:

| Status | Count | Meaning |
| --- | --- | --- |
| Conformant | 12 | Matches the pinned reference on the evidence cited by each surface; a family-level status does not imply that every upstream code path or optimizer outcome has been reproduced |
| Elixir-native equivalent | 3 | Same capability, deliberately different mechanics with no remaining obligation recorded for that grouped surface |
| Tracking | 1 | Following DSPy's unreleased 3.3 normalized-runtime changes |
| Gap | 10 | A named behavior or evidence obligation remains open. Advertised gaps block full ecosystem closure even when the implemented runtime is substantive. |

The per-surface table is the [conformance report](CONFORMANCE.md). Behind
the differential rows, the `scripts/` sidecars and `mix imp.benchmark.*_differential`
tasks run real pinned DSPy 3.2.1 and compare arm to arm — a capture raises
unless Imp's output matches upstream, so you can run them yourself and see
the match. MIPROv2 and SIMBA structural cases additionally name their pinned
DSPy 3.3.0b1 reference. The matched TREC result establishes one task-specific
GEPA and MIPROv2 C3 outcome; it does not close the cross-task, paper, or other
instruction-family gaps. If this page and the generated report disagree, the
report wins.

Ecosystem breadth is the real gap: DSPy has years of retriever integrations,
observability partners, and community. Imp's seams for that are behaviours
(`Imp.LM`, `Imp.Retrieve`, adapters) — implementing one and publishing a Hex
package is the extension story, and it is young.

## Nearby Elixir work

Imp is not the first BEAM attempt at this lineage —
[ds_ex](https://github.com/nshkrdotcom/ds_ex) and
[dspy.ex](https://github.com/arthurcolle/dspy.ex) explored DSPy-style
programming in Elixir earlier, and
[gepa_ex](https://github.com/nshkrdotcom/gepa_ex) explored GEPA. Imp's
distinction is scope and verification: the full optimizer bench, tracked
against a pinned current upstream, with the receipts executable.

## Coming from DSPy: the five-minute version

```elixir
# pip install dspy            →  {:imp, path: "path/to/imp"}  (Hex publication pending)
# dspy.configure(lm=lm)       →  lm = Imp.req_llm("openai:gpt-5.4-mini", api_key: ...)
# dspy.Predict("q -> a")      →  program = Imp.predict("q -> a", lm: lm)
# program(q="...")            →  {:ok, pred} = Imp.call(program, %{q: "..."})
# pred.a                      →  Imp.get(pred, :a)
# optimizer.compile(...)      →  compiled = Imp.optimize!(program, optimizer, trainset)
```

Then take the [Learning Path](LEARNING_PATH.md) — it will feel familiar in
exactly the ways DSPy taught you, and different in exactly the ways the BEAM
earns.
