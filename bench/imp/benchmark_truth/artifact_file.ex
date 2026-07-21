defmodule Imp.BenchmarkTruth.ArtifactFile do
  @moduledoc false

  alias Imp.BenchmarkTruth.Paths

  @slug_limit 48
  @digest_length 12

  def write_json!(path, artifact) do
    write_json_in!(Path.dirname(path), Path.basename(path), artifact)
  end

  def write_json_in!(root, relative_path, artifact) do
    physical_path = Paths.prepare_file_path!(root, relative_path)
    logical_path = Path.join(root, relative_path)
    payload = Jason.encode!(artifact, pretty: true) <> "\n"
    allocated_path = publish_exclusively!(physical_path, payload)

    Path.join(Path.dirname(logical_path), Path.basename(allocated_path))
  end

  @doc false
  def slug(value) do
    source = if is_binary(value), do: value, else: inspect(value)

    readable =
      source
      |> String.replace(~r/[^0-9A-Za-z_.-]+/, "_")
      |> String.replace(~r/_+/, "_")
      |> String.replace(~r/\A[._-]+|[._-]+\z/, "")
      |> String.slice(0, @slug_limit)
      |> case do
        "" -> "artifact"
        value -> value
      end

    digest =
      source
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> binary_part(0, @digest_length)

    "#{readable}--#{digest}"
  end

  @doc false
  def artifact_name(prefix, identities, extension \\ ".json")
      when is_binary(prefix) and is_list(identities) and is_binary(extension) do
    prefix =
      prefix
      |> String.replace(~r/[^0-9A-Za-z_.-]+/, "-")
      |> String.trim("-")

    if prefix == "" or String.contains?(extension, ["/", "\\"]) do
      raise ArgumentError, "artifact name prefix and extension must be safe path fragments"
    end

    ([prefix] ++ Enum.map(identities, &slug/1) ++ [timestamp_slug(), allocation_token()])
    |> Enum.join("-")
    |> Kernel.<>(extension)
  end

  @doc false
  def run_name(prefix, identities) when is_binary(prefix) and is_list(identities) do
    artifact_name(prefix, identities, "")
  end

  @doc false
  def timestamp_slug do
    DateTime.utc_now()
    |> DateTime.to_iso8601()
    |> String.replace(~r/[^0-9A-Za-z]/, "")
  end

  defp publish_exclusively!(path, payload) do
    assert_physical_parent!(path)
    temporary = write_temporary!(path, payload)

    try do
      allocate_link!(temporary, path)
    after
      File.rm(temporary)
    end
  end

  defp write_temporary!(path, payload) do
    temporary = path <> ".tmp-#{allocation_token()}"

    case File.write(temporary, payload, [:binary, :exclusive, :sync]) do
      :ok -> temporary
      {:error, :eexist} -> write_temporary!(path, payload)
      {:error, reason} -> raise_file_error!("write temporary artifact", temporary, reason)
    end
  end

  defp allocate_link!(temporary, preferred_path) do
    assert_physical_parent!(preferred_path)

    case File.ln(temporary, preferred_path) do
      :ok ->
        preferred_path

      {:error, :eexist} ->
        allocate_link!(temporary, collision_path(preferred_path))

      {:error, reason} ->
        raise_file_error!("publish artifact", preferred_path, reason)
    end
  end

  defp collision_path(path) do
    extension = Path.extname(path)
    "#{Path.rootname(path)}--#{allocation_token()}#{extension}"
  end

  defp assert_physical_parent!(path) do
    parent = Path.dirname(path)
    canonical_parent = Paths.canonical_path!(parent)

    unless canonical_parent == parent and File.dir?(canonical_parent) do
      raise ArgumentError,
            "benchmark artifact parent changed canonical identity during allocation: #{parent}"
    end
  end

  defp allocation_token do
    8
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end

  defp raise_file_error!(action, path, reason) do
    raise File.Error, action: action, path: path, reason: reason
  end

  def write_run_json!(path, artifact, %Imp.BenchmarkTruth.RunContext{} = context) do
    artifact = Imp.BenchmarkTruth.RunContext.finish(context, artifact)
    %{artifact: artifact, path: write_json!(path, artifact)}
  end

  def read_run_json!(path) do
    path
    |> File.read!()
    |> Jason.decode!()
    |> Imp.BenchmarkTruth.RunContext.verify!()
  end
end
