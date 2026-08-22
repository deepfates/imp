# Imp for DSPy users

You know DSPy. This page maps what you know onto Imp, names what is
deliberately different on the BEAM, and marks what is tracked rather than
done. Imp's executable product baseline is pinned to DSPy 3.3.1. Historical
family-specific differentials retain their exact earlier DSPy source pins;
they are not silently relabeled as current evidence. The explicitly
experimental Flex code-optimization module remains a tracked downstream gap,
and broad effectiveness or superiority is not implied by product conformance.
The few-shot and weight optimizer families and the adapters carry executable
differential tests that run their exact pinned DSPy sources in a sidecar and
compare arm to arm; other surfaces are held by
behavioral conformance tests or are deliberate Elixir-native equivalents, and
some surface groups are marked as honest gaps (missing exact-reproduction
evidence or declared algorithmic deviations). A shared DSPy
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
| `dspy.ReAct(sig, tools=[...])` | `Imp.react(sig, tools, tool_policy: [...])` — tool policy is explicit; tool execution errors fail the call instead of becoming observations for another model turn |
| `dspy.Example` / `.with_inputs` | `Imp.example/1` / `Imp.with_inputs/2` |
| `dspy.Prediction` | `%Imp.Prediction{}` — read fields with `Imp.get/2` |
| `dspy.Evaluate` | `Imp.evaluate/4` — returns score plus per-example rows |
| `metric(gold, pred, trace)` | Two- or three-arity function, or `Imp.exact_match(:field)` |
| `optimizer.compile(program, trainset=...)` | `Imp.optimize!(program, optimizer, trainset)` |
| `LabeledFewShot`, `BootstrapFewShot`, `BootstrapRS` | Same names, `Imp.Optimizer.*` |
| `KNNFewShot` | Same name, same semantics: per-call embedding retrieval (required `vectorizer:`) plus a metric/teacher-driven BootstrapFewShot over the neighbors, proven against real DSPy by a deterministic-embedder differential |
| `COPRO`, `SIMBA`, `MIPROv2`, `GEPA` | Same names; GEPA takes `Prediction`-shaped score+feedback metrics |
| `BootstrapFinetune`, `Ensemble`, `BetterTogether`, `Avatar` | Same capability families, with explicit BEAM-native contracts: local MLX SFT belongs to `BootstrapFinetune`; `Ensemble` returns one normalized `Prediction` and isolates failed children; `Avatar` uses a bounded typed-action runtime and separate finisher |
| `GRPO` | Explicit experimental integration, not a completed `0.3` optimizer: the bundled local TRL/MPS path performs real durable LoRA updates and verified rebind, but retained natural treatments have not shown positive held-out learning |
| `program.save(path)` / `load` | `Imp.save!/2` / `Imp.load!/1` — checksummed JSON artifact, never credentials |
| `dspy.configure(lm=...)` | `Imp.configure(lm: ...)` sets a supervised node-local default; explicit `lm:` per program is the recommended style |
| `dspy.context(lm=...)` | `Imp.context([lm: ...], fn -> ... end)` — process-scoped |
| `dspy.inspect_history()` | Plan ahead with `Imp.trace/2`, then render retained history with `Imp.inspect_history/2` or inspect `Imp.Observability.status/1`; Imp has no retroactive global last-call buffer |
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

Imp's conformance program groups the upstream surface into conformant,
deliberately BEAM-native, tracking, and gap rows. The generated
[conformance report](https://github.com/deepfates/imp/blob/main/docs/CONFORMANCE.md)
is the repository's current per-surface view; it is intentionally separate from
the packaged manual. A passing selected conformance profile means that its
declared blocking rows are satisfied. It is not the product release verdict or
a statement that every optimizer is effective.

Repository-only differential comparisons run real pinned DSPy and compare public
behavior arm to arm. MIPROv2 and SIMBA structural cases additionally name their
pinned DSPy 3.3.0b1 reference. The matched TREC result establishes one
task-specific GEPA and MIPROv2 outcome; it does not close the cross-task, paper,
or other instruction-family gaps.

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
distinction is the breadth of the shared programming and optimization model
joined to BEAM-native persistence, supervision, and operation. Its source-bound
differentials make specific compatibility claims reviewable; they do not turn
the still-open 3.3.1 migration or optimizer-effectiveness work into completed
parity.

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
