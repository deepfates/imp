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
verdict. In a source checkout, `docs/maintainers/RELEASE.md` defines the
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
