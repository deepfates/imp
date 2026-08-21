---
id: imp-k1od
status: open
deps: [imp-6mls]
links: []
created: 2026-08-13T07:18:07Z
type: gepa
priority: 2
assignee: deepfates
parent: imp-yme4
---
# Run the staged HoVer GEPA replication on the shared instrument

Owner-directed 2026-08-11: prove Imp works on a standard benchmark people use
with DSPy, not a bespoke task. Provisioning, source corpus/index verification,
splits, and preregistration are complete. The next step is not an uncapped
optimizer run: migrate the campaign to the shared instrument, then execute the
preregistered baseline-only cost/parse stage. Use that measurement to write the
separate power/cost authorization for the 7,051-metric-call optimizer stage.

DESIGN ALREADY CORRECT IN benchmarks/data/gepa-campaign-full/families.json: hoverBench split_counts train 150 / dev 300 / test 300 (exactly the gepa-artifact authors' sizes, benchmark.py:30-32 — NOT the starved 16/32/64 that made IFBench unreadable), metric_calls 7051, program HoverMultiHop, metric hover_utils.discrete_retrieval_eval, signature 'claim -> retrieved_docs'. Full campaign manifest exists at benchmarks/config/gepa-paper-campaign-v2.json (seeds [0,1]).

PROVISIONING STATE:
- DONE corpus: wiki.abstracts.2017.jsonl (1.7GB) downloaded from the manifest's source_url and VERIFIED sha256 c006527c... == manifest corpus_checksum.
- DONE isolated venv tmp/gepa-provision-venv (datasets 5.0.1 + bm25s + PyStemmer, now also the pinned dspy lock). Deliberately NOT installed into tmp/dspy-parity-venv or tmp/ifbench-parity-venv — mutating a shared pinned environment is the exact defect class that broke the TREC seal (imp-x83e).
- TODO splits: mix imp.benchmark.gepa_dataset --gepa-root tmp/gepa-artifact --out benchmarks/data/gepa-campaign-full --python <provision venv>, with PYTHONPATH=tmp/dspy-3.2.1:tmp/gepa-v0.1.4/src:tmp/gepa-artifact. Failed twice so far on missing modules in the provisioning venv (datasets, then pydantic); installing the pinned lock is the current attempt.
- TODO BM25 index: bm25s_retriever over the corpus; manifest index_checksum c35ec786... must match.

FALSE STATUS FOUND AND GUARDED: families.json declared retrieval status 'present' while corpus AND index were both absent — the earlier 'live present, capped' HoVer rows ran off a 1,485-row retriever_cache/cache.db, not a corpus. test/gepa_family_manifest_provisioning_test.exs now COMPUTES this from the filesystem and currently fails on the missing index (correct). Third instance today of a declared status contradicting the filesystem; treat as this repo's characteristic failure mode.

BEFORE ANY PAID CALL (lessons from the $68 IFBench rehearsal, non-negotiable): preregister splits/budget/seed-count with a power estimate computed FIRST; report outcomes as two numbers (parse rate, score-given-parse) so an adapter effect cannot masquerade as an optimizer effect; set rng_algorithm :python_v3 so both arms draw identical minibatches (common random numbers, free variance reduction); cost-estimate from measured per-call spend before launching.


## Notes

**2026-08-21T03:23:01Z**

Provisioning is no longer the frontier: commits 75944af0 and c51404d2 verify the source corpus, isolated Python environment, BM25 index/splits, and preregistration. The next scientific step is a bounded baseline-only cost and parse-rate measurement before any uncapped optimizer campaign.

**2026-08-21T03:36:50Z**

Release-gate correction: the corpus and BM25 index are ignored multi-gigabyte machine-local research inputs, so their filesystem assertion is now tagged local_provisioning and enabled only with GEPA_LOCAL_PROVISIONING=1. The preregistration records the exact opt-in command. A clean product checkout no longer claims those external bytes must ship; the campaign host must still pass the guard before any HoVer spend.
