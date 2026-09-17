# Evidence

This page says what kind of evidence stands behind which kind of claim. The
numbers themselves are in
[benchmarks/RESULTS.md](https://github.com/deepfates/imp/blob/main/benchmarks/RESULTS.md),
one row each, with dataset, model, provider, date, commit and command.
[Benchmarks](https://github.com/deepfates/imp/blob/main/docs/BENCHMARKS.md) says what running any of those commands costs you
and which claims cannot be re-measured at all.

There is deliberately no aggregate score, no readiness grade, and no dashboard.

## Four different questions

These get blurred together constantly, usually to a vendor's advantage. Imp
keeps them apart, and the labels below are used consistently across this
repository.

| | The question | How it is answered here |
| --- | --- | --- |
| **C0** | Does the API exist and run? | Ordinary tests |
| **C1** | Does it behave like the pinned upstream? | A deterministic differential against DSPy 3.2.1 (`29448ae12756abdd14bd8796c819247ebb83673c`) and GEPA 0.1.4 for the families that have one; a behavioral conformance test otherwise |
| **C2** | Does it work through its real boundary? | Real transport, real process tree, real artifact round-trip |
| **C3** | Does it actually help? | A held-out number on data nothing selected for |
| **C4–C5** | Does it replicate a paper, or beat an alternative? | Not claimed for anything in this repository today |

A faithful port of an optimizer is a different claim from that optimizer
improving your program. C1 says the first; only C3 says the second, and only
for the task, model and budget it was measured on.

## Where fidelity evidence comes from

The differentials. They compare Imp against pinned upstream source on
deterministic inputs, run in CI at no cost, and have no sampling noise. They
earn their keep: one of them found that GEPA's Pareto pruning broke ties by an
Elixir term-printing artifact rather than upstream's stable discovery order — a
trajectory-level defect that no end-to-end score comparison at any power we can
afford would have detected.

`mix differential.check` runs them all. Per-family notes, saying what each one
compares and what it deliberately does not, are in
[docs/differentials/](https://github.com/deepfates/imp/tree/main/docs/differentials).

## Where effectiveness evidence comes from

Two held-out results, both small, both in RESULTS.md.

Rows R1 and R2 are the ticket-routing tutorial: a zero-shot enum router scored
0.30–0.50 on twenty held-out tickets and 0.95–1.00 after `LabeledFewShot(k: 8)`,
over three live repeats at about a cent each. A stranger with an API key can run
that command and get their own numbers. It is the only end-to-end effectiveness
claim here that is reproducible from scratch.

Row R6 is `examples/deployment/agent_optimization.exs`, the first ordinary Imp
user story that optimizes an agent which actually takes actions. It exposes
three sandboxed ReActV2 tool descriptions as program components, lets Optimize
Anything propose replacements, selects on separate rows, evaluates on four
untouched requests, writes the selected parameter Artifact, reconstructs the
trusted tool functions in a fresh BEAM, and scores the actual ordered tool
calls, results, termination and final answer rather than trusting model prose.
Its held-out mean moved from 0.95 to 1.0 — one point on a four-point
instrument — with task calls on `gpt-5.4-mini` and reflection calls on
`claude-sonnet-4.6`, both through OpenRouter, on 2026-08-23 at `8a6ce8fd`.

That is one stochastic treatment over four requests. It exercised a real
component-optimization, action-observation, Artifact and restart path. It does
not establish agent effectiveness, external-side-effect safety, multi-seed
optimizer effectiveness, or DSPy parity. A normal example test verifies the
retained result and Artifact, applies the Artifact to trusted code, and scans
both files for credential-shaped content.

Rows R3–R5, the matched GEPA and MIPROv2 comparison on TREC, are a third kind:
recomputable from committed scored rows, but not reproducible, because the raw
provider traces were not published. [The case study](CASE_STUDY_TREC.md) says so
in its first paragraph.

## The record of things that did not work

RESULTS.md ends with a table of findings that are not results: a HotPotQA
GEPA run with negative mean lift, a Banking77 MIPRO run that missed its
preregistered bar, a stateful-agent run where every candidate scored zero so
the optimizer had no signal at all, a scorer defect that invalidated a set of
our own optimizer results, and a matched IFBench rehearsal that stopped before
producing a verdict and whose earlier reported comparison is withdrawn in full.

None of these can be re-measured from this repository, and the table says so.
They are kept because a record that only contains successes is not a record.
A completed treatment keeps its negative verdict; a no-signal treatment stays
unresolved; a diagnosed defect is repaired at the layer that owned it and its
results are withdrawn rather than rescored.

## Execution traces

Execution traces, bounded native run observations, cancellation evidence and
portable ATIF trajectories are described in
[Execution evidence and ATIF](TRAJECTORIES.md).
