---
id: imp-tg2z
status: open
deps: []
links: []
created: 2026-07-30T22:14:17Z
type: feature
priority: 0
assignee: deepfates
parent: imp-yme4
tags: [optimizers, semantics, dspy, gepa, optimize-anything, ax]
---
# Make every advertised optimizer family substantive and honest

Obstacle: advertised optimizer names do not yet uniformly guarantee their defining mechanism, and broad labels can hide experimental or narrower behavior. Establish an honest stable center without turning Ax into a wholesale port target.

## Acceptance Criteria

Canonical claims classify every advertised family as stable or distinctly experimental. Every stable family reaches its defining state transition through the ordinary public API: proposal, mutation, search, composition, or weight update as applicable; validation selection; an intelligible report; and reusable application. DSPy, GEPA, and Optimize Anything derived families have pinned comparisons of observable inputs, information and evaluation opportunity, stopping, failures, and outputs. Intentional BEAM-native differences are named and exercised for user value rather than private call-graph identity. Ax is used as a competitive lens for ergonomics, concurrency, and failure visibility. Any stable family that falls back to a different hidden algorithm keeps this ticket open. Positive benchmark lift is not required here.

## Implementation checkpoints

- MIPROv2's pinned DSPy 3.2.1 path now continues beyond Optuna's random
  startup into the real multivariate categorical TPE mechanism, with separate
  NumPy-compatible RNG streams and durable surrogate observations. Independent
  Optuna 4.9.0 execution binds startup and first modeled opportunity; longer
  algebraic acquisition ties retain an explicit BEAM floating-point
  tie-breaking deviation rather than an exact trial-tape claim.
- MIPROv2's pinned path no longer forces a zero-shot substitute: it constructs
  and retains DSPy 3.2.1's ordered zero-shot, labels-only, unshuffled, and
  shuffled bootstrap arms, then jointly searches instruction and demo
  variables through the public API. Independent DSPy/Optuna execution binds
  candidate contents and startup parameter order; checkpoints resume the joint
  search without replay. Python hash-based repeated-call trace choice remains
  an explicit BEAM SHA-256 deviation rather than an exact sequence claim.
- MIPROv2's pinned proposer can now use those few-shot arms as proposal
  evidence. Independent DSPy 3.2.1 public compilation matches every summary
  and proposal message plus the shared CPython rollout-ID stream, while the
  ordinary Imp report records which ordered demo arm grounded each candidate.
  Program-aware proposal remains an explicit unsupported boundary rather than
  silently substituting a different information flow.
- BEAM-native program-aware instruction proposal now grounds on public program
  structure by default instead of reading and transmitting ambient module
  source. Bounded module source or caller-owned text requires explicit opt-in,
  and the chosen mode is part of the effective optimizer configuration. This
  is an intentional privacy-oriented product deviation from DSPy's automatic
  source inspection.
- The pinned DSPy 3.2.1 path now executes program-aware proposal rather than
  rejecting it: each candidate receives the real program-description,
  module-description, and instruction-generation call sequence. An independent
  public DSPy compile matches all eight setup messages and shared rollout IDs
  in the focused fixture. Explicit source text is content-bound but redacted
  from durable reports; resume drift fails before LM activity.
- Ordinary program/module-description failures in that pinned path now preserve
  DSPy's ordered sentinel-grounded instruction opportunity instead of aborting
  the compile. The report retains each diagnostic and the actual logical setup
  call count. DSPy's mechanical Chat-to-JSON fallback retry remains adapter
  policy rather than optimizer semantics; Imp's route, cost, budget, transport,
  and cancellation guards remain fatal rather than being contained as proposal
  diagnostics.
- InferRules now preserves the same fail-closed operational boundary through
  rule induction and candidate evaluation, including `max_errors` cancellation
  envelopes. Ordinary proposal/evaluation failures remain visible and
  candidate-local as documented; route, cost, budget, transport, and explicit
  cancellation errors cannot be mistaken for a merely low-scoring rule set.
- SIMBA now enforces that operational boundary at every defining phase:
  stochastic rollout sampling, reflective mutation, candidate evaluation, and
  final validation. Typed safety causes retained inside trajectories, task
  exits, reflection errors, or final rows are raised; ordinary failed
  trajectories remain reportable optimizer evidence.
- The fail-closed distinction now lives at the shared `Imp.Module`,
  `Imp.Evaluate`, and `TrajectoryRunner` boundaries instead of depending on
  optimizer-specific inspection. Typed causes survive sequential and task
  execution plus metric callbacks. COPRO also preserves them through proposal
  fan-out and coordinate evaluation, so its normal error budget cannot absorb
  a hard operational guard.
- The shared `InstructionProposer` and public `SignatureOptimizer` now preserve
  that same boundary. Ordinary malformed/offline proposals can still yield
  explicit fallback candidates, but typed route, cost, budget, transport, and
  cancellation refusals abort before any fallback or task evaluation instead
  of being laundered into a synthetic instruction.
- The canonical `Imp.Optimizer.run/3` dispatcher and `Imp.optimize` facades now
  preserve the typed safety error itself for both raised and returned forms.
  BetterTogether also refuses to turn a guarded child step into an ordinary
  failed prefix, so composed optimization cannot continue after a hard route,
  cost, budget, transport, or cancellation refusal.
