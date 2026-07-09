defmodule GepaDatasetExportTest do
  use ExUnit.Case

  test "GEPA dataset exporter writes campaign dataset root from upstream-shaped package" do
    gepa_root = tmp_dir("gepa-export-source")
    out = tmp_dir("gepa-export-out")
    write_fake_gepa_package!(gepa_root)

    {output, 0} =
      System.cmd("python3", [
        "scripts/gepa_export_dataset_root.py",
        "--gepa-root",
        gepa_root,
        "--out",
        out,
        "--max-per-split",
        "1"
      ])

    assert normalize_tmp_path(String.trim(output)) == normalize_tmp_path(out)

    families = Path.join(out, "families.json") |> File.read!() |> Jason.decode!()
    assert families["runner"] == "gepa_export_dataset_root.py"
    assert length(families["families"]) == 6

    assert Enum.all?(families["families"], fn spec ->
             family = spec["family"]

             File.exists?(Path.join([out, family, "train.jsonl"])) and
               File.exists?(Path.join([out, family, "dev.jsonl"])) and
               File.exists?(Path.join([out, family, "test.jsonl"])) and
               spec["split_counts"] == %{"dev" => 1, "test" => 1, "train" => 1} and
               spec["split_checksums"]["train"] =~ "sha256:"
           end)
  end

  defp write_fake_gepa_package!(root) do
    File.mkdir_p!(Path.join(root, "gepa_artifact/benchmarks"))
    File.write!(Path.join(root, "gepa_artifact/__init__.py"), "")
    File.write!(Path.join(root, "gepa_artifact/benchmarks/__init__.py"), "")

    write_benchmark_base!(root)

    Enum.each(families(), fn {family, class_name} ->
      dir = Path.join(root, "gepa_artifact/benchmarks/#{family}")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "__init__.py"), benchmark_module(class_name))
    end)
  end

  defp write_benchmark_base!(root) do
    File.write!(
      Path.join(root, "gepa_artifact/benchmarks/benchmark.py"),
      """
      class BenchmarkMeta:
          def __init__(self, benchmark, program, metric, dataset_mode=None, num_threads=None, name=None, metric_with_feedback=None, feedback_fn_maps=None):
              self.benchmark = benchmark
              self.program = program
              self.metric = metric
              self.dataset_mode = dataset_mode
              self.num_threads = num_threads
              self.name = name
              self.metric_with_feedback = metric_with_feedback
              self.feedback_fn_maps = feedback_fn_maps
      """
    )
  end

  defp benchmark_module(class_name) do
    """
    from gepa_artifact.benchmarks.benchmark import BenchmarkMeta

    class Example(dict):
        def toDict(self):
            return dict(self)

    class #{class_name}:
        def __init__(self, dataset_mode=None):
            self.train_set = [Example(question="train", problem="train", claim="train", prompt="train", user_query="train", answer="gold", label="gold", response="gold", target_response="gold")]
            self.val_set = [Example(question="dev", problem="dev", claim="dev", prompt="dev", user_query="dev", answer="gold", label="gold", response="gold", target_response="gold")]
            self.test_set = [Example(question="test", problem="test", claim="test", prompt="test", user_query="test", answer="gold", label="gold", response="gold", target_response="gold")]

    def metric(example, prediction, trace=None):
        return 1

    benchmark = [BenchmarkMeta(#{class_name}, [object()], metric)]
    """
  end

  defp families do
    [
      {"AIME", "AIMEBench"},
      {"hotpotQA", "HotpotQABench"},
      {"hover", "hoverBench"},
      {"IFBench", "IFBench"},
      {"livebench_math", "LiveBenchMathBench"},
      {"papillon", "Papillon"}
    ]
  end

  defp tmp_dir(name) do
    path = Path.join(System.tmp_dir!(), "dsex-#{name}-#{System.unique_integer([:positive])}")
    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end

  defp normalize_tmp_path(path), do: String.replace_prefix(path, "/private/var/", "/var/")
end
