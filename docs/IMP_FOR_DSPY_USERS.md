# Imp for DSPy users

You know DSPy. Imp keeps its core programming model—signatures, modules,
examples, evaluation, optimizers, tools, retrieval, and saved program
parameters—while making programs ordinary immutable Elixir values that run
under OTP.

The names below map familiar concepts, not Python implementation details.
Where the BEAM offers a stronger native shape, Imp uses it directly:
supervised concurrency, process-scoped configuration, immutable program
updates, telemetry, and fresh-runtime artifact application.

## The mapping

| You write in DSPy | You write in Imp |
| --- | --- |
| `dspy.Signature` / `"q -> a"` | `Imp.signature("q -> a")` — the same compact input/output idea with Imp type spellings such as `array[...]`, `enum[...]`, and `number` |
| `dspy.Predict(sig)` | `Imp.predict(sig, lm: lm)` |
| `dspy.ChainOfThought` | `Imp.chain_of_thought/2` |
| `dspy.ReAct(sig, tools=[...])` | `Imp.react(sig, tools, tool_policy: [...])` — typed tools, structured observations, and validated `submit` for several or typed outputs; a signature with one text output ends on a step answered in text. `Imp.Predict.ReAct` is the earlier loop, with a `mode: :dspy` port of `dspy.ReAct` |
| `dspy.Example` / `.with_inputs` | `Imp.example/1` / `Imp.with_inputs/2` |
| `dspy.Prediction` | `%Imp.Prediction{}` — read fields with `Imp.get/2` |
| `dspy.Evaluate` | `Imp.evaluate/4` — returns score plus per-example rows |
| `metric(gold, pred, trace)` | Two- or three-arity function, or `Imp.exact_match(:field)` |
| `optimizer.compile(program, trainset=...)` | `Imp.optimize!(program, optimizer, trainset)` |
| `LabeledFewShot`, `BootstrapFewShot`, `BootstrapFewShotWithRandomSearch` (`BootstrapRS`) | Same names, `Imp.Optimizer.*`; `BootstrapRS` is `BootstrapFewShotWithRandomSearch` |
| `KNNFewShot` | Same name: per-call embedding retrieval (`vectorizer:`) plus metric/teacher-driven BootstrapFewShot over the neighbors |
| `COPRO`, `SIMBA`, `MIPROv2`, `GEPA` | Same names; GEPA takes `Prediction`-shaped score+feedback metrics |
| `BootstrapFinetune`, `Ensemble`, `BetterTogether`, `Avatar` | Same capability families, with explicit BEAM-native contracts: local MLX SFT belongs to `BootstrapFinetune`; `Ensemble` returns one normalized `Prediction` and isolates failed children; `Avatar` uses a bounded typed-action runtime and separate finisher |
| `GRPO` | Experimental external training through TRL-compatible workers and durable adapter checkpoints |
| `program.save(path)` / `load` | `Imp.save!/2` / `Imp.read!/1` — checksummed JSON artifact, never credentials |
| `dspy.configure(lm=...)` | `Imp.configure(lm: ...)` sets a supervised node-local default; explicit `lm:` per program is the recommended style |
| `dspy.context(lm=...)` | `Imp.context([lm: ...], fn -> ... end)` — process-scoped |
| `dspy.streamify(program, stream_listeners=[...])` | `Imp.stream(program, inputs, provider_stream: true, stream_listeners: [...])` — runs the real composed program, streams selected named-predictor fields, and ends with the typed prediction |
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
crashed interpreter restarts. The [deployment example](https://github.com/deepfates/imp/blob/main/examples/deployment/README.md)
is a complete OTP application, not a snippet.

**The restricted interpreters are Elixir-shaped, not OS sandboxes.**
`ProgramOfThought`, `CodeAct`, and RLM parse model-written expressions through
an allowlisted evaluator with bounded syntax, values, effects, and work. BEAM
supervision contains crashes and timeouts, but processes share VM and host
authority. Treat the allowlist plus host-enforced filesystem, network, tool,
credential, and resource policy as the security boundary.

**Artifacts are strict.** Saved programs are checksummed and never contain
credentials; you rebind the live model at load time. This is the same
save/load story as DSPy with the operational edges sharpened.

**Shared names do not imply identical control flow.** `Avatar` adds explicit
policy, timeout, observation, and finisher boundaries; `Ensemble` normalizes
child output and failure handling into an Imp `Prediction`; and weight
optimizers use asynchronous trainer artifacts instead of mutating an LM object.

## Where Imp differs

Imp targets DSPy's programming semantics, not byte-for-byte prompts, random
sequences, or Python object mutation. Provider behavior and stochastic search
still vary by model, data, and budget, so measure the compiled program on your
own held-out data.

DSPy also has a larger Python integration ecosystem. Imp provides extension
boundaries through `Imp.LM`, `Imp.Retrieve`, adapters, tools, and trainer
clients; integrations written for Python do not automatically work on the
BEAM. DSPy's Flex code optimizer is not included.

## Nearby Elixir work

Imp is not the first BEAM attempt at this lineage —
[ds_ex](https://github.com/nshkrdotcom/ds_ex) and
[dspy.ex](https://github.com/arthurcolle/dspy.ex) explored DSPy-style
programming in Elixir earlier, and
[gepa_ex](https://github.com/nshkrdotcom/gepa_ex) explored GEPA. Imp joins that
lineage to a broad programming and optimization model built for OTP deployment.

## Coming from DSPy: the five-minute version

```elixir
# pip install dspy            →  {:imp, "~> 0.5"}
# dspy.configure(lm=lm)       →  lm = Imp.req_llm("openai:gpt-5.4-mini", api_key: ...)
# dspy.Predict("q -> a")      →  program = Imp.predict("q -> a", lm: lm)
# program(q="...")            →  {:ok, pred} = Imp.call(program, %{q: "..."})
# pred.a                      →  Imp.get(pred, :a)
# optimizer.compile(...)      →  compiled = Imp.optimize!(program, optimizer, trainset)
```

Then take the [Learning Path](LEARNING_PATH.md) — it will feel familiar in
exactly the ways DSPy taught you, and different in exactly the ways the BEAM
earns.
