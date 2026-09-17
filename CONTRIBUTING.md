# Contributing to Imp

Imp aims to be an idiomatic Elixir realization of declarative, self-improving
LM programs. Contributions should preserve that goal rather than reproduce
Python implementation details mechanically.

## Development

Use Elixir 1.19, OTP 28, Python 3.12, and Deno 2.8.3, then run:

```sh
mix deps.get
scripts/setup_reference_test_env.sh
mix check
mix integration.check
mix protocol.check
mix package.check
mix livebook.execute.check
mix quality.check
mix dialyzer.check
```

Documentation examples are executable and gated: the learning-path snippets
run under `mix test test/learning_path_contract_test.exs`, and
`mix livebook.execute.check` executes every shipped notebook end to end. Keep
both green when changing public examples or notebooks.

Provider-backed and research-scale tests are separate because they require
credentials, external services, canonical datasets, or significant spend.
`.env.example` documents
the supported live-test variables; keep real credentials in an ignored `.env`.

## Maintainer checks

Some benchmark and upstream-differential tests are excluded from the default
`mix test` run (tag `:evidence_infrastructure`). They need the pinned DSPy
Python environments (`scripts/setup_dspy_parity_env.sh` and friends), and in
some lanes a `.env` with provider credentials — neither of which a fresh clone
has. To run them:

```sh
scripts/setup_dspy_parity_env.sh
scripts/setup_dspy_current_target.sh
scripts/setup_reference_test_env.sh
EVIDENCE_INFRASTRUCTURE=1 mix test        # or: mix test --include evidence_infrastructure
```

## Maintainer Authority

Public behavior belongs to code, tests, and user documentation. Pinned upstream
semantics belong to `benchmarks/authorities.json`: the differential harness
reads it before comparing Imp against upstream, and it fails closed when a pin
drifts. Benchmark results belong to whoever ran the harness, in the report the
task writes. Unfinished work is a pull request on a topic branch; there is no
ticket file in this repository.

## Design Standard

- Prefer explicit data, behaviours, supervision, and process isolation.
- Keep ReqLLM as the provider transport boundary.
- Add executable user-story evidence for public behavior.
- Preserve upstream algorithmic semantics when using an upstream name.
- Give deliberate Elixir-native alternatives a distinct contract and rationale.
- Never turn fixtures, smoke tests, or symbol presence into broad parity claims.
- Every published number needs a row in `benchmarks/RESULTS.md` carrying its
  dataset, license, model, provider, date, commit, and the command that
  produces it; `docs/BENCHMARKS.md` says what running that command needs.
- Keep changes focused and update ExDoc or Livebooks with public API changes.

## Pull Requests

Explain the user story, semantic contract, tests, documentation, and any
upstream source or paper involved. Run the applicable local gates and call out
external evidence that could not be reproduced locally.
