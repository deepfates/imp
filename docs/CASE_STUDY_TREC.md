# Case study: GEPA and MIPROv2 on TREC

**This result is recomputable, not reproducible.** You can re-derive every
statistic below from the scored rows committed in this repository, and the
command that does it is in the next section. You cannot re-run the experiment:
the raw provider responses behind those rows are 181 MB of request-level
evidence that was not published, so the step from "a model answered" to "a row
records this answer" is taken on our word. Nobody outside this repository can
check it. We publish the result anyway, labeled this way, because a withheld
result and an unlabeled one are both worse.

The narrow question it answers: on a frozen classification task, did Imp's GEPA
or MIPROv2 implementation improve its own baseline, and did the winning Imp
optimizer stay within a declared margin of pinned DSPy? Yes, for this task. It
is not evidence that either optimizer will improve every program, or that Imp
is generally better than DSPy.

## What was compared

- a balanced TREC fine-grained classification task with opaque output labels
  (license **unknown**; see
  [the attribution note](https://github.com/deepfates/imp/blob/main/benchmarks/data/TREC_ATTRIBUTION.md));
- disjoint sets of 20 training, 40 selection, and 80 held-out examples;
- three fixed seeds;
- GPT-5.4 Mini for task calls and Claude Sonnet 4.6 for optimizer calls, both
  through OpenRouter;
- Imp GEPA and MIPROv2 against pinned DSPy 3.2.1
  (`29448ae12756abdd14bd8796c819247ebb83673c`) and GEPA 0.1.4; and
- a preregistered `-0.05` noninferiority margin for the winning optimizer.

Program selection happened before held-out rows were opened. The completed
treatment used 6,491 model calls and `$3.13862325` in provider-reported cost.

## What happened

Rows R3, R4 and R5 in
[benchmarks/RESULTS.md](https://github.com/deepfates/imp/blob/main/benchmarks/RESULTS.md)
carry the three numbers, their intervals, their p-values and their provenance.
In summary: GEPA improved over its own baseline and satisfied the frozen
headline; MIPROv2 also improved over its own baseline; and the winning
optimizer stayed above the declared noninferiority margin against DSPy.

MIPROv2's Imp-versus-DSPy difference varied substantially across the three
seeds. Three seeds remain limited evidence about model-sampling uncertainty.

## Recompute the result

The Hex package contains the product and this explanation. The scored rows and
research program remain in the source repository so benchmark machinery does
not become a runtime dependency.

From an exact Imp source checkout, run:

```sh
mix deps.get
mix run --no-start \
  examples/matched_instruction_optimizers_trec/recompute_compact.exs -- \
  examples/matched_instruction_optimizers_trec/contract.json \
  examples/matched_instruction_optimizers_trec/data/imp-scored-rows.json \
  examples/matched_instruction_optimizers_trec/data/upstream-scored-rows.json \
  examples/matched_instruction_optimizers_trec/data/aggregate-recomputed.json
```

It prints the three headline quantities it computed — not stored strings; the
script holds no numeric literals — and then either agrees with the committed
aggregate or prints both sides and exits non-zero.

```text
Recomputed from imp-scored-rows.json and upstream-scored-rows.json:
  GEPA over its own baseline: +0.4000 95% CI [0.2958, 0.5042], Holm-adjusted p = 0.00020
  MIPROv2 over its own baseline: +0.1458 95% CI [0.0458, 0.2458], Holm-adjusted p = 0.00270
  GEPA Imp minus DSPy: -0.0083 95% CI [-0.0458, 0.0292]
  noninferiority margin -0.0500, winning optimizer gepa, headline passed: true

Recomputation agrees with aggregate-recomputed.json in full.
```

The recomputation inputs are content-bound as follows:

| File | SHA-256 |
| --- | --- |
| `recompute_compact.exs` | `3b9041e97913abbc6d21f951216c0adc2b844bc075b27abe7af7cdf13acc7fde` |
| `contract.json` | `0253960b8c570f0e0dd3a2a84450327f3244338fdff002f40ffed44bd9f15e94` |
| `imp-scored-rows.json` | `0b6ab45639dea8f2ac6ea1c0405ef62c414a93228a8d25edd2540694f59826bd` |
| `upstream-scored-rows.json` | `11706b6e1e9c7e3a09f677e3a354df69676a61fc02da19a80b2cdd7c4ec45b4c` |
| `aggregate-recomputed.json` | `295f7f4a2312ccf57f2fae6a4eaf248e51e442e60588a8b769edb679b421dee1` |

The command verifies gold-label checks, row scoring, source-clustered
bootstrapping, Holm correction and the noninferiority decision. It does not
verify the private raw provider responses, routing, cost, or the original
selection barrier.

See [Benchmarks](https://github.com/deepfates/imp/blob/main/docs/BENCHMARKS.md) for what every other number here costs to re-measure.

## How to use this evidence

This result establishes task-, model-, and budget-specific evidence for Imp
GEPA and MIPROv2. It belongs beside the Banking77 and HotPotQA negatives in
RESULTS.md, not in place of them. The useful product lesson is that Imp can run
a real optimizer comparison, select before testing, preserve the result, and
expose a recomputation boundary narrow enough to state honestly. Broader
optimizer usefulness remains an open scientific question.
