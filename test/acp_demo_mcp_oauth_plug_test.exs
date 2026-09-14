defmodule Imp.ACP.DemoMCPOAuthPlugTest do
  use ExUnit.Case, async: true

  test "oversized form bodies are refused before authorization or token state is accessed" do
    body = "padding=" <> String.duplicate("x", 8_000_001)

    for path <- ["/authorize", "/token"] do
      conn =
        :post
        |> Plug.Test.conn(path, body)
        |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")

      response = Imp.ACP.DemoMCPOAuthPlug.call(conn, %{})

      assert response.status == 413
      assert Jason.decode!(response.resp_body) == %{"error" => "invalid_request"}
    end
  end
end
