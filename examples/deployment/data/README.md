# Deployment example data

Each file here carries its own source record. This note surfaces what those
records say, so you do not have to open the JSON to find the license.

| File | Source | License |
| --- | --- | --- |
| `banking77-mipro-stage1.json`, `banking77-mipro-confirmatory-v1.json` | `PolyAI/banking77` on Hugging Face; the receipts pin the parquet files by SHA-256 and record the exclusion, normalization and ordering rules used to derive the splits | CC-BY-4.0, as declared in the receipts |
| `hotpotqa-gepa/{train,selection,test}.jsonl` | `hotpotqa/hotpot_qa`, `distractor` config, `validation` split, revision `1908d6af`; `receipt.json` pins the parquet by SHA-256 | CC-BY-SA-4.0, as declared in `receipt.json` |

The agent-optimization story
(`examples/deployment/agent_optimization.exs`) uses neither file. Its train,
selection and held-out requests are written inline in that script — a dozen
short support requests about accounts, billing and security, invented for the
example. They are MIT, like the rest of this repository, and they are far too
few and too tidy to support a claim about agent behavior in general. See row R6
in [benchmarks/RESULTS.md](../../../benchmarks/RESULTS.md).

The repository's MIT license covers our code and our derived split files. It
does not replace the licenses above for the underlying corpora.
