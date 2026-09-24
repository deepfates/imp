# Multimodal Fidelity

This document defines the evidence boundary for Imp image and native-document
quality. Typed value construction and pre-dispatch content shapes do not prove
that ReqLLM serialized those values, that a provider received them, or that a
model answered correctly.

## What has been observed

One live run, on 2026-07-13, from OpenAI manifest payload SHA-256
`04daa155d3f97edfff62e329dfdca1248855f22b2271f7e954228432f1ae39d8`. Its
record is not published; what follows is the pinned configuration it used.

The run used the pinned OpenAI Responses endpoint and model:

- endpoint: `https://api.openai.com/v1/responses`
- API: `responses`
- model: `gpt-4.1-mini-2025-04-14`
- ReqLLM: Hex package `req_llm` 1.17.1, package SHA-256
  `266c0e06c47b4562f243dcdf41332342cbed2ec37064750edd725fb66bb6e914`,
  upstream revision `33840077c2f1332eb6dff2d268dff02393014da4`

It records six dispatches in this run, zero resumed rows, six durable rows, and
6/6 exact-answer passes. Four image samples and two native-PDF samples passed.
All rows have distinct ReqLLM request IDs, OpenAI request IDs, and OpenAI
Responses IDs. The claim gate has no rejections.

The 2026-07-13 multimodal quality live run is invalidated and removed, and its
result JSON is unpublished history. Its checkpoint schema and pre-dispatch shape
evidence did not exclude forged minimal rows, so its result must not be used as
proof.

## Manifest Contract

The provider manifests are:

- `benchmarks/data/multimodal/manifest.json` for Google
- `benchmarks/data/multimodal/openai-responses-manifest.json` for OpenAI

Their strict, checksummed schema pins every sample ID, prompt, expected output,
family, delivery mode, asset byte count, MIME type, asset SHA-256, provider,
endpoint, API, exact model, generation options, and pricing. The ReqLLM
dependency is not part of the manifest: the runner reads the loaded ReqLLM
version and its Hex package checksum from `mix.lock`, refuses to run when the
two disagree, and binds that dependency into the checkpoint identity, the
request audits and the artifact. A checkpoint cannot resume under a different
ReqLLM package.

All assets are synthetic and repository-owned. Images cover shape counting,
spatial relation, and OCR. The native-document family sends the original
two-page PDF and tests a table subtotal and a cross-page join. Rendered page
PNGs are inspection aids only; they are not executed and cannot establish
native file support.

## Serialized Audit

The runner installs a Req request step after ReqLLM provider `encode_body` and
before transport — the last point at which what Imp actually sends can be
observed. For every request, the redacted audit contains:

- sanitized endpoint, API, HTTP method, serialized model, and body SHA-256;
- ordered serialized part types;
- each part's MIME type, decoded byte count, and content SHA-256;
- ReqLLM package source, version, and package hash;
- ReqLLM request ID and detected transport.

The audit never persists data URIs, base64 payloads, file bytes, prompt text, or
credentials. Pre-dispatch Imp and ReqLLM content-part intentions remain in the
artifact for diagnostics but explicitly cannot authorize claims.

The response audit records HTTP status, raw provider token usage, OpenAI request
ID headers when exposed, and provider response body IDs when exposed. The fresh
run exposes both IDs on all six rows. When an ID is absent, the row records that
limitation and does not describe the missing value as response-metadata proof.

## Checkpoint Gate

Checkpoint schema v2 binds every completed row to the complete campaign
identity and canonical manifest sample binding. A passing row must include the
expected answer, successful outcome and score, exact provider/model/API,
post-serialization request and response audits, a nonzero dispatch record,
consistent provider usage, and recomputed cost.

Checkpoint envelopes retain an unkeyed payload SHA-256 for diagnostics and add
an HMAC-SHA256 tag backed by a separate 32-byte `0600` sidecar. A recomputed
unkeyed hash is insufficient to resume. Unknown/minimal rows, wrong answers,
cross-manifest checkpoints, duplicate sample/dispatch/response IDs, ambiguous
in-progress intents, and authenticated internal inconsistencies fail closed.

The HMAC protects against checkpoint edits by a process that cannot read the
sidecar. It is not protection against the same local principal reading both the
checkpoint and key. Checkpoint files and keys remain ignored local runtime
state; the committed artifact contains no key material.

The report separates rows dispatched in the current run from rows resumed from
the checkpoint. The CLI prints `provider dispatches this run` and `checkpoint
rows resumed`; it never labels total sample rows as provider calls.

## Usage And Cost

Pricing is code-pinned to the official GPT-4.1 mini standard rates current on
2026-07-13: $0.40 per million uncached input tokens, $0.10 per million cached
input tokens, and $1.60 per million output tokens.

The fresh provider response explicitly reports zero cached input tokens. The
artifact therefore records 5,716 uncached input tokens, 0 cached input tokens,
47 output tokens, and exact cost `$0.002361600`. Cached and uncached input are
priced separately for every row. If the provider omits cache classification,
cached and uncached counts and all cost amounts become unavailable, `exact` is
false, the row cannot pass, and no exact-cost claim is emitted.

## Verification

Provider-free tests execute the real ReqLLM OpenAI Responses serializer against
a local HTTP fixture. That fixture proves redacted image and PDF serialization
behavior without authorizing a provider claim because its endpoint differs
from OpenAI. The suite also covers:

- six authenticated rows containing only family and score;
- unkeyed-SHA tampering and authenticated wrong answers;
- duplicate ReqLLM dispatch IDs and duplicate provider response IDs;
- cross-manifest resume attempts;
- missing provider cache classification;
- durable crash/resume dispatch accounting;
- credential and payload redaction.

Run the provider-free plan and tests with:

```sh
mix imp.benchmark.multimodal_quality --profile openai-responses \
  --plan --out tmp/multimodal-plan
mix test test/multimodal_quality_benchmark_test.exs \
  test/multimodal_adapter_test.exs \
  test/optimizer_report_multimodal_test.exs \
  test/optimize_anything_multimodal_test.exs
```

Execute a clean or resumable paid campaign with:

```sh
mix imp.benchmark.multimodal_quality \
  --profile openai-responses --live \
  --max-concurrency 2 \
  --out benchmarks/runs/multimodal
```

The task reads `OPENAI_API_KEY` only from the task process. A live run exits
nonzero if the claim gate rejects any required evidence.

## Scope

This campaign proves only the pinned six-sample image and native-PDF lane. It is
not a broad multimodal leaderboard. `Imp.Adapter.Types.Document` remains text
content, not document vision. Audio is unsupported and unproven. Provider or
pricing drift requires a new campaign identity and fresh live evidence.
