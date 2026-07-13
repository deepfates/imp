defmodule DSEx.BenchmarkTruth.RunContext do
  @moduledoc false

  @enforce_keys [:started_at, :code_source, :code_revision, :source_commits, :clock]
  defstruct @enforce_keys

  def new!(opts) do
    source_commits = Keyword.fetch!(opts, :source_commits)
    code_source = Keyword.get(opts, :code_source, "dsex")
    clock = Keyword.get(opts, :clock, &DateTime.utc_now/0)
    code_identity = Map.fetch!(source_commits, code_source)

    %__MODULE__{
      started_at: timestamp(clock),
      code_source: code_source,
      code_revision: revision!(code_source, code_identity),
      source_commits: source_commits,
      clock: clock
    }
  end

  def finish(%__MODULE__{} = context, artifact) when is_map(artifact) do
    completed_at = timestamp(context.clock)

    artifact
    |> Map.put("generated_at", completed_at)
    |> Map.put("git_sha", context.code_revision)
    |> Map.put("run_context", %{
      "schema_version" => 1,
      "started_at" => context.started_at,
      "completed_at" => completed_at,
      "code" => %{
        "source" => context.code_source,
        "identity" => context.source_commits[context.code_source],
        "revision" => context.code_revision
      },
      "source_commits" => context.source_commits
    })
  end

  defp revision!(source, identity) when is_binary(identity) do
    case String.split(identity, "@", parts: 2) do
      [_repository, revision] when byte_size(revision) > 0 -> revision
      _ -> raise ArgumentError, "source_commits.#{source} must end with an immutable identity"
    end
  end

  defp revision!(source, _identity) do
    raise ArgumentError, "source_commits.#{source} must be a repository identity string"
  end

  defp timestamp(clock) do
    clock.()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end
end
