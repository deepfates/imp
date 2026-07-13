# Multimodal Fidelity

This document defines the evidence boundary for DSEx image and document quality.
Typed value encoding by itself is not a model-quality result. The quality claim
is authorized only by a complete live artifact from the provider-backed campaign.

## Audited Lane

The provider-profile manifests are
`benchmarks/data/multimodal/manifest.json` for Google and
`benchmarks/data/multimodal/openai-responses-manifest.json` for OpenAI. Their
checksum envelopes and strict schema pin:

- every sample ID, asset byte count, and SHA-256 hash;
- the exact prompts, signature, gold answers, normalization, and thresholds;
- provider, API, exact model, credential environment name, identity-evidence
  policy, supported generation options, and USD token prices;
- expected image and native PDF capabilities.

All assets are synthetic and repository-owned. The image family covers shape
counting, spatial relation, and text reading. The native-document family sends a
two-page PDF and covers a table subtotal plus a cross-page join. Rendered page
PNGs are committed for inspection, but the runner does not execute them or count
them as native file support.

DSEx sends image bytes as a typed `DSEx.Adapters.Types.Image` data URI through a
ReqLLM `image_url` content part. It sends the PDF path as a typed
`DSEx.Adapters.Types.File`, which ReqLLM reads into a binary `file` content part
and the selected ReqLLM adapter maps to inline PDF data. OpenAI Responses uses
`input_file.file_data`; its image path uses `input_image.image_url`. Reports retain only the
type, MIME type, byte count, hash, and transport label. They never retain the
data URI, binary file, base64 payload, or API key.

The retained live proof is
`benchmarks/results/multimodal-quality-live-20260713T215119Z.json`, generated
2026-07-13 with manifest SHA-256
`45c632a0806d279a749cce9904b002ec243f16e5ee65fa0081e47b10eb1fd4a3`.
It records 6/6 passing samples, exact effective model
`gpt-4.1-mini-2025-04-14`, API `responses`, 5,716 input tokens, 47 output
tokens, and calculated cost `$0.002361600`. Four image tasks and both native-PDF
tasks passed. This authorizes only the narrow claims defined below.

## Commands

Validate the manifest, assets, dispatch plan, and report shape without loading a
credential or contacting Google:

```sh
mix dsex.benchmark.multimodal_quality --profile openai-responses \
  --plan --out tmp/multimodal-plan
```

`--dry-run` is an alias for `--plan`. Execute or resume the pinned live campaign:

```sh
mix dsex.benchmark.multimodal_quality \
  --profile openai-responses --live \
  --max-concurrency 2 \
  --out benchmarks/results
```

The task reads the key only from the current process environment and passes it
to `DSEx.Clients.ReqLLM`; it does not put the key in application configuration,
the checkpoint, or the report. Each concurrency wave writes durable row intents
before dispatch and durable outcomes after completion. Completed rows resume
without another provider call. An unresolved intent is ambiguous because the
provider may have accepted the request, so resume fails closed instead of
silently retrying and double-billing it.

The repository's current `GEMINI_API_KEY` returned Google HTTP 400 invalid-key
responses on 2026-07-13, so it provides no Google quality evidence. Provider
failures are retained as bounded structured maps with category, exception,
HTTP status, provider code, request ID, and redacted message when available.
Exception structs are converted before redaction so malformed nested fields
cannot turn a provider failure into a runner error.

## Claim Gate

The image threshold is `0.75` across four samples. The native-document threshold
is `1.0` across two samples. Both `image_quality` and `document_quality` remain
false unless all samples have durable outcomes, both required families meet
their preregistered thresholds, usage contains exact integer input/output token
counts, and model/API identity matches the manifest. A provider capability
error, malformed JSON, malformed usage, wrong answer, missing row, plan run, or
identity mismatch prevents every quality claim.

The artifact reports per-row score, failure, latency, token usage, exact
nano-USD cost, effective model/API, content-part shape, family summaries, and
limitations. The task exits nonzero when a live run does not authorize the
claim, while preserving its checkpoint for diagnosis.

## Boundaries

- This campaign proves a small pinned image and native-PDF lane, not general
  multimodal superiority or broad benchmark coverage.
- The PDF evidence is native file input. Rendered page images are inspection
  aids and cannot substitute for that claim in this manifest.
- `DSEx.Adapters.Types.Document` is text content, not native document vision.
- Audio is explicitly unsupported and unproven. No audio claim is permitted by
  this lane.
- Provider behavior, model availability, and pricing can drift. Any change
  requires a new manifest identity and fresh live evidence; editing the current
  payload without updating its checksum fails validation.
