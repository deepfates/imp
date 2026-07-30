# Imp

Imp is [DSPy](https://dspy.ai) for the BEAM: declare a language-model task
as a typed Elixir program, then test, measure, improve, and operate it like
any other code. There are two kinds of intelligence in a modern program,
the fluid kind that can read a situation and the solid kind that does
exactly what it says. Imp is for building programs out of both.

<!-- "Imp with cards", Le Grand Etteilla (public domain, via Wikimedia Commons) -->
<p align="center">
  <img src="assets/imp-with-cards.jpg" width="380"
       alt="An imp studies a hand of cards through a lens while a smaller imp springs from its tail.">
</p>

You declare the task the way you would declare a type, with named inputs,
named outputs, and constraints. Imp turns the declaration into a program.
The program is a value, not a prompt.

```elixir
lm = Imp.req_llm("openai:gpt-5.4-mini", api_key: System.fetch_env!("OPENAI_API_KEY"))

route =
  "ticket -> team: enum[billing,infrastructure,security,product], urgency: enum[low,normal,high]"
  |> Imp.signature("Assign the support ticket to the team that owns it.")
  |> Imp.predict(lm: lm, adapter: Imp.Adapter.JSON, config: [json_retries: 1])

{:ok, prediction} =
  Imp.call(route, %{ticket: "A customer noticed they can open other users' invoices by changing the number in the URL."})

Imp.get(prediction, :team)
#=> "security"
```

## What Imp is trying to finish

Imp succeeds when an ordinary Elixir application can declare a real program,
measure it, improve it through one consistent public optimizer interface, save
the selected parameters, and load them in a fresh process with failures and
costs still visible. That install-to-operation path is the product boundary.

DSPy, GEPA, Optimize Anything, and Ax are important references. Imp compares
observable behavior with them where that comparison protects a user-facing
contract; it does not reproduce incidental Python machinery or make internal
call-graph identity a release goal. Research runs support narrowly worded
claims. They do not define the architecture, the roadmap, or whether the
package is useful.

Maintainer checks follow the same rule: prefer a small integrated test through
the public API over several assertions about private wiring. A frozen research
run keeps only the provenance needed to interpret that run. New manifests,
registries, or status views must replace an existing source of truth rather
than creating another one.

For an exact one-output classifier or scalar program, `Imp.Adapter.SingleField`
uses a concise value-only wire contract while retaining signature validation.

The model read the situation: an invoice complaint that is really a
security incident. The types held the contract: the answer is always one of
your four teams, and a generation that breaks the declaration is rejected
and retried with the validation error. You never wrote a prompt.

## Install

Imp is not yet published to Hex. Until then, install from a source checkout:

```elixir
{:imp, path: "path/to/imp"}
```

The checkout currently reports package metadata `0.2.1`, but `main` contains
breaking unreleased changes and is not a releasable `0.2.1` artifact. Internal
release candidates are therefore identified by exact Git commit and package
digest. The owner will choose the next public SemVer before publication; no
mutable branch or development version should be used as a release coordinate.

The full manual ships in this repository from the [documentation index](docs/README.md); it will land
on hexdocs.pm with the Hex release. You will need an API key for a model
provider (any [ReqLLM](https://hex.pm/packages/req_llm) provider works; the
docs use OpenAI).

No key yet? You can still build, test, evaluate, and even compile a program
with a scripted model — Livebooks 02–05 and the "Test It Without A Provider"
step of the [Learning Path](docs/LEARNING_PATH.md) run start to finish with
no provider and no spend.

For the shortest terminal path, run the
[provider-free ticket router](examples/provider_free_ticket_router/README.md).
It measures the same typed program before and after deterministic few-shot
compilation from an ordinary consumer project; the package gate also runs it
offline from the built artifact.

For the real local optimizer lifecycle, the
[Banking77 GEPA example](examples/local_gepa_banking77/README.md) composes two
different local model runtimes, evaluates a GEPA proposal using train/selection
only, applies the selected named parameters, and reproduces the untouched result
after restarting the exact trained artifact in a fresh OS BEAM.

For joint instruction and few-shot search, the
[Banking77 MIPROv2 example](examples/local_mipro_banking77/README.md) runs the
public optimizer with an exact local fused task model and local proposal model,
keeps the worse proposal out on validation, and reapplies the selected
parameter artifact in a fresh OS BEAM.

For the matched upstream result, the
[strong-model TREC comparison](examples/matched_instruction_optimizers_trec/README.md)
uses the same GPT-5.4 Mini task model, Claude Sonnet 4.6 optimizer model,
messages, disjoint splits, seeds, and semantic budgets in Imp and pinned DSPy.
On that frozen contract, Imp GEPA improved mean untouched accuracy by `+0.4000`
over its baseline and cleared the preregistered `-0.05` noninferiority margin
against DSPy GEPA. Imp MIPROv2 also improved its own baseline by `+0.1458`.
This is one task/model-specific C3 result, not general optimizer effectiveness
or BEAM superiority.

For per-request retrieval and metric-gated bootstrapping, the
[Banking77 KNNFewShot example](examples/local_knn_few_shot_banking77/README.md)
retrieves real training neighbors for the fused classifier, renders accepted
demonstrations, rejects a worse validation result, and reproduces the selected
saved program after a fresh OS restart.

For standalone demo-set search, the
[Banking77 RandomSearch example](examples/local_random_search_banking77/README.md)
uses a separate real local teacher, proves accepted augmented demonstrations
reach fused-model candidate messages, honestly retains zero-shot when every
demo candidate is worse, and reproduces the selected saved program after a
fresh OS restart.

For introspective minibatch search, the
[Banking77 SIMBA example](examples/local_simba_banking77/README.md) samples the
same real fused task model, evaluates a genuine demonstration mutation, rejects
its minibatch overfit on separate validation, and reapplies the selected
parameter artifact in a fresh OS BEAM.

GEPA, MIPROv2, and SIMBA share one deployment handoff. After validation selects
a program, `Imp.Optimizer.Artifact.from_optimized_program/2` captures only its
named signatures, demonstrations, configs, and optimizer report. A restarted
application reconstructs its trusted program and live model clients, then uses
`Imp.Optimizer.Artifact.read!/1` and `apply/4` to install those selected
parameters. The [Learning Path](docs/LEARNING_PATH.md#8-persist-programs-or-selected-parameters-not-secrets)
shows the complete shape without benchmark or training infrastructure.

For natural rule induction, the
[Banking77 InferRules example](examples/local_infer_rules_banking77/README.md)
uses a separate local rule model, evaluates the original source, bootstrapped
baseline, and induced-rule program on validation, and preserves the selected
program across a fresh OS restart. Its retained run also demonstrates why Imp
protects the caller's source program when bootstrap or rule induction regresses.

For arbitrary structured artifacts, the
[retry-policy Optimize Anything example](examples/local_optimize_anything_retry_policy/README.md)
starts with a provider-free two-domain walkthrough that applies native retry
and scheduling artifacts, resumes them from checkpoints, contains malformed
proposals, and reproduces both consumers in a fresh OS BEAM. The same example
also preserves a separately scoped pinned Phi-4 run under an exact component
schema: the model proposed a nontrivial retry-policy mutation, validation chose
it without access to the test rows, and the applied policy improved untouched
behavior from four to five exact cases before reproducing in a fresh OS BEAM.
The deterministic walkthrough proves arbitrary-artifact lifecycle and
application; the one-task/model run is narrow proposer/usefulness evidence, not
general Optimize Anything effectiveness.

For local weight optimization, the
[Banking77 GRPO example](examples/local_grpo_banking77/README.md) runs ordinary
model-generated Qwen rollouts through Imp's public GRPO API, an official pinned
TRL LoRA update on MPS, train/selection/untouched-test separation, exact
artifact verification, and selected-program reproduction in a fresh OS BEAM.
Its retained run is an honest no-signal result rather than a claimed win.

For a harder learned-behavior check, the
[opaque-route Banking77 GRPO example](examples/local_grpo_opaque_banking77/README.md)
includes frozen Banking77 and source-disjoint TREC treatments that withhold
route meanings, run ordinary multi-group/multi-step model-generated GRPO, and
deploy the validation-selected artifact in a fresh OS process. The retained
results are neutral or negative: the TREC treatment improved validation but
regressed slightly on held-out test. They establish a real product lifecycle,
not general GRPO effectiveness.

## Because the program is a value, the rest is ordinary engineering

Each stage below is one stop on the [Learning Path](docs/LEARNING_PATH.md),
which grows this same router end to end.

- **Declare** the task as a typed signature. The prompt is rendered from
  the declaration at call time; you never maintain it.
- **Test** without a provider. A scripted model plays the LM's part while
  the real signature validation, adapters, and metrics run in your suite.
- **Measure** on labeled data. Evaluation returns a score and every row,
  a number instead of an impression.
- **Improve** with an optimizer that compiles a better program. In the
  [tutorial](docs/TUTORIAL_TICKET_ROUTING.md)'s committed runs, the router
  goes from 30% to 85% on tickets it has never seen, for about a cent,
  and you can read exactly what changed, because the optimizer's work is
  data attached to the program.
- **Extend** with typed tools under explicit policies, agent loops from
  ReAct through a sandboxed recursive controller, retrieval, and token
  streaming straight into your LiveView.
- **Operate** it where it belongs. On the BEAM a model call is one more
  slow, fallible, concurrent effect: bounded supervised workers, compiled
  programs persisted as checksummed artifacts with no secrets inside,
  credentials bound at runtime, redacted telemetry on every call, retry,
  and tool step. The [deployment example](examples/deployment/README.md) is a
  complete OTP application.

## The whole surface, stage by stage

Nearly everything is one call on the `Imp` module. This is the map of what
you can reach and where it belongs; the [API Guide](docs/API_GUIDE.md) has
a worked example for every row.

| Stage | What you can use |
| --- | --- |
| **Declare** | `signature` (string DSL or map form with constraints), `example`, `with_inputs`, `prediction`, `get`, `to_map`, conversation `history` and `append_history` |
| **Run** | `call`, `stream` and `collect` (provider token streaming, honest local fallback), `req_llm` (any ReqLLM provider), `configure` / `settings` / `context` for defaults and scoped overrides |
| **Test** | `context` swaps a scripted default into dynamically bound programs; `with_lm` explicitly rebinds pinned program graphs, so signatures, adapters, and metrics run for real in your suite |
| **Measure** | `evaluate` (score plus every row), `exact_match`, `extractive_qa`, `classification`, `classification_report`, `majority` voting |
| **Improve** | `optimize`, `train` (weights are deliberately separate), `with_demos`, `with_playbook`, `with_lm`, `optimizer_capabilities`; optimizers: `LabeledFewShot`, `BootstrapFewShot`, `RandomSearch`, `KNNFewShot`, `COPRO`, `SIMBA`, `MIPROv2`, `GEPA`, `InferRules`, `SignatureOptimizer`, `Ensemble`, `BetterTogether`, `BootstrapFinetune` (including local MLX SFT), `TrainingJobAdoption` (verified completed-artifact adoption, never training), `GRPO` (an explicit reinforcement trainer is required; bundled local TRL/MPS is available), and Optimize-Anything for text plus JSON-safe structured artifacts |
| **Extend** | program shapes: `predict`, `chain_of_thought`, `react` and `react_v2`, `avatar`, `code_act`, `program_of_thought`, `rlm` with `rlm_serializable` handles; composition: `best_of_n`, `refine`, `assert` / `assertion`, `multi_chain_comparison`, `parallel`; tools and context: `tool`, `Imp.MCP.import_tools`, `memory`, `retrieve`, `rag`, `knn` / `nearest`, `Imp.Datasets` loaders, `Imp.Embeddings` |
| **Operate** | `save!` / `load!` (portable programs), `Imp.Optimizer.Artifact` write/read/apply (selected parameters for reconstructed trusted programs), `dump` / `load` (state as data), `trace`, `inspect_history`, `subscribe_optimizer_progress`, `enable_logging` / `disable_logging` |

You will use one or two rows at first; the rest are there when a task
earns them.

## Verification is claim-scoped, and you can run the receipts

Imp is a native BEAM realization of DSPy's research program of programming
language models instead of prompting them. It tracks DSPy 3.2.1. Several
optimizer and adapter contracts run real pinned DSPy in a sidecar and compare
declared observations arm to arm; those receipts prove their stated scope, not
whole-library equivalence or optimizer effectiveness. The [conformance
report](docs/CONFORMANCE.md) enumerates every surface with its own evidence: a
differential where one exists, a behavioral contract or deliberate
Elixir-native equivalent where the mechanics differ, and an honest gap where
an upstream-matched outcome is not yet proven. One sealed three-seed TREC
comparison now establishes task-specific GEPA noninferiority and Imp-baseline
lift for GEPA and MIPROv2; it does not wash over the remaining family gaps. Imp
uses supervision, process isolation, and bounded concurrency as native design
choices; it does not claim comparative advantage without powered paired
evidence. [Imp for DSPy users](docs/IMP_FOR_DSPY_USERS.md) maps every name you
already know and states exactly what differs.

The package ships one generated API truth in `priv/public_api.json`. HexDocs
groups the `Imp` facade and stable modules as the compatibility center, marks
optimizer and advanced modules experimental before 1.0, exposes implementer
interfaces separately, and omits internal machinery. Experimental means real
and supported by tests, not frozen against the next minor release.

## Learn

- [Learning Path](docs/LEARNING_PATH.md): the router above, grown step by
  step from first live call to deployment.
- [Ticket Routing Tutorial](docs/TUTORIAL_TICKET_ROUTING.md): the full
  experiment behind the numbers, artifact included.
- [Livebooks](livebooks/01_real_lm_front_door.livemd): the same path as runnable notebooks.
- Reference: [API Guide](docs/API_GUIDE.md), [Glossary](docs/GLOSSARY.md),
  [Architecture](docs/ARCHITECTURE.md),
  [Production Operations](docs/PRODUCTION_OPERATIONS.md).

## Where this is going

First, a Hex release. The interactive-fiction environment is now
[Grue](https://github.com/deepfates/grue): its optional benchmark harness runs
Imp policies against forkable Z-machine sessions and records replayable Lync
episodes. The next bet belongs to this runtime: optimization as a resident
process, programs improving from their own recorded history, under supervision,
while they run.
