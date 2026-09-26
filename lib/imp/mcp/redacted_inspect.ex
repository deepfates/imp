# ExMCP keeps a connection's transport headers (an `Authorization` bearer, a
# service's API-key header) in its client process state: in
# `ExMCP.Transport.HTTP` and in `ExMCP.Client`'s `transport_opts`. When that
# process crashes, or is inspected with `:sys.get_state/1`, the state is printed
# with `inspect`, and the headers with it. ExMCP 1.5 has no `Inspect`
# implementation for either struct, so Imp gives them the redacting one its own
# clients use. This stops being needed when ExMCP redacts its own state; if it
# adds its own implementation, this one conflicts with it and must go.
defimpl Inspect, for: [ExMCP.Client, ExMCP.Transport.HTTP] do
  def inspect(struct, opts),
    do: Inspect.Any.inspect(Map.merge(struct, Imp.Redaction.redact_for_print(struct)), opts)
end
