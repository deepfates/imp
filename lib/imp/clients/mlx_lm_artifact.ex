defmodule Imp.Clients.MLXLMArtifact do
  @moduledoc false

  @chunk_size 1_048_576

  @type file_entry :: %{
          required(String.t()) => String.t() | non_neg_integer()
        }

  @type inventory :: %{required(String.t()) => 1 | String.t() | [file_entry()]}

  @spec inventory(Path.t()) :: {:ok, inventory()} | {:error, term()}
  def inventory(root) when is_binary(root) do
    root = Path.expand(root)

    with {:ok, %File.Stat{type: :directory}} <- File.lstat(root, time: :posix),
         {:ok, files} <- walk(root, root) do
      payload = %{"schema_version" => 1, "files" => Enum.sort_by(files, & &1["path"])}
      {:ok, Map.put(payload, "sha256", digest(payload))}
    else
      {:ok, %File.Stat{type: type}} -> {:error, {:mlx_lm_artifact_not_a_directory, type}}
      {:error, reason} -> {:error, {:mlx_lm_artifact_inventory_failed, reason}}
    end
  rescue
    error -> {:error, {:mlx_lm_artifact_inventory_failed, Exception.message(error)}}
  end

  def inventory(root), do: {:error, {:mlx_lm_artifact_path_invalid, root}}

  @spec validate(Path.t(), inventory()) :: :ok | {:error, term()}
  def validate(root, %{"files" => files, "sha256" => digest} = expected)
      when is_binary(root) and is_list(files) and is_binary(digest) do
    case inventory(root) do
      {:ok, ^expected} ->
        :ok

      {:ok, actual} ->
        {:error,
         {:mlx_lm_artifact_tree_mismatch,
          %{expected_sha256: digest, actual_sha256: actual["sha256"]}}}

      {:error, _reason} = error ->
        error
    end
  end

  def validate(_root, _expected), do: {:error, :mlx_lm_artifact_inventory_invalid}

  @spec canonical_path(Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def canonical_path(path) when is_binary(path) do
    {:ok, File.cd!(Path.expand(path), fn -> File.cwd!() end)}
  rescue
    error -> {:error, {:mlx_lm_artifact_path_unresolvable, Exception.message(error)}}
  end

  def canonical_path(path), do: {:error, {:mlx_lm_artifact_path_invalid, path}}

  defp walk(root, directory) do
    with {:ok, before_stat} <- File.lstat(directory, time: :posix),
         {:ok, names} <- File.ls(directory),
         {:ok, files} <- walk_names(root, directory, Enum.sort(names), []),
         {:ok, after_names} <- File.ls(directory),
         {:ok, after_stat} <- File.lstat(directory, time: :posix),
         true <- stable?(before_stat, after_stat) and Enum.sort(after_names) == Enum.sort(names) do
      {:ok, files}
    else
      false -> {:error, {:artifact_changed_during_inventory, directory}}
      {:error, _reason} = error -> error
    end
  end

  defp walk_names(_root, _directory, [], files), do: {:ok, files}

  defp walk_names(root, directory, [name | rest], files) do
    path = Path.join(directory, name)

    with {:ok, stat} <- File.lstat(path, time: :posix),
         {:ok, entries} <- entries(root, path, stat) do
      walk_names(root, directory, rest, entries ++ files)
    end
  end

  defp entries(root, path, %File.Stat{type: :directory}) do
    walk(root, path)
  end

  defp entries(root, path, %File.Stat{type: :regular} = before_stat) do
    with {:ok, entry} <- file_entry(root, path, before_stat, nil) do
      {:ok, [entry]}
    end
  end

  defp entries(root, path, %File.Stat{type: :symlink} = before_link_stat) do
    with {:ok, target} <- File.read_link(path),
         {:ok, %File.Stat{type: :regular}} <- File.stat(path, time: :posix),
         {:ok, entry} <- file_entry(root, path, before_link_stat, target),
         {:ok, ^target} <- File.read_link(path) do
      {:ok, [Map.put(entry, "link_target", target)]}
    else
      {:ok, %File.Stat{type: type}} -> {:error, {:unsupported_symlink_target, path, type}}
      {:error, _reason} = error -> error
    end
  end

  defp entries(_root, path, %File.Stat{type: type}),
    do: {:error, {:unsupported_artifact_entry, path, type}}

  defp file_entry(root, path, before_lstat, link_target) do
    with {:ok, before_stat} <- File.stat(path, time: :posix),
         {:ok, bytes, sha256} <- hash_file(path),
         {:ok, after_stat} <- File.stat(path, time: :posix),
         {:ok, after_lstat} <- File.lstat(path, time: :posix),
         true <- stable_open_file?(before_stat, after_stat, bytes),
         true <- stable_entry?(before_lstat, after_lstat, link_target) do
      {:ok,
       %{
         "path" => relative_path(root, path),
         "bytes" => bytes,
         "sha256" => sha256
       }}
    else
      false -> {:error, {:artifact_changed_during_inventory, path}}
      {:error, _reason} = error -> error
    end
  end

  defp hash_file(path) do
    case File.open(path, [:read, :binary], fn io ->
           case hash_chunks(io, 0, :crypto.hash_init(:sha256)) do
             {:ok, bytes, context} ->
               {:ok, bytes, context |> :crypto.hash_final() |> Base.encode16(case: :lower)}

             {:error, _reason} = error ->
               error
           end
         end) do
      {:ok, result} -> result
      {:error, _reason} = error -> error
    end
  end

  defp hash_chunks(io, bytes, context) do
    case IO.binread(io, @chunk_size) do
      :eof -> {:ok, bytes, context}
      {:error, reason} -> {:error, reason}
      chunk -> hash_chunks(io, bytes + byte_size(chunk), :crypto.hash_update(context, chunk))
    end
  end

  defp stable_entry?(before, after_stat, nil),
    do: before.type == :regular and after_stat.type == :regular and stable?(before, after_stat)

  defp stable_entry?(before, after_stat, _link_target),
    do: before.type == :symlink and after_stat.type == :symlink and stable?(before, after_stat)

  defp stable_open_file?(before, after_stat, bytes) do
    before.type == :regular and after_stat.type == :regular and before.size == bytes and
      stable?(before, after_stat)
  end

  defp stable?(left, right) do
    Enum.all?(
      [:type, :size, :mode, :uid, :gid, :major_device, :minor_device, :inode, :mtime, :ctime],
      &(Map.get(left, &1) == Map.get(right, &1))
    )
  end

  defp relative_path(root, path),
    do: path |> Path.relative_to(root) |> Path.split() |> Enum.join("/")

  defp digest(payload) do
    payload
    |> Imp.Training.ChatDataset.canonical_json()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
