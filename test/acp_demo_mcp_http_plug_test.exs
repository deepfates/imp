defmodule Imp.ACP.DemoMCPHTTPPlugTest do
  use ExUnit.Case, async: true

  alias Imp.ACP.DemoMCPHTTPPlug

  @expected "Bearer demo-token-0123456789"

  test "a token of the expected length that differs is refused" do
    supplied = "Bearer demo-token-0123456780"
    assert byte_size(supplied) == byte_size(@expected)

    response = call(supplied)

    assert response.status == 401
    assert response.halted
    assert_received {:mcp_http_auth, :rejected}
    refute_received {:mcp_http_auth, :accepted}
  end

  test "a token of another length is refused" do
    response = call(@expected <> "0")

    assert response.status == 401
    assert_received {:mcp_http_auth, :rejected}
  end

  defp call(authorization) do
    opts = DemoMCPHTTPPlug.init(expected_authorization: @expected, notify: self())

    :post
    |> Plug.Test.conn("/", "{}")
    |> Plug.Conn.put_req_header("authorization", authorization)
    |> DemoMCPHTTPPlug.call(opts)
  end
end
