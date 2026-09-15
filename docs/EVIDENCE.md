# Evidence: What Imp Has Actually Exercised

This page separates API existence, semantic fidelity, real operation, and
effectiveness. The distinctions are useful; turning them into a single release
score is not. Follow the linked test, protocol, and retained result for the
claim you care about.

## The ladder

Each rung answers a different question. **Asserted** means maintainers intend a
statement at its named scope; it is not proof by itself. A claim that is not
asserted remains a **target**, the index's word for work not yet established.

| Rung | What it proves |
| --- | --- |
| **C0** | The API exists and is callable. |
| **C1** | Behavior conforms to a pinned authority for the declared scope — an executable differential against real DSPy 3.3.1 for the families that have one (the optimizer and adapter families), a behavioral conformance test otherwise. |
| **C2** | The capability executes operationally through its real boundary (real transport, real process tree, real artifact round-trip). |
| **C3** | Held-out evidence supports effectiveness for the declared task portfolio — a number on data nothing selected for. |
| **C4** | An exact paper protocol is reproduced from public authoritative materials. |
| **C5** | Powered, paired evidence supports comparative advantage. |

The rungs deliberately separate three questions that marketing language
usually blurs: *is it there* (C0), *is it faithful and operational* (C1–C2),
and *does it actually help* (C3–C5). A faithful port of an optimizer is a
different claim from that optimizer improving your program.

## Read the current state

Start with the documented user story and run its real path. The maintainer
release procedure requires a clean consumer to install, optimize, inspect,
persist, restart, and serve a program through the public API. For compatibility
or research claims, inspect the named authority and retained artifact directly.
There is deliberately no generated global readiness dashboard.

Imp does not claim that an optimizer helps a task until a held-out result says
so. Task-scoped positive, neutral, negative, and stopped results keep their
exact limitations in the result artifact and linked example; a higher rung on
one task never becomes general effectiveness.

## Where the receipts live

- Broad or comparative statements may be indexed in `benchmarks/claims.json`
  with their scope, sources, and requirements.
- Admitted evidence artifacts live under `benchmarks/evidence/admitted/`,
  named by their own SHA-256, and a validator suite replays each one.
- The [conformance report](CONFORMANCE.md) is an audit aid generated from
  pinned authority and implementation mappings; it is not a release score.
- Execution traces, bounded native run observations, cancellation evidence,
  and portable ATIF trajectories are described in
  [Execution evidence and ATIF](TRAJECTORIES.md).

The discipline is simple: a public claim states its scope and points to
observable evidence. Users should not need maintainer bookkeeping to decide
whether the documented workflow works for them.

## A live executed-agent lifecycle now works

The packaged `examples/deployment/agent_optimization.exs` is the first ordinary
Imp user story that optimizes an agent which actually takes actions. It exposes
three sandboxed ReActV2 tool descriptions as program components, lets Optimize
Anything propose natural replacements, selects on separate rows, evaluates on
four untouched requests, writes the selected parameter Artifact, reconstructs
the trusted tool functions in a fresh BEAM, and scores the actual ordered tool
calls, results, termination, and final answer rather than trusting model prose.

The clean rerun at `8a6ce8fd8f5d67da90ab2defeddf7930b1a2a851` improved the
held-out mean from `0.95` to `1.0`. Its selected billing-action description
removed the baseline's unnecessary account lookup on the refund case, and the
selected Artifact scored `1.0` after application to freshly reconstructed
trusted tools in a second BEAM. The run used 72 task requests and three
reflection requests for `$0.054251` and `$0.010494` respectively, under
separate one-dollar hard caps.

This is one stochastic treatment over four held-out requests. It exercised a
real component-optimization, action-observation, Artifact, and restart path; it
does not establish general agent effectiveness, external-side-effect safety,
multi-seed optimizer effectiveness, or DSPy/Ax parity. The
[result](../examples/deployment/evidence/agent-optimization-result.json)
(`6293a68b…`) binds the disjoint row identities, ordered action observations,
budgets, source commit, and the retained parameter
[Artifact](../examples/deployment/evidence/agent-optimization-artifact.json)
(`302c0bad…`). A normal example test verifies the pair, applies the Artifact to
trusted code, and scans both files for credential-shaped content. These files
belong to the executable deployment story rather than the comparative research
registry; their narrow result must not be promoted into a broad C3 claim.

## Historical red results and their classifications

Under the parity frame — pinned DSPy/GEPA/MIPRO are replicated results, so a
faithful port should match them — each historical negative was diagnosed from
its retained artifacts as either a config that could not show lift even
upstream (benign) or an Imp fidelity defect (bug).

| Negative | Verdict | Why |
|---|---|---|
| HotPotQA JSON-GEPA, mean lift −0.015 (3 seeds, GPT-5.4-mini task / Sonnet 4.6 reflection) | **Scientific negative for this treatment** | The declared treatment completed and did not improve held-out performance. Its 32 semantic metric calls were tiny beside the GEPA artifact's 6,871 for HotpotQA, the 24-row test moves in 0.042 steps, and six strict-adapter parse failures scored zero on one seed. Those facts motivate a different future treatment; they do not turn this completed negative into a positive or a product defect. |
| Banking77 modeled-MIPRO, two conditions missed the ≥0.05 bar | **Scientific negative against the preregistered bar** | Both conditions had small positive means (+0.0417 and +0.0208; 2/3 improving seeds each), but neither met the declared ≥0.05 criterion. Real proposals, attached demos, and legal acquisitions make this a clean result. The 48-row test and high baseline explain its resolution limit; they do not retroactively change the threshold. |
| Grue stateful-agent GEPA, 0/3 seeds lift (local llama3.2:3b) | **Unresolved no-signal treatment** | Every candidate scored 0.0 on every selection row, so the optimizer had no ranking signal and correctly retained baseline. Reflected candidates were real and varied. This establishes that the treatment could not answer the usefulness question, not that GEPA is ineffective or that the product is broken. |
| IFBench optimization interpretation | **Product/integration defect — fixed and disclosed** | The scorer represented nested rule arguments incorrectly and used a non-pinned language fallback; fixed source-exact at `8c798d2e` with the superseded interpretation explicitly withdrawn. |

None of these red results is erased. Completed valid treatments keep their
negative verdicts; a no-signal treatment remains unresolved; a diagnosed defect
is repaired at the layer that owned it. A successor experiment must be named
and selected for a reason established before its outcomes are read.

## The matched campaign: state as of 2026-08-20

**Nothing in this section is effectiveness or fidelity evidence.** It records
what an *engineering rehearsal* established, and — as importantly — what an
earlier draft of this section wrongly claimed.

The 16k rehearsal (`examples/matched_ifbench_rehearsal16k`) is scoped by its
own contract as `one_seed_engineering_rehearsal_source_faithful_config`:
it exercises machinery and cost at the benchmark authors' settings before any
larger spend, and by preregistration claims nothing about optimizer
effectiveness. On its eleventh launch both runtimes completed baseline, GEPA,
and MIPROv2 and sealed all six optimization-and-selection cells at 16384-token
settings for $16.42. The campaign itself did not complete: it stopped in the
held-out phase on an input-token bound of our own (4096, exceeded by a
4243-token prompt), so it produced no held-out optimizer verdict. Ten prior
launches stopped on harness defects, each dated in `PREREGISTRATION.md` and
archived under `evidence/matched/`.

**Withdrawn.** An earlier version of this section reported "GEPA optimization
moves at source-faithful budget, and imp's magnitude matches upstream's,"
citing imp 0.8542 vs upstream 0.8698. That comparison was invalid: imp's figure
was its optimizer's *internal* champion score (a maximum over noisy trials,
biased upward by selection), while upstream's was an *independent re-scoring*
of the champion program. They are different quantities. The claim is withdrawn
in full, and no lift or parity conclusion replaces it — the rehearsal is not
powered to support one. A single paired cell in this design carries roughly
±0.09; the effects at issue are 0.05–0.10.

**A measurement worth keeping.** Across takes, per-cell score variation is
dominated not by task performance but by **ChatAdapter parse failures scored
zero** — upstream logged 0–5 such rows per 32-row evaluation (mean 8.3%), and
the count correlates with the take's mean at r = -0.84. Any future outcome
must be reported as two numbers, parse rate and score-given-parse; a single
mean silently absorbs a format-robustness effect and cannot answer a question
about optimizers.

**A repaired parity boundary.** This rehearsal used Imp's explicitly
startup-only Optuna mode, so both arms were limited to 9 post-baseline trials;
that historical treatment remains exactly what its artifact records. Imp now
also implements the pinned modeled Optuna 4.9.0 categorical TPE path and
exercises startup, the first Bayesian opportunity, checkpoint resume, public
compile, and minibatch selection against pinned upstream behavior. A documented
floating-point tie boundary prevents a claim of bit-exact NumPy identity, but
modeled TPE is no longer the blocker to normal source-scale MIPRO use. These
differentials establish search mechanics, not broad live effectiveness; the
latter still requires natural retained optimizer lifecycles and representative
held-out evidence.

**Where fidelity evidence actually comes from.** The C1 rung, not this campaign.
Deterministic differential tests against pinned DSPy 3.2.1 and gepa 0.1.4 —
including a recorded-tape GEPA component comparison of reflective datasets,
reflection prompts, module rotation, and stopping decisions — run in CI at no
cost and with no sampling noise. That instrument is strictly better suited to
the question, and it earns its keep: it exposed a real divergence in GEPA's
Pareto pruning (ties broken by an Elixir term-printing artifact rather than
upstream's stable discovery order), a trajectory-level defect that an
end-to-end score comparison at this power could never have detected.
