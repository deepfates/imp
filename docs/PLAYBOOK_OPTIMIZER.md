# Persistent Playbook Optimization

`Imp.Optimizer.Playbook` treats learned context as a normal typed program
parameter. An `Imp.Playbook.WithContext` program exposes its playbook through
`Imp.ProgramParameters.playbooks/1`; optimizers replace it through
`put_playbook/3`, and executions remain ordinary versioned
`Imp.Optimizer.Trajectory` values.

## Authority and Adaptation

The design is informed by two pinned primary authorities:

| Authority | Pin | Contract used by Imp |
|---|---|---|
| Dynamic Cheatsheet, arXiv:2504.07952 | repository `5cfe3c37e8e52b1d858d0f3df46e7f17c50991b9`; PDF SHA-256 `660680ecc5cdb8f4d921e1284bf95df2dfa9020c5923330e406fff9b93bcfd00` | Persistent, self-curated strategy context updated from prior task execution. |
| ACE, arXiv:2510.04618 | repository `bcb7cea0504afad6f55fec4845dd4864c9f9eee7`; PDF SHA-256 `51050ced82df75c143b151262d5af8763916968ca50374bd8ff778f40552b0ad` | Generator/reflector/curator separation, incremental deltas, helpful/harmful accounting, and grow-and-refine context. |

The pinned ACE curator says that only `ADD` is fully supported in its current
validation path. Imp therefore does not claim exact source parity. It provides
an Elixir-native adaptation with atomic typed add/revise/merge/remove/counter
operations, optimistic revision guards, exact deduplication, bounded provenance,
tombstones, and complete hash chains.

## Promotion Contract

One compile transaction has six reserved stages:

1. Evaluate the baseline on training examples.
2. Propose one atomic delta from training rows and trajectories only.
3. Evaluate baseline and challenger on a source/group-disjoint promotion split.
4. Persist and reload both programs, then evaluate them on a second untouched
   audit split.

Promotion requires the configured lift on both held-out splits. Before any
held-out provider work, Imp rejects excessive retained growth, held-out strings
in changed entries, held-out provenance, unauthorized provenance, split overlap,
and policy violations. A rejected challenger leaves the baseline program exact.
`rollback/1` returns that preserved program deterministically.

Each callback has a declared request, input-token, output-token, and USD
reservation. Actual usage must identify `provider_reported`, pinned-price
`derived`, or genuinely `free` authority and remain inside both its stage
reservation and the aggregate budget. Started checkpoints are written before
callbacks; because a started provider call may already be charged, such a
checkpoint is deliberately not replayable. Completed checkpoints are canonical,
hash-bound, JSON-safe, and rebind only data parameters into fresh runtime code.

## Natural Campaign

The release campaign uses the 250-row `MathEquationBalancer` data stored by the
pinned Dynamic Cheatsheet repository. The source Arrow file, canonical JSONL,
builder, and provenance manifest live under `benchmarks/data/playbook/`.
The metric parses only ordered integer/operator equations and evaluates them
with exact rational arithmetic, accepting any valid operator assignment.
The baseline parameter contains a concise task contract and an inactive bounded
capacity entry. A delta must compress that reserve while revising the active
strategy, so the retained parameter cannot grow and inactive capacity never
enters model context.

Execution is BEAM-native. The campaign exposes a bounded `Imp.Tool` whose
ordinary Elixir implementation enumerates at most seven operator slots and
evaluates them as exact rational numbers. `Imp.Predict.CodeAct` can call that
capability and can only evaluate follow-up expressions through `Imp.Sandbox`;
there is no Python process, `Code.eval_string/3`, or external evaluator. The
proposer learns the tool-use protocol from training failures, and the candidate
must still earn promotion on both unseen splits.

Inspect the zero-network plan:

```sh
mix imp.benchmark.playbook --plan
```

Run the bounded live campaign:

```sh
set -a; source .env; set +a
mix imp.benchmark.playbook \
  --config benchmarks/config/playbook-live.json \
  --api-key-env OPENAI_API_KEY
```

The pinned model is `openai:gpt-4.1-mini-2025-04-14`, priced at $0.40 per
million input tokens and $1.60 per million output tokens. The campaign writes a
checkpoint before every stage and records positive or negative held-out evidence
without converting a failed lift into a success claim.

### Release Evidence

The committed seed-61 campaign in
`benchmarks/results/playbook-equation-balancer-live-v11.json` binds to commit
`37f58dc6e3110606b5b08d01124b2cfb1ef52566` and records SHA-256 identities for
all implementation sources. Its source/group-disjoint results were:

| Split | Baseline | Candidate | Solver calls |
|---|---:|---:|---:|
| Promotion (12 rows) | 0.3333 | 1.0000 | 12/12 candidate rows |
| Untouched audit (12 rows) | 0.4167 | 1.0000 | 12/12 candidate rows |

The promoted playbook shrank from 1,393 to 1,086 retained bytes. The run made
137 accounted requests, used 65,315 input and 3,794 output tokens, and cost
$0.0321964 at pinned prices. Both programs were saved and reloaded before audit;
the selected playbook hash and complete trajectories are retained in the
hash-bound checkpoint `playbook-checkpoint-live-v11.json`.

This was not selected after suppressing negative evidence. The prior seed-59
artifact `playbook-equation-balancer-live-v9.json` improved promotion from
0.5000 to 0.5833 but regressed audit from 0.5833 to 0.3333. It was rejected and
rolled back. Its mechanism trace showed only 7 solver calls across 24 held-out
candidate rows, motivating bounded curator validation of the generated tool-use
protocol before the fresh seed-61 run.

## Limits

- The natural campaign is equation-balancing evidence, not cross-domain proof.
- The campaign demonstrates learned use of an available BEAM-native capability;
  it does not demonstrate synthesis of a new executable tool implementation.
- Imp implements the research ideas through its own stricter parameter and
  promotion contracts; it does not reproduce upstream prompts or string state.
- Semantic near-duplicate detection is not silently applied. Domain-level
  deduplication is exact after canonical Unicode and whitespace normalization;
  model-proposed merges must remain explicit, attributable operations.
