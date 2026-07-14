defmodule BenchmarkArtifactFileTest do
  use ExUnit.Case, async: true

  test "writes complete JSON atomically without overwriting an existing artifact" do
    root =
      Path.join(System.tmp_dir!(), "dsex-artifact-file-#{System.unique_integer([:positive])}")

    prepare_root!(root)
    path = Path.join(root, "artifact.json")

    first = DSEx.BenchmarkTruth.ArtifactFile.write_json!(path, %{"value" => 1})
    second = DSEx.BenchmarkTruth.ArtifactFile.write_json!(path, %{"value" => 2})

    assert first != second
    assert first |> File.read!() |> Jason.decode!() == %{"value" => 1}
    assert second |> File.read!() |> Jason.decode!() == %{"value" => 2}
    assert Path.wildcard(Path.join(root, "*.tmp-*")) == []
  end

  test "enveloped writes use the run's captured source identity" do
    root =
      Path.join(System.tmp_dir!(), "dsex-run-artifact-#{System.unique_integer([:positive])}")

    prepare_root!(root)
    path = Path.join(root, "artifact.json")
    timestamp = ~U[2026-07-13 18:00:00Z]

    context =
      DSEx.BenchmarkTruth.RunContext.new!(
        source_commits: %{
          "dsex" => "deepfates/dsex@abc1234",
          "upstream" => "example/upstream@def5678"
        },
        clock: fn -> timestamp end
      )

    %{artifact: artifact, path: ^path} =
      DSEx.BenchmarkTruth.ArtifactFile.write_run_json!(path, %{"value" => 1}, context)

    assert artifact["git_sha"] == "abc1234"
    assert artifact["generated_at"] == "2026-07-13T18:00:00Z"
    assert get_in(artifact, ["run_context", "started_at"]) == "2026-07-13T18:00:00Z"

    assert get_in(artifact, ["run_context", "code", "identity"]) ==
             "deepfates/dsex@abc1234"

    assert get_in(artifact, ["run_context", "workspace"]) == %{
             "state" => "synthetic",
             "reproducible" => false
           }

    assert get_in(artifact, ["run_context", "payload_sha256"]) =~ "sha256:"

    assert File.read!(path) |> Jason.decode!() == artifact
    assert DSEx.BenchmarkTruth.ArtifactFile.read_run_json!(path) == artifact
  end

  test "verified reads reject payload tampering" do
    root =
      Path.join(System.tmp_dir!(), "dsex-tampered-artifact-#{System.unique_integer([:positive])}")

    prepare_root!(root)
    path = Path.join(root, "artifact.json")

    context =
      DSEx.BenchmarkTruth.RunContext.new!(source_commits: %{"dsex" => "deepfates/dsex@abc1234"})

    %{artifact: artifact} =
      DSEx.BenchmarkTruth.ArtifactFile.write_run_json!(path, %{"value" => 1}, context)

    File.write!(path, Jason.encode!(Map.put(artifact, "value", 2)))

    assert_raise ArgumentError, ~r/invalid or tampered/, fn ->
      DSEx.BenchmarkTruth.ArtifactFile.read_run_json!(path)
    end
  end

  test "run context rejects source identities without immutable revisions" do
    assert_raise ArgumentError, ~r/must end with an immutable identity/, fn ->
      DSEx.BenchmarkTruth.RunContext.new!(source_commits: %{"dsex" => "deepfates/dsex"})
    end
  end

  defp prepare_root!(root) do
    File.rm_rf!(root)
    File.mkdir_p!(root)
  end
end
