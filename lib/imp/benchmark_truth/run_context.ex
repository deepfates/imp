defmodule Imp.BenchmarkTruth.RunContext do
  @moduledoc false

  @workspace_states ~w(clean dirty synthetic unknown)
  @enforce_keys [
    :started_at,
    :code_source,
    :code_revision,
    :source_commits,
    :workspace_state,
    :environment,
    :inputs,
    :clock
  ]
  defstruct @enforce_keys

  def new!(opts) do
    source_commits = opts |> Keyword.fetch!(:source_commits) |> normalize_json!()
    code_source = opts |> Keyword.get(:code_source, "imp") |> to_string()
    workspace_state = Keyword.get(opts, :workspace_state, "synthetic")
    clock = Keyword.get(opts, :clock, &DateTime.utc_now/0)
    code_identity = Map.fetch!(source_commits, code_source)
    environment = opts |> Keyword.get(:environment, %{"kind" => "synthetic"}) |> environment!()
    inputs = opts |> Keyword.get(:inputs, %{}) |> normalize_json!()
    validate_workspace_state!(workspace_state)

    %__MODULE__{
      started_at: timestamp(clock),
      code_source: code_source,
      code_revision: revision!(code_source, code_identity),
      source_commits: source_commits,
      workspace_state: workspace_state,
      environment: environment,
      inputs: inputs,
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
      environment: Keyword.get_lazy(opts, :environment, fn -> capture_environment!(cwd: cwd) end),
      inputs: Keyword.get(opts, :inputs, %{}),
      clock: Keyword.get(opts, :clock, &DateTime.utc_now/0)
    )
  end

  def capture_environment!(opts \\ []) do
    cwd = opts |> Keyword.get(:cwd, File.cwd!()) |> Path.expand()

    %{
      "kind" => "beam",
      "runtime" => %{
        "elixir" => System.version(),
        "otp_release" => System.otp_release(),
        "erts" => :erlang.system_info(:version) |> List.to_string(),
        "architecture" => :erlang.system_info(:system_architecture) |> List.to_string(),
        "os" => os_identity(),
        "mix_env" => mix_env()
      },
      "dependencies" => %{
        "mix_exs_sha256" => file_sha256!(Path.join(cwd, "mix.exs")),
        "mix_lock_sha256" => file_sha256!(Path.join(cwd, "mix.lock")),
        "resolved" => resolved_dependencies!(Path.join(cwd, "mix.lock"))
      }
    }
    |> environment!()
  end

  def finish(%__MODULE__{} = context, artifact) when is_map(artifact) do
    payload =
      artifact
      |> normalize_json!()
      |> Map.drop(["generated_at", "git_sha", "run_context"])

    completed_at = timestamp(context.clock)
    payload_sha256 = payload_sha256(payload)

    run_context = %{
      "schema_version" => 2,
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
      "environment" => context.environment,
      "inputs" => context.inputs,
      "source_commits" => context.source_commits
    }

    run_context = Map.put(run_context, "envelope_sha256", payload_sha256(run_context))

    payload
    |> Map.put("generated_at", completed_at)
    |> Map.put("git_sha", context.code_revision)
    |> Map.put("run_context", run_context)
  end

  def verify!(artifact) when is_map(artifact) do
    context = Map.fetch!(artifact, "run_context")
    revision = get_in(context, ["code", "revision"])
    completed_at = context["completed_at"]
    expected_sha256 = context["payload_sha256"]

    payload = Map.drop(artifact, ["generated_at", "git_sha", "run_context"])

    unless context_schema_valid?(context) and artifact["git_sha"] == revision and
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

  defp context_schema_valid?(%{"schema_version" => 1} = context),
    do: base_context_valid?(context)

  defp context_schema_valid?(
         %{
           "schema_version" => 2,
           "environment" => environment,
           "inputs" => inputs
         } = context
       )
       when is_map(environment) and is_map(inputs) do
    base_context_valid?(context) and environment_valid?(environment) and envelope_valid?(context)
  end

  defp context_schema_valid?(_context), do: false

  defp environment!(environment) when is_map(environment) do
    environment = normalize_json!(environment)
    declared = environment["fingerprint"]
    base = Map.delete(environment, "fingerprint")
    expected = payload_sha256(base)

    if declared not in [nil, expected],
      do: raise(ArgumentError, "environment fingerprint does not match its contents")

    Map.put(base, "fingerprint", expected)
  end

  defp environment!(_environment), do: raise(ArgumentError, "environment must be a JSON object")

  defp environment_valid?(environment) do
    environment!(environment) == environment
  rescue
    ArgumentError -> false
  end

  defp envelope_valid?(context) do
    expected = context["envelope_sha256"]
    is_binary(expected) and expected == payload_sha256(Map.delete(context, "envelope_sha256"))
  end

  defp base_context_valid?(context) do
    with %{
           "started_at" => started_at,
           "completed_at" => completed_at,
           "payload_sha256" => payload_digest,
           "workspace" => %{"state" => workspace_state, "reproducible" => reproducible?},
           "code" => %{
             "source" => code_source,
             "identity" => code_identity,
             "revision" => code_revision
           },
           "source_commits" => source_commits
         } <- context,
         true <- is_binary(code_source) and code_source != "",
         true <- is_binary(code_revision) and code_revision != "",
         true <- is_map(source_commits),
         true <- source_commits[code_source] == code_identity,
         true <- revision_valid?(code_source, code_identity, code_revision),
         true <- workspace_state in @workspace_states,
         true <- is_boolean(reproducible?) and reproducible? == (workspace_state == "clean"),
         true <- valid_sha256?(payload_digest),
         {:ok, started_at} <- parse_timestamp(started_at),
         {:ok, completed_at} <- parse_timestamp(completed_at) do
      DateTime.compare(completed_at, started_at) in [:eq, :gt]
    else
      _other -> false
    end
  end

  defp revision_valid?(source, identity, revision) do
    revision!(source, identity) == revision
  rescue
    ArgumentError -> false
  end

  defp valid_sha256?("sha256:" <> digest),
    do: Regex.match?(~r/^[0-9a-f]{64}$/, digest)

  defp valid_sha256?(_digest), do: false

  defp parse_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _other -> :error
    end
  end

  defp parse_timestamp(_value), do: :error

  defp git!(cwd, args, operation) do
    case System.cmd("git", args, cd: cwd, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {_output, _status} -> raise ArgumentError, "unable to #{operation}"
    end
  end

  defp resolved_dependencies!(lock_path) do
    lock_path
    |> Mix.Dep.Lock.read()
    |> Enum.sort_by(fn {app, _lock} -> Atom.to_string(app) end)
    |> Enum.map(fn {app, lock} -> lock_identity(app, lock) end)
  end

  defp lock_identity(app, lock) do
    case Tuple.to_list(lock) do
      [:hex, package, version, checksum | rest] ->
        %{
          "app" => Atom.to_string(app),
          "source" => "hex",
          "package" => to_string(package),
          "version" => version,
          "checksum" => checksum,
          "outer_checksum" => List.last(rest)
        }

      [:git, repository, revision | _rest] ->
        %{
          "app" => Atom.to_string(app),
          "source" => "git",
          "repository" => repository,
          "revision" => revision
        }

      _other ->
        %{
          "app" => Atom.to_string(app),
          "source" => "other",
          "lock_sha256" => lock |> :erlang.term_to_binary() |> raw_sha256()
        }
    end
  end

  defp file_sha256!(path), do: path |> File.read!() |> raw_sha256()

  defp raw_sha256(bytes) do
    bytes
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> then(&("sha256:" <> &1))
  end

  defp os_identity do
    {family, name} = :os.type()
    %{"family" => Atom.to_string(family), "name" => Atom.to_string(name)}
  end

  defp mix_env do
    if Code.ensure_loaded?(Mix), do: Mix.env() |> Atom.to_string(), else: "unknown"
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
