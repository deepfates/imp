defmodule Imp.LocalSIMBAFeedbackTRECExampleTest do
  use ExUnit.Case, async: false

  @source "examples/local_simba_feedback_trec/run.exs"
  @contract "examples/local_simba_feedback_trec/task-contract.json"
  @treatment "examples/local_simba_feedback_trec/usefulness-v4-treatment.json"
  @old_simba "benchmarks/data/simba-trec-coarse-v1.json"
  @old_grpo "examples/local_grpo_opaque_banking77/trec-source-guided-v1-data.json"
  @stopped_result "examples/local_simba_feedback_trec/exercised-stopped-result.json"
  @structured_stopped_result "examples/local_simba_feedback_trec/exercised-structured-v2-stopped-result.json"
  @schema_decode_stopped_result "examples/local_simba_feedback_trec/exercised-schema-decode-v3-stopped-result.json"
  @phi4_stopped_result "examples/local_simba_feedback_trec/exercised-phi4-reflection-v4-stopped-result.json"

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

    assert source =~ ~s(@treatment_id "local-simba-feedback-trec-phi4-reflection-v4")

    assert source =~ "examples(rows.train, rows.contract, true)"
    assert source =~ "examples(rows.validation, rows.contract, false)"

    refute source =~
             "Imp.optimize!(\n          baseline,\n          optimizer,\n          examples(rows.held_out"

    assert source =~ "max_demos: config[\"max_demos\"]"
    assert source =~ "stage.mutated_rule_finalists > 0"
    assert source =~ "stage.matched_main_advice_responses > 0"
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
    loaded = Imp.read!(path)
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

  test "V4 changes only the reflection model from the frozen task condition" do
    contract = Jason.decode!(File.read!(@contract))
    treatment = Jason.decode!(File.read!(@treatment))

    assert treatment["treatment_id"] == "local-simba-feedback-trec-phi4-reflection-v4"

    assert treatment["task_contract"]["sha256"] ==
             apply(LocalSIMBAFeedbackTREC.Contract, :contract_sha256, [])

    assert treatment["task_model"] == contract["model"]
    assert treatment["optimizer"] == contract["optimizer"]
    assert treatment["splits"] == %{"train" => 20, "validation" => 6, "held_out" => 40}

    assert treatment["reflection_model"] == %{
             "id" => "ollama:phi4:latest",
             "inventory_name" => "phi4:latest",
             "digest" => "ac896e5b8b34a1f4efa7b14d7520725140d5512484457fab45d2a4ea14c69dba"
           }

    assert treatment["runtime"] == %{
             "cache" => false,
             "http_retry" => false,
             "json_fallback" => false,
             "max_concurrency" => 1,
             "max_optimization_transports" => 130,
             "max_retries" => 0,
             "max_total_transports" => 250,
             "reflection_max_tokens" => 768,
             "reflection_temperature" => 0,
             "task_max_tokens" => 32,
             "task_temperature" => 0,
             "timeout_ms" => 120_000
           }
  end

  @tag :tmp_dir
  test "observer atomically retains exact reflection output and module keys", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "reflection-responses.json")
    {:ok, observer} = apply(LocalSIMBAFeedbackTREC.Observer, :start_link, [path])
    :ok = apply(LocalSIMBAFeedbackTREC.Observer, :phase, [observer, "optimization"])

    raw = ~s({"discussion":"contrast","module_advice":{"main":"Use the metric feedback."}})

    lm =
      struct(LocalSIMBAFeedbackTREC.ObservedLM,
        inner: Imp.LM.Static.new(handler: fn _messages, _opts -> raw end),
        observer: observer,
        role: :reflection
      )

    assert {:ok, ^raw} = Imp.LM.generate(lm, [%{role: :user, content: "reflect"}], [])

    ledger = path |> File.read!() |> Jason.decode!()
    assert ledger["status"] == "in_progress"
    assert [response] = ledger["reflection_responses"]
    assert response["raw_output"] == raw
    assert response["module_keys"] == ["main"]
    assert response["matched_main_advice"] == "Use the metric feedback."
  end

  test "retained execution remains an incomplete format-boundary result" do
    result = Jason.decode!(File.read!(@stopped_result))

    assert result["status"] == "stopped_before_selection_or_heldout"

    assert result["contract_sha256"] ==
             apply(LocalSIMBAFeedbackTREC.Contract, :contract_sha256, [])

    assert result["optimization"]["logical_calls"] == 52
    assert result["optimization"]["transport_attempts"] == 52
    assert result["optimization"]["feedback_reflection_calls"] == 1
    assert result["optimization"]["candidate_count"] == 0
    assert result["optimization"]["strict_parse_errors"] == 16
    refute result["heldout_opened"]
    refute result["fresh_process_attempted"]
    assert result["claim_boundary"] =~ "does not establish a SIMBA win or loss"
  end

  test "schema transport stop remains an adapter measurement failure" do
    result = Jason.decode!(File.read!(@structured_stopped_result))

    assert result["status"] == "stopped_before_reflection_selection_or_heldout"
    assert result["optimization"]["transport_attempts"] == 46
    assert result["optimization"]["strict_parse_errors"] == 46
    assert result["optimization"]["reflection_calls"] == 0
    assert result["optimization"]["candidate_count"] == 0
    refute result["heldout_opened"]
    assert result["claim_boundary"] =~ "not a SIMBA win or loss"
  end

  test "corrected schema run remains a no-mutation result before heldout" do
    result = Jason.decode!(File.read!(@schema_decode_stopped_result))

    assert result["status"] == "stopped_before_selection_or_heldout"
    assert result["optimization"]["transport_attempts"] == 52
    assert result["optimization"]["runtime_errors"] == 0
    assert result["optimization"]["feedback_reflection_calls"] == 6
    assert result["optimization"]["candidate_count"] == 0
    assert result["optimization"]["baseline_score"] == 0.5
    refute result["heldout_opened"]
    assert result["claim_boundary"] =~ "does not prove a genuine mutation"
  end

  test "Phi-4 V4 remains a source-schema stop before mutation and heldout" do
    result = Jason.decode!(File.read!(@phi4_stopped_result))

    assert result["status"] == "stopped_before_mutation_selection_or_heldout"
    assert result["runtime_commit"] == "fa14908"
    assert result["optimization"]["completed_steps"] == 4
    assert result["optimization"]["logical_calls"] == 53
    assert result["optimization"]["transport_attempts"] == 53
    assert result["optimization"]["task_calls"] == 46
    assert result["optimization"]["reflection_calls"] == 7
    assert result["optimization"]["reflection_outputs_with_main_key"] == 7
    assert result["optimization"]["reflection_outputs_with_string_main_advice"] == 0
    assert result["optimization"]["reflection_outputs_with_object_main_advice"] == 7
    assert result["optimization"]["candidate_count"] == 0
    refute result["heldout_opened"]
    refute result["fresh_process_attempted"]
    assert result["cleanup"]["resident_models_after_cleanup"] == []
    assert result["primary_source_gap"]["upstream_contract"] =~ "dict[str, str]"
    assert result["claim_boundary"] =~ "proves no genuine instruction mutation"
  end

  defp split_frequencies(rows) do
    Enum.frequencies_by(rows, fn row -> row["label"] |> String.split(":", parts: 2) |> hd() end)
  end
end
