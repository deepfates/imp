# RLM benchmark data

This directory contains acquisition metadata and deterministic normalizers for
the RLM paper campaign. Large normalized corpora are generated local artifacts,
not Git or Hex package contents. Their pinned source and normalized digests are
the reproducibility boundary. Presence here does not establish a paper-exact T3
execution protocol.

Use a Python 3 virtual environment with the verified `pyarrow` release, for
example: `python3 -m venv .venv-rlm && .venv-rlm/bin/pip install
pyarrow==25.0.0`. Then run `.venv-rlm/bin/python
benchmarks/data/rlm/fetch.py` to atomically download the complete
public sources at the revisions in `provenance.json`, verify source digests,
normalize them, and verify the resulting JSONL digests. `normalize.py` remains
available as the offline transform. JSONL output uses sorted keys, compact JSON,
UTF-8, and LF endings.

To materialize OOLONG-Pairs only, use `.venv-rlm/bin/python
benchmarks/data/rlm/fetch.py --family oolong_pairs`. This fetches all
20 questions, all 11 complete answer files, and all seven pinned OOLONG
validation shards. The generated JSONL contains one reserved `__contexts__`
row with the canonical unlabeled contexts, followed by 20 query rows containing
only identity, question, and `gold_by_context_size`. DSEx hydrates contexts
while loading and expands each selected query to 11 evaluated rows. The exact
normalized artifact SHA-256 is
`11b58e289d19152c3e6fa80f347e250021a6fe25f181925bac8e4e4ca2a4d4cc`.

Campaign `--plan` uses a bounded-memory metadata scan: it streams the pinned
file hash, row count, and identity/layout markers without decoding context or
gold bodies. Execution uses the full loader and remains fail-closed on the
same hash, identity, and shape checks.

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
- OOLONG-Pairs: the authoritative 20 questions, all 11 per-length gold files,
  and the seven-shard OOLONG context source are pinned. Normalization selects
  the canonical unlabeled context window for each length once in the reserved
  `__contexts__` row and preserves each length's gold set in the query rows;
  Elixir hydrates and expands every query to exactly 11 rows. The
  context-window mapping is an operator reconstruction matched to the public
  gold counts. The paper-promised pair scorer is not public, so the versioned
  set-F1 parser is an operator metric and this tranche remains T2-only.

BrowseComp construction must reject a row unless it has exactly 1,000 unique
document IDs and the union of its official gold and evidence qrels is a subset
of those IDs. Gold/evidence labels are scoring metadata and must not be exposed
to a runtime prompt. The official answer score is an LLM judge, while evidence
and gold retrieval use `trec_eval`; neither is scalar exact match.
