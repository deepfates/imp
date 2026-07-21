defmodule Imp.BenchmarkTruth.Paths do
  @moduledoc false

  @runs_root "benchmarks/runs"
  @checkpoints_root "benchmarks/checkpoints"
  @admitted_root "benchmarks/evidence/admitted"
  @safe_lane ~r/\A[a-z0-9][a-z0-9_-]*\z/
  @max_symlink_depth 64

  def runs_root, do: @runs_root
  def checkpoints_root, do: @checkpoints_root
  def admitted_root, do: @admitted_root

  def runs(lane), do: join!(@runs_root, lane)
  def checkpoints(lane), do: join!(@checkpoints_root, lane)
  def admitted(protocol), do: join!(@admitted_root, protocol)

  @doc false
  def canonical_path!(path, base \\ File.cwd!())

  def canonical_path!(path, base) when is_binary(path) and is_binary(base) do
    path
    |> Path.expand(base)
    |> resolve_path!(%{}, 0)
  end

  def canonical_path!(path, _base),
    do: raise(ArgumentError, "benchmark path must be a string, got: #{inspect(path)}")

  @doc false
  def contained_path!(root, path) when is_binary(root) and is_binary(path) do
    logical_root = Path.expand(root)
    logical_path = Path.expand(path)

    unless contained?(logical_root, logical_path) do
      raise ArgumentError, "benchmark path escapes its declared root: #{inspect(path)}"
    end

    canonical_root = canonical_path!(logical_root)
    canonical_path = canonical_path!(logical_path)

    unless contained?(canonical_root, canonical_path) do
      raise ArgumentError,
            "benchmark path escapes its canonical root through a symlink: #{inspect(path)}"
    end

    canonical_path
  end

  @doc false
  def prepare_file_path!(root, relative_path)
      when is_binary(root) and is_binary(relative_path) do
    validate_relative_file_path!(relative_path)

    logical_root = Path.expand(root)
    File.mkdir_p!(logical_root)

    logical_path = Path.expand(relative_path, logical_root)
    _canonical_path = contained_path!(logical_root, logical_path)

    physical_parent = ensure_contained_directory!(logical_root, Path.dirname(logical_path))
    physical_path = Path.join(physical_parent, Path.basename(logical_path))

    case File.lstat(physical_path) do
      {:ok, %File.Stat{type: :symlink}} ->
        raise ArgumentError,
              "benchmark artifact path must not be an existing symlink: #{inspect(relative_path)}"

      {:ok, _stat} ->
        physical_path

      {:error, :enoent} ->
        physical_path

      {:error, reason} ->
        raise_path_error!("inspect benchmark artifact path", physical_path, reason)
    end
  end

  def prepare_file_path!(root, relative_path) do
    raise ArgumentError,
          "benchmark artifact root and relative path must be strings, got: " <>
            "#{inspect(root)} and #{inspect(relative_path)}"
  end

  @doc false
  def ensure_contained_directory!(root, directory)
      when is_binary(root) and is_binary(directory) do
    logical_root = Path.expand(root)
    logical_directory = Path.expand(directory)

    unless contained?(logical_root, logical_directory) do
      raise ArgumentError,
            "benchmark directory escapes its declared root: #{inspect(directory)}"
    end

    File.mkdir_p!(logical_root)
    canonical_root = canonical_path!(logical_root)

    unless File.dir?(canonical_root) do
      raise ArgumentError, "benchmark artifact root is not a directory: #{inspect(root)}"
    end

    relative = Path.relative_to(logical_directory, logical_root)

    relative
    |> relative_segments()
    |> Enum.reduce(canonical_root, fn segment, parent ->
      ensure_directory_component!(canonical_root, parent, segment)
    end)
    |> verify_contained_directory!(canonical_root)
  end

  defp join!(root, lane) when is_binary(lane) do
    if Regex.match?(@safe_lane, lane) do
      path = Path.join(root, lane)

      unless contained?(Path.expand(root), Path.expand(path)) do
        raise ArgumentError, "benchmark lane escapes its canonical root: #{inspect(lane)}"
      end

      path
    else
      raise ArgumentError, "benchmark lane must be a safe path segment, got: #{inspect(lane)}"
    end
  end

  defp join!(_root, lane),
    do: raise(ArgumentError, "benchmark lane must be a string, got: #{inspect(lane)}")

  defp resolve_path!(path, seen, depth) do
    segments = path |> Path.expand() |> Path.split() |> Enum.reject(&(&1 == "/"))
    resolve_segments!("/", segments, seen, depth)
  end

  defp resolve_segments!(current, [], _seen, _depth), do: current

  defp resolve_segments!(current, [segment | rest], seen, depth) do
    candidate = Path.join(current, segment)

    case File.lstat(candidate) do
      {:ok, %File.Stat{type: :symlink}} ->
        resolve_symlink!(candidate, current, rest, seen, depth)

      {:ok, _stat} ->
        resolve_segments!(candidate, rest, seen, depth)

      {:error, :enoent} ->
        Path.join([candidate | rest]) |> Path.expand()

      {:error, reason} ->
        raise_path_error!("canonicalize benchmark path", candidate, reason)
    end
  end

  defp resolve_symlink!(candidate, parent, rest, seen, depth) do
    symlink_step = {candidate, rest}

    if depth >= @max_symlink_depth or Map.has_key?(seen, symlink_step) do
      raise ArgumentError, "cannot canonicalize cyclic benchmark symlink: #{candidate}"
    end

    target =
      case File.read_link(candidate) do
        {:ok, target} -> target
        {:error, reason} -> raise_path_error!("read benchmark symlink", candidate, reason)
      end

    expanded_target = Path.expand(target, parent)

    [expanded_target | rest]
    |> Path.join()
    |> resolve_path!(Map.put(seen, symlink_step, true), depth + 1)
  end

  defp contained?("/", path), do: String.starts_with?(path, "/")
  defp contained?(root, path), do: path == root or String.starts_with?(path, root <> "/")

  defp validate_relative_file_path!(relative_path) do
    segments = Path.split(relative_path)

    unless Path.type(relative_path) == :relative and segments != [] and
             Enum.all?(segments, &(&1 not in [".", "..", "/"])) do
      raise ArgumentError,
            "benchmark artifact path must be a non-empty relative path without traversal: " <>
              inspect(relative_path)
    end
  end

  defp relative_segments("."), do: []
  defp relative_segments(relative), do: Path.split(relative)

  defp ensure_directory_component!(root, parent, segment) do
    candidate = Path.join(parent, segment)

    case File.lstat(candidate) do
      {:ok, %File.Stat{type: :directory}} ->
        candidate

      {:ok, %File.Stat{type: :symlink}} ->
        candidate
        |> canonical_path!()
        |> verify_contained_directory!(root)

      {:ok, _stat} ->
        raise ArgumentError,
              "benchmark artifact directory component is not a directory: #{candidate}"

      {:error, :enoent} ->
        case File.mkdir(candidate) do
          :ok -> candidate
          {:error, :eexist} -> ensure_directory_component!(root, parent, segment)
          {:error, reason} -> raise_path_error!("create benchmark directory", candidate, reason)
        end

      {:error, reason} ->
        raise_path_error!("inspect benchmark directory", candidate, reason)
    end
  end

  defp verify_contained_directory!(directory, root) do
    canonical = canonical_path!(directory)

    unless contained?(root, canonical) and File.dir?(canonical) do
      raise ArgumentError,
            "benchmark directory escapes its canonical root through a symlink: #{directory}"
    end

    canonical
  end

  defp raise_path_error!(action, path, reason) do
    raise ArgumentError, "cannot #{action} #{path}: #{:file.format_error(reason)}"
  end
end
