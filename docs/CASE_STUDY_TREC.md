# Case study: GEPA and MIPROv2 on TREC

This case study answers one deliberately narrow question: on a frozen
classification task, did Imp's GEPA or MIPROv2 implementation improve its own
baseline, and did the winning Imp optimizer remain within a declared margin of
the pinned DSPy implementation?

The answer was yes for this task. It is not evidence that either optimizer will
improve every program, or that Imp is generally better than DSPy.

## What was compared

The experiment used:

- a balanced TREC classification task with opaque output labels;
- disjoint sets of 20 training, 40 selection, and 80 held-out examples;
- three fixed seeds;
- GPT-5.4 Mini for task calls and Claude Sonnet 4.6 for optimizer calls;
- Imp GEPA and MIPROv2 against pinned DSPy 3.2.1 and GEPA 0.1.4; and
- a preregistered `-0.05` noninferiority margin for the winning optimizer.

Program selection happened before held-out rows were opened. The completed
treatment used 6,491 model calls and `$3.13862325` in provider-reported cost.

## What happened

Across the three seeds:

- Imp GEPA improved held-out accuracy over its baseline by `+0.4000`. Its
  source-clustered 95% interval was `[0.2958, 0.5042]`, with Holm-adjusted
  `p = 0.00020`.
- Imp GEPA differed from pinned DSPy GEPA by `-0.0083`. Its 95% interval was
  `[-0.0458, 0.0292]`, above the declared `-0.05` margin.
- Imp MIPROv2 improved held-out accuracy over its baseline by `+0.1458`. Its
  interval was `[0.0458, 0.2458]`, with Holm-adjusted `p = 0.00270`.

GEPA therefore satisfied the frozen headline. MIPROv2 also produced positive
own-baseline evidence, but its Imp-versus-DSPy difference varied substantially
across the three seeds. Three seeds remain limited evidence about model-sampling
uncertainty.

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
  benchmarks/evidence/archive/matched_experiments/trec/imp-scored-rows.json \
  benchmarks/evidence/archive/matched_experiments/trec/upstream-scored-rows.json \
  benchmarks/evidence/archive/matched_experiments/trec/aggregate-recomputed.json
```

The command should end with:

```text
matched TREC compact recomputation passed: GEPA +0.4000, MIPROv2 +0.1458, GEPA Imp-minus-DSPy -0.0083
```

The public recomputation inputs are content-bound as follows:

| File | SHA-256 |
| --- | --- |
| `recompute_compact.exs` | `cea5f2fc6721b7cdeec1bd7edc0a97048cab644f6bcdd4e15154427b1df739f0` |
| `contract.json` | `0253960b8c570f0e0dd3a2a84450327f3244338fdff002f40ffed44bd9f15e94` |
| `imp-scored-rows.json` | `0b6ab45639dea8f2ac6ea1c0405ef62c414a93228a8d25edd2540694f59826bd` |
| `upstream-scored-rows.json` | `11706b6e1e9c7e3a09f677e3a354df69676a61fc02da19a80b2cdd7c4ec45b4c` |
| `aggregate-recomputed.json` | `295f7f4a2312ccf57f2fae6a4eaf248e51e442e60588a8b769edb679b421dee1` |

The command verifies gold-label checks, row scoring, source-clustered
bootstrapping, Holm correction, and the noninferiority decision from the
committed scored rows. It does not independently verify the private raw provider
responses, routing, cost, or the original selection barrier. Those raw traces
contain 181 MB of request-level evidence and are intentionally not published.

## How to use this evidence

This result establishes task-, model-, and budget-specific evidence for Imp
GEPA and MIPROv2. It belongs beside the clean Banking77 and HotPotQA negatives,
not in place of them. The useful product lesson is that Imp can run a real
optimizer comparison, select before testing, preserve the result, and expose a
compact recomputation boundary. Broader optimizer usefulness remains an open
scientific question.
