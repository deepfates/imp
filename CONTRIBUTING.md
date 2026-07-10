# Contributing to DSEx

DSEx aims to be an idiomatic Elixir realization of declarative, self-improving
LM programs. Contributions should preserve that goal rather than reproduce
Python implementation details mechanically.

## Development

Use Elixir 1.19 and OTP 28, then run:

```sh
mix deps.get
mix production.check
mix integration.check
mix protocol.check
mix quality.check
```

Provider-backed and research-scale tests are separate because they require
credentials, external services, canonical datasets, or significant spend. See
`docs/PRODUCTION_OPERATIONS.md` and `docs/UPSTREAM_FIDELITY_AUDIT.md` before
changing a provider, optimizer, benchmark, or fidelity claim.

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
