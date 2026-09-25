defmodule Imp.LocalSIMBATRECExampleTest do
  use ExUnit.Case, async: false

  @source "examples/local_simba_trec/run.exs"
  @data "benchmarks/data/simba-trec-coarse-v1.json"
  @result "examples/local_simba_trec/exercised-result.json"
  @json_result "examples/local_simba_trec/exercised-json-result.json"

  setup_all do
    previous = System.get_env("IMP_SIMBA_TREC_DEFINE_ONLY")
    System.put_env("IMP_SIMBA_TREC_DEFINE_ONLY", "1")
    Code.require_file(@source, File.cwd!())

    on_exit(fn ->
      if previous,
        do: System.put_env("IMP_SIMBA_TREC_DEFINE_ONLY", previous),
        else: System.delete_env("IMP_SIMBA_TREC_DEFINE_ONLY")
    end)

    :ok
  end

  test "frozen TREC rows are balanced and source-disjoint" do
    data = @data |> File.read!() |> Jason.decode!()
    rows = data["train"] ++ data["validation"] ++ data["held_out"]

    assert Enum.frequencies_by(data["train"], & &1["route"]) == %{
             "R17" => 6,
             "R42" => 6,
             "R68" => 6,
             "R93" => 6
           }

    assert Enum.frequencies_by(data["validation"], & &1["route"]) == %{
             "R17" => 2,
             "R42" => 2,
             "R68" => 2,
             "R93" => 2
           }

    assert Enum.frequencies_by(data["held_out"], & &1["route"]) == %{
             "R17" => 10,
             "R42" => 10,
             "R68" => 10,
             "R93" => 10
           }

    assert Enum.all?(data["train"] ++ data["validation"], &(&1["source_split"] == "train"))
    assert Enum.all?(data["held_out"], &(&1["source_split"] == "test"))
    assert length(Enum.uniq_by(rows, & &1["group_id"])) == 72

    assert :crypto.hash(:sha256, File.read!(@data)) |> Base.encode16(case: :lower) ==
             "6643645cc3bcd79a5236b7e3920a5c37526be178df2e02f20652d9a16eef51ad"
  end

  test "ordinary front door keeps held-out rows outside SIMBA selection" do
    source = File.read!(@source)

    assert source =~
             "Imp.optimize!(baseline, &1, examples(rows.train), examples(rows.validation))"

    refute source =~ "Imp.optimize!(baseline, &1, examples(rows.held_out)"
    assert source =~ "Artifact.from_optimized_program"
    assert source =~ "Imp.save!(source, paths.program)"
    assert source =~ "source = Imp.read!(paths.program)"
    assert source =~ "IMP_SIMBA_TREC_FRESH"
  end

  test "runtime requires rendered mutation, one-attempt calls, and exact fresh identity" do
    source = File.read!(@source)

    assert source =~ "stage.rendered_mutation_calls > 0"
    assert source =~ "stage.logical_calls == stage.transport_attempts"
    assert source =~ "cache: false"
    assert source =~ "max_retries: 0"
    assert source =~ "req_http_options: [retry: false, max_retries: 0]"
    assert source =~ "fresh process loaded a different selected parameter artifact"
    assert source =~ "fresh selected predictions/errors differ"
  end

  @tag :tmp_dir
  test "source program saves and loads with exact local runtime safety options", %{
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "program.json")
    source = apply(LocalSIMBATREC.Runner, :source_program, [])
    assert :ok = Imp.save!(source, path)
    loaded = Imp.read!(path)
    lm = Imp.ProgramAccess.lm(loaded)

    assert lm.model == "ollama:llama3.2:3b"
    assert Keyword.get(lm.opts, :cache) == false
    assert Keyword.get(lm.opts, :max_retries) == 0
    assert Keyword.get(lm.opts, :req_http_options) == [retry: false, max_retries: 0]
    assert loaded.config[:json_fallback] == false
  end

  @tag :tmp_dir
  test "JSON condition changes only the explicit public adapter", %{tmp_dir: tmp_dir} do
    previous = System.get_env("IMP_SIMBA_TREC_ADAPTER")
    System.put_env("IMP_SIMBA_TREC_ADAPTER", "json")

    on_exit(fn ->
      if previous,
        do: System.put_env("IMP_SIMBA_TREC_ADAPTER", previous),
        else: System.delete_env("IMP_SIMBA_TREC_ADAPTER")
    end)

    source = apply(LocalSIMBATREC.Runner, :source_program, [])
    assert source.adapter == Imp.Adapter.JSON
    assert source.signature.instructions =~ "opaque internal answer service"
    assert :ok = Imp.save!(source, Path.join(tmp_dir, "json-program.json"))
    assert Imp.read!(Path.join(tmp_dir, "json-program.json")).adapter == Imp.Adapter.JSON
  end

  test "unknown adapter conditions fail before model activity" do
    previous = System.get_env("IMP_SIMBA_TREC_ADAPTER")
    System.put_env("IMP_SIMBA_TREC_ADAPTER", "normalize-chat-output")

    on_exit(fn ->
      if previous,
        do: System.put_env("IMP_SIMBA_TREC_ADAPTER", previous),
        else: System.delete_env("IMP_SIMBA_TREC_ADAPTER")
    end)

    assert_raise RuntimeError, ~r/unsupported SIMBA TREC adapter/, fn ->
      apply(LocalSIMBATREC.Runner, :source_program, [])
    end
  end

  test "retained result preserves the format-failed SIMBA mutation lifecycle" do
    result = @result |> File.read!() |> Jason.decode!()

    assert result["status"] == "complete"

    assert result["search"] == %{
             "baseline_score" => 0.0,
             "selected_score" => 0.0,
             "selected" => "baseline",
             "candidate_count" => 1,
             "mutated_finalists" => 1,
             "rendered_mutation_calls" => 26,
             "logical_calls" => 96,
             "transport_attempts" => 96
           }

    assert result["held_out_test"]["baseline"] == %{
             "accuracy" => 0.0,
             "macro_f1" => 0.0,
             "errors" => 40
           }

    assert result["held_out_test"]["selected"] == result["held_out_test"]["baseline"]
    assert result["fresh_process"]["byte_identical"]
  end

  test "retained JSON condition preserves its negative mutation selection" do
    result = @json_result |> File.read!() |> Jason.decode!()

    assert result["adapter"] == "Imp.Adapter.JSON"
    assert result["search"]["baseline_score"] == 0.25
    assert result["search"]["selected_score"] == 0.25
    assert result["search"]["selected"] == "baseline"
    assert result["search"]["candidate_count"] == 5
    assert result["search"]["mutated_finalists"] == 3
    assert result["search"]["rendered_mutation_calls"] == 111
    assert result["search"]["logical_calls"] == 146
    assert result["search"]["transport_attempts"] == 146
    assert result["held_out_test"]["baseline"]["accuracy"] == 0.35
    assert_in_delta result["held_out_test"]["baseline"]["macro_f1"], 0.2516469038208169, 1.0e-12
    assert result["held_out_test"]["selected"] == result["held_out_test"]["baseline"]
    assert result["fresh_process"]["byte_identical"]
  end
end
