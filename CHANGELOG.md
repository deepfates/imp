# Changelog

User-visible changes to Imp are recorded here.

## Unreleased

- Added `Imp.MCP.OAuth`, a credential store for remote HTTP MCP servers that
  require a browser-authorized OAuth grant. It begins the flow, listens on
  `127.0.0.1` for the redirect, stores the grant encrypted as one file per
  credential under a directory the host names, and refreshes it without the
  person. A grant is bound to the URL it was authorized for, so a descriptor
  cannot point another server's credential at itself. A refresh the
  authorization server answers with `invalid_grant` is reported as
  `{:mcp_oauth_reauthorization_required, credential}` rather than as a
  retryable failure.
- Added two server descriptor auth forms that `Imp.MCP.connect/2` resolves to
  headers at connect time: `%{"type" => "oauth", "credential" => ref}`, which
  reads the store passed as the new `:credentials` option, and
  `%{"type" => "bearer_env", "variable" => name}`, which reads the host's
  environment and connects with no `Authorization` header (logging one
  warning) when the variable is unset, unless `"required" => true`. Static
  `"headers"` are unchanged.

## 0.3.2 — 2026-09-01

- Made the RLM controller prompt describe the restricted language actually
  accepted by its interpreter, including supported repair paths and explicit
  unsupported forms.
- Preserved explicit no-retry provider policy across Req function, module, and
  `{module, function, args}` adapters.

## 0.3.1 — 2026-08-23

- Clarified the supported center versus pre-1.0 advanced workflows, the exact
  meaning of typed inputs and outputs, and the restricted-interpreter security
  boundary.
- Completed the structured signature field reference and corrected cold-reader
  prerequisites and cross-references.

## 0.3.0 — 2026-08-23

Private Git source release. Imp is not published to Hex.

### Added

- Typed code fields, richer structured signatures, and consistent Chat, JSON,
  and XML adapter validation.
- General program parameters and checksummed parameter artifacts for named
  predictors, tools, playbooks, and custom optimizable components.
- Full MIPROv2 TPE search, expanded GEPA/SIMBA/COPRO behavior, persistent
  playbook optimization, optimizer checkpoints, and Optimize Anything program
  artifacts.
- Addressable ReActV2 and RLM runs with ordered events, cancellation, explicit
  per-effect authorization, and owner-death cleanup.
- MCP stdio process ownership that reaps server process groups when a call or
  run is cancelled.
- Provider streaming for composed programs, including named-predictor field
  selection and a typed terminal prediction.
- A complete deployment example with disjoint evaluation, parameter artifacts,
  fresh-process loading, concurrent serving, hot reload, and failure
  containment.

### Changed

- `Imp.optimize/3`, `/4`, and `/5` now return `{:ok, program}` or
  `{:error, reason}`. The corresponding `optimize!` functions raise.
- Adapter types moved from `Imp.Adapters.Types` to `Imp.Adapter.Types`.
- Saved programs and parameter artifacts use atomic private writes and require
  live providers, callbacks, tools, and policies to be rebound from trusted
  application code.
- ReActV2 uses a validated `submit` tool, falls back to tools-disabled typed
  extraction when a provider cannot honor forced tool choice, and grounds that
  extraction only in successful retained observations.
- Evaluation timeouts, provider failures, metric failures, budget exhaustion,
  and cancelled work propagate as observable failures instead of silently
  becoming ordinary scores.
- The private release installs consistently from the immutable `v0.3.0` Git
  tag in the README, Livebooks, and packaged examples.

### Fixed

- Cached ReqLLM responses no longer double-count token usage.
- ReAct retains a single tool-call trajectory when context truncation cannot
  safely remove a complete turn.
- ReActV2 converts malformed provider tool calls into non-executable error
  observations so a model can recover without bypassing policy or
  authorization.
- Whole-program and optimizer-report identities survive artifact round trips.
- Composed streaming cancels provider work on early halt or consumer death.
- Batch messages retain their structured conversations after JSON transport.
- Optimizer progress subscribers receive real trial events.

### Removed

- `Imp.Agent` and `Imp.Agent.Runtime`. Use ReActV2 or RLM as the program and
  ordinary Elixir supervision as the runtime.
- `Imp.Streaming.Messages.StatusMessageProvider`, which did not implement an
  execution-stage status contract. Use stream listeners and `:telemetry`.

## 0.2.1 — 2026-07-18

### Added

- Configurable teacher and rollout timeouts for BootstrapFewShot, GRPO, and
  BootstrapFinetune.

### Fixed

- Saved Predict programs retain JSON retry and fallback configuration.
- GEPA reflection no longer sends an invalid provider connection option.
- Reasoning-model token-limit normalization is wire-neutral.
- Signature errors suggest `array[...]` when given DSPy's `list[...]` spelling.
- Global test configuration and async synchronization no longer leak across
  tests.

## 0.2.0 — 2026-07-17

### Added

- `Imp.stream/3` and `Imp.collect/3`, with provider streaming and local
  post-call chunking modes.
- Public optimizer progress subscriptions and evaluation timeout reporting.
- Deterministic LabeledFewShot selection and seeded data splitting.

### Fixed

- Batch requests preserve structured messages.
- Optimizer trial telemetry is emitted as documented.
- Timed-out evaluation rows are reported explicitly.

## 0.1.0 — 2026-07-16

Initial private Git source release of Imp's signature, program, provider,
evaluation, optimization, tool, retrieval, persistence, and Livebook APIs.
