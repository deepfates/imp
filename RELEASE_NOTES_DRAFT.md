# Imp v0.1.0 — draft release notes (plain-language rewrite)

Imp is a library for programming language models in Elixir. Instead of pasting
prompt strings around your codebase, you declare an LM task as an ordinary
Elixir value — a typed input/output signature, a callable program, examples,
and a metric — and the library handles prompting, parsing, evaluation, and
optimization. It is inspired by DSPy, rebuilt natively for the BEAM: structs,
behaviours, supervision trees, and telemetry rather than a Python port.

## Install

```elixir
{:imp, github: "deepfates/imp", tag: "v0.1.0"}
```

Imp is not on Hex yet; a Hex release is planned.

## What works today

- **Typed programs.** Write `"question -> answer: short_span"`, get a callable
  program with structured, validated output.
- **Swappable providers.** The model provider is a runtime dependency. Develop
  and test deterministically with `Imp.LM.Static`; point the same program at a
  real provider (via ReqLLM) in production without changing its shape.
- **Evaluation.** Examples, metrics, and evaluation reports so you can measure
  a program's behavior instead of eyeballing it.
- **Optimization.** Few-shot selection, instruction search, and
  reflective-mutation optimizers (in the family of DSPy's MIPROv2, SIMBA, and
  GEPA) that measurably improve a program against your metric.
- **Tools and agents.** ReAct-style tool loops, MCP client support, and
  sandboxed code execution.
- **Retrieval.** RAG helpers, including multi-hop.
- **Persistence and operations.** Save and load optimized programs, redact
  credentials from anything serialized, and run under OTP supervision. A small
  deployment example app ships in `examples/deployment`.
- **Runnable docs.** Five Livebook notebooks and a learning path; the code
  snippets in the docs are executed by the test suite, so they cannot silently
  rot.

## What is honestly not done

- **Not on Hex.** Install from the Git tag above.
- **Parity with DSPy is measured, not assumed — and it is not complete.**
  We keep a ledger comparing Imp's behavior against pinned upstream DSPy on
  the same inputs. Where the ledger says a feature matches, that claim is
  backed by a committed, re-runnable comparison. Where it does not, the
  feature may still work, but we do not claim equivalence.
- **Recursive language-model programs (RLM) are structural, not proven at
  paper scale.** The control loop works and is tested deterministically; we
  do not claim the published benchmark results.
- **No performance or cost benchmarks yet.** Optimizer results depend on your
  task, metric, and model; nothing here promises specific quality numbers.
- **APIs may change.** This is a 0.x release; expect breaking changes before
  1.0.

## For contributors

On current `main`, a fresh clone's `mix test` runs the library's test suite
and is green with no extra setup (at the v0.1.0 tag itself this was not yet
true). The maintainer-only checks — the ones that re-validate the
benchmark-evidence ledger against pinned Python DSPy environments and full git
history — are opt-in; see "Maintainer checks" in the README.

Released from commit `e7edc10a0dd0b493b3afddcd556869a370a7647e`.
