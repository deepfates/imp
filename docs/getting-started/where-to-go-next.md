# Where to go next

We built one program and took it the whole way: a signature, a prediction we
could inspect, tests without a model, a tool, a two-stage module, a baseline,
an optimizer, a saved file, and a supervised server. From here, follow the
task in front of you.

## Coming from DSPy

[Coming from DSPy](../coming-from-dspy.md) maps DSPy's names to Imp's and says
where the two differ.

## Keep the common calls at hand

The [cheatsheet](../cheatsheet.cheatmd) has the calls from this guide, and a
few more, on one page.

## Go deeper on a piece

Each page in Diving deeper takes one idea from this guide and explains why it
works the way it does:

- [Signatures](../diving-deeper/signatures.md): types, constraints, and how
  a signature is checked.
- [Adapters](../diving-deeper/adapters.md): how a signature becomes messages,
  and a reply becomes fields.
- [Modules and composition](../diving-deeper/modules-and-composition.md): the
  built-in modules, and writing your own.
- [Tools and MCP](../diving-deeper/tools-and-mcp.md): tools, policies, and MCP
  servers.
- [Retrieval](../diving-deeper/retrieval.md): retrievers, retrieval before a
  prediction, and search as a tool.
- [ReAct](../diving-deeper/react.md): how the agent loop runs and ends.
- [Metrics and evaluation](../diving-deeper/metrics-and-evaluation.md):
  metrics beyond exact match, and reading an evaluation.
- [Choosing an optimizer](../diving-deeper/choosing-an-optimizer.md): which
  optimizer for which task, and what each costs.
- [Saving and artifacts](../diving-deeper/saving-and-artifacts.md): saved
  programs, and saving only what an optimizer learned.
- [Runs and supervision](../diving-deeper/runs-and-supervision.md): runs you
  can observe, authorize, and cancel.
- [Settings and context](../diving-deeper/settings-and-context.md): defaults,
  `Imp.context/2`, and explicit `lm:`.

The module documentation is the reference for every function.

## Run it in production

[Running Imp in production](../production.md) covers what the last page
began: supervision, provider failures, runs you can observe and cancel, and
telemetry. The [deployment example](https://github.com/deepfates/imp/blob/main/examples/deployment/README.md)
is a complete application to copy from.

## Try it in a notebook

The tutorials are Livebook notebooks that run the same ideas, offline or
with a key: [01](../../livebooks/01_real_lm_front_door.livemd) the first
calls, [02](../../livebooks/02_without_a_provider.livemd) the exact messages
with a scripted model, [03](../../livebooks/03_evaluate_and_optimize.livemd)
evaluation and optimization, [04](../../livebooks/04_tools_agents_mcp_rlm.livemd)
tools, agents and RLM, and [05](../../livebooks/05_operating_imp.livemd)
operating Imp.
