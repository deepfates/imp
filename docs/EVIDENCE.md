# Evidence: How Imp Grades Its Own Claims

Every capability claim Imp makes is a row in a machine-checked ledger, and
every row states how strong its evidence is. This page defines that scale, so
when another page says "verified" you can ask — verified *to what rung?* —
and check the answer yourself.

## The ladder

Each rung is a stronger kind of evidence than the one below it. A claim
declares its target rung. **Asserted** is a maintainer attestation: the
maintainers have run the claim's evidence lanes and seen the target rung
reached, and intend the claim for the named product profile. It is not a
statement that a fresh checkout can replay that evidence from committed
artifacts alone — the dashboard computes that stronger property (see the
reconciliation below), and a claim is publishable only when the dashboard
computes it **proven**. A claim that is not asserted remains a **target**,
the ledger's word for "promised, not proven."

| Rung | What it proves |
| --- | --- |
| **C0** | The API exists and is callable. |
| **C1** | Behavior conforms to a pinned authority for the declared scope — an executable differential against real DSPy 3.2.1 for the families that have one (the optimizer and adapter families), a behavioral conformance test otherwise. |
| **C2** | The capability executes operationally through its real boundary (real transport, real process tree, real artifact round-trip). |
| **C3** | Held-out evidence supports effectiveness for the declared task portfolio — a number on data nothing selected for. |
| **C4** | An exact paper protocol is reproduced from public authoritative materials. |
| **C5** | Powered, paired evidence supports comparative advantage. |

The rungs deliberately separate three questions that marketing language
usually blurs: *is it there* (C0), *is it faithful* (C1–C2), and *does it
actually help* (C3–C5). A faithful port of an optimizer is a different claim
from that optimizer improving your program, and each is graded on its own
receipts.

## Read the current state

This page deliberately does not copy live claim counts from the generated
dashboard. A prose snapshot creates a second status system and goes stale as
soon as evidence or claim scope changes.

From a source checkout, compute the current product-scoped view directly:

```sh
mix benchmark.dashboard --profile v0.1
```

Use the result as a claim audit, not as a roadmap or a complete product
verdict. In a source checkout, the maintainer release procedure defines the
ordinary release finish line: a clean consumer must install, optimize, inspect,
persist, restart, and serve a real program through the public API. Research
targets may remain open without making that narrower product behavior false.

Imp does not claim that an optimizer helps a task until a held-out result says
so. Task-scoped positive, neutral, negative, and stopped results keep their
exact limitations in the result artifact and linked example; a higher rung on
one task never becomes general effectiveness.

## Where the receipts live

- The ledger itself is `benchmarks/claims.json` in the repository — every
  claim with its scope, sources, and requirements.
- Admitted evidence artifacts live under `benchmarks/evidence/admitted/`,
  named by their own SHA-256, and a validator suite replays each one.
- The per-surface view is the [conformance report](CONFORMANCE.md), generated
  from the same program.
- The dashboard task (`mix benchmark.dashboard`, source checkout only)
  recomputes claim state from evidence rather than trusting this page — if
  this page and the dashboard ever disagree, the dashboard wins.

The discipline behind the ledger is simple: a public claim should state its
scope and point to observable evidence. The generated dashboard may group that
information into surfaces, claims, requirements, and profiles for maintainers;
users should not need those counts to decide whether the documented workflow
works for them.

## Historical negatives: bug-or-benign verdicts (2026-08-09)

Under the parity frame — pinned DSPy/GEPA/MIPRO are replicated results, so a
faithful port should match them — each historical negative was diagnosed from
its retained artifacts as either a config that could not show lift even
upstream (benign) or an Imp fidelity defect (bug).

| Negative | Verdict | Why |
|---|---|---|
| HotPotQA JSON-GEPA, mean lift −0.015 (3 seeds, GPT-5.4-mini task / Sonnet 4.6 reflection) | **Benign** | 32 semantic metric calls vs the GEPA artifact's 6,871 for HotpotQA (`tmp/gepa-artifact/scripts/experiment_configs.py`); −0.015 is below the 24-row test's 0.042 per-row granularity; instructions verifiably mutated and selection improved before failing to transfer from an 8-row selection set. The strict one-attempt JSON policy also scored 6 parse failures as zeros on one seed — a declared conservative deviation from DSPy's retrying adapters. |
| Banking77 modeled-MIPRO, two conditions missed the ≥0.05 bar | **Benign** | Both conditions were *positive* (means +0.0417 and +0.0208, 2/3 seeds each; verified against `benchmarks/results/banking77-mipro-*`); the preregistered bar exceeded what a 48-row test at a 0.875–0.93 baseline ceiling can resolve (one row = 0.0208). The postmortem verified real proposals, attached demos, and legal Optuna acquisitions. |
| Grue stateful-agent GEPA, 0/3 seeds lift (local llama3.2:3b) | **Benign — metric floor** | Every candidate scored 0.0 on every selection row: GEPA received zero signal to optimize against, and strict admission correctly retained baseline. Reflected candidates were real and varied (inspected in the retained raw results). Upstream GEPA given an all-zero frontier returns the seed program identically. |
| IFBench optimization interpretation | **Bug — fixed and disclosed** | Scorer represented nested rule arguments incorrectly and used a non-pinned language fallback; fixed source-exact at `8c798d2e` with the superseded interpretation explicitly withdrawn. |

None of the benign verdicts double as effectiveness evidence: they say the
configs could not have resolved a lift, not that lift exists. The matched
campaign remains the instrument that can.
