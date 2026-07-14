defmodule Imp.BenchmarkTruth.RunContext do
  @moduledoc false

  @workspace_states ~w(clean dirty synthetic unknown)
  @enforce_keys [
    :started_at,
    :code_source,
    :code_revision,
    :source_commits,
    :workspace_state,
    :clock
  ]
  defstruct @enforce_keys

  def new!(opts) do
    source_commits = Keyword.fetch!(opts, :source_commits)
    code_source = Keyword.get(opts, :code_source, "imp")
    workspace_state = Keyword.get(opts, :workspace_state, "synthetic")
    clock = Keyword.get(opts, :clock, &DateTime.utc_now/0)
    code_identity = Map.fetch!(source_commits, code_source)
    validate_workspace_state!(workspace_state)

    %__MODULE__{
      started_at: timestamp(clock),
      code_source: code_source,
      code_revision: revision!(code_source, code_identity),
      source_commits: source_commits,
      workspace_state: workspace_state,
      clock: clock
    }
  end

  def capture_git!(opts \\ []) do
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    code_source = Keyword.get(opts, :code_source, "imp")
    repository = Keyword.get(opts, :repository, "deepfates/imp")
    source_commits = Keyword.get(opts, :source_commits, %{})
    revision = git!(cwd, ["rev-parse", "HEAD"], "resolve Git HEAD")

    workspace_state =
      if git!(cwd, ["status", "--porcelain=v1"], "inspect Git status") == "",
        do: "clean",
        else: "dirty"

    if Keyword.get(opts, :require_clean, false) and workspace_state != "clean" do
      raise ArgumentError, "evidence capture requires a clean Git checkout"
    end

    new!(
      source_commits: Map.put(source_commits, code_source, "#{repository}@#{revision}"),
      code_source: code_source,
      workspace_state: workspace_state,
      clock: Keyword.get(opts, :clock, &DateTime.utc_now/0)
    )
  end

  def finish(%__MODULE__{} = context, artifact) when is_map(artifact) do
    artifact = normalize_json!(artifact)
    completed_at = timestamp(context.clock)
    payload_sha256 = payload_sha256(artifact)

    artifact
    |> Map.put("generated_at", completed_at)
    |> Map.put("git_sha", context.code_revision)
    |> Map.put("run_context", %{
      "schema_version" => 1,
      "started_at" => context.started_at,
      "completed_at" => completed_at,
      "payload_sha256" => payload_sha256,
      "workspace" => %{
        "state" => context.workspace_state,
        "reproducible" => context.workspace_state == "clean"
      },
      "code" => %{
        "source" => context.code_source,
        "identity" => context.source_commits[context.code_source],
        "revision" => context.code_revision
      },
      "source_commits" => context.source_commits
    })
  end

  def verify!(artifact) when is_map(artifact) do
    context = Map.fetch!(artifact, "run_context")
    revision = get_in(context, ["code", "revision"])
    completed_at = context["completed_at"]
    expected_sha256 = context["payload_sha256"]

    payload = Map.drop(artifact, ["generated_at", "git_sha", "run_context"])

    unless context["schema_version"] == 1 and artifact["git_sha"] == revision and
             artifact["generated_at"] == completed_at and
             expected_sha256 == payload_sha256(payload) do
      raise ArgumentError, "invalid or tampered benchmark run envelope"
    end

    artifact
  rescue
    KeyError ->
      reraise ArgumentError,
              [message: "benchmark artifact is missing its run envelope"],
              __STACKTRACE__
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

  defp validate_workspace_state!(state) when state in @workspace_states, do: :ok

  defp validate_workspace_state!(state) do
    raise ArgumentError, "invalid evidence workspace state: #{inspect(state)}"
  end

  defp git!(cwd, args, operation) do
    case System.cmd("git", args, cd: cwd, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {_output, _status} -> raise ArgumentError, "unable to #{operation}"
    end
  end

  defp payload_sha256(payload) do
    payload
    |> canonical_json()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> then(&("sha256:" <> &1))
  end

  defp canonical_json(%{} = map) do
    entries =
      map
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map_join(",", fn {key, value} ->
        Jason.encode!(key) <> ":" <> canonical_json(value)
      end)

    "{" <> entries <> "}"
  end

  defp canonical_json(list) when is_list(list),
    do: "[" <> Enum.map_join(list, ",", &canonical_json/1) <> "]"

  defp canonical_json(value), do: Jason.encode!(value)

  defp normalize_json!(artifact), do: artifact |> Jason.encode!() |> Jason.decode!()

  defp timestamp(clock) do
    clock.()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end
end
