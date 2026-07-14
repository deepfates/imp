defmodule GepaCampaignManifestTest do
  use ExUnit.Case, async: false

  alias DSEx.BenchmarkTruth.GepaCampaignManifest
  alias Mix.Tasks.Dsex.Benchmark.GepaCampaign, as: Task

  @manifest "benchmarks/config/gepa-paper-campaign-v1.json"

  test "loads the canonical manifest and resolves pinned paths" do
    manifest = GepaCampaignManifest.load!(@manifest)
    opts = GepaCampaignManifest.task_options!(manifest, manifest: @manifest)

    assert manifest["families"] ==
             DSEx.BenchmarkTruth.GepaReplicationContract.required_families()

    assert opts.generations == :metric_budget
    assert opts.seeds == [0, 1]
    assert opts.max_concurrency == 32
    assert opts.max_retries == 0
    assert opts.reflection_model == opts.model
    assert opts.judge_model == opts.model
    assert opts.dataset_root == Path.expand("benchmarks/data/gepa-campaign-full")
    assert opts.out == Path.expand("benchmarks/results")
    assert opts.manifest_identity["path"] == @manifest
    assert opts.manifest_identity["sha256"] == manifest["manifest_sha256"]
  end

  test "rejects every CLI override in manifest mode" do
    manifest = GepaCampaignManifest.load!(@manifest)

    assert_raise ArgumentError, ~r/cannot be combined.*--families/, fn ->
      GepaCampaignManifest.task_options!(manifest,
        manifest: @manifest,
        families: "AIMEBench"
      )
    end
  end

  test "task surfaces manifest override rejection as a Mix error" do
    assert_raise Mix.Error, ~r/cannot be combined.*--max-concurrency/, fn ->
      Task.resolve_manifest_options!(manifest: @manifest, max_concurrency: 1)
    end
  end

  test "manifest rejects an undeclared shard selector before execution" do
    assert_raise Mix.Error, ~r/unknown GEPA campaign shard selector/, fn ->
      Task.resolve_manifest_options!(manifest: @manifest, shard: "family:NotDeclared")
    end
  end

  test "task resolves typed manifest families and seeds without CSV coercion" do
    opts = Task.resolve_manifest_options!(manifest: @manifest)

    assert opts[:families] ==
             DSEx.BenchmarkTruth.GepaReplicationContract.required_families()

    assert opts[:seeds] == [0, 1]

    assert opts[:dspy_source] ==
             "gepa-ai/dspy@62dc3b634d7dc0c4889abcf905cb4c391ea6b396"
  end

  test "canonical manifest environment fails closed and accepts exact upstream bindings" do
    opts = Task.resolve_manifest_options!(manifest: @manifest)

    names =
      ~w(DSEX_HOVER_UPSTREAM_BM25 DSEX_IFBENCH_UPSTREAM_DESCRIPTIONS DSEX_GEPA_PYTHON DSEX_GEPA_ROOT)

    previous = Map.new(names, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    Enum.each(names, &System.delete_env/1)

    assert_raise Mix.Error, ~r/requires DSEX_HOVER_UPSTREAM_BM25=1/, fn ->
      Task.verify_manifest_environment!(opts)
    end

    System.put_env("DSEX_HOVER_UPSTREAM_BM25", "1")
    System.put_env("DSEX_IFBENCH_UPSTREAM_DESCRIPTIONS", "1")
    System.put_env("DSEX_GEPA_PYTHON", System.find_executable("python3") || "/usr/bin/python3")
    System.put_env("DSEX_GEPA_ROOT", File.cwd!())

    assert :ok = Task.verify_manifest_environment!(opts)
  end

  test "task rejects positional arguments and duplicate manifests in manifest mode" do
    assert_raise Mix.Error, ~r/cannot use positional arguments/, fn ->
      Task.resolve_manifest_options!([manifest: @manifest], ["unexpected"])
    end

    assert_raise Mix.Error, ~r/must be provided exactly once/, fn ->
      Task.resolve_manifest_options!(manifest: @manifest, manifest: @manifest)
    end
  end

  test "fails closed on unknown keys and altered scientific settings" do
    raw = @manifest |> File.read!() |> Jason.decode!()

    assert_raise ArgumentError, ~r/manifest keys must be exactly/, fn ->
      GepaCampaignManifest.validate!(Map.put(raw, "notes", "mutable"), @manifest)
    end

    assert_raise ArgumentError, ~r/max_retries must be 0/, fn ->
      changed = put_in(raw, ["request", "max_retries"], 1)
      GepaCampaignManifest.validate!(changed, @manifest)
    end

    assert_raise ArgumentError, ~r/campaign_id must be a lowercase stable identifier/, fn ->
      changed = put_in(raw, ["campaign_id"], "GEPA campaign latest")
      GepaCampaignManifest.validate!(changed, @manifest)
    end

    assert_raise ArgumentError, ~r/provider-qualified, dated model identifier/, fn ->
      changed = put_in(raw, ["models", "reflection"], "openai:gpt-5")
      GepaCampaignManifest.validate!(changed, @manifest)
    end

    assert_raise ArgumentError, ~r/families must be exactly/, fn ->
      changed = put_in(raw, ["families"], Enum.drop(raw["families"], -1))
      GepaCampaignManifest.validate!(changed, @manifest)
    end
  end

  test "fails closed when the pinned dataset manifest changes" do
    tmp = Path.join(System.tmp_dir!(), "gepa-manifest-test-#{System.unique_integer([:positive])}")
    config_dir = Path.join(tmp, "config")
    data_dir = Path.join(tmp, "data")
    File.mkdir_p!(config_dir)
    File.mkdir_p!(data_dir)
    on_exit(fn -> File.rm_rf!(tmp) end)

    raw = @manifest |> File.read!() |> Jason.decode!()
    File.write!(Path.join(data_dir, "families.json"), "{}")

    changed = put_in(raw, ["dataset", "root"], "../data")
    path = Path.join(config_dir, "manifest.json")
    File.write!(path, Jason.encode!(changed))

    assert_raise ArgumentError, ~r/dataset families manifest hash mismatch/, fn ->
      GepaCampaignManifest.load!(path)
    end
  end
end
