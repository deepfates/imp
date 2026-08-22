# Claims And Proof Obligations

`benchmarks/claims.json` is a scoped index of broad product, conformance, and
research statements. It exists to stop a narrow result from silently becoming
a general claim. It is not a release profile, readiness score, roadmap, or
substitute for exercising the product.

The release procedure is `docs/maintainers/RELEASE.md`. A product statement is
owned by the public behavior and documentation it describes. Comparative and
scientific statements additionally point to a pinned authority, protocol, and
retained result. Unknown research remains unknown; it does not make an
unrelated, honestly scoped product behavior false.

Claims that are true only for a narrower path must say so in the statement and
linked documentation. A `full` requirement means complete evidence for that
precise scope, never blanket parity for a subsystem or upstream project.

## Evidence Rungs

Every claim stops at an explicit rung:

| Rung | Meaning |
| --- | --- |
| C0 | The API exists and is callable. |
| C1 | Behavior conforms to a pinned authority for the declared scope. |
| C2 | The capability executes through its real operational boundary. |
| C3 | Held-out evidence supports effectiveness on the declared portfolio. |
| C4 | An exact paper protocol is reproduced from public authority. |
| C5 | Powered paired evidence supports comparative advantage. |

Higher rungs do not erase lower contracts. A C3 result cannot repair C1
semantic divergence, and an operational C2 sample cannot authorize an
effectiveness claim. Exact authority that is genuinely unavailable blocks only
the C4 claim; a separately named adapted protocol may still earn C3.

## Shape

Each claim has:

- `id`: stable claim identifier.
- `statement`: the human-readable public claim.
- `category`: package, docs, parity, optimizer, performance, operations, or a
  similarly concrete release area.
- `surface`: the APIs or user stories covered by the claim.
- `claim_type`: feature completeness, conformance, live-provider proof,
  functional effectiveness, or performance.
- `comparison`: `dspy`, `imp_native`, or a narrower comparison target.
- `claim_state`: `asserted`, `target`, or `retired`. This is intent, not proof.
- `target_rung`: the exact C0-C5 evidence rung required by the claim.
- `release`: the profile that owns the claim, such as `v0.1` or `telos`.
- `scope`: the precise boundary of the claim.
- `limitations`: explicit exclusions or evidence still required.
- `gate_policy`: retained historical classification; current release blocking
  follows the release contract and public wording, not a computed profile.
- `sources`: docs, tests, fixtures, or papers that explain the claim.
- `requirements`: concrete checks or result properties that can falsify the
  statement.

Some older requirements name evidence lanes. Treat those as coordinates to the
underlying check or artifact, not as a global score:

```json
{
  "id": "live_matched_model.full",
  "kind": "live_parity",
  "lane": "live_matched_model",
  "evidence": "full",
  "threshold": "required live lanes satisfy their policies"
}
```

`"evidence": "full"` means the result meets the complete protocol for the
declared scope. `"evidence": "passing"` means a behavioral or operational check
passed. Neither upgrades a fixture into effectiveness evidence.

Live matched-model evidence also consumes `benchmarks/model_availability.json`
for documented external model unavailability. That file can unblock a historical
lane only when the historical endpoint itself is no longer a stable provider
baseline; it cannot replace current-model coverage.

RLM research claims require exact paper-scale authority. The checked-in RLM
protocol still marks the exact S-NIAH instances, BrowseComp+ query/document
selection, and OOLONG-Pairs scorer as unavailable with explicit acquisition
markers. T0 fixture replay, T1 operational contracts, and sampled T2 evidence
cannot be promoted to the exact T3 research claim while those authorities are
unavailable.

GEPA research claims use the `gepa_replication` protocol, not the generic
`optimizer_lift` protocol. The result supports those claims only when a fresh
non-smoke `gepa-replication-*.json` artifact covers the required GEPA paper
families and reports baseline, DSPy GEPA, Imp GEPA, MIPROv2, metric-call
budget, token/cost, wall-clock, seed variance, and train/dev/test gap. The
validator recomputes the evidence from the row contract: campaign provenance,
dataset scope, split counts, dataset checksums, source commits, concrete
comparator sources, distinct split digests, and positive live token/cost
accounting are required. Capped `--max-per-split` dataset roots are explicitly
rejected for full GEPA claims. SIMBA may be reported as extra comparator
evidence when present, but it is not required by the upstream GEPA artifact.
The active current-model six-family table is deliberately separate: it uses
the official task families and scorers but current models/runtime policies and
Imp's GEPA 0.1.4 no-merge profile. It can earn a scoped C3 matched reference
differential, not this lane's exact C4 paper-replication claim. Do not feed its
artifact to `gepa_replication` admission or describe it as paper reproduction;
an exact C4 attempt requires its own paper-authority protocol, including merge
where used by the original arm.

Optimize Anything non-prompt effectiveness uses its own `optimize_anything`
lane. Full evidence requires executable code, agent-configuration, and
scheduling artifact families; at least three live provider-backed seeds per
family; pairwise-distinct train, selection, and untouched test splits; positive
mean test lift; a strict majority of improving runs; candidate selection that
does not consult test outcomes; positive usage and cost; and durable checkpoint
provenance. Smoke artifacts, development-only pre-v2 artifacts, and authored
comparator scores cannot authorize the claim. A passing schema-v2 lane proves
the scoped Imp-native effectiveness statement, not paper-scale upstream parity.

Local MLX weight-training effectiveness uses the `local_mlx_weight_training`
lane. Its asserted scope is one pinned Qwen2.5-0.5B MLX SFT artifact on the
frozen four-intent Banking77 subset: untouched 40-row accuracy `0.125 -> 0.55`,
macro-F1 `0.0610 -> 0.4561`, and byte-identical ordered predictions/errors after
save/load and fresh-process serving of the exact fused artifact. It does not
authorize general Imp or SFT effectiveness, GRPO, production reliability,
DSPy-matched parity, or BEAM superiority.

BetterTogether has one narrower retained-artifact lifecycle result on that same
model and task. Its prompt stage evaluated two rendered instructions through
the fused task LM; validation scored weight-only and weight-then-prompt equally
at `0.50`, so stable prefix selection retained weight-only. That selected
program scored `0.55` accuracy, `0.4561` macro-F1, and zero parse errors on the
40 untouched rows, then reproduced ordered predictions and errors byte-for-byte
after save/load and fresh-OS rebinding. This proves real composition mechanics,
honest weight-only fallback, and portable selected-program behavior. It does
not satisfy the separate general BetterTogether or prompt-optimizer
effectiveness target.

Weight and composition claims are divided into six authority families: Avatar
actor, AvatarOptimizer, BootstrapFinetune, DSPy mmGRPO, BetterTogether, and
Ensemble. Each has its own C0 API claim, C1 source-conformance target, and C3
effectiveness target. Avatar actor task quality is separate from AvatarOptimizer
rewrite lift. The clean Imp local-MLX artifact belongs only to
BootstrapFinetune's local-effectiveness claim; the pre-rename legacy artifact is
not Imp evidence. C1 work must preserve the declared native differences, including
Avatar candidate evaluation, BootstrapFinetune's `pred_ind` correction,
GRPO's durable dispatch lifecycle, BetterTogether's bounded generic optimizer
contract, and Ensemble's deterministic replay. Exact Python RNG parity is not
implied.

Failure-recovery operational evidence is limited to two required local rows:
provider-shaped timeout/retry/idempotency and integration retrieval plus exact
tool-agent failure/retry/submit recovery. The campaign uses injected local
transports, a static LM, and dummy canaries only. It makes no external-provider
or live provider-training claim.

RAG, tool, and agent evidence is split into individual C1 claims for the exact
provider-free RAG, ReAct, ReActV2, MCP import, agent policy, CodeAct,
ProgramOfThought, streaming, async, and credential-redaction rows. Exact DSPy
comparison is claimed only for memory RAG and successful ReAct lookup; the
other rows are explicitly Imp-native fixture contracts. Bounded HotPotQA
retrieval is a separate differential. The CC0 BFCL-shaped scorer check is only C1/T1
fixture agreement: independent Elixir and Python implementations score twelve
original positives and nine mutations. It executes neither official BFCL nor
DSPy scorer code and establishes no model generation/tool-selection quality,
official BFCL performance, or operational behavior. A separate C2 differential
executes an identical queued-action failure schedule through actual Imp and
source-authenticated DSPy 3.2.1 ReAct, but fixture-owned retry/idempotency and
an injected timeout exception do not establish model recovery effectiveness or
wall-clock timeout parity.
Historical selected live paths do not satisfy the C4 target.

For release or documentation review, read the actual public statement, run the
smallest relevant behavioral check, and inspect the retained result for any
comparative or effectiveness claim. Fix the product, narrow the statement, or
preserve the result as negative/unknown according to what fails. Do not add a
claim row for a routine API fact already owned clearly by code, tests, and
documentation; reserve this index for statements whose scope could otherwise
be overstated.
