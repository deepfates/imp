# Working on Imp

Orientation for anyone — person or agent — changing this repository.
`CONTRIBUTING.md` has the gates and the development setup; `decisions.md` has
the rulings that are in force and the condition under which each retires. This
file is the design context those two assume.

## What Imp owns

Language-model behavior as a typed Elixir program: signatures, adapters,
predictors, optimizers, evaluation, training, and the clients that reach models
and local training backends. It is a library, and it runs inside an ordinary OTP
application rather than owning one.

## What Imp does not own

Product-specific characters, accounts, inboxes, or chat threads. Imp includes
the optional `Imp.ACP` program adapter and the generic `Imp.MCP` tool
integration; ExMCP owns both wire protocols. Imp owns typed program/tool
conversion and execution, and the host application owns product lifetimes.
Ordinary Imp startup opens no protocol listeners or remote connections.

## The centre of the model

`Imp.Signature` is the declaration everything else derives from: adapters render
it, schemas validate structured outputs against it, optimizers mutate programs
around it, and persistence stores it as plain data. Thirty-three modules read it.
When something needs to know a program's shape, it should ask the signature
rather than re-describe it.

## Where the boundaries are half-declared

Imp has many `@callback` boundaries, and nearly all of them return
`{:error, term()}`. A reason that is only text is one a caller cannot act on
except by matching it. The `validate_*` functions that return
`{:error, "expected ..."}` are the exception: they are NimbleOptions custom
validators, whose contract is a message string, and their failure reaches a
caller as the `ArgumentError` NimbleOptions raises.

The classes that exist are the ones to extend rather than inventing a new
scheme: `Imp.LMError` carries `status`, `retryable` and
`context_window_exceeded`, read through `Imp.Errors`; `Imp.AdapterParseError`
carries `:kind`; `Imp.OperationalSafetyError` carries `:kind`; and
`Imp.MCP.CallFailure` carries `outcome`. A boundary should name the failure
classes its callers must distinguish, especially anywhere a retry or a spend
decision hangs on the answer, and a reason is a term — the exception struct
itself where there is one — never its message text.

## Process ownership

`Imp.ExternalCommand` runs MLX and TRL training workers, and implements its own
process-group lifecycle on raw ports: TERM, grace, KILL, and a check that the
group is gone. The grace period is the requirement worth preserving — a trainer
SIGKILLed mid-checkpoint loses work.

`Imp.MCP.OwnedStdio` runs local MCP servers through erlexec instead: each server
leads its own process group, and stopping it sends the group TERM, waits the
`kill_timeout`, then sends KILL. That is the same shape with the grace period
kept, so `ExternalCommand` could move onto erlexec; until it does, the two are a
documented divergence (`decisions.md`) rather than an accident.

## Protocol integration

`Imp.MCP.connect/2` opens explicitly authorized server descriptors through
ExMCP. Its clients follow an explicit owner PID; tools retain original source
identity in `metadata.mcp`, independently of model-facing names. `Imp.ACP.MCP`
adds ACP presentation hints to that import; it is not another client.
ExMCP is the Hex package, unpatched. Where Imp needs something ExMCP does not
do — owned stdio process groups, trust for authorized remote origins, the HTTP
options public servers need, the browser OAuth flow — Imp does it in its own
module, with the reason and the condition that retires it written there.

`Imp.ACP` owns the default session/program adapter formerly shipped separately
as the `imp_acp` package. Its namespace stays stable, but consumers depend on
Imp directly. `docs/PRODUCTION_OPERATIONS.md` describes the MCP lifecycle and
API migration.

## Checks

`mix check` is the default merge signal and needs no credentials. Provider-backed
and research-scale runs are deliberately separate because they need credentials,
datasets or spend. Keep that separation — a green default run is not evidence
about a fidelity claim.
