defmodule Imp.BenchmarkTruth.FileTree do
  @moduledoc false

  require Record

  Record.defrecordp(:file_info, Record.extract(:file_info, from_lib: "kernel/include/file.hrl"))

  @typedoc "A canonical inventory whose digest commits to its schema and `files` list."
  @type inventory :: %{String.t() => 1 | String.t() | [file_entry()]}

  @typedoc "Metadata for one regular file or dereferenced symlink."
  @type file_entry :: %{String.t() => String.t() | non_neg_integer()}

  @chunk_size 1_048_576

  @doc "Builds a deterministic inventory for `root`, which must be a directory."
  @spec inventory!(Path.t()) :: inventory()
  def inventory!(root) when is_binary(root) do
    root = Path.expand(root)
    root_stat = lstat!(root, "root")

    unless root_stat.type == :directory do
      raise ArgumentError, "file-tree root is not a directory: #{inspect(root)}"
    end

    files =
      root
      |> walk_directory!(root, root_stat)
      |> Enum.sort_by(& &1["path"])

    payload = %{"schema_version" => 1, "files" => files}

    Map.put(payload, "sha256", digest(payload))
  end

  def inventory!(root) do
    raise ArgumentError, "file-tree root must be a path, got: #{inspect(root)}"
  end

  @doc "Recomputes `root` and returns `:ok` only when the complete inventory matches."
  @spec validate(Path.t(), inventory()) :: :ok | {:error, term()}
  def validate(root, expected) when is_binary(root) and is_map(expected) do
    actual = inventory!(root)

    if actual == expected do
      :ok
    else
      {:error,
       %{
         expected_sha256: Map.get(expected, "sha256"),
         actual_sha256: actual["sha256"]
       }}
    end
  rescue
    error -> {:error, error}
  end

  def validate(root, expected),
    do:
      {:error,
       ArgumentError.exception(
         "invalid file-tree validation arguments: #{inspect({root, expected})}"
       )}

  @doc "Like `validate/2`, but raises when the tree does not match."
  @spec validate!(Path.t(), inventory()) :: :ok
  def validate!(root, expected) do
    case validate(root, expected) do
      :ok ->
        :ok

      {:error, %{expected_sha256: expected_sha256, actual_sha256: actual_sha256}} ->
        raise ArgumentError,
              "file-tree inventory mismatch: expected #{inspect(expected_sha256)}, got #{inspect(actual_sha256)}"

      {:error, error} when is_exception(error) ->
        raise error

      {:error, reason} ->
        raise ArgumentError, "file-tree validation failed: #{inspect(reason)}"
    end
  end

  defp walk_directory!(root, directory, before_stat) do
    names = list_directory!(directory)

    files =
      Enum.flat_map(names, fn name ->
        path = Path.join(directory, name)
        stat = lstat!(path, "entry")

        case stat.type do
          :directory ->
            walk_directory!(root, path, stat)

          :regular ->
            [regular_entry!(root, path, stat)]

          :symlink ->
            [symlink_entry!(root, path, stat)]

          type ->
            raise ArgumentError,
                  "unsupported file-tree entry #{inspect(path)} of type #{inspect(type)}"
        end
      end)

    after_stat = lstat!(directory, "directory")
    after_names = list_directory!(directory)

    unless stable_stat?(before_stat, after_stat) and names == after_names do
      raise ArgumentError, "file-tree directory changed during inventory: #{inspect(directory)}"
    end

    files
  end

  defp regular_entry!(root, path, before_stat) do
    {bytes, sha256, before_fd_stat, after_fd_stat} = hash_file!(path)
    after_stat = lstat!(path, "file")

    unless stable_stat?(before_stat, before_fd_stat) and
             stable_stat?(before_fd_stat, after_fd_stat) and
             stable_stat?(after_fd_stat, after_stat) and after_stat.type == :regular and
             bytes == after_fd_stat.size do
      raise ArgumentError, "file changed during inventory: #{inspect(path)}"
    end

    entry(root, path, bytes, sha256)
  end

  defp symlink_entry!(root, path, before_link_stat) do
    link_target = read_link!(path)
    before_target_stat = stat!(path, "symlink target")

    unless before_target_stat.type == :regular do
      raise ArgumentError,
            "file-tree symlink must resolve to a regular file: #{inspect(path)} resolves to #{inspect(before_target_stat.type)}"
    end

    {bytes, sha256, before_fd_stat, after_fd_stat} = hash_file!(path)
    after_link_stat = lstat!(path, "symlink")
    after_target_stat = stat!(path, "symlink target")
    after_link_target = read_link!(path)

    unless stable_stat?(before_link_stat, after_link_stat) and after_link_stat.type == :symlink and
             stable_stat?(before_target_stat, before_fd_stat) and
             stable_stat?(before_fd_stat, after_fd_stat) and
             stable_stat?(after_fd_stat, after_target_stat) and
             after_target_stat.type == :regular and bytes == after_fd_stat.size and
             link_target == after_link_target do
      raise ArgumentError, "symlink changed during inventory: #{inspect(path)}"
    end

    entry(root, path, bytes, sha256)
    |> Map.put("link_target", link_target)
  end

  defp entry(root, path, bytes, sha256) do
    %{
      "path" => relative_posix_path(root, path),
      "bytes" => bytes,
      "sha256" => sha256
    }
  end

  defp relative_posix_path(root, path) do
    path
    |> Path.relative_to(root)
    |> Path.split()
    |> Enum.join("/")
  end

  defp list_directory!(path) do
    case File.ls(path) do
      {:ok, names} -> Enum.sort(names)
      {:error, reason} -> raise File.Error, reason: reason, action: "list directory", path: path
    end
  end

  defp lstat!(path, label) do
    case File.lstat(path, time: :posix) do
      {:ok, stat} -> stat
      {:error, reason} -> raise File.Error, reason: reason, action: "stat #{label}", path: path
    end
  end

  defp stat!(path, label) do
    case File.stat(path, time: :posix) do
      {:ok, stat} -> stat
      {:error, reason} -> raise File.Error, reason: reason, action: "stat #{label}", path: path
    end
  end

  defp read_link!(path) do
    case File.read_link(path) do
      {:ok, target} -> target
      {:error, reason} -> raise File.Error, reason: reason, action: "read symlink", path: path
    end
  end

  defp hash_file!(path) do
    File.open!(path, [:read, :binary], fn io ->
      before_stat = fd_stat!(io, path)
      {bytes, sha256} = hash_chunks!(io, :crypto.hash_init(:sha256), 0, path)
      after_stat = fd_stat!(io, path)
      {bytes, sha256, before_stat, after_stat}
    end)
  end

  defp fd_stat!(io, path) do
    case :file.read_file_info(io, time: :posix) do
      {:ok, info} ->
        %{
          type: file_info(info, :type),
          size: file_info(info, :size),
          mode: file_info(info, :mode),
          uid: file_info(info, :uid),
          gid: file_info(info, :gid),
          major_device: file_info(info, :major_device),
          minor_device: file_info(info, :minor_device),
          inode: file_info(info, :inode),
          mtime: file_info(info, :mtime),
          ctime: file_info(info, :ctime)
        }

      {:error, reason} ->
        raise File.Error, reason: reason, action: "stat open file", path: path
    end
  end

  defp hash_chunks!(io, context, bytes, path) do
    case IO.binread(io, @chunk_size) do
      :eof ->
        {bytes, context |> :crypto.hash_final() |> Base.encode16(case: :lower)}

      {:error, reason} ->
        raise File.Error, reason: reason, action: "read file", path: path

      chunk ->
        hash_chunks!(io, :crypto.hash_update(context, chunk), bytes + byte_size(chunk), path)
    end
  end

  defp stable_stat?(left, right) do
    Enum.all?(
      [:type, :size, :mode, :uid, :gid, :major_device, :minor_device, :inode, :mtime, :ctime],
      &(Map.fetch!(left, &1) == Map.fetch!(right, &1))
    )
  end

  defp digest(value) do
    value
    |> canonical_json()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp canonical_json(%{} = map) do
    encoded =
      map
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map_join(",", fn {key, value} ->
        Jason.encode!(key) <> ":" <> canonical_json(value)
      end)

    "{" <> encoded <> "}"
  end

  defp canonical_json(list) when is_list(list),
    do: "[" <> Enum.map_join(list, ",", &canonical_json/1) <> "]"

  defp canonical_json(value), do: Jason.encode!(value)
end
