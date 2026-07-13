defmodule DSEx.IdentityProgress.Git do
  @moduledoc false

  @snapshot_attempts 3

  @type snapshot :: %{
          revision: String.t(),
          tracked_paths: MapSet.t(String.t()),
          accepted_revisions: %{String.t() => String.t()}
        }

  @spec snapshot!(String.t(), String.t()) :: snapshot()
  def snapshot!(inbox_glob, root) do
    root = Path.expand(root)
    stable_snapshot!(inbox_glob, root, @snapshot_attempts)
  end

  @spec accepted_revisions!(String.t(), String.t()) :: %{String.t() => String.t()}
  def accepted_revisions!(inbox_glob, root),
    do: snapshot!(inbox_glob, root).accepted_revisions

  defp stable_snapshot!(_inbox_glob, _root, 0) do
    raise "Git state changed repeatedly while taking the identity acceptance snapshot"
  end

  defp stable_snapshot!(inbox_glob, root, attempts_left) do
    before = repository_state!(root)
    tree = tree_entries!(root, before.revision)
    accepted = accepted_revisions(inbox_glob, root, tree, before)
    after_state = repository_state!(root)

    if before == after_state do
      %{
        revision: before.revision,
        tracked_paths: tree |> Map.keys() |> MapSet.new(),
        accepted_revisions: accepted
      }
    else
      stable_snapshot!(inbox_glob, root, attempts_left - 1)
    end
  end

  defp repository_state!(root) do
    revision = git_line!(root, ["rev-parse", "HEAD"])

    dirty_paths =
      [
        git_paths!(root, ["diff", "--cached", "--name-only", "-z", revision, "--"]),
        git_paths!(root, ["diff", "--name-only", "-z", "--"]),
        git_paths!(root, ["ls-files", "--others", "--exclude-standard", "-z", "--"])
      ]
      |> Enum.reduce(MapSet.new(), &MapSet.union/2)

    %{
      revision: revision,
      object_format: git_line!(root, ["rev-parse", "--show-object-format"]),
      dirty_paths: dirty_paths
    }
  end

  defp accepted_revisions(inbox_glob, root, tree, state) do
    inbox_glob
    |> Path.wildcard()
    |> Enum.map(&Path.expand(&1, root))
    |> Enum.reduce(%{}, fn path, accepted ->
      with {:ok, tree_oid} <- Map.fetch(tree, path),
           false <- MapSet.member?(state.dirty_paths, path),
           {:ok, body} <- File.read(path),
           ^tree_oid <- git_blob_oid(body, state.object_format) do
        Map.put(accepted, path, sha256(body))
      else
        _other -> accepted
      end
    end)
  end

  defp tree_entries!(root, revision) do
    root
    |> git_output!(["ls-tree", "-r", "-z", revision])
    |> String.split(<<0>>, trim: true)
    |> Enum.reduce(%{}, fn entry, tree ->
      [metadata, relative] = String.split(entry, "\t", parts: 2)
      [_mode, type, oid] = String.split(metadata, " ", parts: 3)

      if type == "blob",
        do: Map.put(tree, Path.expand(relative, root), oid),
        else: tree
    end)
  end

  defp git_paths!(root, args) do
    root
    |> git_output!(args)
    |> String.split(<<0>>, trim: true)
    |> Enum.map(&Path.expand(&1, root))
    |> MapSet.new()
  end

  defp git_line!(root, args), do: root |> git_output!(args) |> String.trim()

  defp git_output!(root, args) do
    case System.cmd("git", args, cd: root, stderr_to_stdout: true) do
      {output, 0} ->
        output

      {output, status} ->
        raise "git #{Enum.join(args, " ")} failed with status #{status}: #{String.trim(output)}"
    end
  end

  defp git_blob_oid(body, "sha1"), do: blob_hash(body, :sha)
  defp git_blob_oid(body, "sha256"), do: blob_hash(body, :sha256)

  defp git_blob_oid(_body, format),
    do: raise("unsupported Git object format #{inspect(format)}")

  defp blob_hash(body, algorithm) do
    payload = ["blob ", Integer.to_string(byte_size(body)), <<0>>, body]
    :crypto.hash(algorithm, payload) |> Base.encode16(case: :lower)
  end

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
