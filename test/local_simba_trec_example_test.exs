defmodule Imp.LocalSIMBATRECExampleTest do
  use ExUnit.Case, async: false

  @source "examples/local_simba_trec/run.exs"
  @data "benchmarks/data/simba-trec-coarse-v1.json"

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
             "SIMBA.compile(baseline, examples(rows.train), examples(rows.validation))"

    refute source =~ "SIMBA.compile(baseline, examples(rows.held_out)"
    assert source =~ "Artifact.from_optimized_program"
    assert source =~ "Imp.save!(source, paths.program)"
    assert source =~ "source = Imp.load!(paths.program)"
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
    loaded = Imp.load!(path)
    lm = Imp.ProgramAccess.lm(loaded)

    assert lm.model == "ollama:llama3.2:3b"
    assert Keyword.get(lm.opts, :cache) == false
    assert Keyword.get(lm.opts, :max_retries) == 0
    assert Keyword.get(lm.opts, :req_http_options) == [retry: false, max_retries: 0]
    assert loaded.config[:json_fallback] == false
  end
end
