defmodule BenchmarkArtifactFileTest do
  use ExUnit.Case, async: true

  test "writes complete JSON atomically without overwriting an existing artifact" do
    root =
      Path.join(System.tmp_dir!(), "dsex-artifact-file-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    path = Path.join(root, "artifact.json")

    first = DSEx.BenchmarkTruth.ArtifactFile.write_json!(path, %{"value" => 1})
    second = DSEx.BenchmarkTruth.ArtifactFile.write_json!(path, %{"value" => 2})

    assert first != second
    assert first |> File.read!() |> Jason.decode!() == %{"value" => 1}
    assert second |> File.read!() |> Jason.decode!() == %{"value" => 2}
    assert Path.wildcard(Path.join(root, "*.tmp-*")) == []
  end
end
