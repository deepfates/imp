defmodule DSEx.BenchmarkTruth.ArtifactFile do
  @moduledoc false

  def write_json!(path, artifact) do
    path = available_path(path)
    temporary = path <> ".tmp-#{System.unique_integer([:positive])}"

    try do
      File.write!(temporary, Jason.encode!(artifact, pretty: true) <> "\n", [:sync])
      File.rename!(temporary, path)
      path
    after
      File.rm(temporary)
    end
  end

  defp available_path(path) do
    if File.exists?(path) do
      extension = Path.extname(path)
      stem = String.trim_trailing(path, extension)
      available_path("#{stem}-#{System.unique_integer([:positive])}#{extension}")
    else
      path
    end
  end
end
