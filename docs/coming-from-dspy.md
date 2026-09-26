# Coming from DSPy

You know DSPy. Imp keeps its programming model: signatures, modules,
examples, metrics, evaluation, optimizers, tools, retrieval, and saved
programs. What changes is the host. An Imp program is an immutable Elixir
value, it runs under OTP supervision, and the model is passed to it like any
other dependency.

## The five-minute version

```elixir
# pip install dspy             ->  {:imp, "~> 0.5"}
# lm = dspy.LM("openai/...")    ->  lm = Imp.req_llm("openai:gpt-5.4-mini", api_key: ...)
# dspy.Predict("q -> a")        ->  program = Imp.predict("q -> a", lm: lm)
# program(q="...")              ->  {:ok, pred} = Imp.call(program, %{q: "..."})
# pred.a                        ->  Imp.get(pred, :a)
# optimizer.compile(p, trainset=...)  ->  improved = Imp.optimize!(p, optimizer, trainset)
# p.save("p.json")              ->  Imp.save!(improved, "p.json")
```

Then read [Getting started](getting-started/index.md). It will feel
familiar in the ways DSPy taught you, and different where the BEAM does
something better.

## The mapping

| DSPy | Imp |
| --- | --- |
| `dspy.LM("openai/gpt-...")` | `Imp.req_llm("openai:gpt-...")`, through [ReqLLM](https://hex.pm/packages/req_llm) |
| `dspy.configure(lm=...)` | `Imp.configure(lm: ...)`; an explicit `lm:` on each program is the recommended style |
| `dspy.context(lm=...)` | `Imp.context([lm: ...], fn -> ... end)`, scoped to the calling process |
| `dspy.Signature`, `"q -> a"` | `Imp.signature("q -> a", instructions)`; types are spelled `array[...]`, `enum[...]`, `number` ([Signatures](diving-deeper/signatures.md)) |
| `InputField(desc=...)`, `OutputField(desc=...)` | `name: type "description"`, or the map form |
| `dspy.Predict(sig)` | `Imp.predict(sig, lm: lm)` |
| `dspy.ChainOfThought(sig)` | `Imp.chain_of_thought(sig, lm: lm)` |
| `dspy.ReAct`, `dspy.ReActV2` | `Imp.react(sig, tools, lm: lm)`, the ReActV2 design ([ReAct](diving-deeper/react.md)) |
| `dspy.Tool(fn)` | `Imp.tool(name, description, fn, schema: ...)` |
| `dspy.Tool.from_mcp_tool(session, tool)` | `Imp.MCP.connect(descriptors, trusted_servers: ...)` ([Tools and MCP](diving-deeper/tools-and-mcp.md)) |
| `dspy.Retrieve`, a RAG `forward` | `Imp.retrieve(retriever, query, k: 3)`, `Imp.rag(program, retriever)` ([Retrieval](diving-deeper/retrieval.md)) |
| `dspy.BestOfN`, `dspy.Refine` | `Imp.best_of_n(program, metric, n: 3)`, `Imp.refine(program, metric, n: 3)` |
| `dspy.majority` | `Imp.majority(values, field: :answer)`, which returns the winning value |
| `dspy.MultiChainComparison` | `Imp.multi_chain_comparison(sig, m: 3)` |
| `dspy.Parallel`, `module.batch(...)` | `Imp.parallel(program, inputs_list, num_threads: n)` |
| `dspy.ProgramOfThought`, `dspy.CodeAct`, `dspy.RLM` | `Imp.program_of_thought/2`, `Imp.code_act/3`, `Imp.rlm/2`, which run model-written code in Imp's own restricted interpreter |
| `dspy.Module` with `forward` | a struct implementing `Imp.Module`'s `call/2` ([Modules and composition](diving-deeper/modules-and-composition.md)) |
| `module.named_predictors()` | `Imp.ProgramParameters.predictors/1`; a custom module names its own with `optimizer_predictors/1` |
| `dspy.Example(...).with_inputs(...)` | `Imp.example/1`, then `Imp.with_inputs/2` |
| `dspy.Prediction`, `pred.field` | `%Imp.Prediction{}`, `Imp.get(pred, :field)` |
| `dspy.History` | `Imp.History` |
| `dspy.Evaluate(devset=..., metric=...)` | `Imp.evaluate(program, devset, metric)`, which returns the score and every row |
| `metric(gold, pred, trace=None)` | a two- or three-argument function, or `Imp.exact_match(:field)` |
| `optimizer.compile(program, trainset=...)` | `Imp.optimize!(program, optimizer, trainset)` |
| `LabeledFewShot`, `BootstrapFewShot`, `BootstrapFewShotWithRandomSearch`, `KNNFewShot` | the same names under `Imp.Optimizer.*` |
| `COPRO`, `MIPROv2`, `SIMBA`, `GEPA` | the same names; GEPA takes metrics that return a score with feedback |
| `BootstrapFinetune`, `BetterTogether`, `Ensemble`, `AvatarOptimizer` | the same capabilities, with Elixir-shaped contracts; see each module |
| `GRPO` | experimental, through TRL-compatible training workers |
| `dspy.ChatAdapter`, `JSONAdapter`, `XMLAdapter`, `TwoStepAdapter` | `Imp.Adapter.Chat`, `JSON`, `XML`, `TwoStep` ([Adapters](diving-deeper/adapters.md)) |
| `use_json_adapter_fallback=False` | `config: [json_fallback: false]` |
| `program.save(path)`, `dspy.load(path)` | `Imp.save!(program, path)`, `Imp.read!(path)`; `Imp.dump/1` and `Imp.load/1` for maps |
| `dspy.streamify(program, stream_listeners=...)` | `Imp.stream(program, inputs, provider_stream: true, stream_listeners: ...)` |
| `dspy.inspect_history()` | `prediction.metadata.trace.messages`, `Imp.trace/2`, `Imp.inspect_history/2` |
| `track_usage=True`, `pred.get_lm_usage()` | `Imp.configure(track_usage: true)`, `Imp.Prediction.get_lm_usage/1` |
| `DummyLM` | `Imp.LM.Static`: a scripted model; everything else runs for real |

## What is deliberately different

**Programs are values.** Nothing mutates a program. `Imp.with_demos/2`,
`Imp.with_lm/2` and every optimizer return a new program, so twenty
candidates in a search cannot disturb one another, and the program you
evaluated is the program you ship.

**The model is explicit.** `Imp.configure/1` exists, but a program built with
`lm:` carries its model, and `Imp.context/2` overrides it for one process.
That explicit seam is why a test swaps in `Imp.LM.Static` without patching
anything.

**Supervision is the execution model.** Evaluation, parallel calls, tool calls
and interpreted code run in bounded, supervised tasks. A slow provider call
ends in a timeout rather than a hung program, and one failing example is one
error row, not a crashed run. The
[deployment example](https://github.com/deepfates/imp/blob/v0.5.0/examples/deployment/README.md)
is a complete OTP application.

**Optimizers see what you name.** DSPy finds predictors by walking a module's
attributes. An Imp module lists them, under names that become the parameter
IDs in a saved program. Nothing is picked up by accident, and nothing is
missed because it sat somewhere the walk did not look.

**Errors are values.** A call returns `{:ok, prediction}` or
`{:error, reason}`, and parse failures, provider failures and tool failures
each have their own shape. A tool call that may have run is reported as
unknown, never as failed, and is not retried for you.

**The code interpreters are not operating system sandboxes.** Program of
thought, CodeAct and RLM parse model-written code and run only an allowlisted
subset, with bounded steps, values and effects. That code runs inside your VM,
so treat the tools you give it, and the host's own file, network and
credential policy, as the security boundary.

**Saved programs hold no secrets.** A saved program is checksummed JSON with
no credentials; you pass the live model again when you load it.

**Shared names do not promise identical control flow.** `Imp.react/3` answers
in text for a one-text-output signature, `Ensemble` returns one prediction and
isolates a failing member, and weight optimizers train through external
workers instead of mutating an LM object. Each module's documentation says
where it differs.

## What Imp does not have

Imp targets DSPy's programming model, not byte-identical prompts for every
module, the same random sequences, or Python object mutation. Measure a
compiled program on your own held-out data.

Python integrations do not carry over. Imp's extension points are
`Imp.LM`, `Imp.Retrieve`, adapters, tools and training clients. DSPy's `Flex`
code optimizer has no Imp counterpart.

## Nearby Elixir work

[ds_ex](https://github.com/nshkrdotcom/ds_ex) and
[dspy.ex](https://github.com/arthurcolle/dspy.ex) explored DSPy-style
programming in Elixir before Imp, and
[gepa_ex](https://github.com/nshkrdotcom/gepa_ex) explored GEPA.
