# TREC question-classification subset attribution

`confidence-calibration-trec-fine.jsonl` is a 400-row materialization (200
calibration, 200 held-out) of the TREC question-classification corpus with
fine-grained labels. `benchmarks/data/confidence-calibration-trec-fine.provenance.json`
records the two source files, their SHA-256 digests, the deduplication and
overlap rules, and the selection seed;
`benchmarks/data/build_confidence_calibration_trec.py` rebuilds it.

The matched GEPA/MIPROv2 experiment in
`examples/matched_instruction_optimizers_trec/` draws its 20 train, 40
selection and 80 held-out rows from this file. Those splits are listed by
source id in that example's `contract.json`.

Source:

- Project: https://cogcomp.seas.upenn.edu/Data/QA/QC/
- Files: `train_5500.label`, `TREC_10.label`
- Dataset card: https://huggingface.co/datasets/CogComp/trec
- Papers: Li and Roth, COLING 2002; Hovy et al., HLT 2001

**License: unknown.** The pinned dataset card states no license, and the
project page distributes the label files without one. The provenance file
records this as `"unknown (as reported by the pinned dataset card)"` rather
than guessing. The repository's MIT license covers our code and our derived
split files; it makes no statement about the underlying corpus. If you intend
to redistribute these rows, resolve the license with the corpus authors first.
