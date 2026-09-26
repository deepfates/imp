defmodule Imp.MCP.CallFailure do
  @moduledoc """
  An MCP tool call that got no answer from its tool.

  An imported MCP tool returns `{:error, %Imp.MCP.CallFailure{}}` when the call
  did not reach an answer from the tool: the server declined it, it could not be
  sent, or it was sent and no trustworthy answer came back. `outcome` says which,
  so a host decides what to do without matching ExMCP's terms:

    * `:refused` — declined before anything ran. The server answered with a
      JSON-RPC error that rejects the request before any method runs (parse
      error, invalid request, method not found), or the HTTP layer refused it
      with a 4xx status other than 401 (403 included). Nothing ran, so
      repeating the call is safe; whether it will succeed depends on why it
      was refused (a 408 or 429 may pass later, a 404 will not).
    * `:auth_refused` — the credential was refused before anything ran: an
      HTTP 401, or an OAuth flow that failed. Nothing ran; renewing the
      credential and trying once more may succeed.
    * `:not_sent` — the request never left: the connection could not be
      opened, the address could not be resolved, the client was not connected,
      the client process was already gone, or every connection to an HTTP
      server stayed busy until the call's timeout (`:no_idle_connection`).
    * `:unknown` — the request was, or may yet be, delivered, and whether the
      tool acted is not known: the caller's timeout, a connection that closed
      after sending, a 5xx status, a response that could not be read, a stream
      that broke after delivery, a handler that crashed or that the server
      stopped waiting for (it may still be running), invalid params, any other
      JSON-RPC error, an error ExMCP raised itself partway through a call, a
      cancelled request, and a client that exited during the call. Check
      before repeating it.

  Invalid params (-32602) is `:unknown`, not `:refused`, because a server can
  send it after its tool ran: MCP names it the code for a bad tool call, and
  ExMCP's server passes a tool handler's returned `ExMCP.Error.ProtocolError`
  on as the JSON-RPC error, after the handler ran
  (`ExMCP.MessageProcessor.MethodHandlers.handle_tool_reply/3`). Parse error,
  invalid request and method not found are read as refusals on the premise that
  a server sends them before it dispatches to a tool, as JSON-RPC defines them;
  a tool handler that returns one after acting breaks that premise, and the
  code cannot show it. An `ExMCP.Error.ProtocolError` struct is `:unknown` whatever its code: ExMCP
  builds those itself, including after the first round of a multi-round call
  has reached the server.

  A timeout is `:unknown` even when the request was still waiting in the
  client: ExMCP's client sends a plain HTTP request from inside its own
  process, so a call behind a slow one on the same client waits, and when its
  caller gives up the request stays queued and is sent later. Imp lends each
  call to an HTTP server a client of its own (`pool_size:` in
  `Imp.MCP.Connections`), so a call waits for a client rather than inside one,
  and a call that never got one is `:not_sent`.

  An answer from the tool itself, including an MCP error result
  (`{:mcp_tool_error, envelope}`, where `isError` is true), is not a
  `CallFailure`: the tool said what happened. `Imp.Tool.outcome/1` reads any
  tool call's return value, this one included.

  `reason` is what ExMCP returned, unchanged, when the failure came from
  ExMCP; a process exit is kept as `{:exit, reason}`. Three reasons are Imp's
  own, from the connection pool in front of ExMCP: `:timeout` (the caller's
  `:timeout` passed while the request was out), `:no_idle_connection` (every
  connection to the server stayed busy until the timeout), and
  `:not_connected` (the server has no connection left). `server` is the
  descriptor's name and `tool` the name the server published.
  """

  @enforce_keys [:outcome, :server, :tool, :reason]
  defstruct [:outcome, :server, :tool, :reason]

  @type outcome :: :refused | :auth_refused | :not_sent | :unknown

  @type t :: %__MODULE__{
          outcome: outcome(),
          server: String.t(),
          tool: String.t(),
          reason: term()
        }

  # JSON-RPC 2.0 section 5.1: parse error, invalid request, method not found.
  # Each rejects the request before a method runs. Every other code, -32602 and
  # -32603 included, may come after the tool ran (see the moduledoc).
  @refusal_codes [-32_700, -32_600, -32_601]

  # `ExMCP.Transport.HTTP.TargetPolicy` and the request-size check refuse
  # before a connection is opened.
  @unsent_reasons [
    :invalid_http_url,
    :invalid_network_policy,
    :dns_failed,
    :dns_timeout,
    :non_public_address,
    :non_loopback_address,
    :request_too_large
  ]

  @doc false
  @spec returned(String.t(), String.t(), term()) :: t()
  def returned(server, tool, reason),
    do: %__MODULE__{outcome: classify(reason), server: server, tool: tool, reason: reason}

  @doc false
  @spec exited(String.t(), String.t(), term()) :: t()
  def exited(server, tool, reason) do
    # `:noproc` means the client was gone before the call was made; any other
    # exit ended the client while it held the call.
    outcome = if match?({:noproc, _call}, reason), do: :not_sent, else: :unknown
    %__MODULE__{outcome: outcome, server: server, tool: tool, reason: {:exit, reason}}
  end

  defp classify(:not_connected), do: :not_sent
  defp classify(:no_idle_connection), do: :not_sent
  defp classify(%{"code" => code}) when is_integer(code), do: code_outcome(code)

  defp classify(%ExMCP.Error.ValidationError{}), do: :not_sent

  # A streaming POST reports its transport's own reason.
  defp classify({:transport_error, reason}), do: transport_outcome(reason)

  # ExMCP's request handler reports a failed synchronous HTTP send as
  # `%{type: :transport_error, message: "Failed to send request: " <> inspect(reason)}`,
  # so the transport's reason reaches Imp only as that text. These prefixes are
  # the `inspect/1` of the reasons `transport_outcome/1` names. They go when
  # ExMCP keeps the reason as a term.
  defp classify(%{type: :transport_error, message: "Failed to send request: " <> text})
       when is_binary(text),
       do: transport_text_outcome(text)

  defp classify(_reason), do: :unknown

  defp code_outcome(code) when code in @refusal_codes, do: :refused
  defp code_outcome(_code), do: :unknown

  # `ExMCP.Transport.HTTP.BoundedClient`: a bare Mint error comes from opening
  # the connection; errors after it are wrapped as `:http_request_failed`
  # (writing the request) or `:http_receive_failed` (reading the answer).
  defp transport_outcome(%Mint.TransportError{}), do: :not_sent
  defp transport_outcome(%Mint.HTTPError{}), do: :not_sent
  defp transport_outcome(reason) when reason in @unsent_reasons, do: :not_sent
  defp transport_outcome({:security_violation, _error}), do: :not_sent
  # An ExMCP auth provider reports a refused credential as `:forbidden` or
  # `:scope_step_up_exhausted`; those would read as `:unknown` below. Imp
  # configures no auth provider, so neither reaches here today; one that is
  # configured should map them to `:auth_refused`.
  defp transport_outcome({:unauthorized, 401, _body, _challenge}), do: :auth_refused
  defp transport_outcome({:oauth_failed, _reason}), do: :auth_refused
  defp transport_outcome({:http_error, status, _body}), do: status_outcome(status)
  defp transport_outcome(_reason), do: :unknown

  defp transport_text_outcome("%Mint.TransportError{" <> _), do: :not_sent
  defp transport_text_outcome("%Mint.HTTPError{" <> _), do: :not_sent
  defp transport_text_outcome("{:security_violation, " <> _), do: :not_sent
  defp transport_text_outcome("{:unauthorized, 401, " <> _), do: :auth_refused
  defp transport_text_outcome("{:oauth_failed, " <> _), do: :auth_refused

  defp transport_text_outcome("{:http_error, " <> rest) do
    case Integer.parse(rest) do
      {status, _rest} -> status_outcome(status)
      :error -> :unknown
    end
  end

  defp transport_text_outcome(":" <> atom) do
    if Enum.any?(@unsent_reasons, &(Atom.to_string(&1) == atom)), do: :not_sent, else: :unknown
  end

  defp transport_text_outcome(_text), do: :unknown

  # A 4xx status says the request was rejected as sent, and a 401 that the
  # credential was. A 5xx says a server on the path failed with it, which may
  # be after the MCP server acted.
  defp status_outcome(401), do: :auth_refused
  defp status_outcome(status) when status in 400..499, do: :refused
  defp status_outcome(_status), do: :unknown
end
