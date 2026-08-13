# HoVer GEPA replication — preregistration

Written **before** any paid call. Not editable after launch; corrections go in
dated addenda.

## Why HoVer, and why now

The project needs evidence that imp's optimizers help on a benchmark people
actually run with DSPy — not a bespoke workshop task. HoVer is a GEPA-paper
family with source-exact BM25 retrieval, and its design in
`benchmarks/data/gepa-campaign-full/families.json` already matches the
artifact authors' own splits. Held-out effectiveness is currently demonstrated
on exactly one family (TREC); this is the breadth gap.

## Provisioning, verified 2026-08-11 (all free, all checked by execution)

| item | state |
|---|---|
| corpus `wiki.abstracts.2017.jsonl` | 1.7 GB, sha256 `c006527c…` **matches** manifest |
| BM25 index `bm25s_retriever` | 1.0 GB, built by upstream's own `initialize_bm25s_retriever_and_corpus` (k1=0.9, b=0.4) |
| splits train/dev/test | 150 / 300 / 300, sha256 **byte-identical** to manifest `split_checksums` |
| retrieval smoke | real dev claim returns the correct multi-hop chain |
| provisioning guard | `test/gepa_family_manifest_provisioning_test.exs` green |

`families.json` had declared retrieval `status: "present"` while corpus and
index were both absent; earlier "live present, capped" HoVer rows ran off a
1,485-entry retrieval cache. That field is now computed from the filesystem.

## Fixed design (from the manifest; not chosen by me)

- program `HoverMultiHop`, signature `claim -> retrieved_docs`
- metric `hover_utils.discrete_retrieval_eval`
- splits 150 train / 300 dev(selection) / 300 test(held-out)
- GEPA budget 7,051 metric calls — the paper's own figure
- selection on dev; **test opened only after every arm seals**

## What this run must not repeat

The IFBench rehearsal cost ~$68 and could not answer its question. Its
per-cell noise was sd≈0.063, dominated by a 32-row selection set — a 10x
starvation against the authors' 300. HoVer's 300-row splits give a binomial SE
near 0.029 at p≈0.5, and paired-by-row comparison tightens it further. Three
rules follow:

1. **Report two numbers, always**: parse/format failure rate AND
   score-given-parse. In IFBench ~8% of rows scored zero on adapter parse
   failures, and parse-failure count correlated with the cell mean at
   r = -0.84. A single mean lets an adapter effect masquerade as an optimizer
   effect.
2. **Common random numbers**: `rng_algorithm: :python_v3` so imp and upstream
   draw identical minibatches from the same seed. imp ships a bit-exact
   MT19937 for this and the IFBench campaign never used it.
3. **Row-level paired analysis**, never a difference of 300-row means.

## Staged spend — measure before committing

**Stage 1 (this request, cheap):** baseline-only. Evaluate the unoptimized
`HoverMultiHop` program on the 300-row dev split, one seed, both runtimes.
This yields (a) the baseline number, (b) a *measured* cost per metric call and
per task call, (c) the parse-failure rate, (d) confirmation the retrieval path
runs under load. Estimated well under $10; the exact figure is what stage 1
exists to measure rather than guess.

**Stage 2 (separate approval):** the full 7,051-metric-call GEPA arm, seeds
and total cost projected from stage 1's measured per-call figures, with a
power estimate computed before launch. No stage-2 launch without that
projection in writing.

## Predictions, recorded now

- **P1 (machinery):** stage 1 completes with both runtimes producing 300
  scored rows and no operational stop.
- **P2 (parity):** baseline dev scores agree within the noise band implied by
  n=300; a gap materially beyond it indicates an imp defect, not noise, since
  both arms run the identical unoptimized program.
- **P3 (report-only):** the parse-failure rate on HoVer, whatever it is, is
  recorded — it sets whether a mean is interpretable at all here.

Whatever the numbers are, they are recorded and disclosed.
