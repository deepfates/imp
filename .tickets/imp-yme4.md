---
id: imp-yme4
status: closed
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
  operation form one public lifecycle.
- The defining mechanisms for the advertised DSPy optimizer families are
  present, including modeled categorical TPE for MIPROv2. Optimize Anything
  optimizes structured arbitrary artifacts and Playbooks make verified changes
  reusable. GRPO remains explicitly experimental rather than being counted as
  a finished product optimizer.
- ReActV2 and RLM share the typed program/evaluation path and can run through an
  addressable, observable, cancellable execution boundary. External tool
  authorization is explicit, source-owned, and fail-closed.

### Exercised

- A package-only consumer has repeatedly completed typed composition, disjoint
  evaluation and optimization, result inspection, Artifact reload across VMs,
  tamper rejection, fresh OTP release startup, concurrent service, cancellation,
  crash containment, and recovery without the maintainer checkout.
- Natural live lifecycles now cover every optimizer advertised as a product
  capability, with separate selection and held-out data, retained costs and
  failures, parameter Artifacts, and fresh-state application. The exercised
  portfolio includes prompt, demonstration, rule, population, ensemble,
  finetuning, and arbitrary structured-artifact mechanisms.
- Real OpenRouter and local Ollama routes have executed typed, composed,
  streaming, tool-using, ReActV2, RLM, and cross-provider selected programs.
- The final bounded live tutorial repeats improved held-out routing from
  0.50/0.35/0.30 to 0.95/1.00/0.95. The compact pinned-DSPy TREC recomputation
  independently reproduces GEPA +0.4000, MIPROv2 +0.1458, and an Imp-minus-DSPy
  GEPA difference of -0.0083 for that frozen task.
- Optimize Anything retains positive results across retry code, agent
  configuration, and scheduling. Banking77, HotPot, local SIMBA/GRPO, classic
  ReAct model-adherence, and the stopped IFBench rehearsal retain their scoped
  negative or unresolved classifications rather than being euphemized away.

See `docs/EVIDENCE.md` for claim scope and retained results. Historical run
chronology belongs in Git, experiment artifacts, and the bounded research
tickets—not in this active brief.

### Release boundary

The stable source authorities for this cut are DSPy `3.3.1` (tag commit
`638e155cf725236fe5d01b5332394a7bc128881d`), GEPA `0.1.4` (tag commit
`8b0ce6cd99a234f6b74daf37558a2ac0ce18f975`), and Ax `24.0.4` (tag commit
`a366e49759bd596c8217eca91dfdc9dd8382835d`). Their material user-facing
semantics have executable differentials, BEAM-native implementations, or an
explicit product disposition in the source audit.

An adversarial cutover review reopened and then completed the last stable
product obligation: provider streaming now executes normal composed modules,
observes selected fields at named intermediate predictors, and returns the
typed final prediction. This closes the library-making epic, not every future
research program.

Paper-scale matched breadth, resume economics, observatory work, broader GRPO
effectiveness, external adoption, and blanket superiority remain separate work.
Publication channel, public repository visibility, final SemVer, tag, and Hex
publication remain owner decisions. Release claims must stay at the scale of
the retained product and task-specific evidence.

## Cutover

The dependency-ordered capability work is complete: early cold consumption,
stable-source audits, optimizer lifecycles, realistic provider/OTP operation,
final cold consumption, bounded comparison, and the adversarial
composed-streaming repair all closed on their own acceptance criteria. Freeze
this exact state and rerun the candidate gates in
`docs/maintainers/RELEASE.md`; if a gate falsifies the candidate, repair that
concrete defect and repeat.

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

## Notes

**2026-08-22T21:35:30Z**

Closed literally after all seven definition-of-done limbs were exercised and the dependency chain reached terminal: stable DSPy/GEPA/Ax/OA audits, real defining optimizer lifecycles, explicit experimental GRPO boundary, cross-provider/stream/tool/RLM/OTP operation, repeated package-only cold consumption, and bounded positive plus negative live comparison. The exact release candidate still must survive docs/maintainers/RELEASE.md gates; a red gate reopens the owning defect rather than changing this verdict by rhetoric.

**2026-08-22T21:04:00Z**

Reclosed after the cutover review falsified the earlier composed-streaming
disposition and the implementation was completed rather than bounded away.
The real OpenRouter two-stage path streams both named predictors and returns its
typed result; cancellation, dead-consumer cleanup, provider error, usage, and
single-worker backpressure regressions pass. The full non-live suite is 2,771
tests, 54 doctests, and 9 properties with zero failures; the 16-test live gate,
integration, protocols, package clean room, executable livebooks, public
surface, conformance, Credo, Hex audit, and Dialyzer are green on the candidate
tree. Exact clean-commit identity and publication remain the release procedure,
not unfinished library capability.
