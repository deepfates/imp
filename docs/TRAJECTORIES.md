# Native execution evidence and ATIF

Use an addressable run when an application needs an execution record as well as
its prediction. Native events are the source; ATIF is a portable projection.

```elixir
{:ok, run} = Imp.Run.start(program, inputs, event_sink: &persist_event/1)
result = Task.await(run.task, :infinity)
events = Imp.Run.events(run)
Imp.Run.stop(run)
document = Imp.Trajectory.to_atif(events, agent: %{name: "my-agent", version: "1"})
File.write!("trajectory.json", Jason.encode!(document, pretty: true))
```

An event sink receives `%Imp.Run.Event{}`. `Imp.Run.Event.to_map(event)` produces
redacted, JSON-compatible native data. `Imp.Trajectory.to_atif/2` also accepts
these stored maps. Keep native records when order, lifecycle, or application
recovery matters; the ATIF projection attaches tool results to their earlier
call step and keeps original sequence/time alongside the result.

For cancellation, `Imp.Run.cancel_with_events(run, reason, timeout)` returns
`{:ok, events}` before releasing the control process. It captures the owner's
terminal decision even when the asynchronous sink is blocked. An unfinished
external operation remains unknown. Neither a terminal event nor an absent
result proves that a write did not happen.

Run events are in memory until the application persists them. A sink is
asynchronous, its exceptions do not veto execution, and node or owner death can
lose undelivered observations. Applications that require evidence before an
effect must persist at the synchronous authorization boundary before granting
it. A trajectory is not that transaction.

Capture is bounded separately from execution. `Imp.Run.start/3` accepts
`:max_event_bytes` (default 65,536), `:max_events` (512), and
`:max_snapshot_bytes` (4,194,304). Oversized payloads become explicit size/digest
markers before sink delivery. Snapshot eviction adds a `capture_gap` marker;
the sink can retain all bounded events independently of snapshot eviction.
Applications can choose a larger event bound when persisting long prompts, but
must account for memory and sink throughput. A digest is not a recoverable
artifact. Truncated observations are never exported as complete model output.

The projection uses ATIF-v1.8. It preserves actual initial context roles, marks
that context as copied, and keeps later model request messages in metadata.
Structured model outputs remain structured output rendered as JSON text. Tool
calls and explicit reasoning come from native semantic events. Run lifecycle
and final prediction bookkeeping remain diagnostics, avoiding duplicate final
answers. Model request counts are not inference counts: a cache may satisfy a
request, so `llm_call_count` remains null. Deterministic tool dispatch steps use
zero. Metrics are retained only as observed metadata; none are inferred.
Overlapping reused native tool IDs are rejected rather than mispaired.

Coverage follows execution boundaries: `Imp.LM.request/2` supplies model
observations, and ReActV2/RLM supply semantic tool observations. Streaming paths
that bypass that boundary are not complete model episodes. Unknown outcomes,
missing calls, and capture gaps stay explicit. Redaction removes known
credential patterns; prompts and results still contain private application data.

## Independent validation

Generate a provider-free export from an actual ReActV2 execution, then run the
upstream Harbor validator rather than a hand-maintained schema copy:

```sh
IMP_ATIF_FIXTURE_OUT=/tmp/imp-trajectory.json mix test test/trajectory_test.exs
uv run --with harbor==0.23.0 python scripts/validate_atif.py /tmp/imp-trajectory.json
```

The reference is Harbor's [ATIF specification](https://www.harborframework.com/docs/agents/trajectory-format)
and [trajectory models](https://github.com/harbor-framework/harbor/tree/88fdbc9d42e907c0414654f041ece5eaf798f538/src/harbor/models/trajectories).
`PYTHONPATH=/path/to/harbor/src` selects a checked-out reference implementation
when validating against a specific upstream revision.

For another implementation's rendering, open the same synthetic fixture with
[`atif-lens`](https://github.com/Eli-Chandler/atif-lens). Version 0.2.0 accepts
and renders this text/tool subset but warns that v1.8 is rendered with v1.7
semantics. That warning must not be reported as full v1.8 viewer support; v1.8's
audio additions are outside this export's current coverage. Validation and
rendering demonstrate interchange for the exercised fixture, not completeness
of an arbitrary application's evidence.
