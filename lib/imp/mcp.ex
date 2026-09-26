defmodule Imp.MCP do
  @moduledoc """
  Imports the tools of authorized MCP servers as ordinary `Imp.Tool` values.

  `connect/2` dials each server, lists its tools and returns them with their
  source provenance and one cleanup function. Imported tools validate required
  fields and basic JSON-schema-style property constraints. Tool schemas follow
  the MCP specification dialect: the input contract is the camelCase
  `"inputSchema"` key (MCP spec, Tool definition) and `"description"` is
  optional.

  Imported tools default to `result_mode: :text`, matching DSPy's MCP tool
  boundary: one text block becomes a string, multiple text blocks become a
  list, and non-text blocks are returned when no text is present. Set
  `result_mode: :structured` to return `structuredContent` exactly when the
  server includes it—even when its value is `nil`, `false`, `0`, or empty—and
  fall back to the text conversion only when that field is absent. MCP error
  results become `{:error, {:mcp_tool_error, original_envelope}}` before either
  conversion. The original structured failure and content remain available;
  uncertainty about an effect must not be collapsed into a retryable refusal.
  A call that got no answer from its tool returns
  `{:error, %Imp.MCP.CallFailure{}}`, whose `outcome` says whether it was
  refused, never sent, or sent with no trustworthy answer.
  """

  @doc """
  Connects authorized MCP servers; returns tools with source metadata and cleanup.

  `servers` is a list of descriptor maps, local (`"command"`) or remote
  (`"url"`); see `Imp.MCP.Connections` for their shape and every option.

      server = %{"name" => "files", "command" => "my-mcp-server", "args" => ["--stdio"]}
      {:ok, import} = Imp.MCP.connect([server], trusted_servers: [server])
      agent = Imp.react("question -> answer", import.tools, lm: lm)
  """
  @spec connect([Imp.MCP.Connections.server()], keyword()) ::
          {:ok, Imp.MCP.Import.t()} | {:error, term()}
  def connect(servers, opts \\ []), do: Imp.MCP.Connections.connect(servers, opts)

  @doc """
  The words a model reads for a failed MCP tool call.

  An error result (`{:mcp_tool_error, envelope}`) is the text its tool wrote:
  MCP spec, CallToolResult, puts what went wrong in the content, for the model
  to read. Its text items are joined; its structured content stands in as plain
  data when there is no text. For an `Imp.MCP.CallFailure`, a JSON-RPC error is
  the server's message, and otherwise the sentence follows its outcome: a
  refused call says the server refused it, a call whose credential was
  refused says so, a call that was not sent says so,
  and a call whose outcome is unknown says it got no answer, why, and that it
  may have been carried out, because a timeout, a closed or failed connection,
  a broken stream, or a server that stopped waiting for its tool does not say
  whether the tool ran, and a write that did run must not read as one that did
  not.

  This is only what is read. The error term itself, which the loop records,
  keeps the whole envelope or reason.

      iex> Imp.MCP.failure_text(Imp.MCP.CallFailure.returned("kite", "reply", :timeout))
      "no answer came back; it timed out, so it may have been carried out."
  """
  @may_have_run "so it may have been carried out."

  @spec failure_text(term()) :: String.t()
  def failure_text(reason)

  def failure_text({:mcp_tool_error, envelope}), do: error_result_text(envelope)

  def failure_text(%Imp.MCP.CallFailure{reason: {:exit, exit_reason}}),
    do: "no answer came back; " <> exit_text(exit_reason)

  def failure_text(%Imp.MCP.CallFailure{outcome: outcome, reason: reason}) do
    case {json_rpc_message(reason), outcome} do
      {{:ok, message}, _outcome} ->
        message

      {:error, :refused} ->
        "the server refused the call."

      {:error, :auth_refused} ->
        "the server refused the credential, so it was not carried out."

      {:error, :not_sent} when reason != :not_connected ->
        "it was not sent, so it was not carried out."

      {:error, _outcome} ->
        "no answer came back; " <> no_answer_reason(reason)
    end
  end

  def failure_text({:json_rpc_error, error}) do
    case json_rpc_message(error) do
      {:ok, message} -> message
      :error -> "the server refused the call."
    end
  end

  defp error_result_text(envelope) when is_map(envelope) do
    texts =
      envelope
      |> fetch_field(:content, [])
      |> List.wrap()
      |> Enum.filter(&(is_map(&1) and text_content?(&1)))
      |> Enum.map(&fetch_field(&1, :text, nil))
      |> Enum.filter(&(is_binary(&1) and &1 != ""))

    cond do
      texts != [] ->
        Enum.join(texts, "\n")

      structured = fetch_field(envelope, :structuredContent, nil) ->
        Imp.Adapter.Chat.format_value(structured)

      true ->
        "The tool reported an error without saying what it was."
    end
  end

  defp error_result_text(_envelope), do: "The tool reported an error without saying what it was."

  # `ExMCP.Client.call_tool(format: :map)` returns a server's JSON-RPC error as
  # its decoded map; the `:struct` format wraps it in an `ExMCP.Error` or
  # `ExMCP.Error.ProtocolError` whose `:code` is an integer. ExMCP's server
  # failure classes (`data.type`) add a clause where they say something the
  # message does not; the others are identifiers, not words, and are left out.
  #
  # A handler that crashed or outlived the server's wait had started, so those
  # two read as a call that may have been carried out rather than by ExMCP's
  # "Tool call failed".
  defp json_rpc_message(%{"data" => %{"type" => "handler_crash"}}),
    do: {:ok, "the tool crashed while running, " <> @may_have_run}

  defp json_rpc_message(%{"data" => %{"type" => "handler_timeout"}}),
    do: {:ok, "the server stopped waiting for the tool, " <> @may_have_run}

  defp json_rpc_message(%{"message" => message} = error)
       when is_binary(message) and message != "",
       do: {:ok, message <> json_rpc_type_text(Map.get(error, "data"))}

  defp json_rpc_message(%{message: message, code: code})
       when is_binary(message) and message != "" and is_integer(code),
       do: {:ok, message}

  defp json_rpc_message(_reason), do: :error

  defp json_rpc_type_text(%{"type" => "handler_start_failed"}),
    do: "; the server could not start the tool."

  defp json_rpc_type_text(_data), do: ""

  # The ways ExMCP reports a tool call that got no answer. Which of them were
  # never sent is `Imp.MCP.CallFailure`'s decision; these are the words.
  defp no_answer_reason(:not_connected), do: "the connection is not open."
  defp no_answer_reason(:timeout), do: "it timed out, " <> @may_have_run
  defp no_answer_reason(:closed), do: "the connection closed, " <> @may_have_run
  defp no_answer_reason(:cancelled), do: "the request was cancelled, " <> @may_have_run

  defp no_answer_reason(%ExMCP.Error.TransportError{reason: :outcome_unknown}),
    do: "the connection broke after the request was sent, " <> @may_have_run

  defp no_answer_reason(%ExMCP.Error.TransportError{reason: :timeout}),
    do: no_answer_reason(:timeout)

  defp no_answer_reason(%ExMCP.Error{code: :connection_error}), do: no_answer_reason(:closed)
  defp no_answer_reason(_reason), do: "the connection failed, " <> @may_have_run

  # The exit of a call to the client process names its pid and arguments; none
  # of that is for the reader.
  defp exit_text({reason, {GenServer, :call, _args}}), do: exit_text(reason)
  defp exit_text(:timeout), do: no_answer_reason(:timeout)
  defp exit_text(:noproc), do: no_answer_reason(:not_connected)
  defp exit_text(_reason), do: no_answer_reason(:closed)

  @doc false
  def tool_result(result, mode \\ :text)

  def tool_result(result, mode) when mode in [:text, :structured] and is_map(result) do
    if call_tool_result?(result) do
      text = text_content(result)

      if fetch_field(result, :isError, false) do
        {:error, {:mcp_tool_error, result}}
      else
        convert_tool_result(result, mode, text)
      end
    else
      # An in-process adapter may return a bare application value instead of
      # an MCP CallToolResult envelope. Pass it through unchanged; only
      # envelopes are normalized.
      result
    end
  end

  def tool_result(result, mode) when mode in [:text, :structured], do: result

  defp call_tool_result?(result) do
    has_field?(result, :content) or has_field?(result, :structuredContent) or
      has_field?(result, :isError)
  end

  defp convert_tool_result(result, :structured, text) do
    case fetch_present(result, :structuredContent) do
      {:ok, value} -> value
      :error -> text_fallback(result, text)
    end
  end

  defp convert_tool_result(result, :text, text), do: text_fallback(result, text)

  defp text_fallback(result, []) do
    result
    |> fetch_field(:content, [])
    |> Enum.reject(&text_content?/1)
  end

  defp text_fallback(_result, text), do: text

  defp text_content(result) do
    texts =
      result
      |> fetch_field(:content, [])
      |> Enum.filter(&text_content?/1)
      |> Enum.map(&fetch_field(&1, :text, ""))

    case texts do
      [text] -> text
      texts -> texts
    end
  end

  defp text_content?(content), do: fetch_field(content, :type, nil) in ["text", :text]

  defp has_field?(map, name), do: match?({:ok, _value}, fetch_present(map, name))

  defp fetch_field(map, name, default) do
    case fetch_present(map, name) do
      {:ok, value} -> value
      :error -> default
    end
  end

  defp fetch_present(map, name) do
    names = [name, Atom.to_string(name), snake_case(name), Atom.to_string(snake_case(name))]

    Enum.find_value(names, :error, fn key ->
      if Map.has_key?(map, key), do: {:ok, Map.fetch!(map, key)}
    end)
  end

  defp snake_case(:structuredContent), do: :structured_content
  defp snake_case(:isError), do: :is_error
  defp snake_case(name), do: name
end
