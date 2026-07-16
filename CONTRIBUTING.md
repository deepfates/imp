# Contributing to Imp

Imp aims to be an idiomatic Elixir realization of declarative, self-improving
LM programs. Contributions should preserve that goal rather than reproduce
Python implementation details mechanically.

## Development

Use Elixir 1.19, OTP 28, Python 3.12, and Deno 2.8.3, then run:

```sh
mix deps.get
scripts/setup_reference_test_env.sh
mix production.check
mix integration.check
mix protocol.check
mix quality.check
```

Provider-backed and research-scale tests are separate because they require
credentials, external services, canonical datasets, or significant spend. See
`docs/maintainers/RELEASE.md` and `docs/maintainers/EVIDENCE.md` before changing
a provider, optimizer, benchmark, or fidelity claim.

## Maintainer Authority

The repository authority order is deliberately narrow:

1. `benchmarks/claims.json` declares claim scope and proof obligations.
2. `benchmarks/authorities.json` pins reference behavior.
3. `benchmarks/reproductions.json` declares protocols and admitted artifacts.
4. `mix benchmark.dashboard` computes evidence and profile readiness.
5. `tk` owns unfinished work, dependencies, and priorities.

Markdown explains contracts and methods; it does not maintain a parallel status
or roadmap. Start with `docs/maintainers/CLAIMS.md`,
`docs/maintainers/AUTHORITIES.md`, `docs/maintainers/REPRODUCTIONS.md`, and
`docs/maintainers/RESEARCH_PROTOCOLS.md`.

## Design Standard

- Prefer explicit data, behaviours, supervision, and process isolation.
- Keep ReqLLM as the provider transport boundary.
- Add executable user-story evidence for public behavior.
- Preserve upstream algorithmic semantics when using an upstream name.
- Give deliberate Elixir-native alternatives a distinct contract and rationale.
- Never turn fixtures, smoke tests, or symbol presence into broad parity claims.
- Keep changes focused and update ExDoc or Livebooks with public API changes.

## Pull Requests

Explain the user story, semantic contract, tests, documentation, and any
upstream source or paper involved. Run the applicable local gates and call out
external evidence that could not be reproduced locally.
