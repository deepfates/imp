# Multimodal Fidelity

This document defines the evidence boundary for DSEx image and document quality.
Typed value encoding by itself is not a model-quality result. The quality claim
is authorized only by a complete live artifact from the provider-backed campaign.

## Audited Lane

The preregistered manifest is
`benchmarks/data/multimodal/manifest.json`. Its checksum envelope and strict
schema pin:

- every sample ID, asset byte count, and SHA-256 hash;
- the exact prompts, signature, gold answers, normalization, and thresholds;
- Google `generateContent`, ReqLLM model `google:gemini-2.5-flash`, and the
  process-scoped `GEMINI_API_KEY` credential name;
- temperature, top-p, seed, output limit, timeout, concurrency limit, and USD
  token prices;
- expected image and native PDF capabilities.

All assets are synthetic and repository-owned. The image family covers shape
counting, spatial relation, and text reading. The native-document family sends a
two-page PDF and covers a table subtotal plus a cross-page join. Rendered page
PNGs are committed for inspection, but the runner does not execute them or count
them as native file support.

DSEx sends image bytes as a typed `DSEx.Adapters.Types.Image` data URI through a
ReqLLM `image_url` content part. It sends the PDF path as a typed
`DSEx.Adapters.Types.File`, which ReqLLM reads into a binary `file` content part
and the audited Google adapter maps to inline PDF data. Reports retain only the
type, MIME type, byte count, hash, and transport label. They never retain the
data URI, binary file, base64 payload, or API key.

## Commands

Validate the manifest, assets, dispatch plan, and report shape without loading a
credential or contacting Google:

```sh
mix dsex.benchmark.multimodal_quality --plan --out tmp/multimodal-plan
```

`--dry-run` is an alias for `--plan`. Execute or resume the pinned live campaign:

```sh
GEMINI_API_KEY="$GEMINI_API_KEY" mix dsex.benchmark.multimodal_quality \
  --live \
  --max-concurrency 2 \
  --checkpoint benchmarks/results/multimodal-checkpoints/google-gemini-2.5-flash-v1.json \
  --out benchmarks/results
```

The task reads the key only from the current process environment and passes it
to `DSEx.Clients.ReqLLM`; it does not put the key in application configuration,
the checkpoint, or the report. Each concurrency wave writes durable row intents
before dispatch and durable outcomes after completion. Completed rows resume
without another provider call. An unresolved intent is ambiguous because the
provider may have accepted the request, so resume fails closed instead of
silently retrying and double-billing it.

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
