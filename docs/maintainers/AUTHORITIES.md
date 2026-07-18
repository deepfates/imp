# Authority Index

`benchmarks/authorities.json` is the machine-readable upstream authority
inventory for Imp's claimed algorithm and benchmark families. It is an audit
ledger, not proof by itself. A pinned source identifies what should be compared;
it does not show that Imp conforms to it. A paper identifies a research claim;
it does not establish a faithful implementation or a reproduced result. Local
tests and artifact paths identify evidence locations, but their presence alone
does not establish freshness, validity, scale, or a passing verdict.

## Scope

The inventory is derived from:

- `benchmarks/claims.json`
- `docs/CONFORMANCE.md`
- `docs/internal/COVERAGE_MATRIX.md`
- `docs/internal/PARITY_VALIDATION_PROGRAM.md`
- `docs/internal/INSTRUCTION_OPTIMIZER_FIDELITY.md`
- `docs/internal/RESEARCH_LANDSCAPE.md`

Every family row maps the exact claim surface tokens it owns, upstream-surface
ledger IDs, Coverage Matrix concepts, and Parity Validation Program lanes. A
token may be owned by more than one family when the claim is cross-cutting. The
test contract fails when a source inventory adds an unmapped token, concept,
surface ID, or parity lane.

## Row Contract

Each row records five independent authority dimensions:

| Dimension | What it records | Gap rule |
| --- | --- | --- |
| `upstream_repository` | Repository, release/version, git ref, commit, source paths, and a digest-bound per-file source manifest | Unknown immutable coordinates remain `null`; a repository name alone is not a pin. |
| `primary_authority` | Primary paper or specification locator and revision | Missing or non-primary documentation is recorded as `gap` or `no_primary_authority`. |
| `upstream_tests` | Whether the audited upstream tree has relevant tests | Unaudited coverage is `not_audited`; absence is not inferred from silence. |
| `dataset_protocol` | Dataset split/protocol references and immutable digests | A named dataset without source and split digests is `partial`, `protocol_defined`, or `gap`. |
| `local_differential` | Checked-in or generated Imp-vs-upstream artifact locations | Unit tests and artifact globs are not promoted to completed differential proof. |

All five blocks are required on every row. Empty arrays and explicit `null`
values are intentional: they prevent a consumer from confusing an omitted field
with an established authority.

Pinned repository rows reference `benchmarks/authority_sources/*.json`. Each
manifest binds the repository and commit to every tracked file under the row's
declared source paths with a SHA-256 digest. The ledger also binds the complete
manifest bytes and file count. Authority loading fails closed on a changed
manifest, an uncovered source path, duplicate paths, or repository/commit drift.

## Status Vocabulary

Repository statuses are `release_and_commit_pinned`, `commit_pinned`, `gap`,
and `not_applicable`. Primary-authority statuses are `pinned`, `identified`,
`no_primary_authority`, `gap`, and `not_applicable`. Upstream-test statuses are
`present`, `partial`, `absent`, `not_audited`, and `not_applicable`.
Dataset/protocol statuses are `pinned`, `protocol_defined`, `partial`, `gap`,
and `not_applicable`. Local-differential statuses are `present`, `partial`,
`gap`, and `not_applicable`.

`identified` means the audit names an authority but does not establish an
immutable revision. `protocol_defined` means the required procedure is stated
but immutable input data is not fully pinned. `partial` means some relevant
material exists while the complete authority or evidence contract remains
open.

## Family Summary

<!-- evidence-authority-summary:start -->
| Family | Kind | Repository | Paper/spec | Upstream tests | Dataset/protocol | Local differential |
| --- | --- | --- | --- | --- | --- | --- |
| Package, public API, documentation, and release | product | 3.2.1 @ 29448ae12756 | no_primary_authority | present | not_applicable | partial |
| DSPy programming model | algorithm | 3.2.1 @ 29448ae12756 | pinned | present | not_applicable | present |
| Model, provider, settings, and normalized runtime | runtime | 3.3.0b1 @ b2829b7ae3b6 | no_primary_authority | present | not_applicable | partial |
| Structured adapters and multimodal value types | algorithm | 3.2.1 @ 29448ae12756 | no_primary_authority | present | pinned | partial |
| Tools, MCP, ReAct, CodeAct, and ProgramOfThought | algorithm | 3.3.0b1 @ b2829b7ae3b6 | no_primary_authority | present | pinned | present |
| Recursive Language Models | algorithm | 3.3.0b1 @ b2829b7ae3b6 | pinned | present | partial | partial |
| Refinement, evaluation, and metrics | algorithm | 3.2.1 @ 29448ae12756 | pinned | present | not_applicable | present |
| Few-shot, KNN, and random search optimizers | optimizer | 3.2.1 @ 29448ae12756 | no_primary_authority | present | protocol_defined | partial |
| COPRO, InstructionSearch, InferRules, and SignatureOptimizer | optimizer | 3.2.1 @ 29448ae12756 | no_primary_authority | partial | protocol_defined | partial |
| MIPROv2 | optimizer | 3.3.0b1 @ b2829b7ae3b6 | pinned | absent | partial | partial |
| SIMBA | optimizer | 3.3.0b1 @ b2829b7ae3b6 | no_primary_authority | absent | protocol_defined | partial |
| GEPA prompt and program optimization | optimizer | 0.1.4 @ 8b0ce6cd99a2 | pinned | partial | protocol_defined | partial |
| Avatar, AvatarOptimizer, BootstrapFinetune, GRPO, BetterTogether, and Ensemble | optimizer | 3.2.1 @ 29448ae12756 | no_primary_authority | partial | partial | partial |
| Fast-Slow interleaved prompt and policy adaptation | optimizer | gap | pinned | absent | partial | partial |
| Optimize Anything arbitrary artifact optimization | optimizer | 0.1.4 @ 8b0ce6cd99a2 | pinned | partial | protocol_defined | partial |
| Retrieval, RAG, embeddings, and dataset loading | algorithm | 3.2.1 @ 29448ae12756 | no_primary_authority | present | pinned | present |
| Async, streaming, cache, observability, and provider-free overhead | runtime | 3.2.1 @ 29448ae12756 | no_primary_authority | present | protocol_defined | present |
| Persistence, deployment, and protocol boundaries | operations | 3.2.1 @ 29448ae12756 | no_primary_authority | present | protocol_defined | partial |
| GSM8K math | benchmark | dataset-head @ 3101c7d50724 | pinned | not_applicable | pinned | partial |
| HotPotQA and HotpotQABench | benchmark | paper-artifact @ cbefbc1aa0f4 | pinned | not_applicable | pinned | partial |
| Color and structured classification tasks | benchmark | n/a | no_primary_authority | not_applicable | partial | partial |
| AIMEBench | benchmark | paper-artifact @ cbefbc1aa0f4 | no_primary_authority | not_applicable | pinned | gap |
| HoVer / hoverBench | benchmark | paper-artifact @ cbefbc1aa0f4 | pinned | not_applicable | pinned | present |
| IFBench | benchmark | paper-artifact @ cbefbc1aa0f4 | pinned | not_applicable | pinned | present |
| LiveBenchMathBench | benchmark | paper-artifact @ cbefbc1aa0f4 | pinned | not_applicable | pinned | gap |
| Papillon privacy delegation | benchmark | paper-artifact @ cbefbc1aa0f4 | pinned | not_applicable | pinned | gap |
<!-- evidence-authority-summary:end -->

## DSPy Instruction Optimizer Pins

The instruction optimizer authority is DSPy `3.3.0b1` at full commit
`b2829b7ae3b6e276ac6a8bef66a7ec519dbc923f`. The following SHA-256 values are
copied exactly from `docs/internal/INSTRUCTION_OPTIMIZER_FIDELITY.md`:

| Source | SHA-256 |
| --- | --- |
| `dspy/teleprompt/mipro_optimizer_v2.py` | `6bf7632836d3a54ab0da3f38a8f1963813472312e9c0e3f2ff19b4377af407f3` |
| `dspy/teleprompt/utils.py` | `218c38c25dde75aab9b1d452a15c75687c2e1842d7157dcc6c695f5adbcaf182` |
| `dspy/teleprompt/bootstrap.py` | `0a588f11f09a358a5306540cc42401d905073c9452e54d32348b13d12bbb1255` |
| `dspy/propose/grounded_proposer.py` | `c9900b74c0997410f915f2a470d39dcd9d55c1fa8b9cdf35799915ec0b1617e3` |
| `dspy/teleprompt/simba.py` | `4de72e1d0cb1cd30a180569c21973c41fa272c3ebb82a365e3f307986ab67a55` |
| `dspy/teleprompt/simba_utils.py` | `ed745647ffcfcf4090e5d5b5489cd0b13ebfff1d38a22559563f4f606b31fb2c` |

The audited upstream tree has adjacent bootstrap and grounded-proposer tests,
but no dedicated MIPROv2 or SIMBA test suite. Consequently, released source is
the control-flow authority and the MIPROv2 paper is the research authority. The
matched structural task is implemented, but the local differential remains
`partial` until a fresh artifact passes the dashboard authority and freshness
checks.

## GEPA Current And Historical Pins

The current standalone GEPA authority is tag `v0.1.4` at full commit
`8b0ce6cd99a234f6b74daf37558a2ac0ce18f975`. Its complete 114-file
`src/gepa` tree is content-bound by
`benchmarks/authority_sources/gepa-0.1.4-8b0ce6c.json`. The tag retains package
version `0.1.3` in `pyproject.toml`; tag identity and package metadata are
recorded separately.

The existing exact executable contract remains GEPA `v0.1.1` at
`b4dbb55b7601dac448cdb836d5a401ca7d9eb920`. That historical tag retains
`version="0.1.0"` in `pyproject.toml`. The hashes below belong to this retained
regression contract, not the current release surface.

| Source | SHA-256 |
| --- | --- |
| `src/gepa/core/engine.py` | `92627720354261b9eb5359337b9b237a2a29ebf179b22a4b724b737bde81a088` |
| `src/gepa/core/result.py` | `5ee9ccfdf31e2d4d1262793c569e44ef7b39659a3e971e4f3dc7d656d69a1d85` |
| `src/gepa/core/state.py` | `08108908eb922808c2ad134c9717d32b107581a5766e6b99199c248d538999e5` |
| `src/gepa/gepa_utils.py` | `60aca7024e31a3e273a01187a6329f381f297a77ec7b6add4b9c90b4d64e9b6c` |
| `src/gepa/proposer/merge.py` | `cd0a3254927e399d0cae4a212076f7577161027b3c4ff19d03c3d2150408ee5a` |
| `src/gepa/strategies/component_selector.py` | `248cc6eb125eeddaa98f90b7780db2754ec0444a6143aeb1f97ff5660cf39568` |
| `src/gepa/utils/stop_condition.py` | `3f18fa989a376711dc198d60963dc9b866da6d5a81f5c5339e242b3301764a0c` |

`mix benchmark.gepa.contract.check` executes released provider-free helpers and
fixtures, then compares equivalent Imp pure-module behavior. Its T1 artifact
does not satisfy GEPA paper reproduction, effectiveness, or full-parity claims.

The ledger pins GEPA `v0.1.4` as the current algorithm authority and `v0.1.1`
as a historical executable contract, Ax `23.0.0` as an independent
implementation comparator, and ReqLLM `v1.17.1` as the BEAM runtime dependency.
Comparator pins help detect accidental design assumptions; they do not create
scientific parity claims.

Ax's selected implementation files are bound by
`benchmarks/authority_sources/ax-23.0.0-eb5835e.json`; the executable scope and
intentional native deviations are documented in `docs/internal/AX_DIFFERENTIAL.md`.

## Optimize Anything Protocol Pins

The matched differential uses the public Optimize Anything artifact at commit
`58cdf89d856f2fbc174991b89076eccdcf68e4ca`. The canonical ledger binds ten
implementation and evaluator files from that checkout. Its authors' offline
verifier covers nine published artifact domains; passing that verifier proves
that the reference corpus is available, not that Imp reproduces its results.

The bounded repository lane uses `pallets__flask-5014` from SWE-bench Verified
at dataset revision `91aa3ed51b709be6457e12d00300a6a596d4c6a3`. The ledger binds the
2 MB Parquet payload, the canonical selected row, Flask base commit
`7ee9ceb71e868944a46e1ff00b506772a53a4f1d`, the official test patch, one
FAIL_TO_PASS test, and the 59-test PASS_TO_PASS split. These pins establish
protocol identity only. A matched claim additionally requires independently
replayed evaluator traces, matched controls and realized budgets, complete
declared seed/domain coverage, and an admitted content-bound run artifact.

The Flask evaluator receipt also binds the resolved Python interpreter bytes
and a deterministic inventory of every installed distribution's name,
version, and installed-file content digest. Admission recomputes that runtime
identity, so ignored `.venv` drift cannot inherit a clean repository status.
This remains a platform-local receipt: it records the OS release and
architecture and is not a cross-platform resolver lock or container-image
identity.

## Consumption Rules

Consumers should join claim tokens to `families[].surface_tokens`, then inspect
each authority dimension independently. They must not collapse the row to a
single green/red status. A repository pin cannot substitute for a dataset pin;
an upstream test cannot substitute for a local differential; and an artifact
path cannot substitute for validating the artifact's schema, provenance,
freshness, scope, and verdict through the benchmark dashboard.
