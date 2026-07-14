# Observability and Debugging

Imp exposes telemetry for live integrations and immutable inspection artifacts
for shell, test, LiveView, and incident workflows. These surfaces are redacted by
default. Disabling inspection redaction is an explicit local debugging decision;
telemetry and status subscriptions remain redacted.

## Inspection

`Imp.Observability.inspect_artifact/2` returns a
`Imp.Observability.Inspection` with a common entry shape:

```elixir
inspection = Imp.Observability.inspect_artifact(prediction)

Enum.each(inspection.entries, fn entry ->
  IO.inspect({entry.source, entry.sequence, entry.payload})
end)
```

Predictions collect their provider trace, tool or ReAct history, RLM trace, and
attached optimizer report in that order. Conversation histories, optimizer
reports, and `Imp.Observability.Trace` values are recognized directly. Tag
otherwise ambiguous lists by source:

```elixir
Imp.Observability.inspect_artifact({:provider, provider_history})
Imp.Observability.inspect_artifact({:tool, tool_history})
Imp.Observability.inspect_artifact({:rlm, rlm_trace})
Imp.Observability.inspect_artifact({:optimizer, optimizer_report})
```

The default inspection keeps the latest 50 entries and limits each redacted
payload to 16 KiB. Oversized payloads become type, byte-count, and fingerprint
records. Use `render_inspection/2` for stable pretty JSON and `:io` to write it to
an IO device. `Imp.inspect_history/2` keeps its compact conversation renderer
and recognizes DSPy-shaped provider histories containing `messages` or `prompt`,
`outputs`, and an optional `timestamp`. Provider history is rendered through the
bounded typed inspection path.

This follows DSPy's recent-history inspection semantics while retaining Imp's
signature-shaped conversation history and BEAM-native immutable artifacts. It
does not depend on provider-specific callback objects.

## Status and Progress

`Imp.Observability.status/1` normalizes optimizer reports, predictions, provider
status maps, and telemetry event triples into `Imp.Observability.Status`.
Statuses carry a lifecycle state, phase, optional completed and total counts, a
short message, and redacted metadata.

Optimizer subscriptions retain the existing telemetry-compatible message and
also send a normalized status artifact:

```elixir
subscription = Imp.subscribe_optimizer_progress()

receive do
  {:imp_status, %Imp.Observability.Status{} = status} ->
    IO.inspect(status)
end

Imp.unsubscribe_optimizer_progress(subscription)
```

## Traces and Secrets

`Imp.trace/2` captures ordered LM, streaming, tool, retrieval, optimizer, and
training telemetry around a function. Both measurements and metadata are
redacted in the collector even when a producer bypasses `Imp.Telemetry`.
Inspection error messages are redacted as well.

Do not persist snapshots produced with `redact: false`. Prompt and completion
content can contain application data even when it does not resemble a provider
credential.
