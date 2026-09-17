# GEPA six-family splits attribution

`gepa-campaign-full/families.json` pins the six families of the GEPA paper's
benchmark — AIMEBench, HotpotQABench, hoverBench, IFBench, LiveBenchMathBench
and Papillon — by family name, program shape, signature, upstream metric, split
row counts and a SHA-256 for each of the train, dev and test splits.

**The split files themselves are not in this repository.** `families.json` is a
manifest of data that is absent: nothing under `benchmarks/data/` matches those
checksums, for any of the six families. Any claim that rests on running these
splits therefore cannot be re-measured here. See the "Cannot be re-measured"
section of [docs/BENCHMARKS.md](../../docs/BENCHMARKS.md).

Upstream source, as recorded in the manifest:

- GEPA artifact repository, commit `cbefbc1aa0f43dd39874ec4bf42211365dbda42e`:
  https://github.com/gepa-ai/gepa-artifact
- GEPA paper: https://arxiv.org/abs/2507.19457

The underlying corpora have their own licenses, which differ per family:
HotpotQA is CC BY-SA 4.0, HoVer derives from HotpotQA and Wikipedia, and
Papillon uses the PUPA corpus. AIMEBench, IFBench and LiveBenchMathBench are
**unknown**: the artifact repository does not declare a license for them and we
have not resolved one. The manifest's `dataset_aliases` name the Hugging Face
repositories where two of the six can be obtained.
