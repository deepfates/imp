defmodule GepaDatasetExportTest do
  use ExUnit.Case

  test "family selector isolates hoverBench without importing other families" do
    script = Path.expand("scripts/gepa_export_dataset_root.py")

    python = """
    import importlib.util, json
    spec = importlib.util.spec_from_file_location("gepa_export", #{inspect(script)})
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    print(json.dumps(list(module.selected_family_specs("hoverBench").keys())))
    """

    assert {"[\"hoverBench\"]\n", 0} = System.cmd("python3", ["-c", python])
  end

  test "authenticated hoverBench export refuses a missing raw-source checkout before imports" do
    gepa_root = tmp_dir("gepa-export-hover-source")
    out = tmp_dir("gepa-export-hover-out")
    write_fake_gepa_package!(gepa_root)
    initialize_source_repo!(gepa_root)

    {output, status} =
      System.cmd(
        "python3",
        [
          "scripts/gepa_export_dataset_root.py",
          "--gepa-root",
          gepa_root,
          "--out",
          out,
          "--family",
          "hoverBench"
        ],
        stderr_to_stdout: true
      )

    assert status != 0
    assert output =~ "authenticated hoverBench export requires --hover-source-root"
    refute File.exists?(Path.join(out, "hoverBench/train.jsonl"))
  end

  @tag :evidence_infrastructure
  test "authenticated HoVer export removes the released cross-split content duplicate without scores" do
    material = Path.expand("tmp/hover-materialization-v1")
    out = tmp_dir("hover-identity-disjoint")

    {output, 0} =
      System.cmd(
        Path.join(material, ".venv/bin/python"),
        [
          "scripts/gepa_export_dataset_root.py",
          "--gepa-root",
          "tmp/gepa-artifact",
          "--out",
          out,
          "--family",
          "hoverBench",
          "--hover-source-root",
          Path.join(material, "hover-source"),
          "--hover-identity-disjoint"
        ],
        env: [{"HF_HOME", Path.join(material, "hf-home")}],
        stderr_to_stdout: true
      )

    assert output =~ out
    family = out |> Path.join("families.json") |> File.read!() |> Jason.decode!()
    [hover] = family["families"]

    assert hover["split_checksums"] == %{
             "train" => "sha256:448048cc80de7982b344ef3c8767816164eeabe3d2a1ad4f776245e3dff39370",
             "dev" => "sha256:052fdda83d8e7fff83c7f4db67cd1a2a8cb66047e6cd68ecfe14310dcbf93602",
             "test" => "sha256:cf1b51ca6ed32c21355a954624d88b396d3e963585549cea68308b519c5a8807"
           }

    assert get_in(hover, ["split_lineage", "skipped", "dev"]) == [
             %{
               "content_sha256" =>
                 "ef899c595acd9714480791fe7d15e929dab4799308e0c67bab5756a16a141c17",
               "released_position" => 57
             }
           ]

    assert get_in(hover, ["split_lineage", "replacements", "dev"]) == [
             %{
               "content_sha256" =>
                 "00213c2cde2b65017097d21be6a77fe2a46ba6f053227a677b148130da1e2e5c",
               "source_pool_position" => 1_101
             }
           ]
  end

  test "GEPA dataset exporter writes campaign dataset root from upstream-shaped package" do
    gepa_root = tmp_dir("gepa-export-source")
    out = tmp_dir("gepa-export-out")
    write_fake_gepa_package!(gepa_root)
    initialize_source_repo!(gepa_root)

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
    assert families["schema_version"] == 2
    assert families["runner"] == "gepa_export_dataset_root.py"
    assert families["dataset_scope"] == "capped"
    assert families["max_per_split"] == 1
    assert families["upstream_source"]["repository"] == "https://github.com/gepa-ai/gepa-artifact"
    assert families["upstream_source"]["commit"] =~ ~r/^[0-9a-f]{40}$/
    assert families["upstream_source"]["tree"] =~ ~r/^[0-9a-f]{40}$/
    refute Map.has_key?(families, "gepa_root")

    assert families["dataset_aliases"] == %{
             "hotpot_qa" => "hotpotqa/hotpot_qa",
             "hover" => "hover-nlp/hover"
           }

    assert length(families["families"]) == 6

    assert Enum.all?(families["families"], fn spec ->
             family = spec["family"]

             File.exists?(Path.join([out, family, "train.jsonl"])) and
               File.exists?(Path.join([out, family, "dev.jsonl"])) and
               File.exists?(Path.join([out, family, "test.jsonl"])) and
               spec["dataset_scope"] == "capped" and
               spec["max_per_split"] == 1 and
               spec["split_counts"] == %{"dev" => 1, "test" => 1, "train" => 1} and
               spec["dataset_source"] =~
                 ~r"^https://github.com/gepa-ai/gepa-artifact@[0-9a-f]{40}$" and
               not String.contains?(spec["dataset_source"], gepa_root) and
               spec["split_checksums"]["train"] =~ "sha256:"
           end)

    papillon = Enum.find(families["families"], &(&1["family"] == "Papillon"))
    assert papillon["signature"] == "user_query -> llm_request, response"
    assert papillon["output_key"] == "response"

    assert papillon["dataset_authorities"] == [
             %{
               "kind" => "huggingface_dataset",
               "repository" => "Columbia-NLP/PUPA",
               "revision" => "9981b49b6ced0033988a224b6712895ebf119294"
             }
           ]

    aime = Enum.find(families["families"], &(&1["family"] == "AIMEBench"))

    assert Enum.map(aime["dataset_authorities"], &{&1["repository"], &1["revision"]}) == [
             {"AI-MO/aimo-validation-aime", "13f9e12f613e720c2a2b2f345dd04b998a29494d"},
             {"MathArena/aime_2025", "c94da77eb22bbd6439e62a323bec18493a421302"}
           ]

    hotpot = Enum.find(families["families"], &(&1["family"] == "HotpotQABench"))
    assert hotpot["retrieval"]["kind"] == "bm25s_wiki_abstracts_2017"
    assert hotpot["retrieval"]["corpus_checksum"] =~ "sha256:"

    assert hotpot["retrieval"]["corpus_path"] ==
             "gepa_artifact/benchmarks/hover/wiki.abstracts.2017.jsonl"

    assert hotpot["retrieval"]["index_path"] ==
             "gepa_artifact/benchmarks/hover/bm25s_retriever"

    refute inspect(families) =~ gepa_root

    assert hotpot["retrieval"] ==
             Enum.find(families["families"], &(&1["family"] == "hoverBench"))["retrieval"]

    hover = Enum.find(families["families"], &(&1["family"] == "hoverBench"))
    assert hover["signature"] == "claim -> retrieved_docs"
    assert hover["output_key"] == "retrieved_docs"
    assert hover["upstream_metric"] == "hover_utils.discrete_retrieval_eval"
    assert hover["retrieval"]["kind"] == "bm25s_wiki_abstracts_2017"
    assert hover["retrieval"]["status"] == "present"
    assert hover["retrieval"]["corpus_checksum"] =~ "sha256:"
    assert hover["retrieval"]["index_checksum"] =~ "sha256:"

    ifbench = Enum.find(families["families"], &(&1["family"] == "IFBench"))
    assert length(ifbench["dataset_authorities"]) == 2

    assert Enum.all?(ifbench["dataset_authorities"], fn authority ->
             authority["kind"] == "embedded_upstream_file" and
               authority["repository"] == "https://github.com/gepa-ai/gepa-artifact" and
               authority["revision"] =~ ~r/^[0-9a-f]{40}$/ and
               authority["path"] =~ ~r{^gepa_artifact/} and
               authority["sha256"] =~ ~r/^[0-9a-f]{64}$/
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

      if family == "hover" do
        File.write!(
          Path.join(dir, "wiki.abstracts.2017.jsonl"),
          ~s({"title":"gold","text":["supporting document"]}\n)
        )

        index_dir = Path.join(dir, "bm25s_retriever")
        File.mkdir_p!(index_dir)
        File.write!(Path.join(index_dir, "params.json"), ~s({"k1":0.9,"b":0.4}\n))
      end

      if family == "IFBench" do
        data_dir = Path.join(dir, "data")
        File.mkdir_p!(data_dir)
        File.write!(Path.join(data_dir, "IFBench_train.jsonl"), ~s({"prompt":"train"}\n))
        File.write!(Path.join(data_dir, "IFBench_test.jsonl"), ~s({"prompt":"test"}\n))
      end
    end)
  end

  defp initialize_source_repo!(root) do
    commands = [
      ["init", "--quiet"],
      ["config", "user.email", "authority-test@example.invalid"],
      ["config", "user.name", "Authority Test"],
      ["remote", "add", "origin", "git@github.com:gepa-ai/gepa-artifact.git"],
      ["add", "."],
      ["commit", "--quiet", "-m", "fixture"]
    ]

    Enum.each(commands, fn args ->
      assert {_output, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
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
    path = Path.join(System.tmp_dir!(), "imp-#{name}-#{System.unique_integer([:positive])}")
    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end

  defp normalize_tmp_path(path), do: String.replace_prefix(path, "/private/var/", "/var/")
end
