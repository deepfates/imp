# Imp for DSPy users

You know DSPy. This page maps what you know onto Imp, names what is
deliberately different on the BEAM, and is honest about what is tracked
rather than done. Imp follows DSPy 3.2.1 — not loosely: the optimizers are
verified against the pinned upstream source with executable differential
tests, and the conformance table below is generated from that program.

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
| `optimizer.compile(program, trainset=...)` | `Imp.optimize(program, optimizer, trainset)` |
| `LabeledFewShot`, `BootstrapFewShot`, `BootstrapRS`, `KNNFewShot` | Same names, `Imp.Optimizer.*` |
| `COPRO`, `SIMBA`, `MIPROv2`, `GEPA` | Same names; GEPA takes `Prediction`-shaped score+feedback metrics |
| `BootstrapFinetune`, `GRPO`, `Ensemble`, `BetterTogether`, `Avatar` | Same names; local MLX fine-tuning included |
| `program.save(path)` / `load` | `Imp.save!/2` / `Imp.load!/1` — checksummed JSON artifact, never credentials |
| `dspy.configure(lm=...)` | No global. Pass `lm:` explicitly, or scope with `Imp.context/2` |
| `dspy.context(lm=...)` | `Imp.context([lm: ...], fn -> ... end)` — process-scoped |
| `dspy.inspect_history()` | `Imp.trace/2` and `Imp.Observability.status/1` — redacted by default |
| `dspy.LM("openai/gpt-...")` (LiteLLM) | `Imp.req_llm("openai:gpt-...")` ([ReqLLM](https://hex.pm/packages/req_llm) providers) |
| `DummyLM` in tests | `Imp.LM.Static` — scripted fields, everything else runs for real |

## What is deliberately different

**No ambient globals.** `dspy.configure` sets process-wide state; Imp has no
global model. The LM is an explicit dependency on the program, or a
process-scoped override via `Imp.context/2`. In a runtime built on millions
of independent processes, ambient configuration is a bug factory; explicit
seams are also why swapping `Imp.LM.Static` into tests requires no patching.

**Supervision is the execution model, not an add-on.** Evaluation fan-out,
tool execution, and sandboxed code all run in bounded, supervised workers.
A slow provider call returns a timeout instead of hanging your program; a
crashed interpreter restarts. The [deployment example](../examples/deployment)
is a complete OTP application, not a snippet.

**The sandboxes are Elixir.** `ProgramOfThought`, `CodeAct`, and RLM execute
model-written code in a budgeted, allowlisted Elixir evaluator under
supervision — the BEAM equivalent of DSPy's Python interpreter and
experimental WASM sandbox, with process isolation as the safety boundary.

**Artifacts are strict.** Saved programs are checksummed and never contain
credentials; you rebind the live model at load time. This is the same
save/load story as DSPy with the operational edges sharpened.

## What is honestly not identical

Imp's conformance program tracks 23 upstream surface groups against DSPy
3.2.1. Current state: **14 conformant** (differentially verified), **6
Elixir-native equivalents** (same capability, deliberately different
mechanics — the model runtime, the ReAct family internals, RLM's sandbox,
weight-optimizer plumbing, retrieval backends, fast/slow learning), **2
tracking** DSPy's unreleased 3.3 changes, and **1 claim-scoped gap** in the
instruction-optimizer family's exact-reproduction evidence. The full table
with per-surface status lives in the repository's conformance report, and
every "conformant" row is backed by the conformance program's executable checks — if this
paragraph and the code ever disagree, the tests win.

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
# pip install dspy            →  {:imp, github: "deepfates/imp", tag: "v0.1.0"}
# dspy.configure(lm=lm)       →  lm = Imp.req_llm("openai:gpt-5.4-mini", api_key: ...)
# dspy.Predict("q -> a")      →  program = Imp.predict("q -> a", lm: lm)
# program(q="...")            →  {:ok, pred} = Imp.call(program, %{q: "..."})
# pred.a                      →  Imp.get(pred, :a)
# optimizer.compile(...)      →  compiled = Imp.optimize(program, optimizer, trainset)
```

Then take the [Learning Path](LEARNING_PATH.md) — it will feel familiar in
exactly the ways DSPy taught you, and different in exactly the ways the BEAM
earns.
