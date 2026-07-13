# Optimizer Trajectory Contract

`DSEx.Optimizer.Trajectory` is the canonical execution envelope shared by
GEPA, MIPROv2, SIMBA, RLM, ReAct, optimize-anything, and evaluation adapters.
It preserves each runtime's native `trace`, feedback, metadata, and named
parameter values while also projecting ordered provider-neutral events.

The version 1 envelope includes:

- text or typed multimodal examples and predictions;
- reasoning, module calls, tool calls/results, partial errors, and evaluator feedback;
- token/request/cost usage and microsecond timing;
- cache key/hit identity, program and rollout identity, and named parameters;
- optimizer-specific metadata that is intentionally not flattened.

Use `DSEx.Optimizer.Trajectory.project/3` at runtime boundaries. A trajectory
batch can be checked with `validate_aligned!/1`; events must be contiguous and
tool results must follow a unique matching call. `dump/1` emits the only
supported cross-runtime JSON representation and redacts credentials in
structured fields before they cross that boundary. Opaque image, audio, and
file bytes remain byte-for-byte intact; callers must not place credentials in
attachment payloads. `DSEx.dump/1` and `DSEx.load/1` use this same codec.
`load/1` accepts only the exact versioned schema,
known typed values, valid accounting, ordered events, and aligned tool calls.
It returns `{:error, %DSEx.Optimizer.Trajectory.DecodeError{}}` for malformed or
future-version data rather than partially restoring it.

The native `trace` remains available because reflection semantics differ by
optimizer. Consumers should use `events` for cross-runtime inspection and the
native fields when implementing optimizer-specific reflection or mutation.
