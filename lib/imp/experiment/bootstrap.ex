defmodule Imp.Experiment.Bootstrap do
  @moduledoc """
  Canonical, non-secret runtime and provenance bootstrap for Imp experiments.

  The bootstrap starts the public application boundary and records only the
  minimal reproducibility owners: source commit, dependency locks, data, and
  configuration. It does not read credentials, provider catalogs, or held-out
  row contents beyond the already-validated data manifest.
  """

  alias Imp.Experiment.Data

  @doc "Starts Imp and returns content-bound minimal provenance."
  @spec capture!(Data.t(), term(), keyword()) :: map()
  def capture!(data, config, opts \\ [])

  def capture!(%Data{} = data, config, opts) when is_list(opts) do
    unless Keyword.keyword?(opts), do: invalid!(opts)

    unknown = Keyword.keys(opts) -- [:source_root, :locks, :require_clean, :upstreams, :metadata]

    if unknown != [],
      do: raise(ArgumentError, "unknown experiment bootstrap options: #{inspect(unknown)}")

    {:ok, _apps} = Application.ensure_all_started(:imp)

    root = opts |> Keyword.get(:source_root, File.cwd!()) |> Path.expand()
    git = git_identity(root, Keyword.get(opts, :require_clean, false))
    locks = Keyword.get(opts, :locks, default_locks(root))

    %{
      "schema_version" => 1,
      "git" => git,
      "locks" => digest_files!(root, locks),
      "data" => Data.manifest(data),
      "config_sha256" => Data.digest(config),
      "upstreams" => normalize_map(Keyword.get(opts, :upstreams, %{})),
      "metadata" => normalize_map(Keyword.get(opts, :metadata, %{}))
    }
  end

  def capture!(data, _config, _opts) do
    raise ArgumentError,
          "experiment bootstrap requires Imp.Experiment.Data, got: #{inspect(data)}"
  end

  defp git_identity(root, require_clean?) do
    case System.cmd("git", ["rev-parse", "HEAD"], cd: root, stderr_to_stdout: true) do
      {commit, 0} ->
        {status, status_code} =
          System.cmd("git", ["status", "--porcelain"], cd: root, stderr_to_stdout: true)

        if status_code != 0,
          do:
            raise(ArgumentError, "cannot inspect experiment Git worktree: #{String.trim(status)}")

        clean? = status == ""

        if require_clean? and not clean?,
          do: raise(ArgumentError, "experiment source worktree is not clean")

        %{"commit" => String.trim(commit), "clean" => clean?}

      {_output, _status} ->
        if require_clean?,
          do: raise(ArgumentError, "experiment source_root is not a Git worktree")

        %{"commit" => nil, "clean" => nil}
    end
  end

  defp default_locks(root) do
    if File.regular?(Path.join(root, "mix.lock")), do: ["mix.lock"], else: []
  end

  defp digest_files!(root, paths) when is_list(paths) do
    Map.new(paths, fn path ->
      expanded = Path.expand(path, root)

      unless File.regular?(expanded),
        do: raise(ArgumentError, "experiment lock does not exist: #{path}")

      {path, expanded |> File.read!() |> sha256()}
    end)
  end

  defp digest_files!(_root, value),
    do: raise(ArgumentError, "experiment :locks must be a list, got: #{inspect(value)}")

  defp normalize_map(map) when is_map(map), do: Imp.Optimizer.Report.json_safe(map)

  defp normalize_map(value),
    do: raise(ArgumentError, "experiment provenance fields must be maps, got: #{inspect(value)}")

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp invalid!(opts),
    do:
      raise(ArgumentError, "experiment bootstrap expects keyword options, got: #{inspect(opts)}")
end
