defmodule WorkspaceAgent.Tools do
  @moduledoc """
  Bounded workspace tools rooted in one ACP-selected workspace.

  These tools reject absolute paths, lexical traversal, and symlink traversal.
  They deliberately skip dependency, build, and VCS directories. ACP permission
  remains a separate pre-effect decision for writes and commands; neither layer
  is a filesystem sandbox.
  """

  import Bitwise

  @max_files 500
  @max_source_bytes 1_048_576
  @default_read_lines 200
  @max_read_lines 400
  @max_read_chars 32_000
  @max_search_results 100
  @max_search_line_chars 500
  @ignored_names MapSet.new([
                   ".git",
                   ".elixir_ls",
                   "_build",
                   "deps",
                   "erl_crash.dump",
                   "node_modules"
                 ])

  @spec for_workspace(Path.t()) :: [Imp.Tool.t()]
  def for_workspace(root) do
    root = Path.expand(root)

    [
      Imp.tool(
        :list_files,
        "List source files below a relative workspace directory",
        fn args ->
          list_files(root, fetch(args, :path, "."))
        end,
        schema: object_schema(%{"path" => %{"type" => "string"}})
      ),
      Imp.tool(
        :read_file,
        "Read a bounded UTF-8 line range from one workspace file",
        fn args ->
          read_file(
            root,
            fetch(args, :path),
            fetch(args, :line_start, 1),
            fetch(args, :line_count, @default_read_lines)
          )
        end,
        schema:
          object_schema(
            %{
              "path" => %{"type" => "string"},
              "line_start" => %{"type" => "integer", "minimum" => 1},
              "line_count" => %{
                "type" => "integer",
                "minimum" => 1,
                "maximum" => @max_read_lines
              }
            },
            ["path"]
          )
      ),
      Imp.tool(
        :search_text,
        "Find literal text in one bounded UTF-8 file or below a workspace directory",
        fn args ->
          search_text(root, fetch(args, :query), fetch(args, :path, "."))
        end,
        schema:
          object_schema(
            %{
              "query" => %{"type" => "string"},
              "path" => %{
                "type" => "string",
                "description" => "Relative file or directory path"
              }
            },
            ["query"]
          )
      ),
      Imp.tool(
        :create_file,
        "Create one new UTF-8 file without overwriting an existing path",
        fn args ->
          create_file(root, fetch(args, :path), fetch(args, :content))
        end,
        schema:
          object_schema(
            %{
              "path" => %{"type" => "string"},
              "content" => %{"type" => "string"}
            },
            ["path", "content"]
          )
      ),
      Imp.tool(
        :replace_text,
        "Replace an exact UTF-8 fragment in one existing workspace file",
        fn args ->
          replace_text(
            root,
            fetch(args, :path),
            fetch(args, :old_text),
            fetch(args, :new_text),
            fetch(args, :replace_all, false)
          )
        end,
        schema:
          object_schema(
            %{
              "path" => %{"type" => "string"},
              "old_text" => %{"type" => "string", "minLength" => 1},
              "new_text" => %{"type" => "string"},
              "replace_all" => %{"type" => "boolean"}
            },
            ["path", "old_text", "new_text"]
          )
      ),
      Imp.tool(
        :run_command,
        "Run one executable with an argument vector inside the workspace",
        fn args ->
          run_command(
            root,
            fetch(args, :command),
            fetch(args, :args, []),
            fetch(args, :cwd, "."),
            fetch(args, :timeout_ms, 120_000)
          )
        end,
        schema:
          object_schema(
            %{
              "command" => %{
                "type" => "string",
                "minLength" => 1,
                "description" => "Executable name or absolute path"
              },
              "args" => %{
                "type" => "array",
                "items" => %{"type" => "string"},
                "description" => "Arguments after the executable; do not repeat command"
              },
              "cwd" => %{"type" => "string"},
              "timeout_ms" => %{
                "type" => "integer",
                "minimum" => 1,
                "maximum" => 120_000
              }
            },
            ["command"]
          )
      )
    ]
  end

  @spec list_files(Path.t(), String.t()) :: String.t() | {:error, term()}
  def list_files(root, relative) do
    with {:ok, directory} <- safe_path(root, relative),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(directory) do
      directory
      |> walk(root, [])
      |> Enum.sort()
      |> Enum.take(@max_files)
      |> Enum.join("\n")
    else
      {:ok, %File.Stat{type: type}} -> {:error, {:not_a_directory, type}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec read_file(Path.t(), String.t(), pos_integer(), pos_integer()) ::
          String.t() | {:error, term()}
  def read_file(root, relative, line_start \\ 1, line_count \\ @default_read_lines)

  def read_file(
        root,
        relative,
        line_start,
        line_count
      )
      when is_integer(line_start) and line_start >= 1 and is_integer(line_count) and
             line_count >= 1 and line_count <= @max_read_lines do
    with {:ok, path} <- safe_path(root, relative),
         {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_source_bytes <-
           File.lstat(path),
         {:ok, content} <- File.read(path),
         true <- String.valid?(content) do
      lines = String.split(content, "\n")
      total_lines = length(lines)

      if line_start > total_lines do
        {:error, {:line_start_beyond_end, total_lines}}
      else
        selected = lines |> Enum.slice(line_start - 1, line_count) |> Enum.join("\n")
        selected = truncate_chars(selected, @max_read_chars)

        if line_start == 1 and total_lines <= line_count do
          selected
        else
          last_line = min(line_start + line_count - 1, total_lines)
          "[#{relative} lines #{line_start}-#{last_line} of #{total_lines}]\n#{selected}"
        end
      end
    else
      {:ok, %File.Stat{type: :regular, size: size}} -> {:error, {:source_too_large, size}}
      {:ok, %File.Stat{type: type}} -> {:error, {:not_a_regular_file, type}}
      false -> {:error, :not_utf8}
      {:error, reason} -> {:error, reason}
    end
  end

  def read_file(_root, _relative, _line_start, _line_count), do: {:error, :invalid_line_range}

  @spec search_text(Path.t(), String.t(), String.t()) :: String.t() | {:error, term()}
  def search_text(root, query, relative)
      when is_binary(query) and query != "" and is_binary(relative) do
    with {:ok, directory} <- safe_path(root, relative),
         {:ok, %File.Stat{type: type}} <- File.lstat(directory) do
      case type do
        :directory -> search_directory(directory, root, query)
        :regular -> search_file(root, relative, query)
        other -> {:error, {:not_a_regular_file_or_directory, other}}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def search_text(_root, _query, _relative), do: {:error, :invalid_search}

  @spec create_file(Path.t(), String.t(), String.t()) :: String.t() | {:error, term()}
  def create_file(root, relative, content) when is_binary(content) do
    with {:ok, path} <- safe_path(root, relative),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(Path.dirname(path)),
         :ok <- exclusive_write(path, content, 0o644) do
      "Created #{relative} (#{byte_size(content)} bytes, sha256 #{sha256(content)})"
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def create_file(_root, _relative, _content), do: {:error, :invalid_create}

  @spec replace_text(Path.t(), String.t(), String.t(), String.t(), boolean()) ::
          String.t() | {:error, term()}
  def replace_text(root, relative, old_text, new_text, replace_all?)
      when is_binary(old_text) and old_text != "" and is_binary(new_text) and
             is_boolean(replace_all?) do
    with {:ok, path} <- safe_path(root, relative),
         {:ok, %File.Stat{type: :regular, size: size, mode: mode}}
         when size <= @max_source_bytes <- File.lstat(path),
         {:ok, content} <- File.read(path),
         true <- String.valid?(content),
         matches when matches > 0 <- length(:binary.matches(content, old_text)),
         :ok <- ensure_unambiguous(matches, replace_all?),
         updated <- String.replace(content, old_text, new_text, global: replace_all?),
         :ok <- atomic_write(path, updated, band(mode, 0o777)) do
      "Updated #{relative} (#{matches} replacement#{if matches == 1, do: "", else: "s"}, " <>
        "sha256 #{sha256(updated)})"
    else
      {:ok, %File.Stat{type: :regular, size: size}} -> {:error, {:source_too_large, size}}
      {:ok, %File.Stat{type: type}} -> {:error, {:not_a_regular_file, type}}
      false -> {:error, :not_utf8}
      0 -> {:error, :text_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def replace_text(_root, _relative, _old_text, _new_text, _replace_all?),
    do: {:error, :invalid_replace}

  @spec run_command(Path.t(), String.t(), [String.t()], String.t(), pos_integer()) ::
          String.t() | {:error, term()}
  def run_command(root, command, args, relative_cwd, timeout_ms)
      when is_binary(command) and command != "" and is_list(args) and is_binary(relative_cwd) and
             is_integer(timeout_ms) and timeout_ms > 0 and timeout_ms <= 120_000 do
    with true <- Enum.all?(args, &is_binary/1),
         {:ok, directory} <- safe_path(root, relative_cwd),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(directory),
         {:ok, result} <-
           Imp.ExternalCommand.run(command, args,
             cd: directory,
             timeout: timeout_ms,
             max_output_bytes: 32_000
           ) do
      command_result(result)
    else
      false ->
        {:error, :invalid_command_arguments}

      {:ok, %File.Stat{type: type}} ->
        {:error, {:not_a_directory, type}}

      {:error, {:exit_status, status, result}} ->
        {:error, {:command_failed, status, command_result(result)}}

      {:error, {:timeout, result}} ->
        {:error, {:command_timed_out, command_result(result)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def run_command(_root, _command, _args, _relative_cwd, _timeout_ms),
    do: {:error, :invalid_command}

  defp search_directory(directory, root, query) do
    directory
    |> walk(root, [])
    |> Enum.reduce_while([], fn relative_path, matches ->
      case read_whole_file(root, relative_path) do
        content when is_binary(content) ->
          found = matching_lines(relative_path, content, query)
          combined = matches ++ found

          if length(combined) >= @max_search_results do
            {:halt, Enum.take(combined, @max_search_results)}
          else
            {:cont, combined}
          end

        _error ->
          {:cont, matches}
      end
    end)
    |> Enum.join("\n")
  end

  defp search_file(root, relative, query) do
    case read_whole_file(root, relative) do
      content when is_binary(content) ->
        relative |> matching_lines(content, query) |> Enum.join("\n")

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp walk(directory, root, acc) do
    case File.ls(directory) do
      {:ok, entries} ->
        Enum.reduce_while(Enum.sort(entries), acc, fn entry, paths ->
          cond do
            MapSet.member?(@ignored_names, entry) ->
              {:cont, paths}

            length(paths) >= @max_files ->
              {:halt, paths}

            true ->
              path = Path.join(directory, entry)

              case File.lstat(path) do
                {:ok, %File.Stat{type: :regular}} ->
                  {:cont, [Path.relative_to(path, root) | paths]}

                {:ok, %File.Stat{type: :directory}} ->
                  {:cont, walk(path, root, paths)}

                _symlink_or_error ->
                  {:cont, paths}
              end
          end
        end)

      {:error, _reason} ->
        acc
    end
  end

  defp safe_path(root, relative) when is_binary(relative) and relative != "" do
    case :filelib.safe_relative_path(String.to_charlist(relative), String.to_charlist(root)) do
      :unsafe -> {:error, :outside_workspace}
      safe -> {:ok, Path.join(root, List.to_string(safe))}
    end
  end

  defp safe_path(_root, _relative), do: {:error, :invalid_path}

  defp matching_lines(path, content, query) do
    content
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, line_number} ->
      if String.contains?(line, query) do
        ["#{path}:#{line_number}:#{truncate_chars(line, @max_search_line_chars)}"]
      else
        []
      end
    end)
  end

  defp read_whole_file(root, relative) do
    with {:ok, path} <- safe_path(root, relative),
         {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_source_bytes <-
           File.lstat(path),
         {:ok, content} <- File.read(path),
         true <- String.valid?(content) do
      content
    else
      _error -> {:error, :unreadable}
    end
  end

  defp ensure_unambiguous(1, _replace_all?), do: :ok
  defp ensure_unambiguous(_matches, true), do: :ok
  defp ensure_unambiguous(matches, false), do: {:error, {:ambiguous_replacement, matches}}

  defp atomic_write(path, content, mode) do
    temporary = path <> ".imp-acp-#{System.unique_integer([:positive])}.tmp"

    with :ok <- File.write(temporary, content, [:binary, :sync]),
         :ok <- File.chmod(temporary, mode),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(temporary)
        {:error, {:write_failed, reason}}
    end
  end

  defp exclusive_write(path, content, mode) do
    result =
      File.open(path, [:write, :exclusive, :binary], fn device ->
        with :ok <- IO.binwrite(device, content),
             :ok <- :file.sync(device) do
          :ok
        end
      end)

    case result do
      {:ok, :ok} ->
        case File.chmod(path, mode) do
          :ok ->
            :ok

          {:error, reason} ->
            _ = File.rm(path)
            {:error, {:write_failed, reason}}
        end

      {:error, :eexist} ->
        {:error, :path_already_exists}

      {:ok, {:error, reason}} ->
        _ = File.rm(path)
        {:error, {:write_failed, reason}}

      {:error, reason} ->
        {:error, {:write_failed, reason}}
    end
  end

  defp command_result(result) do
    output = String.trim_trailing(result.output)
    header = "exit #{result.exit_status} in #{result.duration_ms}ms"
    if output == "", do: header, else: header <> "\n" <> output
  end

  defp sha256(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  defp truncate_chars(text, limit) do
    if String.length(text) <= limit,
      do: text,
      else: String.slice(text, 0, limit) <> "\n[truncated]"
  end

  defp fetch(map, key, default \\ nil) when is_map(map),
    do: Map.get(map, Atom.to_string(key), default)

  defp object_schema(properties, required \\ []) do
    %{"type" => "object", "properties" => properties, "required" => required}
  end
end
