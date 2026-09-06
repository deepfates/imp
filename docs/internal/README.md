# Internal Docs

These maintainer-facing protocols and reports explain how Imp's claims are
tested against upstream systems, papers, and pinned datasets. They are not a
second user manual or roadmap, and they are excluded from the package.

Start with the question you are trying to answer:

- **What does parity require?** Read the
  [Parity Validation Program](PARITY_VALIDATION_PROGRAM.md) for the distinct
  semantic, live-model, optimizer, production, and performance evidence lanes.
- **How strong is a piece of evidence?** Read the
  [evidence handbook](../maintainers/EVIDENCE.md) before treating product,
  compatibility, operational, effectiveness, or paper evidence as equivalent.
- **Why does one implementation differ from upstream?** Read the source-bound
  fidelity note for that surface, such as
  [adapters](ADAPTER_FIDELITY.md),
  [instruction optimizers](INSTRUCTION_OPTIMIZER_FIDELITY.md), or
  [RLM](RLM_FIDELITY.md).

The repository [README](../../README.md) owns the user-facing purpose and path.
The [release procedure](../maintainers/RELEASE.md) owns the current product
finish line; machine-readable pins and artifact coordinates live under
`benchmarks/`; unfinished work lives in `tk`. Dated reports and historical
results remain useful at their recorded scope, but do not silently become
current decisions.
