defmodule Mix.Tasks.ImpAcp.DemoMcpHttpServer do
  @shortdoc "Runs the demo MCP tool server over Streamable HTTP"

  use Mix.Task

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _rest, invalid} =
      OptionParser.parse(args,
        strict: [port: :integer, auth_env: :string, oauth: :boolean, oauth_token_ttl: :integer]
      )

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    port = Keyword.get(opts, :port, 43_219)
    ref = {:imp_acp_demo_mcp_http, port}

    {:ok, _server} = start_server(port, ref, opts)

    IO.puts(:stderr, "Imp ACP demo MCP HTTP server listening on http://127.0.0.1:#{port}")
    Process.sleep(:infinity)
  end

  defp start_server(port, ref, opts) do
    case {Keyword.get(opts, :auth_env), Keyword.get(opts, :oauth, false)} do
      {env_name, true} when is_binary(env_name) ->
        Mix.raise("--auth-env and --oauth are mutually exclusive")

      {nil, true} ->
        origin = "http://127.0.0.1:#{port}"

        {:ok, state} =
          Agent.start_link(fn ->
            %{clients: %{}, codes: %{}, access_tokens: %{}, refresh_tokens: %{}}
          end)

        Plug.Cowboy.http(
          Imp.ACP.DemoMCPOAuthPlug,
          [
            origin: origin,
            state: state,
            token_ttl: Keyword.get(opts, :oauth_token_ttl, 3600)
          ],
          port: port,
          ip: {127, 0, 0, 1},
          ref: ref
        )

      {nil, false} ->
        Imp.ACP.DemoMCPServer.start_link(
          transport: :http,
          port: port,
          use_sse: false,
          ranch_ref: ref
        )

      {env_name, false} ->
        token =
          case System.fetch_env(env_name) do
            {:ok, value} when value != "" -> value
            _missing -> Mix.raise("credential environment variable #{env_name} is not set")
          end

        Plug.Cowboy.http(
          Imp.ACP.DemoMCPHTTPPlug,
          [expected_authorization: "Bearer " <> token],
          port: port,
          ip: {127, 0, 0, 1},
          ref: ref
        )
    end
  end
end
