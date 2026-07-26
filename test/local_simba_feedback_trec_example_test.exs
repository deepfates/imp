defmodule Imp.LocalSIMBAFeedbackTRECExampleTest do
  use ExUnit.Case, async: false

  @source "examples/local_simba_feedback_trec/run.exs"
  @contract "examples/local_simba_feedback_trec/task-contract.json"
  @old_simba "benchmarks/data/simba-trec-coarse-v1.json"
  @old_grpo "examples/local_grpo_opaque_banking77/trec-source-guided-v1-data.json"

  setup_all do
    previous = System.get_env("IMP_SIMBA_FEEDBACK_TREC_DEFINE_ONLY")
    System.put_env("IMP_SIMBA_FEEDBACK_TREC_DEFINE_ONLY", "1")
    Code.require_file(@source, File.cwd!())

    on_exit(fn ->
      if previous,
        do: System.put_env("IMP_SIMBA_FEEDBACK_TREC_DEFINE_ONLY", previous),
        else: System.delete_env("IMP_SIMBA_FEEDBACK_TREC_DEFINE_ONLY")
    end)

    :ok
  end

  test "frozen binary task is balanced and source-disjoint from prior tasks" do
    rows = apply(LocalSIMBAFeedbackTREC.Contract, :load!, [File.cwd!(), @contract])

    assert split_frequencies(rows.train) == %{"DESC" => 10, "ENTY" => 10}

    assert split_frequencies(rows.validation) == %{"DESC" => 3, "ENTY" => 3}

    assert split_frequencies(rows.held_out) == %{"DESC" => 20, "ENTY" => 20}

    selected_source_ids =
      (rows.train ++ rows.validation ++ rows.held_out)
      |> MapSet.new(& &1["source_id"])

    for predecessor <- [@old_simba, @old_grpo] do
      prior = predecessor |> File.read!() |> Jason.decode!()

      prior_source_ids =
        Enum.flat_map(~w(train validation held_out), &prior[&1])
        |> MapSet.new(& &1["source_id"])

      assert MapSet.disjoint?(selected_source_ids, prior_source_ids)
    end

    assert Enum.all?(rows.train ++ rows.validation, &(&1["split"] == "calibration"))
    assert Enum.all?(rows.held_out, &(&1["split"] == "heldout"))
  end

  test "only train examples disclose semantic route feedback" do
    mapping = @contract |> File.read!() |> Jason.decode!() |> Map.fetch!("route_mapping")
    metric = apply(LocalSIMBAFeedbackTREC.Runner, :metric, [mapping])

    train =
      Imp.Example.new(%{
        question: "What is a quasar?",
        route: "K11",
        source_label: "DESC",
        feedback_allowed: true
      })

    validation =
      Imp.Example.new(%{
        question: "What is a quasar?",
        route: "K11",
        source_label: "DESC",
        feedback_allowed: false
      })

    wrong = Imp.Prediction.new(%{route: "K47"})

    assert %{score: score, feedback: feedback} = metric.(train, wrong)
    assert score == 0.0
    assert feedback =~ "Expected K11 for question asking for a description"
    assert feedback =~ "K47 represents question asking for an entity"
    assert metric.(validation, wrong) == 0.0

    source =
      apply(LocalSIMBAFeedbackTREC.Runner, :source_program, [
        Jason.decode!(File.read!(@contract))
      ])

    refute source.signature.instructions =~ "definition"
    refute source.signature.instructions =~ "entity"
  end

  test "ordinary compile boundary excludes held-out and requires rendered rule lifecycle" do
    source = File.read!(@source)

    assert source =~ "examples(rows.train, rows.contract, true)"
    assert source =~ "examples(rows.validation, rows.contract, false)"

    refute source =~
             "SIMBA.compile(\n          optimizer,\n          baseline,\n          examples(rows.held_out"

    assert source =~ "max_demos: config[\"max_demos\"]"
    assert source =~ "stage.mutated_rule_finalists > 0"
    assert source =~ "stage.rendered_rule_calls > 0"
    assert source =~ "stage.feedback_reflection_calls > 0"
    assert source =~ "Artifact.from_optimized_program"
    assert source =~ "Artifact.apply(baseline)"
    assert source =~ "fresh selected predictions/errors differ"
  end

  @tag :tmp_dir
  test "source program round-trips with one-attempt local runtime settings", %{tmp_dir: tmp_dir} do
    contract = Jason.decode!(File.read!(@contract))
    path = Path.join(tmp_dir, "source-program.json")
    source = apply(LocalSIMBAFeedbackTREC.Runner, :source_program, [contract])

    assert :ok = Imp.save!(source, path)
    loaded = Imp.load!(path)
    lm = Imp.ProgramAccess.lm(loaded)

    assert lm.model == "ollama:llama3.2:3b"
    assert Keyword.get(lm.opts, :cache) == false
    assert Keyword.get(lm.opts, :max_retries) == 0
    assert Keyword.get(lm.opts, :req_http_options) == [retry: false, max_retries: 0]
    assert loaded.adapter == Imp.Adapter.SingleField
    assert loaded.config[:json_fallback] == false
  end

  test "contract and runner freeze the bounded call envelope" do
    contract = Jason.decode!(File.read!(@contract))
    optimizer = contract["optimizer"]

    assert optimizer == %{
             "bsize" => 5,
             "max_demos" => 0,
             "max_steps" => 4,
             "num_candidates" => 2,
             "seed" => 2_026_072_602
           }

    source = File.read!(@source)
    assert source =~ "@max_optimization_transports 130"
    assert source =~ "@max_optimization_transports + 120"
    assert source =~ "stage.logical_calls == 40 and stage.transport_attempts == 40"
  end

  defp split_frequencies(rows) do
    Enum.frequencies_by(rows, fn row -> row["label"] |> String.split(":", parts: 2) |> hd() end)
  end
end
