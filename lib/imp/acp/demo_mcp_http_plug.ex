defmodule Imp.ACP.DemoMCPHTTPPlug do
  @moduledoc false

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts) do
    %{
      expected_authorization: Keyword.fetch!(opts, :expected_authorization),
      notify: Keyword.get(opts, :notify),
      mcp:
        ExMCP.HttpPlug.init(
          handler: Imp.ACP.DemoMCPServer,
          server_info: %{name: "imp-acp-demo-mcp", version: "0.1.0"},
          allowed_hosts: ["localhost", "127.0.0.1", "::1"],
          allowed_origins: :any
        )
    }
  end

  @impl true
  def call(conn, opts) do
    supplied = get_req_header(conn, "authorization")

    if authorized?(supplied, opts.expected_authorization) do
      notify(opts.notify, :accepted)
      ExMCP.HttpPlug.call(conn, opts.mcp)
    else
      notify(opts.notify, :rejected)

      conn
      |> put_resp_header("www-authenticate", ~s|Bearer realm="imp-acp-demo-mcp"|)
      |> send_resp(401, "Unauthorized")
      |> halt()
    end
  end

  defp authorized?([supplied], expected)
       when byte_size(supplied) == byte_size(expected),
       do: Plug.Crypto.secure_compare(supplied, expected)

  defp authorized?(_supplied, _expected), do: false

  defp notify(pid, status) when is_pid(pid), do: send(pid, {:mcp_http_auth, status})
  defp notify(_pid, _status), do: :ok
end
