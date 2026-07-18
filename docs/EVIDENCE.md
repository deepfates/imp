# Evidence: How Imp Grades Its Own Claims

Every capability claim Imp makes is a row in a machine-checked ledger, and
every row states how strong its evidence is. This page defines that scale, so
when another page says "verified" you can ask — verified *to what rung?* —
and check the answer yourself.

## The ladder

Each rung is a stronger kind of evidence than the one below it. A claim
declares its target rung, and it is **asserted** only when committed,
replayable evidence reaches that rung — otherwise it remains a **target**,
which is the ledger's word for "promised, not proven."

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

## Where the ledger stands

As of v0.2.0, the ledger holds **64 claims: 45 asserted, 19 still targets.**

| Rung | Claims | Asserted |
| --- | --- | --- |
| C0 | 9 | 9 |
| C1 | 25 | 25 |
| C2 | 9 | 8 |
| C3 | 19 | 3 |
| C4 | 2 | 0 |

Read the shape honestly: everything at the exists-and-conforms level is
asserted, with committed differential artifacts behind it. Most effectiveness
claims are still targets — Imp does not claim an optimizer helps your task
until a held-out score in a committed artifact says so. The three asserted C3
rows include the [ticket-routing tutorial](TUTORIAL_TICKET_ROUTING.md)'s
25–30% → 85% result, whose run artifact is content-addressed in the
repository and reproducible with one script.

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

## Why the counts differ

A skeptic reading these docs meets three different numbers, and each counts a
different thing. **Surfaces** are the grouped upstream capability areas the
[conformance report](CONFORMANCE.md) totals — 23 of them. **Claims** are the
graded rows in this ledger — 64, each targeting a rung and each attached to one
surface. **Requirement ids** are the individual checks nested inside claims, so
with the 64 claim ids they account for the 130 `id` fields in
`benchmarks/claims.json`. These numbers are current as of v0.2.0 and are
asserted nowhere but here — the dashboard is the authority if it disagrees.

The discipline behind the ledger is simple: an unclaimed surface is a place
a silent bug can live, so every public surface carries a claim, every claim
carries its evidence state, and the numbers in the docs are required to cite
committed artifacts. When you catch a page violating that, it is a bug —
file it.
