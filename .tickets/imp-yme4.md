---
id: imp-yme4
status: in_progress
deps: [imp-szhr]
links: []
created: 2026-07-25T16:21:13Z
type: epic
priority: 0
assignee: deepfates
tags: [dspy, parity, optimizers, gepa, optimize-anything, product]
---
# Finish Imp as a coherent self-improving programming system

Imp should let an Elixir developer describe a typed LM program, compose it from
multiple predictors and tools, measure it, improve its prompts or weights, keep
the selected result, and operate it as an ordinary supervised BEAM application.
It aims for the useful semantics of current DSPy and its ecosystem, with better
BEAM-native behavior where the runtime offers a real advantage. It is not a
collection of optimizer names, benchmark harnesses, or Python-shaped facades.

## Product pull hypothesis

- **Situation:** an Elixir/OTP team has an LM feature that worked as a prompt
  prototype and must now become a production behavior. The team has examples,
  corrections, or traffic that reveal quality and reliability gaps.
- **Urgent project:** make that behavior measurable, improve it systematically,
  review what changed, and deploy the selected behavior safely in the existing
  application.
- **Options they would otherwise use:** keep hand-maintaining ReqLLM prompt,
  parser, retry, and evaluation glue; operate DSPy/GEPA or Ax in another runtime;
  buy an evaluation/observability tool that does not own the program lifecycle;
  or build an internal compiler and artifact system.
- **Why those options block the project:** manual glue drifts and does not
  produce repeatable selected programs; another runtime splits deployment,
  supervision, credentials, and failure handling; evaluation-only products do
  not connect measurement to optimization and retained deployment; rebuilding
  the stack costs time before the application behavior improves.
- **What Imp must make possible:** one native loop from typed program through
  measurement and optimization to inspectable selected state and supervised OTP
  operation, without hiding provider cost or failure.
- **Who should not choose it:** a team that needs only an unmeasured model call,
  has no examples or behavior it can score, or is already satisfied operating
  the Python/TypeScript alternatives.

This is the current demand hypothesis, not customer-validation evidence. Cold
consumer behavior and external adoption may falsify it; when they do, change
the product story rather than explaining the user away.

## Definition of done

This epic closes only when all of the following are true:

1. A cold consumer can install the distributable package and, using public
   documentation alone, build and evaluate a realistic composed program.
2. Every optimizer advertised as a product capability completes a credible
   successful user story through its defining mechanism and the ordinary public
   API. Learned work uses separate selection and untouched evaluation data.
3. Selected prompt, program, value, or weight state is inspectable, contains no
   credentials, reloads into fresh trusted code, and works after an OS-process
   restart through a concurrent supervised service.
4. Supported providers, structured outputs, streaming, tools, budgets, usage,
   caching, retries, cancellation, and failure reporting behave coherently in
   realistic composed programs. Unsupported behavior fails explicitly.
5. Every material surface in the latest stable DSPy release has an executable
   semantic differential, a tested BEAM-native equivalent, an explicit
   research-only disposition, or an owned implementation defect. Contemporary
   GEPA/Optimize Anything and Ax concepts are judged by the same user-value
   standard rather than copied mechanically.
6. Bounded live comparisons across representative tasks and providers can
   falsify the central functionality. Positive and negative outcomes, costs,
   data boundaries, and selected-state application remain recomputable.
7. README, tutorial, API documentation, package contents, and the release
   procedure describe the same product without workshop context or inflated
   parity, effectiveness, or superiority claims.

A passing package gate, one benchmark, or a frozen candidate cannot substitute
for these outcomes.

## Current reality — 2026-08-22

### Implemented

- Typed signatures, examples, predictions, adapters, Predict/CoT and composed
  modules, tools and agent-style programs, evaluation, public optimizers,
  parameter/value artifacts, provider transport through ReqLLM, and supervised
  operation all exist.
- The defining mechanisms for the advertised DSPy optimizer families are
  present, including modeled categorical TPE for MIPROv2. Optimize Anything has
  a structured arbitrary-artifact path. Local weight-training integrations are
  present but do not define the shared product center.
- An installable `0.3.0` candidate was previously frozen and passed its bounded
  package lifecycle. That is a completed predecessor milestone, not this epic.

### Exercised

- Clean-package install, optimization, Artifact reload, fresh-process service,
  concurrency, cancellation, and provider smoke paths have passed on prior
  exact commits.
- TREC provides scoped positive held-out GEPA/MIPRO evidence. The current
  Optimize Anything campaign provides scoped positive results across code,
  agent configuration, and scheduling artifacts.
- Banking77 and HotPot retain honest treatment-specific negatives. IFBench take
  11 is a terminal instrument stop after optimization/selection, not a held-out
  effectiveness result.

See `docs/EVIDENCE.md` for claim scope and retained results. Historical run
chronology belongs in Git, experiment artifacts, and the bounded research
tickets—not in this active brief.

### Not yet established

- Source-current completion. The latest released authorities observed on
  2026-08-22 are DSPy `3.3.1` (tag commit
  `638e155cf725236fe5d01b5332394a7bc128881d`), GEPA `0.1.4` (tag commit
  `8b0ce6cd99a234f6b74daf37558a2ac0ce18f975`), and Ax `24.0.4` (tag commit
  `a366e49759bd596c8217eca91dfdc9dd8382835d`). Existing Imp differentials
  largely predate those exact surfaces. Current upstream `main` branches may be
  inspected for important fixes and imminent concepts, but are not silently
  promoted into stable compatibility requirements.
- A credible successful retained lifecycle for every optimizer advertised as a
  product capability. Deterministic mechanism tests and another family's
  positive result do not satisfy this.
- Realistic composed operation across materially different providers,
  especially incremental streaming, async/tool failures, cache isolation,
  actual-cost accounting, and selected-artifact application.
- A final adversarial cold-consumer pass and the bounded live comparisons that
  follow its repairs.

No blanket claim of whole-DSPy parity, broad optimizer effectiveness, or Imp
superiority is currently justified.

## Work order

The ticket dependency graph is the operational plan:

1. `imp-7yim` — run a thin clean-consumer spine probe immediately, before the
   broader audits can hide ordinary product friction.
2. `imp-0du1` — audit and implement the latest stable DSPy semantic delta.
3. `imp-nenu` — audit contemporary Optimize Anything and Ax product semantics.
   The two source audits and the early consumer probe can proceed together.
4. `imp-n8zn` — make every advertised optimizer complete a natural retained
   lifecycle. It depends on both audits.
5. `imp-uhp2` — use the early consumer findings to exercise composed programs
   across providers and OTP failures. It can proceed alongside the source
   audits and optimizer lifecycles; the audits inform it rather than gate it.
6. `imp-juni` — run the final adversarial cold-consumer completion pass after
   both product tracks are sound.
7. `imp-szhr` — run bounded representative live comparisons after cold-consumer
   repairs, then rerun the exact candidate gates in
   `docs/maintainers/RELEASE.md`.

Paper-scale Heavy/HoVer campaigns, observatory work, resume-economics research,
and optional local integrations do not block this release unless they expose a
defect in an advertised ordinary path.

## How to work this epic

- Start from a user story and observable behavior. A module name or green
  fixture is not a capability.
- Pin released upstream code, docs, tests, examples, and relevant gold data.
  Compare semantics and opportunity, not private call graphs or source-language
  accidents.
- Treat current upstream issues as adversarial input. Provider drift, streaming
  hangs, tool-call identity, schema loss, cache leakage between splits, usage
  undercounting, and optimized state not being applied are central failure
  classes.
- Classify each red result before acting: product defect, treatment/integration
  defect, valid scientific negative, or unresolved uncertainty. Preserve valid
  negatives, but do not use them to declare an optimizer complete.
- Acquire data and spend just in time for the question. Fixtures prove
  mechanics; representative live tasks prove usefulness; large campaigns are
  reserved for large claims.
- Put durable conclusions in the code, public docs, exact child ticket, or
  immutable experiment that owns them. Do not append chronological status logs
  to this epic or create another dashboard.
- If a discovery changes the dependency order or the product promise, update
  this short current-state section. Otherwise keep the detail in the bounded
  child ticket.

## Start here

1. Read `README.md`, `docs/maintainers/RELEASE.md`, and
   `docs/internal/UPSTREAM_FIDELITY_AUDIT.md`.
2. Run `../ticket/ticket dep tree --full imp-yme4` and
   `../ticket/ticket ready` from this repository.
3. Enter the first ready product child, inspect its pinned upstream and current
   Imp public path, choose the most consequential uncertainty, and falsify it.
4. Do not begin with the old notes in Git history, a research dashboard, or the
   largest available benchmark.

Publication channel, public repository visibility, tag, and Hex publication
remain owner decisions after the product reaches this finish line.
