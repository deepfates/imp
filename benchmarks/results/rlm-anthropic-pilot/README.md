# Bounded Anthropic RLM Pilot

This directory records an adapted T2 live sample. It is not paper-exact RLM
evidence and does not establish aggregate quality, reliability, latency, cost,
semantic superiority, or cross-runtime parity.

## Reproduction

The run used commit `2b9cacd73ba91872db83f26a616a354e96139823`, Python
3.13.12, and Deno 2.8.3. With those interpreters on `PATH` and
`ANTHROPIC_API_KEY` set, run from the repository root:

```console
PYTHON=python3.13 scripts/setup_reference_test_env.sh
scripts/setup_rlm_pilot_inputs.sh
ERL_FLAGS='+S 4:4' mix imp.benchmark.rlm_campaign \
  --manifest benchmarks/config/rlm-oolong-pairs-anthropic-v1.json \
  --runtime both --approach direct,rlm --row-limit 1 \
  --python tmp/dspy-current-venv/bin/python \
  --out benchmarks/results/rlm-anthropic-pilot \
  --checkpoint-dir benchmarks/results/rlm-anthropic-pilot/checkpoints-2b9cacd
```

The first script creates the version-pinned Python environment and verifies
Deno. The second downloads and hash-verifies the paper PDF, RLM source, the
complete 149-file DSPy source tree, and public OOLONG source shards, then
normalizes and verifies the 1.5 GB dataset. The manifest also binds a dated
Anthropic pricing capture. Package versions are pinned; Python distribution
artifacts are not hash-locked.

Imp and the DSPy sidecar disabled their client/application caches. This does
not claim that Anthropic disabled infrastructure-level caching. The artifact
records a clean tracked worktree and `untracked_worktree_dirty: true`; it does
not identify untracked paths.

## Result

The frozen sample was OOLONG-Pairs query `1` at context size `1024`, evaluated
with normalized unordered pair-set F1 and `claude-sonnet-5` through Anthropic.
Costs use Anthropic's July 2026 introductory rates of $2 per million input
tokens and $10 per million output tokens; they are derived from reported token
usage rather than provider-reported billing totals.

| Runtime | Approach | Status | Score | Calls | Cost (USD) |
| --- | --- | --- | ---: | ---: | ---: |
| Imp | direct | ok | 0.0 | 1 | 0.009484 |
| Imp | RLM | ok | 1.0 | 4 | 0.050940 |
| DSPy | direct | ok | 0.0 | 1 | 0.010290 |
| DSPy | RLM | error | n/a | 2 | 0.008354 |

The gold answer is the empty pair set. Both direct lanes explained that result
in prose, which the strict output contract rejects. Imp RLM's bounded trace
records one `run` event, two `action_error` events, and one `submit`, ending
with the accepted empty-set marker `No such pairs exist.` DSPy RLM failed with
`dspy.utils.exceptions.AdapterParseError`; its already-incurred usage is
retained, its score is null, and it is excluded from paired estimates.

The artifact reports one Imp direct/RLM paired row with a direct-minus-RLM
score difference of `-1.0`. Its DSPy and cross-runtime comparison records have
zero paired rows and no estimate. These are single observations, not general
performance claims. Provider-free tests independently verify the DSPy API,
interpreter, prediction, sidecar wrapper, failure metering, submit, extraction,
trajectory, and usage contracts.

## Integrity

- Manifest SHA-256: `da975f3ecf4cdffee83c001d356009895a2c5f0500e703fccfc2fb1f3627afa6`
- Dataset SHA-256: `11b58e289d19152c3e6fa80f347e250021a6fe25f181925bac8e4e4ca2a4d4cc`
- DSPy dependency set SHA-256: `3bd236fe1ffa2e295d470d781573b3a402d9ec39cc4c6700fa01c47b4fa324fa`
- Reference setup SHA-256: `b97e6e5a469db0fdf686220572ff05e9e8235f05707d77dfa638a838ccfa9b60`
- Input setup SHA-256: `4495ee968b22fadbc378dbf8d09145a38559c657ca64b65c195624289eb67f0f`
- DSPy source tree SHA-256: `282755ac176deb51438b685ad227fdb088ae378404a9c97e7c0fa236c3e06f3a`
- DSPy verifier SHA-256: `caae2c15b8f68ce0c8c883a14f1e86cf6e2a6279098d6b8b1bd4810281483fdf`
- Pricing authority SHA-256: `041c27978d265f439ffd6f5c6ca4379985285c0010253848092dacfa177244a7`
- Artifact SHA-256: `b6b9757696c424568633cd80f84f626fb2093db51176b8d79e279b477ddfcaff`
- Checkpoint SHA-256: `fe99d164d4dec11531aea91fb424ab91162cdd12f4745dd4ef9169fbc242e3bd`

The admitted evidence artifact is
`rlm-benchmark-parity-20260715T201821Z.json`. The checkpoint remains local for
audit and resumption diagnostics but is not admitted because it duplicates the
row payload.
