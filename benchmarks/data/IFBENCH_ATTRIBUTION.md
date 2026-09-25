# IFBench rows: what is and is not IFBench here

Two different things in this repository carry the name IFBench. They have
different provenance and only one of them is the benchmark.

## `ifbench_instruction_following` — not IFBench data

`mix imp.benchmark.fetch --tasks ifbench_instruction_following` writes
`ifbench_instruction_following-test-0-N.jsonl` into the output directory. Those
rows are **written in this repository**, in
`bench/imp/benchmark_truth/fetcher.ex`, under the internal dataset name
`imp/local-ifbench`, config `verifier-smoke`. They are a handful of
hand-authored instruction/constraint pairs that exercise the constraint
verifier. They are MIT, like the rest of this repository.

They are not drawn from IFBench, they are not a sample of it, and a score on
them is not an IFBench score. Naming the task after the benchmark it was
modeled on was a mistake that this note exists to correct until the name
changes.

## The matched IFBench experiments — real IFBench, license unknown

`research/local_gepa_ifbench_cross_task/` and
`research/matched_instruction_family_ifbench/` use the real IFBench program,
metric and rows, keeping upstream split ownership, taken from the GEPA artifact
repository:

- https://github.com/gepa-ai/gepa-artifact
- GEPA paper: https://arxiv.org/abs/2507.19457
- IFBench scorer dependencies are pinned in
  `benchmarks/requirements-ifbench-parity.txt`

**License: unknown.** The artifact repository declares no license for the
IFBench data, and we have not resolved one with its authors. The corpus files
themselves are not committed here; the experiment contracts pin them by digest
and the harness materializes them. The repository's MIT license makes no
statement about that corpus.
