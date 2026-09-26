defmodule Imp.ACP.Host do
  @moduledoc """
  A session-bound handle to capabilities supplied by an ACP host.

  ACP calls the user-facing application the *client*. `Imp.ACP.Host` uses the
  product-facing name instead: it is the Toad, editor, or future chat
  application that mounted the workspace and advertised filesystem or terminal
  capabilities. The handle is created by `Imp.ACP` and passed to a
  `:program_factory` as `session.host`.

  `tools/2` turns those host capabilities into ordinary `Imp.Tool` values. The
  tools still cross Imp's per-execution authorization boundary before a write
  or command is sent. ExMCP remains responsible for ACP capability negotiation,
  request encoding, request cancellation, and response validation.
  """

  alias ExMCP.ACP.{Agent, Maps}

  @enforce_keys [:agent, :session_id, :cwd, :client_capabilities]
  defstruct [:agent, :session_id, :cwd, :client_capabilities]

  @type t :: %__MODULE__{
          agent: GenServer.server(),
          session_id: String.t(),
          cwd: Path.t(),
          client_capabilities: map()
        }

  @default_read_lines 200
  @max_read_lines 400
  @max_write_chars 128_000
  @max_command_args 128
  @max_output_bytes 32_000
  @default_command_timeout 120_000
  @host_tool_names [:read_file, :write_file, :run_command]

  @doc false
  @spec new(GenServer.server(), String.t(), Path.t(), map() | nil) :: t()
  def new(agent, session_id, cwd, client_capabilities)
      when is_binary(session_id) and is_binary(cwd) do
    %__MODULE__{
      agent: agent,
      session_id: session_id,
      cwd: Path.expand(cwd),
      client_capabilities: client_capabilities || %{}
    }
  end

  @tools_schema [
    only: [
      type: {:list, {:in, @host_tool_names}},
      default: @host_tool_names,
      doc: "The host tools to request."
    ]
  ]

  @doc """
  Builds tools for the capabilities advertised by the connected ACP host.

  All three host tools are requested by default, but unsupported tools are
  omitted. ACP treats omitted capabilities as unsupported, so an agent never
  advertises an effect that its host cannot perform.

  ## Options

  #{NimbleOptions.docs(@tools_schema)}
  """
  @spec tools(t(), keyword()) :: [Imp.Tool.t()]
  def tools(%__MODULE__{} = host, opts \\ []) do
    only = Imp.Options.validate!(opts, @tools_schema, "Imp.ACP.Host.tools/2")[:only]

    catalog = %{
      read_file: read_file_tool(host),
      write_file: write_file_tool(host),
      run_command: run_command_tool(host)
    }

    only
    |> Enum.filter(&supported?(host, &1))
    |> Enum.map(&Map.fetch!(catalog, &1))
  end

  @doc "Returns whether the connected ACP host advertised a tool's capability."
  @spec supported?(t(), :read_file | :write_file | :run_command) :: boolean()
  def supported?(%__MODULE__{client_capabilities: capabilities}, :read_file) do
    capabilities |> Maps.get("fs") |> Maps.get("readTextFile") == true
  end

  def supported?(%__MODULE__{client_capabilities: capabilities}, :write_file) do
    capabilities |> Maps.get("fs") |> Maps.get("writeTextFile") == true
  end

  def supported?(%__MODULE__{client_capabilities: capabilities}, :run_command) do
    Maps.get(capabilities, "terminal") == true
  end

  @doc """
  Delegates authorization for tools built by `tools/2` to the ACP host.

  Use this as `Imp.ACP.run/1`'s `:permission_policy` only when the catalog
  entries with these names came from this module. Imp records a local allow at
  its execution boundary, but the tool immediately calls the connected ACP
  host, which applies its own capability policy and returns success or denial.
  This keeps one human decision at the host-owned effect boundary.

  Other tool names retain the ordinary ACP permission request.
  """
  @spec permission_policy(Imp.Execution.Authorization.t(), map()) :: :allow | :client
  def permission_policy(%{tool_name: name}, _session) do
    if Enum.any?(@host_tool_names, &(to_string(&1) == to_string(name))),
      do: :allow,
      else: :client
  end

  defp read_file_tool(host) do
    Imp.tool(
      :read_file,
      "Read a bounded UTF-8 line range from a file supplied by the ACP host",
      fn args ->
        with {:ok, path} <- workspace_path(host, fetch(args, :path)),
             {:ok, line} <- positive_integer(fetch(args, :line_start, 1), :line_start),
             {:ok, limit} <- read_limit(fetch(args, :line_count, @default_read_lines)),
             {:ok, %{"content" => content}} when is_binary(content) <-
               request(fn ->
                 Agent.read_text_file(host.agent, host.session_id, path,
                   line: line,
                   limit: limit,
                   timeout: 30_000
                 )
               end) do
          content
        else
          {:ok, other} -> {:error, {:invalid_file_read_response, result_shape(other)}}
          {:error, reason} -> {:error, reason}
        end
      end,
      schema:
        object_schema(
          %{
            "path" => %{"type" => "string", "minLength" => 1},
            "line_start" => %{"type" => "integer", "minimum" => 1},
            "line_count" => %{
              "type" => "integer",
              "minimum" => 1,
              "maximum" => @max_read_lines
            }
          },
          ["path"]
        )
    )
  end

  defp write_file_tool(host) do
    Imp.tool(
      :write_file,
      "Write complete UTF-8 contents to a file supplied by the ACP host",
      fn args ->
        content = fetch(args, :content)

        with {:ok, path} <- workspace_path(host, fetch(args, :path)),
             :ok <- bounded_text(content, @max_write_chars, :content),
             {:ok, response} <-
               request(fn ->
                 Agent.write_text_file(host.agent, host.session_id, path, content,
                   timeout: 30_000
                 )
               end),
             true <- is_nil(response) or is_map(response) do
          "Wrote #{relative_path(host, path)} (#{byte_size(content)} bytes)"
        else
          false -> {:error, :invalid_file_write_response}
          {:error, reason} -> {:error, reason}
        end
      end,
      schema:
        object_schema(
          %{
            "path" => %{"type" => "string", "minLength" => 1},
            "content" => %{
              "type" => "string",
              "maxLength" => @max_write_chars,
              "description" => "Complete replacement contents for the file"
            }
          },
          ["path", "content"]
        )
    )
  end

  defp run_command_tool(host) do
    Imp.tool(
      :run_command,
      "Run one executable with an argument vector in an ACP-hosted terminal",
      fn args ->
        command = fetch(args, :command)
        argv = fetch(args, :args, [])
        timeout_ms = fetch(args, :timeout_ms, @default_command_timeout)

        with :ok <- command(command, argv),
             {:ok, cwd} <- workspace_path(host, fetch(args, :cwd, ".")),
             {:ok, timeout_ms} <- command_timeout(timeout_ms),
             {:ok, %{"terminalId" => terminal_id}} when is_binary(terminal_id) <-
               request(fn ->
                 Agent.terminal_create(
                   host.agent,
                   host.session_id,
                   %{
                     "command" => command,
                     "args" => argv,
                     "cwd" => cwd,
                     "outputByteLimit" => @max_output_bytes
                   },
                   timeout: 30_000
                 )
               end) do
          await_terminal(host, terminal_id, timeout_ms)
        else
          {:ok, other} -> {:error, {:invalid_terminal_create_response, result_shape(other)}}
          {:error, reason} -> {:error, reason}
        end
      end,
      schema:
        object_schema(
          %{
            "command" => %{"type" => "string", "minLength" => 1},
            "args" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "maxItems" => @max_command_args,
              "description" => "Arguments after the executable; do not repeat command"
            },
            "cwd" => %{"type" => "string"},
            "timeout_ms" => %{
              "type" => "integer",
              "minimum" => 1,
              "maximum" => @default_command_timeout
            }
          },
          ["command"]
        )
    )
  end

  defp await_terminal(host, terminal_id, timeout_ms) do
    cancellable =
      Imp.Run.register_cancellable(fn _reason ->
        terminate_terminal(host, terminal_id)
      end)

    try do
      with {:ok, wait} <-
             request(fn ->
               Agent.terminal_wait_for_exit(host.agent, host.session_id, terminal_id,
                 timeout: timeout_ms
               )
             end),
           {:ok, output} <-
             request(fn ->
               Agent.terminal_output(host.agent, host.session_id, terminal_id, timeout: 10_000)
             end),
           {:ok, exit_code} <- exit_code(wait, output),
           text <- terminal_text(output),
           :ok <- command_status(exit_code, text) do
        command_result(exit_code, text, output["truncated"] == true)
      end
    after
      Imp.Run.unregister_cancellable(cancellable)
      release_terminal(host, terminal_id)
    end
  end

  defp terminate_terminal(host, terminal_id) do
    _ =
      request(fn ->
        Agent.terminal_kill(host.agent, host.session_id, terminal_id, timeout: 2_000)
      end)

    release_terminal(host, terminal_id)
    :ok
  end

  defp release_terminal(host, terminal_id) do
    _ =
      request(fn ->
        Agent.terminal_release(host.agent, host.session_id, terminal_id, timeout: 2_000)
      end)

    :ok
  end

  defp exit_code(%{"exitCode" => code}, _output) when is_integer(code), do: {:ok, code}

  defp exit_code(_wait, %{"exitStatus" => %{"exitCode" => code}})
       when is_integer(code),
       do: {:ok, code}

  defp exit_code(_wait, _output), do: {:error, :terminal_exit_status_missing}

  defp terminal_text(%{"output" => text}) when is_binary(text), do: text
  defp terminal_text(_output), do: ""

  defp command_status(0, _text), do: :ok
  defp command_status(code, text), do: {:error, {:command_failed, code, text}}

  defp command_result(code, text, truncated?) do
    suffix = if truncated?, do: " (output truncated)", else: ""
    "Command exited #{code}#{suffix}\n#{text}"
  end

  defp workspace_path(%__MODULE__{cwd: root}, relative)
       when is_binary(relative) and relative != "" do
    if Path.type(relative) == :relative do
      expanded = Path.expand(relative, root)
      relative_to_root = Path.relative_to(expanded, root)

      if Path.type(relative_to_root) != :relative or relative_to_root == ".." or
           String.starts_with?(relative_to_root, "../") do
        {:error, :path_outside_workspace}
      else
        {:ok, expanded}
      end
    else
      {:error, :absolute_path_not_allowed}
    end
  end

  defp workspace_path(_host, _path), do: {:error, :invalid_workspace_path}

  defp relative_path(%__MODULE__{cwd: root}, path), do: Path.relative_to(path, root)

  defp positive_integer(value, _name) when is_integer(value) and value > 0, do: {:ok, value}
  defp positive_integer(_value, name), do: {:error, {:invalid_positive_integer, name}}

  defp read_limit(value) when is_integer(value) and value > 0 and value <= @max_read_lines,
    do: {:ok, value}

  defp read_limit(_value), do: {:error, :invalid_line_count}

  defp command_timeout(value)
       when is_integer(value) and value > 0 and value <= @default_command_timeout,
       do: {:ok, value}

  defp command_timeout(_value), do: {:error, :invalid_command_timeout}

  defp bounded_text(value, max, _name) when is_binary(value) and byte_size(value) <= max, do: :ok
  defp bounded_text(_value, _max, name), do: {:error, {:invalid_or_oversized_text, name}}

  defp command(command, args)
       when is_binary(command) and command != "" and is_list(args) and
              length(args) <= @max_command_args do
    if Enum.all?(args, &(is_binary(&1) and byte_size(&1) <= 8_192)),
      do: :ok,
      else: {:error, :invalid_command_arguments}
  end

  defp command(_command, _args), do: {:error, :invalid_command}

  defp request(fun) do
    fun.()
  rescue
    exception -> {:error, {:host_request_failed, exception}}
  catch
    :exit, {:timeout, _details} -> {:error, :host_request_timeout}
    :exit, reason -> {:error, {:host_request_exit, Imp.Redaction.redact(reason)}}
    kind, reason -> {:error, {:host_request_failed, {kind, Imp.Redaction.redact(reason)}}}
  end

  defp fetch(map, key, default \\ nil) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp object_schema(properties, required) do
    %{
      "type" => "object",
      "properties" => properties,
      "required" => required,
      "additionalProperties" => false
    }
  end

  defp result_shape(value) when is_map(value), do: {:map, Map.keys(value) |> Enum.sort()}
  defp result_shape(value), do: value |> inspect(limit: 3) |> String.slice(0, 200)
end
