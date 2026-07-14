defmodule Imp.Test.LocalHTTP do
  @moduledoc false

  import Plug.Conn

  def start(handler) when is_function(handler, 1) do
    server =
      ExUnit.Callbacks.start_supervised!(
        {Bandit,
         [
           plug: {__MODULE__, handler: handler},
           ip: {127, 0, 0, 1},
           port: 0,
           startup_log: false
         ]}
      )

    "http://127.0.0.1:#{listener_port(server)}"
  end

  def child_spec(handler) when is_function(handler, 1) do
    {Bandit,
     [
       plug: {__MODULE__, handler: handler},
       ip: {127, 0, 0, 1},
       port: 0,
       startup_log: false
     ]}
  end

  def init(opts), do: opts

  def call(conn, opts) do
    handler = Keyword.fetch!(opts, :handler)
    {:ok, body, conn} = read_body(conn)

    request = %{
      method: conn.method,
      path: conn.request_path,
      headers: Map.new(conn.req_headers),
      body: body
    }

    {status, response_body} = handler.(request)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(response_body))
  end

  defp listener_port(server) do
    server
    |> ThousandIsland.listener_info()
    |> extract_port()
  end

  defp extract_port(%{port: port}) when is_integer(port), do: port
  defp extract_port(%{addr: {_ip, port}}) when is_integer(port), do: port
  defp extract_port(%{sockname: {_ip, port}}) when is_integer(port), do: port
  defp extract_port({_ip, port}) when is_integer(port), do: port
  defp extract_port({:ok, info}), do: extract_port(info)

  defp extract_port(info) do
    raise "could not determine local HTTP listener port from #{inspect(info)}"
  end
end
