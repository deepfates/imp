# RLM benchmark data

This directory contains acquisition metadata and deterministic normalizers for
the RLM paper campaign. Large normalized corpora are generated local artifacts,
not Git or Hex package contents. Their pinned source and normalized digests are
the reproducibility boundary. Presence here does not establish a paper-exact T3
execution protocol.

Run `python3 benchmarks/data/rlm/fetch.py` to atomically download both complete
public sources at the revisions in `provenance.json`, verify their source
digests, normalize them, and verify the resulting JSONL digests. OOLONG
normalization requires `pyarrow`. `normalize.py` remains available as the
offline transform. JSONL output uses sorted keys, compact JSON, UTF-8, and LF
endings.

## Status

- `longbench_v2_codeqa.jsonl` (generated): complete official 50-row Code
  Repository Understanding / Code repo QA split.
- `oolong_trec_coarse.jsonl` (generated): complete official paper-era 50-row
  `trec_coarse` validation selection at 131,072 tokens.
- S-NIAH: blocked on unpublished paper-author generation choices and frozen
  instances. RULER's generator is pinned, but substituting a newly generated
  set would not recover the paper set.
- BrowseComp+ (1K): official queries, corpus, qrels, and scorer are pinned. The
  paper does not publish the 150 query IDs, document-sampling seed, or sampled
  1,000-document lists. The preregistered operator query selection is recorded,
  but is not mislabeled as the paper-author selection.
- OOLONG-Pairs: the authoritative 20 questions and all 11 per-length gold files
  are pinned. The current loader has one scalar answer per query and therefore
  cannot represent the different gold pair set at each context length. The
  paper-promised pair scorer is not public, so the versioned set-F1 parser is an
  operator metric and cannot authorize a paper-exact scoring claim.

BrowseComp construction must reject a row unless it has exactly 1,000 unique
document IDs and the union of its official gold and evidence qrels is a subset
of those IDs. Gold/evidence labels are scoring metadata and must not be exposed
to a runtime prompt. The official answer score is an LLM judge, while evidence
and gold retrieval use `trec_eval`; neither is scalar exact match.
