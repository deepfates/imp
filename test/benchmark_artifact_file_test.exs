defmodule BenchmarkArtifactFileTest do
  use ExUnit.Case, async: true

  test "writes complete JSON atomically without overwriting an existing artifact" do
    root =
      Path.join(System.tmp_dir!(), "imp-artifact-file-#{System.unique_integer([:positive])}")

    prepare_root!(root)
    path = Path.join(root, "artifact.json")

    first = Imp.BenchmarkTruth.ArtifactFile.write_json!(path, %{"value" => 1})
    second = Imp.BenchmarkTruth.ArtifactFile.write_json!(path, %{"value" => 2})

    assert first != second
    assert first |> File.read!() |> Jason.decode!() == %{"value" => 1}
    assert second |> File.read!() |> Jason.decode!() == %{"value" => 2}
    assert Path.wildcard(Path.join(root, "*.tmp-*")) == []
  end

  test "concurrent writers reserve unique complete artifacts without overwrites" do
    root =
      Path.join(System.tmp_dir!(), "imp-artifact-race-#{System.unique_integer([:positive])}")

    prepare_root!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    path = Path.join(root, "artifact.json")

    results =
      1..32
      |> Task.async_stream(
        fn value ->
          written = Imp.BenchmarkTruth.ArtifactFile.write_json!(path, %{"value" => value})
          {written, value}
        end,
        max_concurrency: 32,
        ordered: false,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    paths = Enum.map(results, &elem(&1, 0))
    assert length(Enum.uniq(paths)) == 32

    Enum.each(results, fn {written, value} ->
      assert written |> File.read!() |> Jason.decode!() == %{"value" => value}
    end)

    assert Path.wildcard(Path.join(root, "*.tmp-*")) == []
  end

  test "readable identity slugs retain a digest and cannot collapse distinct names" do
    alias Imp.BenchmarkTruth.ArtifactFile

    slash = ArtifactFile.slug("a/b")
    question = ArtifactFile.slug("a?b")

    assert slash =~ ~r/\Aa_b--[0-9a-f]{12}\z/
    assert question =~ ~r/\Aa_b--[0-9a-f]{12}\z/
    refute slash == question

    first = ArtifactFile.artifact_name("parity", ["a/b"])
    second = ArtifactFile.artifact_name("parity", ["a/b"])
    refute first == second
    assert String.starts_with?(first, "parity-#{slash}-")
  end

  test "writes through a symlinked root but rejects nested, future, and final symlink escapes" do
    alias Imp.BenchmarkTruth.{ArtifactFile, Paths}

    container =
      Path.join(System.tmp_dir!(), "imp-artifact-links-#{System.unique_integer([:positive])}")

    physical_root = Path.join(container, "physical")
    linked_root = Path.join(container, "linked")
    outside = Path.join(container, "outside")

    File.mkdir_p!(physical_root)
    File.mkdir_p!(outside)
    File.ln_s!(physical_root, linked_root)
    on_exit(fn -> File.rm_rf!(container) end)

    written = ArtifactFile.write_json_in!(linked_root, "nested/artifact.json", %{"safe" => true})
    assert String.starts_with?(written, linked_root)

    assert written |> Paths.canonical_path!() |> File.read!() |> Jason.decode!() == %{
             "safe" => true
           }

    File.ln_s!(outside, Path.join(physical_root, "escape"))

    assert_raise ArgumentError, ~r/escapes its canonical root/, fn ->
      ArtifactFile.write_json_in!(physical_root, "escape/artifact.json", %{"safe" => false})
    end

    future = Path.join(physical_root, "future")
    _identity_before_creation = Paths.canonical_path!(Path.join(future, "artifact.json"))
    File.ln_s!(outside, future)

    assert_raise ArgumentError, ~r/escapes its canonical root/, fn ->
      ArtifactFile.write_json_in!(physical_root, "future/artifact.json", %{"safe" => false})
    end

    victim = Path.join(outside, "victim.json")
    File.write!(victim, "untouched")
    File.ln_s!(victim, Path.join(physical_root, "artifact.json"))

    assert_raise ArgumentError, ~r/symlink/, fn ->
      ArtifactFile.write_json_in!(physical_root, "artifact.json", %{"safe" => false})
    end

    assert File.read!(victim) == "untouched"
  end

  test "enveloped writes use the run's captured source identity" do
    root =
      Path.join(System.tmp_dir!(), "imp-run-artifact-#{System.unique_integer([:positive])}")

    prepare_root!(root)
    path = Path.join(root, "artifact.json")
    timestamp = ~U[2026-07-13 18:00:00Z]

    context =
      Imp.BenchmarkTruth.RunContext.new!(
        source_commits: %{
          "imp" => "deepfates/imp@abc1234",
          "upstream" => "example/upstream@def5678"
        },
        clock: fn -> timestamp end
      )

    %{artifact: artifact, path: ^path} =
      Imp.BenchmarkTruth.ArtifactFile.write_run_json!(path, %{"value" => 1}, context)

    assert artifact["git_sha"] == "abc1234"
    assert artifact["generated_at"] == "2026-07-13T18:00:00Z"
    assert get_in(artifact, ["run_context", "started_at"]) == "2026-07-13T18:00:00Z"

    assert get_in(artifact, ["run_context", "code", "identity"]) ==
             "deepfates/imp@abc1234"

    assert get_in(artifact, ["run_context", "workspace"]) == %{
             "state" => "synthetic",
             "reproducible" => false
           }

    assert get_in(artifact, ["run_context", "payload_sha256"]) =~ "sha256:"
    assert get_in(artifact, ["run_context", "schema_version"]) == 2
    assert get_in(artifact, ["run_context", "environment", "kind"]) == "synthetic"
    assert get_in(artifact, ["run_context", "environment", "fingerprint"]) =~ "sha256:"
    assert get_in(artifact, ["run_context", "inputs"]) == %{}
    assert get_in(artifact, ["run_context", "envelope_sha256"]) =~ "sha256:"

    assert File.read!(path) |> Jason.decode!() == artifact
    assert Imp.BenchmarkTruth.ArtifactFile.read_run_json!(path) == artifact
  end

  test "verified reads reject payload tampering" do
    root =
      Path.join(System.tmp_dir!(), "imp-tampered-artifact-#{System.unique_integer([:positive])}")

    prepare_root!(root)
    path = Path.join(root, "artifact.json")

    context =
      Imp.BenchmarkTruth.RunContext.new!(source_commits: %{"imp" => "deepfates/imp@abc1234"})

    %{artifact: artifact} =
      Imp.BenchmarkTruth.ArtifactFile.write_run_json!(path, %{"value" => 1}, context)

    File.write!(path, Jason.encode!(Map.put(artifact, "value", 2)))

    assert_raise ArgumentError, ~r/invalid or tampered/, fn ->
      Imp.BenchmarkTruth.ArtifactFile.read_run_json!(path)
    end
  end

  test "run envelopes replace producer timestamps and revisions before hashing" do
    context =
      Imp.BenchmarkTruth.RunContext.new!(
        source_commits: %{"imp" => "deepfates/imp@canonical-revision"},
        clock: fn -> ~U[2026-07-15 12:00:00Z] end
      )

    artifact =
      Imp.BenchmarkTruth.RunContext.finish(context, %{
        "value" => 1,
        "generated_at" => "2000-01-01T00:00:00Z",
        "git_sha" => "stale-revision",
        "run_context" => %{"stale" => true}
      })

    assert artifact["generated_at"] == "2026-07-15T12:00:00Z"
    assert artifact["git_sha"] == "canonical-revision"
    assert Imp.BenchmarkTruth.RunContext.verify!(artifact) == artifact
  end

  test "run context rejects source identities without immutable revisions" do
    assert_raise ArgumentError, ~r/must end with an immutable identity/, fn ->
      Imp.BenchmarkTruth.RunContext.new!(source_commits: %{"imp" => "deepfates/imp"})
    end
  end

  test "captured environments bind the BEAM runtime and exact dependency lock" do
    environment = Imp.BenchmarkTruth.RunContext.capture_environment!()

    assert environment["kind"] == "beam"
    assert environment["runtime"]["elixir"] == System.version()
    assert environment["runtime"]["otp_release"] == System.otp_release()
    assert environment["dependencies"]["mix_exs_sha256"] =~ "sha256:"
    assert environment["dependencies"]["mix_lock_sha256"] =~ "sha256:"
    assert Enum.any?(environment["dependencies"]["resolved"], &(&1["app"] == "jason"))
    assert environment["fingerprint"] =~ "sha256:"
  end

  test "verified reads reject environment-fingerprint tampering" do
    context =
      Imp.BenchmarkTruth.RunContext.new!(
        source_commits: %{"imp" => "deepfates/imp@abc1234"},
        environment: %{"kind" => "fixture", "runtime" => %{"otp" => "28"}}
      )

    artifact = Imp.BenchmarkTruth.RunContext.finish(context, %{"value" => 1})
    tampered = put_in(artifact, ["run_context", "environment", "runtime", "otp"], "27")

    assert_raise ArgumentError, ~r/invalid or tampered/, fn ->
      Imp.BenchmarkTruth.RunContext.verify!(tampered)
    end
  end

  test "verified reads reject protocol-input and source-envelope tampering" do
    context =
      Imp.BenchmarkTruth.RunContext.new!(
        source_commits: %{"imp" => "deepfates/imp@abc1234"},
        inputs: %{"manifest_sha256" => "sha256:fixture"}
      )

    artifact = Imp.BenchmarkTruth.RunContext.finish(context, %{"value" => 1})

    for tampered <- [
          put_in(artifact, ["run_context", "inputs", "manifest_sha256"], "sha256:forged"),
          put_in(artifact, ["run_context", "source_commits", "imp"], "deepfates/imp@forged")
        ] do
      assert_raise ArgumentError, ~r/invalid or tampered/, fn ->
        Imp.BenchmarkTruth.RunContext.verify!(tampered)
      end
    end
  end

  test "legacy envelopes remain readable but must retain their complete bound shape" do
    context =
      Imp.BenchmarkTruth.RunContext.new!(source_commits: %{"imp" => "deepfates/imp@abc1234"})

    artifact = Imp.BenchmarkTruth.RunContext.finish(context, %{"value" => 1})
    run_context = artifact["run_context"]

    legacy_context =
      run_context
      |> Map.put("schema_version", 1)
      |> Map.drop(["environment", "inputs", "envelope_sha256"])

    legacy = Map.put(artifact, "run_context", legacy_context)
    assert Imp.BenchmarkTruth.RunContext.verify!(legacy) == legacy

    forged =
      put_in(legacy, ["run_context"], %{
        "schema_version" => 1,
        "completed_at" => legacy["generated_at"],
        "payload_sha256" => legacy_context["payload_sha256"],
        "code" => %{"revision" => legacy["git_sha"]}
      })

    assert_raise ArgumentError, ~r/invalid or tampered/, fn ->
      Imp.BenchmarkTruth.RunContext.verify!(forged)
    end
  end

  defp prepare_root!(root) do
    File.rm_rf!(root)
    File.mkdir_p!(root)
  end
end
