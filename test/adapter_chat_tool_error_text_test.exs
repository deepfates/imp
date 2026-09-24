defmodule Imp.Adapter.ChatToolErrorTextTest do
  # What the model reads when a tool call does not succeed. Each failure class
  # renders as plain text: the tool's own words where the tool gave words, and
  # otherwise one sentence saying what happened. The terms below are the ones
  # the MCP boundary actually returns (`Imp.MCP.Connections`, ExMCP's
  # `call_tool(format: :map)`), several captured from a live server.
  use ExUnit.Case, async: true

  alias Imp.Adapter.Chat

  describe "an MCP error result" do
    test "is the text of its content, and nothing else" do
      envelope = %{
        "content" => [
          %{"type" => "text", "text" => "error: write outcome unknown; reconcile before retry"}
        ],
        "isError" => true,
        "structuredContent" => %{"code" => "indeterminate", "outcome" => "unknown"},
        "_meta" => %{"io.modelcontextprotocol/serverInfo" => %{"name" => "kite"}}
      }

      assert Chat.format_tool_result({:error, {:mcp_tool_error, envelope}}) ==
               "error: write outcome unknown; reconcile before retry"
    end

    test "joins several text items and skips content that is not text" do
      envelope = %{
        content: [
          %{type: "text", text: "not posted"},
          %{type: "image", data: "…", mimeType: "image/png"},
          %{type: "text", text: "the thread is locked"}
        ],
        isError: true
      }

      assert Chat.format_tool_result({:error, {:mcp_tool_error, envelope}}) ==
               "not posted\nthe thread is locked"
    end

    test "with no text, is its structured content as data" do
      envelope = %{
        "content" => [],
        "isError" => true,
        "structuredContent" => %{"code" => "refused"}
      }

      assert Chat.format_tool_result({:error, {:mcp_tool_error, envelope}}) ==
               ~s({"code": "refused"})
    end

    test "with nothing at all, says so" do
      assert Chat.format_tool_result({:error, {:mcp_tool_error, %{"isError" => true}}}) ==
               "The tool reported an error without saying what it was."
    end
  end

  describe "a JSON-RPC error from the server" do
    test "is its message" do
      error = %{
        "code" => -32602,
        "message" => "Invalid params: uri is required",
        "data" => %{"type" => "validation"}
      }

      assert Chat.format_tool_result({:error, {:mcp_tool_call_failed, "kite", error}}) ==
               "Error: Invalid params: uri is required"

      assert Chat.format_tool_result({:error, {:json_rpc_error, error}}) ==
               "Error: Invalid params: uri is required"
    end

    test "adds the error's type in words when the server named one ExMCP defines" do
      crash = %{
        "code" => -32603,
        "message" => "Tool call failed",
        "data" => %{"type" => "handler_crash"}
      }

      assert Chat.format_tool_result({:error, {:mcp_tool_call_failed, "kite", crash}}) ==
               "Error: Tool call failed; the tool crashed."

      slow = %{
        "code" => -32603,
        "message" => "Tool call failed",
        "data" => %{"type" => "handler_timeout"}
      }

      assert Chat.format_tool_result({:error, {:mcp_tool_call_failed, "kite", slow}}) ==
               "Error: Tool call failed; the tool took too long."
    end
  end

  describe "a call that got no answer" do
    test "a timeout says it timed out" do
      assert Chat.format_tool_result({:error, {:mcp_tool_call_failed, "kite", :timeout}}) ==
               "Error: no answer came back; it timed out."

      exit = {:timeout, {GenServer, :call, [self(), {:request, "tools/call", %{}, %{}}, 300]}}

      assert Chat.format_tool_result({:error, {:mcp_connection_unavailable, "kite", exit}}) ==
               "Error: no answer came back; it timed out."
    end

    test "a closed connection says the connection closed" do
      closed = ExMCP.Error.connection_error("Transport closed: :normal")

      assert Chat.format_tool_result({:error, {:mcp_tool_call_failed, "kite", closed}}) ==
               "Error: no answer came back; the connection closed."

      exit = {:normal, {GenServer, :call, [self(), :request, 300]}}

      assert Chat.format_tool_result({:error, {:mcp_connection_unavailable, "kite", exit}}) ==
               "Error: no answer came back; the connection closed."
    end

    test "a connection that is not open says so" do
      exit = {:noproc, {GenServer, :call, [self(), :request, 300]}}

      assert Chat.format_tool_result({:error, {:mcp_connection_unavailable, "kite", exit}}) ==
               "Error: no answer came back; the connection is not open."

      assert Chat.format_tool_result({:error, {:mcp_tool_call_failed, "kite", :not_connected}}) ==
               "Error: no answer came back; the connection is not open."
    end

    test "a transport failure says the connection failed" do
      refused = %{
        type: :transport_error,
        message: "Failed to send request: %Mint.TransportError{reason: :econnrefused}"
      }

      assert Chat.format_tool_result({:error, {:mcp_tool_call_failed, "kite", refused}}) ==
               "Error: no answer came back; the connection failed."
    end

    test "a broken stream after delivery says the call may have been carried out" do
      unknown =
        ExMCP.Error.transport_error(:http, :outcome_unknown, %{
          method: "tools/call",
          message:
            "The response stream broke after delivery; the server may have completed the request."
        })

      assert Chat.format_tool_result({:error, {:mcp_tool_call_failed, "kite", unknown}}) ==
               "Error: no answer came back; the connection broke after the request was sent, " <>
                 "so it may have been carried out."
    end

    test "a tool that exits says it stopped before answering" do
      assert Chat.format_tool_result({:error, {:tool_error, :lookup, {:exit, :killed}}}) ==
               "Error: lookup failed: it stopped before answering."

      assert Chat.format_tool_result(
               {:error, {:tool_error, :lookup, {:exit, {:timeout, {GenServer, :call, []}}}}}
             ) == "Error: lookup failed: it timed out."
    end
  end

  describe "a call the loop refused before running it" do
    test "an unknown tool names the tool that does not exist" do
      assert Chat.format_tool_result({:error, {:unknown_tool, "frobnicate"}}) ==
               "Error: there is no tool named frobnicate."
    end

    test "missing and invalid arguments say which arguments" do
      assert Chat.format_tool_result({:error, {:missing_required, ["uri", "text"]}}) ==
               "Error: missing required arguments: uri, text"

      errors = [
        %{field: "limit", rule: :maximum, message: "must be <= 100"},
        %{field: "kind", rule: :type, message: "expected string"}
      ]

      assert Chat.format_tool_result({:error, {:schema_validation, errors}}) ==
               "Error: invalid arguments: limit must be <= 100; kind expected string"
    end

    test "a denied tool and an unreadable call say so" do
      assert Chat.format_tool_result({:error, {:tool_denied, :post}}) ==
               "Error: post is not allowed."

      assert Chat.format_tool_result({:error, {:malformed_tool_call, %{"function" => nil}}}) ==
               "Error: the tool call could not be read."
    end
  end
end
