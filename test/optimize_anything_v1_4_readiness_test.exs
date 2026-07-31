defmodule Imp.BenchmarkTruth.OptimizeAnything.V14ReadinessTest do
  use ExUnit.Case, async: false

  alias Imp.BenchmarkTruth.OptimizeAnything.V14Readiness

  @authority_root Path.expand("tmp/optimize-anything-upstream")

  unless File.dir?(@authority_root) do
    @moduletag skip: "clone gepa-ai/optimize-anything-artifact v1.4 into tmp to run this gate"
  end

  test "released warm Circle state becomes a schema-3 value artifact and replays fresh" do
    root = temporary_path("circle-v14")
    artifact_path = Path.join(root, "selected.json")
    receipt_path = Path.join(root, "fresh.json")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    replay = V14Readiness.circle_retained_state!()

    assert_in_delta replay.seed.score, 0.9797642169962063, 1.0e-12
    assert_in_delta replay.retained.score, 2.635983362593453, 1.0e-12
    assert replay.result.total_metric_calls == 133
    assert length(replay.result.history) == 133
    assert replay.result.checkpoint["source_state_kind"] == "warm-resumed-retained-state"

    assert %{
             schema_version: 3,
             champion_id: "candidate-0001",
             candidates: [
               %{"id" => "candidate-0000", "kind" => "value"},
               %{"id" => "candidate-0001", "kind" => "value", "report" => report}
             ]
           } = Imp.Optimizer.Artifact.inspect(replay.artifact)

    assert report["total_metric_calls"] == 133
    :ok = Imp.Optimizer.Artifact.write!(replay.artifact, artifact_path)

    code = """
    artifact = Imp.Optimizer.Artifact.read!(#{inspect(artifact_path)})
    value = Imp.Optimizer.Artifact.value(artifact)
    evaluation = Imp.BenchmarkTruth.OptimizeAnything.V14Readiness.evaluate_circle_value!(value)
    File.write!(#{inspect(receipt_path)}, Jason.encode!(evaluation))
    """

    assert {"", 0} =
             System.cmd("mix", ["run", "--no-compile", "--no-deps-check", "-e", code],
               cd: File.cwd!(),
               env: [
                 {"MIX_ENV", "test"},
                 {"OPENAI_API_KEY", ""},
                 {"ANTHROPIC_API_KEY", ""}
               ],
               stderr_to_stdout: true
             )

    fresh = receipt_path |> File.read!() |> Jason.decode!()
    assert_in_delta fresh["score"], replay.retained.score, 1.0e-12
    assert fresh["circle_count"] == 26
    assert fresh["overlaps"] == []
    assert fresh["boundary_violations"] == []
    assert fresh["code_sha256"] == replay.retained.code_sha256
    assert fresh["incumbent_sha256"] == replay.retained.incumbent_sha256
    assert fresh["refiner_prompt_sha256"] == replay.retained.refiner_prompt_sha256
  end

  test "released gskill evidence fails exact-reproduction readiness closed" do
    assert {:error, audit} = V14Readiness.gskill_release_readiness()

    assert audit.reason == "released gskill evidence cannot support exact artifact reproduction"

    assert audit.observed["opportunity"]["blevesearch__bleve"] == %{
             "requested_metric_calls" => 300,
             "completed_metric_calls" => 300,
             "proposer" => "loop",
             "resumed" => true
           }

    assert audit.observed["opportunity"]["pallets__jinja"] == %{
             "requested_metric_calls" => 300,
             "completed_metric_calls" => 307,
             "proposer" => "batch",
             "resumed" => false
           }

    assert audit.observed["default_600_call_protocol"] == "pygments__pygments"
    assert audit.observed["five_seed_status"] =~ "new robustness design"
    assert "dataset.revision" in audit.missing
    assert "splits.train.ordered_task_ids[200]" in audit.missing
    assert "repositories.blevesearch__bleve.base_commit" in audit.missing
    assert "docker_image_digests" in audit.missing
    assert "platform.architecture" in audit.missing
  end

  test "a future current-source gskill identity must pin every split and environment" do
    identity = complete_gskill_identity()
    assert {:ok, ^identity} = V14Readiness.audit_gskill_identity(identity)

    incomplete = put_in(identity, ["splits", "test", "ordered_task_hashes"], [])

    assert {:error, missing} = V14Readiness.audit_gskill_identity(incomplete)
    assert missing == ["splits.test.ordered_task_hashes[100]"]
  end

  defp complete_gskill_identity do
    %{
      "dataset" => %{"revision" => "dataset-commit", "file_hashes" => %{"train" => "sha256"}},
      "splits" => %{
        "train" => split(200),
        "selection" => split(50),
        "test" => split(100)
      },
      "repositories" => %{
        "blevesearch__bleve" => %{
          "repository" => "https://github.com/blevesearch/bleve",
          "repository_commit" => "repository-commit",
          "base_commit" => "base-commit"
        },
        "pallets__jinja" => %{
          "repository" => "https://github.com/pallets/jinja",
          "repository_commit" => "repository-commit",
          "base_commit" => "base-commit"
        }
      },
      "docker_image_digests" => %{"task" => "sha256:image"},
      "dependency_locks" => %{"python" => "sha256:lock"},
      "platform" => %{"os" => "linux", "architecture" => "amd64"},
      "models" => %{"task" => "gpt-5-mini", "reflection" => "gpt-5.2-pro"},
      "seed" => 42,
      "opportunity" => %{
        "blevesearch__bleve" => %{
          "requested_metric_calls" => 300,
          "completed_metric_calls" => 300,
          "proposer" => "loop"
        },
        "pallets__jinja" => %{
          "requested_metric_calls" => 300,
          "completed_metric_calls" => 307,
          "proposer" => "batch"
        }
      }
    }
  end

  defp split(size) do
    %{
      "ordered_task_ids" => Enum.map(1..size, &"task-#{&1}"),
      "ordered_task_hashes" => Enum.map(1..size, &"sha256:#{&1}")
    }
  end

  defp temporary_path(name) do
    Path.join(
      System.tmp_dir!(),
      "imp-oa-v14-#{System.unique_integer([:positive, :monotonic])}-#{name}"
    )
  end
end
