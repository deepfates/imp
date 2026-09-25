defmodule Imp.Test.MCPConnect do
  @moduledoc false

  # One trusted descriptor through `Imp.MCP.connect/2`, raising when it cannot
  # be connected, for tests that exercise one server.

  def stdio!(command, opts \\ []) do
    {args, opts} = Keyword.pop(opts, :args, [])
    {env, opts} = Keyword.pop(opts, :env, [])

    connect!(
      %{
        "name" => "stdio",
        "type" => "stdio",
        "command" => command,
        "args" => args,
        "env" =>
          Enum.map(env, fn {k, v} -> %{"name" => to_string(k), "value" => to_string(v)} end)
      },
      opts
    )
  end

  def http!(url, opts \\ []) do
    {headers, opts} = Keyword.pop(opts, :headers, [])

    connect!(
      %{
        "name" => "http",
        "type" => "http",
        "url" => url,
        "headers" =>
          Enum.map(headers, fn {k, v} -> %{"name" => to_string(k), "value" => to_string(v)} end)
      },
      opts
    )
  end

  def connect!(server, opts \\ []) do
    opts = Keyword.put_new(opts, :trusted_servers, [server])

    case Imp.MCP.connect([server], opts) do
      {:ok, import} -> import
      {:error, reason} -> raise ArgumentError, "MCP connection failed: #{inspect(reason)}"
    end
  end
end
