---
id: imp-k1od
status: open
deps: []
links: []
created: 2026-08-13T07:18:07Z
type: gepa
priority: 0
assignee: deepfates
parent: imp-yme4
---
# HoVer full-scale GEPA replication: provision, preregister, run

Owner-directed 2026-08-11: prove imp works on a STANDARD benchmark people actually use with DSPy, not a bespoke task. HoVer chosen as the nearest-credible GEPA-paper family (source-exact BM25 retrieval matching upstream; design already source-faithful).

DESIGN ALREADY CORRECT IN benchmarks/data/gepa-campaign-full/families.json: hoverBench split_counts train 150 / dev 300 / test 300 (exactly the gepa-artifact authors' sizes, benchmark.py:30-32 — NOT the starved 16/32/64 that made IFBench unreadable), metric_calls 7051, program HoverMultiHop, metric hover_utils.discrete_retrieval_eval, signature 'claim -> retrieved_docs'. Full campaign manifest exists at benchmarks/config/gepa-paper-campaign-v2.json (seeds [0,1]).

PROVISIONING STATE:
- DONE corpus: wiki.abstracts.2017.jsonl (1.7GB) downloaded from the manifest's source_url and VERIFIED sha256 c006527c... == manifest corpus_checksum.
- DONE isolated venv tmp/gepa-provision-venv (datasets 5.0.1 + bm25s + PyStemmer, now also the pinned dspy lock). Deliberately NOT installed into tmp/dspy-parity-venv or tmp/ifbench-parity-venv — mutating a shared pinned environment is the exact defect class that broke the TREC seal (imp-x83e).
- TODO splits: mix imp.benchmark.gepa_dataset --gepa-root tmp/gepa-artifact --out benchmarks/data/gepa-campaign-full --python <provision venv>, with PYTHONPATH=tmp/dspy-3.2.1:tmp/gepa-v0.1.4/src:tmp/gepa-artifact. Failed twice so far on missing modules in the provisioning venv (datasets, then pydantic); installing the pinned lock is the current attempt.
- TODO BM25 index: bm25s_retriever over the corpus; manifest index_checksum c35ec786... must match.

FALSE STATUS FOUND AND GUARDED: families.json declared retrieval status 'present' while corpus AND index were both absent — the earlier 'live present, capped' HoVer rows ran off a 1,485-row retriever_cache/cache.db, not a corpus. test/gepa_family_manifest_provisioning_test.exs now COMPUTES this from the filesystem and currently fails on the missing index (correct). Third instance today of a declared status contradicting the filesystem; treat as this repo's characteristic failure mode.

BEFORE ANY PAID CALL (lessons from the $68 IFBench rehearsal, non-negotiable): preregister splits/budget/seed-count with a power estimate computed FIRST; report outcomes as two numbers (parse rate, score-given-parse) so an adapter effect cannot masquerade as an optimizer effect; set rng_algorithm :python_v3 so both arms draw identical minibatches (common random numbers, free variance reduction); cost-estimate from measured per-call spend before launching.

