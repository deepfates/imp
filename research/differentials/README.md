# Differential notes

One note per family, saying what that differential compares Imp against, what
it found, and what it deliberately does not establish. They are written for
someone reading the differential's output or changing the implementation it
guards — not as a second user manual.

[research/BENCHMARKS.md](../BENCHMARKS.md) is the index: it lists every command,
what each one needs, and links back here. `mix differential.check` runs them
all against the pinned upstream sources.

The pinned upstream is DSPy 3.2.1 at commit
`29448ae12756abdd14bd8796c819247ebb83673c` and GEPA 0.1.4, materialized under
`tmp/` by the setup scripts. Two newer probes compare against DSPy 3.3.1
(`638e155c`) instead and say so where they appear.

- **Adapters and rendering** — [ADAPTER_FIDELITY.md](ADAPTER_FIDELITY.md)
- **Instruction optimizers (MIPROv2, SIMBA)** — [INSTRUCTION_OPTIMIZER_FIDELITY.md](INSTRUCTION_OPTIMIZER_FIDELITY.md)
- **GEPA reflection aggregation** — [COMBEE_FIDELITY.md](COMBEE_FIDELITY.md)
- **Weight composition (BootstrapFinetune, BetterTogether)** — [WEIGHT_COMPOSITION_C1.md](WEIGHT_COMPOSITION_C1.md)
- **GRPO / mmGRPO** — [MMGRPO_C1.md](MMGRPO_C1.md)
- **Avatar actor and trajectory optimizer** — [AVATAR_FIDELITY.md](AVATAR_FIDELITY.md)
- **Playbook parameters** — [PLAYBOOK_OPTIMIZER.md](PLAYBOOK_OPTIMIZER.md)
- **Recursive Language Models** — [RLM_FIDELITY.md](RLM_FIDELITY.md)
- **ReAct family and code execution** — [REACT_V2_FIDELITY.md](REACT_V2_FIDELITY.md)
- **Auto-evaluation metrics** — [AUTO_EVALUATION_DIFFERENTIAL.md](AUTO_EVALUATION_DIFFERENTIAL.md)
- **Confidence and calibration** — [CONFIDENCE_CALIBRATION.md](CONFIDENCE_CALIBRATION.md)
- **Multimodal primitives** — [MULTIMODAL_FIDELITY.md](MULTIMODAL_FIDELITY.md)
- **Failure and recovery** — [FAILURE_RECOVERY_EVIDENCE.md](FAILURE_RECOVERY_EVIDENCE.md)
- **Ax, an independent TypeScript implementation** — [AX_DIFFERENTIAL.md](AX_DIFFERENTIAL.md)
- **DSPy's own test suite, ported and accounted for** — [UPSTREAM_EXAM.md](UPSTREAM_EXAM.md), the disposition map for `test/upstream_exam/`
- **Which tutorial and example covers which family** — [TUTORIAL_EXAMPLE_PARITY.md](TUTORIAL_EXAMPLE_PARITY.md)
- **Prior art and neighbouring systems** — [RESEARCH_LANDSCAPE.md](RESEARCH_LANDSCAPE.md), a dated outside view

A differential proving Imp matches upstream on an input says nothing about
whether either helps your program. Held-out effectiveness numbers live in
[research/RESULTS.md](../RESULTS.md), and there are only three.

Dated observations in these notes remain true at the date they record. They do
not silently become current decisions.
