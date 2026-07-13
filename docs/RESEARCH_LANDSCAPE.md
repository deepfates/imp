# Research Landscape

This note records the outside view used to shape DSEx. It separates scientific
authorities, implementation comparators, production complements, and recent
work that is promising but too new to become a release claim.

The review was refreshed on 2026-07-12. Moving repositories must still be
re-pinned before their behavior is used in a differential gate.

## Current GEPA And Optimize Anything Snapshot

The released implementation authority is GEPA `v0.1.1` at
`b4dbb55b7601dac448cdb836d5a401ca7d9eb920`. Optimize Anything was introduced
in `v0.1.0`; by `v0.1.1` it already included the unified single-task,
multi-task, and held-out generalization modes, seeded and seedless operation,
string or named-component candidates, objective and background context, typed
and image side information, refiners, content-addressed evaluation caching,
merge, configurable selection/batching/evaluation policies, stopper protocols,
callbacks, experiment tracking, four frontier types, and durable run state.
These are released requirements, not speculative post-release ideas.

The accompanying paper is
[arXiv:2605.19633v1](https://arxiv.org/abs/2605.19633), DOI
`10.1145/3786335.3813167`. Its reproduction repository is pinned at
[`58cdf89d856f2fbc174991b89076eccdcf68e4ca`](https://github.com/gepa-ai/optimize-anything-artifact/commit/58cdf89d856f2fbc174991b89076eccdcf68e4ca).
The paper distinguishes multi-task search, which returns a specialized winner
for each related task, from generalization, which returns one artifact selected
on a held-out validation set.

GEPA `main` at `92dadfffbe98c8ecf508179a1cab09c1bb85cd32` is 68 commits beyond the
release but still reports package version `0.1.1`. Its material unreleased
deltas are richer callback and tracker events, dynamic trainsets, opaque adapter
checkpoint state, configurable strict/equal/custom acceptance, concurrent
proposal pipelines with sequential acceptance, refiner and reflection cost
accounting, a unified retrying LM layer, `ConfidenceAdapter`, and a LangChain
adapter. The release pin defines parity; this moving snapshot defines a separate
forward-compatibility horizon and must not silently replace the release.

## Where The Work Comes From

DSPy grew from Omar Khattab's Stanford NLP work with Christopher Potts, Matei
Zaharia, and collaborators. Khattab is now at MIT EECS and CSAIL. The research
line connects retrieval with ColBERT, declarative LM programs with DSP and DSPy,
joint prompt optimization with MIPRO, reflective Pareto search with GEPA, and
recursive or harness-level optimization in newer work.

The useful lineage is broader than one lab:

1. [AutoPrompt](https://aclanthology.org/2020.emnlp-main.346/) established
   discrete prompt search using model gradients.
2. [LMQL](https://arxiv.org/abs/2212.06094) treated prompting as a constrained
   programming and execution problem.
3. [DSP](https://arxiv.org/abs/2212.14024) introduced
   Demonstrate-Search-Predict and pipeline-aware demonstration bootstrapping.
4. [ProTeGi](https://arxiv.org/abs/2305.03495),
   [OPRO](https://arxiv.org/abs/2309.03409), and
   [PromptBreeder](https://arxiv.org/abs/2309.16797) developed textual feedback,
   LM-guided search, and evolutionary mutation.
5. [DSPy](https://openreview.net/forum?id=sY5N0zY5Od) combined signatures,
   modules, traces, metrics, evaluation, and optimizers into a declarative
   programming model.
6. [MIPRO](https://arxiv.org/abs/2406.11695v2) jointly optimized instructions
   and demonstrations with grounded proposals and surrogate-guided search.
7. [TextGrad](https://arxiv.org/abs/2406.07496) generalized textual feedback
   over compound computation graphs, while
   [BetterTogether](https://arxiv.org/abs/2407.10930) combined prompt and weight
   optimization.
8. [GEPA](https://arxiv.org/abs/2507.19457v2) added full-trajectory reflection,
   Pareto candidate selection, and candidate merging.
9. [Dynamic Cheatsheet](https://arxiv.org/abs/2504.07952) and
   [ACE](https://arxiv.org/abs/2510.04618) moved toward persistent, incrementally
   curated strategy context.
10. Recent work such as [MCE](https://arxiv.org/abs/2601.21557),
    [Combee](https://arxiv.org/abs/2604.04247),
    [SkillOpt](https://arxiv.org/abs/2605.23904), and
    [VISTA](https://arxiv.org/abs/2603.18388) explores co-evolving optimizer
    skills, parallel trace learning, bounded edits, and verification-first
    alternatives. [PrefPO](https://arxiv.org/abs/2603.19311) adds label-free
    pairwise preference optimization and evaluates prompt repetition and reward
    hacking, while [JTPRO](https://arxiv.org/abs/2604.19821) jointly optimizes
    agent instructions and named tool-schema parameters. These are design inputs
    that require explicit adjudication; they are not established parity targets.
11. [Prompt Optimization Is a Coin Flip](https://arxiv.org/abs/2604.14585)
    reports frequent negative lift in compound systems and proposes inexpensive
    headroom and interaction diagnostics before optimization. Its result is a
    direct warning against treating an optimizer run as inherently useful and
    belongs in DSEx's campaign and promotion design even if its exact diagnostic
    is not adopted.

SIMBA is different from the paper-backed entries above. No authoritative
standalone SIMBA paper was located. Its released DSPy source, adjacent tests,
documentation, pull requests, and release history are therefore its behavioral
authorities. DSEx must not describe source fidelity as SIMBA paper parity.

## Repositories And Roles

| System | Role for DSEx | Pin or authority policy |
| --- | --- | --- |
| [DSPy](https://github.com/stanfordnlp/dspy) | Primary compatibility authority for signatures, modules, runtime semantics, and named optimizers. | Pin an exact release, commit, source hashes, and relevant tests for each claim. Current instruction-optimizer gates use `3.3.0b1` at `b2829b7ae3b6e276ac6a8bef66a7ec519dbc923f`. |
| [GEPA](https://github.com/gepa-ai/gepa) | Primary standalone implementation authority for generic reflective text optimization. | Release `v0.1.1` resolves to `b4dbb55b7601dac448cdb836d5a401ca7d9eb920`. Current `main` is separate and must not silently replace the release pin. |
| [Ax](https://github.com/ax-llm/ax) | Strongest independent implementation comparator for a typed TypeScript interpretation of DSPy-style programming. | Release `23.0.0` resolves to `eb5835e54ba0c5b2fbac380daed1cb87faeefd5e`. Use for API and behavioral comparison, not as scientific authority. |
| [BAML](https://github.com/BoundaryML/baml) | Comparator for compiler diagnostics, generated typed clients, and partial structured streaming. | Study its contracts; do not add a separate DSEx language unless Elixir modules and macros are demonstrably insufficient. |
| [AdalFlow](https://github.com/SylphAI-Inc/AdalFlow), [TextGrad](https://github.com/zou-group/textgrad), and [SAMMO](https://github.com/microsoft/sammo) | Comparators for explicit parameter graphs, textual feedback, and structure-aware prompt transformations. | Borrow mechanisms only after pinning code and paper protocols independently. |
| [ReqLLM](https://github.com/agentjido/req_llm) | Preferred BEAM provider substrate. | Release `v1.17.1` resolves to `33840077c2f1332eb6dff2d268dff02393014da4`. Integrate its provider, multimodal, tool, stream, usage, error, and telemetry contracts instead of rebuilding them. |
| [Jido](https://github.com/agentjido/jido) and [Jido AI](https://github.com/agentjido/jido_ai) | Optional deployment and long-running-agent complements. | Study immutable state, explicit effects, supervision, and signals without making their agent model mandatory. |
| [LangGraph](https://github.com/langchain-ai/langgraph), [Pydantic AI](https://github.com/pydantic/pydantic-ai), [MLflow](https://mlflow.org/docs/latest/genai/prompt-registry/optimize-prompts), and [Promptfoo](https://github.com/promptfoo/promptfoo) | Production references for checkpoints, durable execution, registries, eval matrices, and adversarial testing. | Treat as operational comparators, not optimizer parity authorities. |

## Architectural Conclusion

The durable core is a typed textual parameter system, not a collection of
optimizers that only know about one instruction string. A parameter may hold an
instruction, demonstrations, a tool description, retrieval policy, context
playbook, skill document, code fragment, schema, or program configuration.

That system needs:

- stable component identities and typed values;
- immutable candidates with parentage, provenance, and content hashes;
- complete component-level trajectories and actionable feedback;
- pluggable proposal, mutation, merge, selection, and promotion policies;
- scalar, structured, and textual metrics;
- held-out evaluation and strict promotion gates;
- population, Pareto, archive, and rejected-edit state;
- incremental edits as well as whole-value replacement;
- deterministic aggregation over bounded parallel work;
- resumable checkpoints, schema migration, secret sanitization, and rollback.

This is compatible with the current Elixir design. `DSEx.ProgramParameters`,
optimizer reports, explicit random state, trajectories, GEPA archives, and
save/load boundaries are the beginning of that system. The next step is to make
their shared contract explicit without flattening MIPROv2, SIMBA, GEPA, and
future optimizers into one generic state machine.

Combee's emphasis on parallel scans, batching, and trace processing is
especially relevant to the BEAM. OTP can provide bounded concurrency,
backpressure, cancellation, supervision, and fault isolation, but those runtime
advantages count only when algorithmic behavior and effectiveness remain
measurable against pinned authorities.

## What Changes The Roadmap

P0 work on the current finish line:

1. Finish and execute the MIPROv2/SIMBA structural differential.
2. Complete the six-family GEPA campaign with exact release, artifact, dataset,
   model, metric, budget, seed, cost, and uncertainty metadata.
3. Make GEPA's parameter identities, Pareto state, merge lineage, checkpoints,
   and immutable results reusable below DSPy-shaped adapters.
4. Establish one canonical typed trajectory for text, multimodal values,
   reasoning, tools, errors, usage, latency, cache identity, and evaluator
   feedback.
5. Complete durable optimizer artifacts: inspect, compare, apply, rollback,
   champion/challenger, migrate, and prove secret absence.

P1 work after those blockers:

1. Add pinned Ax differentials where a second implementation reduces the risk
   of copying accidental DSPy behavior.
2. Add operational failure campaigns for cancellation, timeout, retries,
   partial streams, checkpoint resume, idempotency, process failure, and
   concurrency limits.
3. Add persistent playbook or context parameters inspired by Dynamic Cheatsheet
   and ACE without creating an incompatible learning subsystem.

MCE, Combee, SkillOpt, VISTA, PrefPO, JTPRO, Fast-Slow Training, and
harness-level optimization follow the pinned core implementation in execution
order. They remain part of the full telos through `de-s8uv` and their dedicated
tickets: each mechanism must be pinned, tested at the decision-relevant level,
and then integrated, represented by a concrete extension contract, or rejected
with evidence and a revisit trigger. This sequencing prevents moving preprints
from destabilizing the core while also preventing “future research” from
becoming an informal out-of-scope bucket.

## Claim Discipline

- Architectural inspiration may cite the broader ecosystem.
- Behavioral parity requires a fresh differential against a pinned authority.
- Effectiveness requires matched datasets, models, budgets, multiple seeds,
  uncertainty, cost, and held-out evaluation.
- A paper result applies only to its exact protocol and revision.
- GEPA-vs-RL claims apply to the reported GRPO configurations, not to
  reinforcement learning in general.
- Recent preprints are hypotheses to test, not headline numbers to repeat.
- Exact cross-language RNG sequences are not implied when runtimes use different
  random generators.
- No moving branch, project README, or algorithm name is evidence by itself.
