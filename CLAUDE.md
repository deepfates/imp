# Working on Imp

Read this before changing anything here. The workshop's `AGENTS.md` has the
idioms these repositories share; this file is what is specific to Imp.

## What Imp owns

Language-model behavior as a typed Elixir program: signatures, adapters,
predictors, optimizers, evaluation, training, and the clients that reach models
and local training backends. It is a library, and it runs inside an ordinary OTP
application rather than owning one.

## What Imp does not own

Protocols. Imp has no ACP and no notion of an agent session, a host, or a
conversation. `imp_acp` adapts an `Imp.Module` to a host over ACP; `dwell` gives
an inhabitant continuity and character. Neither belongs inside Imp, and Imp
should not grow an opinion about either.

## The centre of the model

`Imp.Signature` is the declaration everything else derives from: adapters render
it, schemas validate structured outputs against it, optimizers mutate programs
around it, and persistence stores it as plain data. Thirty-three modules read it.
When something needs to know a program's shape, it should ask the signature
rather than re-describe it.

This is the strongest instance of "declare once, derive everything" in the
constellation, and it is the pattern the other repositories are measured against.

## Where the boundaries are half-declared

Imp has more `@callback` boundaries than any other repository here — and nearly
all of them return `{:error, term()}`. Some paths return bare strings
(`{:error, "expected an LM module exporting generate/2"}`), which a caller cannot
act on except by matching text.

The classification instinct is already present: `Imp.Exceptions` carries
`retryable`, and `Imp.OperationalSafetyError` carries `:kind`. Extend that to the
behaviours rather than inventing a new scheme — a boundary should name the
failure classes its callers must distinguish, especially anywhere a retry or a
spend decision hangs on the answer.

## Process ownership

`Imp.ExternalCommand` runs MLX and TRL training workers, and implements its own
process-group lifecycle on raw ports: TERM, grace, KILL, and a check that the
group is gone. The grace period is the requirement worth preserving — a trainer
SIGKILLed mid-checkpoint loses work — and it is the reason Imp cannot simply
adopt `ExMCP.Internal.OwnedProcess`, which stops the root process before
signalling and so can never deliver a handleable TERM.

If that consolidation happens, graceful shutdown is a precondition, not a
follow-up. Until then this is a documented divergence rather than an accident.

## Imp also contains an MCP client

`lib/imp/mcp.ex` speaks MCP over HTTP, stdio and Streamable HTTP with SSE, with
its own retry and backoff, and does not depend on `ex_mcp`. `imp_acp` uses
`ExMCP.Client` for the same job while using `Imp.MCP` only for schema and result
shaping, so a host running both has two MCP client implementations in one BEAM.
That is a known duplication, not a design; nothing should be built on the
assumption that it stays that way.

## Checks

`CONTRIBUTING.md` lists the gates. `mix check` is the default; provider-backed,
research-scale and evidence-infrastructure runs are deliberately separate
because they need credentials, datasets or spend. Keep that separation — a green
default run is not evidence about a fidelity claim.
