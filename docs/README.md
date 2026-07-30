# Imp Manual

Imp turns language-model work into typed, measurable Elixir programs. The
manual starts with one program and adds complexity only when the program needs
it.

## Learn the complete path with one example

Start with the [Learning Path](LEARNING_PATH.md). It grows a support-ticket
router through the sequence most Imp applications follow:

1. **Declare** named inputs and typed outputs.
2. **Run** the program against a real model.
3. **Test** the same program without a provider.
4. **Measure** it with examples and a metric.
5. **Improve** it with an optimizer.
6. **Extend** it with tools, retrieval, or a larger program only when needed.
7. **Operate** the selected program under OTP.

The [Ticket Routing Tutorial](TUTORIAL_TICKET_ROUTING.md) slows down at the
optimization step. It shows the data split, baseline, optimized result, cost,
and selected program rather than presenting optimization as a magic button.

## Understand the ideas before choosing advanced features

- [API Guide](API_GUIDE.md) explains signatures, programs, predictions,
  examples, metrics, optimizers, experiments, and artifacts through normal
  application code.
- [Imp for DSPy Users](IMP_FOR_DSPY_USERS.md) maps DSPy concepts to Imp and
  explains which differences come from the BEAM.
- [Glossary](GLOSSARY.md) gives short definitions for Imp's vocabulary.
- [Philosophy](PHILOSOPHY.md) explains why Imp treats prompts and learned
  parameters as data attached to programs.
- [Architecture](ARCHITECTURE.md) is for readers who need to understand the
  library's internal shape.
- [Prior Art](PRIOR_ART.md) covers DSPy, GEPA, Ax, and Optimize Anything.

## Build the part your application needs

- [API Guide](API_GUIDE.md) — normal program construction and use.
- [Advanced Imp](ADVANCED.md) — less common program and optimizer surfaces.
- [Operations Reference](OPERATIONS_REFERENCE.md) — durable resume, provider
  training jobs, batches, and protocol-owned lifecycle details.
- [Observability and Debugging](OBSERVABILITY.md) — traces, redaction,
  progress events, and inspection.
- [Production Operations](PRODUCTION_OPERATIONS.md) — credentials,
  supervision, concurrency, and deployment.

The generated module reference is the exhaustive API inventory. The guides
teach why and when to use the public surface; they are not meant to repeat
every function signature.

## Run the examples

The Livebooks follow the same progression as the written guide:

- [01 Real LM Front Door](../livebooks/01_real_lm_front_door.livemd)
- [02 Programming, Not Prompting](../livebooks/02_programming_not_prompting.livemd)
- [03 Evaluate And Optimize](../livebooks/03_evaluate_and_optimize.livemd)
- [04 Tools, Agents, MCP, Recursive Control](../livebooks/04_tools_agents_mcp_rlm.livemd)
- [05 Operate And Live Checks](../livebooks/05_operate_and_live_checks.livemd)

The first notebook uses a real provider when `OPENAI_API_KEY` is present and
explains what to set when it is not. The others include provider-free paths so
you can inspect the program mechanics without spending money.

The [OTP deployment example](../examples/deployment/README.md) shows the
application boundary: a two-stage program, disjoint selection and test data,
a saved parameter artifact, a fresh-process load, concurrent service, hot
reload, and contained worker failure.

## Read research evidence separately from product guidance

Most users do not need the repository's compatibility and research records to
build an application. When you do need to audit a claim:

- [Conformance](CONFORMANCE.md) describes the observable upstream behavior
  currently compared with DSPy and related projects.
- [Evidence](EVIDENCE.md) links narrowly worded research claims to their
  retained results.

Maintainer protocols, benchmark machinery, and release procedures live under
`docs/internal/` and `docs/maintainers/`. They support the user-facing docs;
they are not part of the learning path.
