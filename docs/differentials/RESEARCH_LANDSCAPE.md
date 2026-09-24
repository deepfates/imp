# Research Landscape — 2026-08-06 Review

This dated note records the outside view used to shape Imp. It separates
scientific authorities, implementation comparators, production complements,
and recent work that was promising but too new to become a release claim.

It is evidence of what was reviewed on 2026-08-06, not a current authority
registry or roadmap. Moving repositories must still be re-pinned before their
behavior is used in a differential gate; current pins live in
`benchmarks/authorities.json`.

## Current GEPA And Optimize Anything Snapshot

DSPy `3.3.1` is the current stable authority at commit `638e155c`. Imp's
reviewed baseline now binds that exact source tree and public API inventory.
Earlier 3.2.1, 3.3.0b1, and 3.3.0 differentials remain valid only for their
declared treatments. Stable 3.3.1 includes ReActV2, normalized LM envelopes,
resource and adapter changes, and the explicitly experimental `Flex` code
optimization module. Imp has no admitted Flex equivalent today; its existing
Optimize Anything code-artifact machinery is relevant prior art, not a parity
claim or proof of current-DSPy superiority.

The current released implementation authority is GEPA `v0.1.4` at
`8b0ce6cd99a234f6b74daf37558a2ac0ce18f975`. That tag still reports package
version `0.1.3` in `pyproject.toml`; the ledger records tag identity and source
identity separately. Optimize Anything was introduced in `v0.1.0`; by
`v0.1.1` it already included the unified single-task,
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

The `v0.1.4` release incorporates the material post-`v0.1.1` surface: a
`ReflectionLM` protocol, batched parallel proposal generation with sequential
acceptance, configurable acceptance strategies, reflection-cost accounting,
richer callbacks and experiment tracking, `ConfidenceAdapter`, and a LangChain
adapter. The exact `v0.1.1` checkout remains a historical executable contract
for the existing provider-free differential; it no longer defines the current
public compatibility horizon.

The moving GEPA documentation now centers the engine-pluggable
`optimize_anything` API and lists adapters for full DSPy programs, RAG, MCP,
and terminal agents in addition to predictor-level prompt optimization. Those
development docs are landscape evidence, not a new immutable release pin. They
do change the strategic interpretation: the historical six-family table is a
recognizable and valuable optimizer comparison, but it is not a census of the
current GEPA ecosystem or evidence of whole-framework superiority.

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
    belongs in Imp's campaign and promotion design even if its exact diagnostic
    is not adopted.

SIMBA is different from the paper-backed entries above. No authoritative
standalone SIMBA paper was located. Its released DSPy source, adjacent tests,
documentation, pull requests, and release history are therefore its behavioral
authorities. Imp must not describe source fidelity as SIMBA paper parity.

## Fast-Slow Training

The primary authority is [*Learning, Fast and Slow: Towards LLMs That Adapt
Continually*, arXiv:2605.12484v2](https://arxiv.org/abs/2605.12484), supplemented
by the [official GEPA project
article](https://gepa-ai.github.io/gepa/blog/2026/05/11/learning-fast-and-slow/).
Algorithm 1 alternates two different adaptation timescales in this order:

1. Prefetch the next `T` slow-learning minibatches from the continual stream.
2. Hold the current policy parameters and reflection LM fixed while GEPA performs
   fast prompt adaptation, then retain a `K`-member per-instance Pareto prompt
   population. The initial population is the singleton seed prompt, not `K`
   copies of it.
3. For each question, collect exactly `G` rollouts, allocating `G / K` rollouts
   to each retained prompt (`K` must divide `G`). Normalize rewards once across
   the complete cross-prompt group of `G` rollouts; prompt-local normalization
   would change the learning signal.
4. Keep that prompt population fixed while applying exactly `T` slow policy
   updates, one for each prefetched minibatch, and only then begin the next GEPA
   cycle with the updated policy.

Thus `T` is the number of slow updates per GEPA cycle, `K` is the active Pareto
prompt-population size after fast adaptation, and `G` is the total rollout group
size per question, not a per-prompt count. The current policy supplies rollout
probabilities and is frozen during the fast phase; the reflection LM proposes
prompt changes and is also frozen. During the slow phase the policy changes,
but the selected prompts do not.

The paper's rollout reuse optimization does not make trajectories
interchangeable. A reused GEPA trajectory must remain bound to its cycle,
behavior-policy identity, problem/input, exact prompt, output and reward, with
the response token IDs, mask, and behavior-policy token log-probabilities needed
for the slow update. Reuse is a single-claim operation within that cycle; stale,
duplicate, or mismatched trajectories must fall back to a fresh rollout rather
than silently altering the off-policy ratio or advantage group.

Imp treats this as a paper-ordered Elixir/BEAM orchestration adaptation, not
source parity: the official code page still said “code coming soon” at this
review. Its explicit immutable cycle state, sequential deterministic rollout
planning, durable operation intent, operation budget, event ledger, and
checkpoint recovery preserve the ordering and statistical groups above. The
slow phase ends at a backend handoff: Imp does not bundle or verify the CISPO
loss, gradients, optimizer step, or resulting model weights. This section does
not establish end-to-end provider evidence or claim that the Imp implementation
is a paper reproduction. Revisit the design and parity status when first-party
code, a revised paper, or an official executable artifact is released.

## Weight-Training Engines

Imp's supported local MLX path is supervised fine-tuning and fused-model
deployment. It does not supply a GRPO updater. Two distinct candidates were
inspected for that later boundary; neither is currently installed or bundled.

[TRL `v1.6.0`](https://github.com/huggingface/trl/releases/tag/v1.6.0), pinned
at `0dac440542c2ef9b575f56534f29f6fca1febe4a`, is the preferred production
engine candidate. Its GRPO trainer performs causal-LM gradient updates,
supports PEFT/LoRA and durable checkpoints, and gives reward functions the
prompts, completions, completion token IDs, and additional dataset columns.
It has the more mature implementation and test surface, but it is an external
Python/GPU stack. Apple/MPS feasibility has not been established and must not
be inferred from isolated MPS fixes in its release history.

[`mlx-lm-lora` `v3.0.0`](https://github.com/Goekdeniz-Guelmez/mlx-lm-lora/tree/v3.0.0),
pinned at `fb4f39db66fadec3b71a41441e863d9f1bf87844`, is the experimental
Apple-local candidate. Its GRPO trainer really computes grouped rewards,
advantages, loss, gradients, optimizer updates, adapter checkpoints, and
resume state. Adoption is blocked on exact dependency pinning, loss and resume
differentials, artifact validation, and resolution of a license-metadata
contradiction (the repository license and package declaration differ). It also
loads arbitrary reward Python and invokes reward functions once for scores and
again for metrics. A scorer with effects or cost would therefore be duplicated
unless a controlled shim used content-bound idempotent caching; that workaround
would not substitute for correcting or pinning the engine behavior.

Imp now defines the first version of that narrow data protocol rather than an
arbitrary Python callback. A pinned-TRL session binds the ordered dataset and
prompt schedule, base-model and tokenizer identities, optimizer configuration,
and initial RNG. Each immutable update binds session/update/batch identifiers,
ordered groups, rendered prompts, completion text, prompt/completion token IDs
and masks, behavior log probabilities, finite external rewards, trainer step,
optimizer/RNG identities, and a canonical payload hash. Exact replay returns
the existing receipt; missing, reordered, or same-id/different-content updates
fail closed. Checkpoint, receipt, update, and final artifact manifests form a
content-verified chain that `TrainingJob.rebind/3` rechecks before installing a
TRL artifact in another program.

A deterministic no-model conformance server exercises this contract through
the ordinary public GRPO lifecycle, including accepted-then-disconnected
reconciliation and fresh-process job/program load and rebind. It changes only a
synthetic content-addressed artifact. No Python worker, TRL/PyTorch runtime,
tokenizer, causal model, GRPO loss, gradient, or real weight change exists yet.
Those remain the next engine slice; this protocol cannot establish GRPO or
mmGRPO parity, training effectiveness, Apple/MPS feasibility, or deployable
model behavior.

This inspection recommends TRL as the first production integration target and
`mlx-lm-lora` only as a separately audited Apple-local experiment. It does not
establish that either engine runs on the owner's hardware, matches DSPy/mmGRPO
semantics, or produces useful held-out improvement.

## Repositories And Roles

| System | Role for Imp | Pin or authority policy |
| --- | --- | --- |
| [DSPy](https://github.com/stanfordnlp/dspy) | Primary compatibility authority for signatures, modules, runtime semantics, and named optimizers. | Pin an exact release, commit, source hashes, and relevant tests for each claim. Current instruction-optimizer gates use `3.3.0b1` at `b2829b7ae3b6e276ac6a8bef66a7ec519dbc923f`. |
| [GEPA](https://github.com/gepa-ai/gepa) | Primary standalone implementation authority for generic reflective text optimization. | Current release `v0.1.4` resolves to `8b0ce6cd99a234f6b74daf37558a2ac0ce18f975`; `v0.1.1` remains an explicitly historical differential contract. |
| [Ax](https://github.com/ax-llm/ax) | Strongest independent implementation comparator for a typed TypeScript interpretation of DSPy-style programming. | Current product-semantic audit: npm `24.0.4`, registry `gitHead` `a366e49759bd596c8217eca91dfdc9dd8382835d`. Historical executable differential: `23.0.0` at `eb5835e54ba0c5b2fbac380daed1cb87faeefd5e`. Use for API and behavioral comparison, not as scientific authority. |
| [BAML](https://github.com/BoundaryML/baml) | Comparator for compiler diagnostics, generated typed clients, and partial structured streaming. | Study its contracts; do not add a separate Imp language unless Elixir modules and macros are demonstrably insufficient. |
| [AdalFlow](https://github.com/SylphAI-Inc/AdalFlow), [TextGrad](https://github.com/zou-group/textgrad), and [SAMMO](https://github.com/microsoft/sammo) | Comparators for explicit parameter graphs, textual feedback, and structure-aware prompt transformations. | Borrow mechanisms only after pinning code and paper protocols independently. |
| [ReqLLM](https://github.com/agentjido/req_llm) | Preferred BEAM provider substrate. | Release `v1.24.0` resolves to `fd9e079fddf253e9b719b2d2c6920f4306592809`. Integrate its provider, multimodal, tool, stream, usage, error, and telemetry contracts instead of rebuilding them. |
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
- resumable current-schema checkpoints, strict schema rejection, secret sanitization, and rollback.

This is compatible with the current Elixir design. `Imp.ProgramParameters`,
optimizer reports, explicit random state, trajectories, GEPA archives, and
save/load boundaries are the beginning of that system. The next step is to make
their shared contract explicit without flattening MIPROv2, SIMBA, GEPA, and
future optimizers into one generic state machine.

Combee's emphasis on parallel scans, batching, and trace processing is
especially relevant to the BEAM. OTP can provide bounded concurrency,
backpressure, cancellation, supervision, and fault isolation, but those runtime
advantages count only when algorithmic behavior and effectiveness remain
measurable against pinned authorities.

## Recommendations From This Review

The review proposed this first group of work:

1. Finish and execute the MIPROv2/SIMBA structural differential.
2. Preserve the complete six-family current-model table, but execute it
   significance-first: matched baseline/GEPA/MIPROv2 on AIME, then repaired
   multi-stage IFBench, before scaling the unchanged remaining families. Report
   it as an adapted reference differential. A separate C4 paper reproduction
   must restore paper-authority models and optimizer semantics, including merge
   where applicable.
3. Make GEPA's parameter identities, Pareto state, merge lineage, checkpoints,
   and immutable results reusable below DSPy-shaped adapters.
4. Establish one canonical typed trajectory for text, multimodal values,
   reasoning, tools, errors, usage, latency, cache identity, and evaluator
   feedback.
5. Complete durable optimizer artifacts: inspect, compare, apply, rollback,
   champion/challenger, promote and roll back, and prove secret absence.

It proposed this later group:

1. Maintain the pinned Ax `23.0.0` executable differential and current
   `24.0.4` product-semantic audit in `docs/differentials/AX_DIFFERENTIAL.md` as
   independent implementation checks without promoting Ax to scientific
   authority.
2. Add operational failure campaigns for cancellation, timeout, retries,
   partial streams, checkpoint resume, idempotency, process failure, and
   concurrency limits.
3. Add persistent playbook or context parameters inspired by Dynamic Cheatsheet
   and ACE without creating an incompatible learning subsystem.

The review treated MCE, Combee, SkillOpt, VISTA, PrefPO, JTPRO, Fast-Slow
Training, and harness-level optimization as later candidates. Its criterion
remains useful: each mechanism should be pinned, tested at the
decision-relevant level, and then integrated, represented by a concrete
extension contract, or rejected with evidence and a revisit trigger. The named
ordering and ticket coordinates were recommendations from this review, not
current priority. This sequencing rationale prevents moving preprints from
destabilizing the core while also preventing “future research” from becoming
an informal out-of-scope bucket.

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
