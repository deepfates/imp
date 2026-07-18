# Imp Manual

Imp turns language-model work into declared, callable, measurable, improvable
Elixir programs. This manual is organized by what you are trying to do.

## Manual Spine

Every guide and notebook follows the same product story:

1. **Declare** the task as a typed signature.
2. **Run** it as an Imp program through `Imp.call/2`.
3. **Develop** it deterministically with `Imp.LM.Static`.
4. **Measure** behavior with examples, metrics, and evaluation reports.
5. **Improve** the program with optimizers.
6. **Extend** it with tools, retrieval, agents, or RLM only when needed.
7. **Operate** it with ReqLLM, explicit credentials, redaction, telemetry, and
   supervision.

## Start Here

- [Learning Path](LEARNING_PATH.md): the canonical route from your first live
  model call to evaluation, optimization, tools, persistence, and deployment.
- [Ticket Routing Tutorial](TUTORIAL_TICKET_ROUTING.md): build a support-ticket
  router, measure it on held-out data, and improve it with an optimizer —
  real scores, real costs.

## Learn The Model

- [Imp for DSPy Users](IMP_FOR_DSPY_USERS.md): the concept mapping, what is
  deliberately different on the BEAM, and the honest conformance state.

- [Philosophy](PHILOSOPHY.md): the mental model: signatures, programs,
  adapters, examples, metrics, and optimizers.
- [Glossary](GLOSSARY.md): short definitions for Imp vocabulary.
- [Architecture](ARCHITECTURE.md): how the pieces fit together inside the
  library.
- [Prior Art](PRIOR_ART.md): lineage from DSPy, Ax, GEPA, and
  optimize-anything style systems.

## Check The Claims

- [Evidence](EVIDENCE.md): the C0–C5 ladder every Imp claim is graded on,
  and where the ledger stands today.
- [Conformance Report](CONFORMANCE.md): every tracked upstream surface and
  its verification status, generated from executable checks.

## Build With Imp

- [API Guide](API_GUIDE.md): task-oriented examples for normal application
  code.
- [Advanced Imp](ADVANCED.md): artifact optimization, GEPA-style reflection,
  agents, MCP, schemas, and deterministic test doubles.
- [Operations Reference](OPERATIONS_REFERENCE.md): the contract-heavy
  boundaries — durable optimizer resume, provider training-job lifecycle and
  dispatch journals, Fast-Slow training, resumable provider batches, and
  advanced MCP transports.

## Learn By Running Code

The notebooks in `livebooks/` follow the manual spine with runnable code. The
first notebook makes real model calls when `OPENAI_API_KEY` is set and tells
you exactly what to set when it is not.

- [01 Real LM Front Door](../livebooks/01_real_lm_front_door.livemd)
- [02 Programming, Not Prompting](../livebooks/02_programming_not_prompting.livemd)
- [03 Evaluate And Optimize](../livebooks/03_evaluate_and_optimize.livemd)
- [04 Tools, Agents, MCP, Recursive Control](../livebooks/04_tools_agents_mcp_rlm.livemd)
- [05 Operate And Live Checks](../livebooks/05_operate_and_live_checks.livemd)

## Operate It

- [Observability and Debugging](OBSERVABILITY.md): redacted inspection,
  normalized status, progress subscriptions, and trace capture.
- [Production Operations](PRODUCTION_OPERATIONS.md): runtime posture, live
  credentials, secret handling, telemetry, and deployment.

## First Things To Try

1. Run the first live call in the [Learning Path](LEARNING_PATH.md) — five
   minutes with an OpenAI API key.
2. Open [Livebook 01](../livebooks/01_real_lm_front_door.livemd) and extract
   structured data from an email with a real model.
3. Build and improve a program end to end with the
   [Ticket Routing Tutorial](TUTORIAL_TICKET_ROUTING.md) — held-out
   before/after scores for about a cent.
4. Swap your own task into the same shape: change the signature, keep the
   program, add a metric and a dev set from
   [Livebook 03](../livebooks/03_evaluate_and_optimize.livemd).

Maintainer material — fidelity audits, benchmark evidence, parity programs,
and release protocols — lives in the repository's `internal` and `maintainers`
directories under this one. None of it ships in the Hex package, and none of
it is needed to use Imp; the user-facing summary of that work is the
[Evidence](EVIDENCE.md) page and the [Conformance Report](CONFORMANCE.md).
