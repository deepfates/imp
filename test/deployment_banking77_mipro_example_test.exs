defmodule DeploymentBanking77MIPROExampleTest do
  use ExUnit.Case, async: true

  # Requires the pinned DSPy parity environment (scripts/setup_dspy_parity_env.sh
  # + setup_dspy_stable_source.sh) and/or example-project deps; runs in the CI
  # differential lane, not fast.check.
  @moduletag :dspy_parity

  @root Path.expand("../examples/deployment", __DIR__)
  @data Path.join(@root, "data/banking77-mipro-confirmatory-v1.json")
  @script Path.join(@root, "banking77_mipro.exs")
  @data_sha "6550e65edf66353af54d74daa48778a98d747052cb85ad05a64a9ad5e3680e86"

  Code.require_file(Path.join(@root, "lib/imp_deployment/callbacks.ex"))
  Code.require_file(Path.join(@root, "lib/imp_deployment/support_pipeline.ex"))
  Code.require_file(Path.join(@root, "lib/imp_deployment/workflow.ex"))
  Code.require_file(Path.join(@root, "lib/imp_deployment/banking77_pipeline.ex"))
  Code.require_file(Path.join(@root, "lib/imp_deployment/program_server.ex"))
  System.put_env("IMP_BANKING77_MIPRO_DEFINE_ONLY", "1")
  Code.require_file(@script)
  System.delete_env("IMP_BANKING77_MIPRO_DEFINE_ONLY")

  test "frozen complement is balanced, source-disjoint, and content-bound" do
    bytes = File.read!(@data)
    assert sha256(bytes) == @data_sha
    payload = Jason.decode!(bytes)

    assert payload["condition_id"] == "imp-88sn-banking77-mipro-confirmatory-v1"

    assert payload["payload_sha256"] ==
             "sha256:fc48ff2a8d4408eeaf917e7df4c32f80cfd162b1dcb542f467971ade217b71e3"

    assert payload["derivation"]["seed"] == "imp-88sn-banking77-mipro-confirmatory-v1"

    assert payload["derivation"]["base_commit"] ==
             "868923a0a103ae4fbddc4f20b311a45bc940035d"

    assert payload["source"]["revision"] == "796a4623935746f71378f0ebd435635a8ce08e50"

    assert payload["source"]["snapshot_sha256"] ==
             "5b2420944b57c674ec91b330bd5ab015d4637873488556cbf743c14291f46d00"

    assert payload["digests"] == %{
             "train" => "sha256:ae934e51f39eadf632b93a7715294acd601d23c693f5f5f119adb5584448cfa9",
             "selection" =>
               "sha256:aa5cdb1b33e1ad06c1905505f4b23ff01a741c4f0000d855a4545488ff70f1ea",
             "test" => "sha256:09f9850284f4ce70dd18c3e0dd77c6c18eead80b27ccb375c96a178b3b7f9f99"
           }

    assert payload["exposure"]["errors"] == []
    assert payload["exposure"]["coordinate_count"] == 336
    assert payload["exposure"]["normalized_text_digest_count"] == 336

    assert payload["derivation"]["availability_after_exclusion"]["test"] ==
             Map.new(~w(15 16 27 32 38 45 53 70), &{&1, 24})

    exposed_coordinates =
      payload["exposure"]["coordinates"]
      |> MapSet.new(&{&1["split"], &1["index"]})

    exposed_texts = MapSet.new(payload["exposure"]["normalized_text_sha256"])
    rows = payload["train"] ++ payload["selection"] ++ payload["test"]

    assert length(payload["train"]) == 24
    assert length(payload["selection"]) == 24
    assert length(payload["test"]) == 48
    assert length(Enum.uniq_by(rows, & &1["source_id"])) == 96
    assert length(Enum.uniq_by(rows, & &1["normalized_text_sha256"])) == 96

    for row <- rows do
      refute MapSet.member?(exposed_coordinates, {row["source_split"], row["source_index"]})
      refute MapSet.member?(exposed_texts, row["normalized_text_sha256"])
      assert normalized_digest(row["utterance"]) == row["normalized_text_sha256"]
    end

    for {split, per_label} <- [{"train", 3}, {"selection", 3}, {"test", 6}] do
      assert payload[split]
             |> Enum.frequencies_by(& &1["source_label_id"])
             |> Map.values()
             |> Enum.uniq() == [per_label]
    end
  end

  test "ordinary program performs both stages and exposes both optimizer predictors" do
    {:ok, calls} = Agent.start_link(fn -> [] end)

    lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          count = Agent.get_and_update(calls, &{length(&1), &1 ++ [messages]})
          if count == 0, do: %{evidence: "card fee evidence"}, else: %{route: "R15"}
        end
      )

    program = Banking77MIPRO.program()

    assert Enum.map(Imp.ProgramParameters.predictors(program), & &1.name) ==
             [:analyze_intent, :classify_route]

    assert {:ok, prediction} =
             Imp.context([lm: lm], fn ->
               Imp.call(program, %{utterance: "Why was I charged extra?"})
             end)

    assert Imp.get(prediction, :route) == "R15"
    [analysis_messages, routing_messages] = Agent.get(calls, & &1)
    refute inspect(analysis_messages) =~ "card fee evidence"
    assert inspect(routing_messages) =~ "card fee evidence"

    changed =
      program
      |> Imp.ProgramParameters.put_instruction(:analyze_intent, "changed analyzer")
      |> Imp.ProgramParameters.put_instruction(:classify_route, "changed router")

    assert changed.analyze_intent.signature.instructions == "changed analyzer"
    assert changed.classify_route.signature.instructions == "changed router"
  end

  test "the extracted default program remains compatible with the retained GEPA artifact" do
    artifact =
      Path.join(@root, "banking77-gepa-selected-artifact.json")
      |> Imp.Optimizer.Artifact.read!()

    applied = Imp.Optimizer.Artifact.apply(artifact, ImpDeployment.Banking77Pipeline.new())

    assert Enum.map(Imp.ProgramParameters.predictors(applied), & &1.name) ==
             [:analyze_intent, :classify_route]
  end

  test "the predecessor invalid MIPRO options fail before Banking program or evaluator work" do
    owner = self()

    lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          send(owner, :unexpected_lm_call)
          %{}
        end
      )

    modeled = Banking77MIPRO.optimizer(lm, lm, hd(Banking77MIPRO.seeds()))
    assert modeled.config.num_trials == 15
    assert modeled.startup_trials == 10

    valid =
      Imp.Optimizer.MIPROv2.new(&Banking77MIPRO.metric/2,
        auto: nil,
        num_candidates: 3,
        num_trials: 6,
        max_bootstrapped_demos: 2,
        max_labeled_demos: 2,
        prompt_lm: lm,
        task_lm: lm,
        startup_trials: 10,
        minibatch: false,
        proposer_fidelity: :dspy_3_2_1,
        search_fidelity: :dspy_3_2_1_optuna_4_9_0,
        program_aware_proposer: false,
        data_aware_proposer: true,
        tip_aware_proposer: true,
        fewshot_aware_proposer: true,
        num_threads: 1,
        max_errors: 10,
        seed: hd(Banking77MIPRO.seeds())
      )

    invalid = %{valid | startup_trials: 2}

    assert {:error,
            %{
              stage: :optimizer_validation,
              reason: "pinned DSPy 3.2.1/Optuna 4.9.0 search requires startup_trials: 10"
            }} =
             Imp.Experiment.check(
               Banking77MIPRO.program(),
               invalid,
               Banking77MIPRO.data!(),
               &Banking77MIPRO.metric/2,
               evaluation_options: [max_errors: 10]
             )

    refute_received :unexpected_lm_call

    caps = Banking77MIPRO.transport_caps()
    assert caps.per_seed.task == 3 * 48 + 48 + 48 + 15 * 48 + 3 * 48 + 3 * 192 + 4 * 2
    assert caps.per_seed.optimizer == 4 + 2 * 3
    assert caps.stage == %{task: 5_064, optimizer: 30}
    assert_in_delta caps.reservation_usd, 5_064 * 0.007104 + 30 * 0.08064, 1.0e-12

    # Outside bootstrap, 1,640 task transports are fixed per seed. The single
    # calling bootstrap arm may accept two rows immediately (4 transports) or
    # scan all 24 two-stage rows (48 transports), so expected usage is outcome
    # dependent while 1,688 remains the legal maximum.
    assert 1_644 == 1_640 + 4
    assert 1_688 == 1_640 + 48
  end

  test "finite diagnostics allow a real two-stage MIPRO artifact to continue into a fresh OS" do
    {:ok, router_calls} = Agent.start_link(fn -> 0 end)

    task_lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          rendered = Enum.map_join(messages, "\n", & &1.content)

          if rendered =~ "`evidence`" and not (rendered =~ "`route`") do
            %{evidence: "fee evidence"}
          else
            call = Agent.get_and_update(router_calls, &{&1, &1 + 1})

            cond do
              call == 0 -> "[[ ## route ## ]]\nR15\n[[ ## completed ]]"
              rendered =~ "candidate router" -> %{route: "R15"}
              rendered =~ ~r/fee [0-3] charged/ -> %{route: "R15"}
              true -> %{route: "R16"}
            end
          end
        end
      )

    prompt_lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          rendered = Enum.map_join(messages, "\n", & &1.content)

          cond do
            rendered =~ "`proposed_instruction`" -> %{proposed_instruction: "candidate router"}
            rendered =~ "`summary`" -> %{summary: "All rows ask about a card fee."}
            true -> %{observations: "The route is R15 for fee rows."}
          end
        end
      )

    source =
      ImpDeployment.Banking77Pipeline.new(
        routes: ["R15", "R16"],
        analysis_instruction: "Extract fee evidence.",
        routing_instruction: "Return R16 for this baseline."
      )

    rows =
      Enum.map(0..7, fn index ->
        Imp.example(
          source_id: "row-#{index}",
          utterance: "Why was fee #{index} charged?",
          route: "R15"
        )
        |> Imp.with_inputs(:utterance)
      end)

    data =
      Imp.Experiment.Data.new(
        train: Enum.slice(rows, 0, 4),
        selection: Enum.slice(rows, 4, 2),
        test: Enum.slice(rows, 6, 2),
        id: :source_id
      )

    optimizer =
      Imp.Optimizer.MIPROv2.new(&Banking77MIPRO.metric/2,
        auto: nil,
        num_candidates: 3,
        num_trials: 15,
        max_bootstrapped_demos: 2,
        max_labeled_demos: 2,
        minibatch: false,
        prompt_lm: prompt_lm,
        task_lm: task_lm,
        startup_trials: 10,
        proposer_fidelity: :dspy_3_2_1,
        search_fidelity: :dspy_3_2_1_optuna_4_9_0,
        program_aware_proposer: false,
        data_aware_proposer: true,
        tip_aware_proposer: true,
        fewshot_aware_proposer: true,
        view_data_batch_size: 10,
        num_threads: 1,
        max_errors: 10,
        seed: 9
      )

    assert {:ok, result} =
             Imp.context([lm: task_lm], fn ->
               Imp.Experiment.check(
                 source,
                 optimizer,
                 data,
                 &Banking77MIPRO.metric/2,
                 artifact_id: "finite-error-selected",
                 evaluation_options: [
                   failure_score: 0.0,
                   num_threads: 1,
                   max_errors: 10,
                   repetitions: 3,
                   aggregation: :mean
                 ]
               )
             end)

    assert result.selected == :optimized
    assert result.baseline_selection.score == 0.0
    assert [%{index: 0}] = result.baseline_selection.errors
    assert result.optimized_selection.score == 1.0
    assert result.test.score == 1.0
    assert result.repetition_summary.count == 3
    assert result.repetition_summary.aggregation == :mean

    assert result.program.classify_route.demos != []

    report = Imp.Optimizer.Report.fetch(result.program)
    assert report.metadata["completed_trials"] == 15
    assert report.metadata["sampler"] == "optuna_4_9_0_multivariate_categorical_tpe"
    assert length(report.candidates) == 15
    assert report.metadata["bootstrap"]["accepted_count"] > 0
    assert report.metadata["proposals"]["analyze_intent"]["slots"] |> length() == 3
    assert report.metadata["proposals"]["classify_route"]["slots"] |> length() == 3

    root = Path.join(System.tmp_dir!(), "imp-mipro-finite-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    artifact_path = Path.join(root, "artifact.json")
    receipt_path = Path.join(root, "fresh.json")
    :ok = Imp.Optimizer.Artifact.write!(result.artifact, artifact_path)

    code = """
    Code.require_file(#{inspect(Path.join(@root, "lib/imp_deployment/banking77_pipeline.ex"))})
    artifact = Imp.Optimizer.Artifact.read!(#{inspect(artifact_path)})
    lm = Imp.LM.Static.new(handler: fn messages, _opts ->
      rendered = Enum.map_join(messages, "\\n", & &1.content)
      if rendered =~ "`evidence`" and not (rendered =~ "`route`"),
        do: %{evidence: "fee evidence"},
        else: %{route: if(rendered =~ "candidate router" or rendered =~ ~r/fee [0-3] charged/, do: "R15", else: "R16")}
    end)
    source = ImpDeployment.Banking77Pipeline.new(
      routes: ["R15", "R16"],
      analysis_instruction: "Extract fee evidence.",
      routing_instruction: "Return R16 for this baseline."
    )
    selected = Imp.Optimizer.Artifact.apply(artifact, source)
    {:ok, prediction} = Imp.context([lm: lm], fn ->
      Imp.call(selected, %{utterance: "Why was the fee charged?"})
    end)
    File.write!(#{inspect(receipt_path)}, Jason.encode!(%{
      route: Imp.get(prediction, :route),
      instruction: selected.classify_route.signature.instructions,
      demo_count: length(selected.classify_route.demos)
    }))
    """

    assert {"", 0} =
             System.cmd("mix", ["run", "--no-compile", "--no-deps-check", "-e", code],
               cd: File.cwd!(),
               env: [{"MIX_ENV", "test"}],
               stderr_to_stdout: true
             )

    assert %{
             "demo_count" => demo_count,
             "instruction" => instruction,
             "route" => "R15"
           } = receipt_path |> File.read!() |> Jason.decode!()

    assert demo_count == length(result.program.classify_route.demos)
    assert instruction == result.program.classify_route.signature.instructions

    File.rm_rf!(root)
  end

  test "provider-disabled ordinary entry needs no key or benchmark bridge" do
    source = File.read!(@script)
    refute source =~ "IFBench"
    refute source =~ "Ledger"
    refute source =~ "Coordinator"
    refute source =~ "manifest"

    {output, 0} =
      System.cmd("mix", ["run", "--no-start", "banking77_mipro.exs"],
        cd: @root,
        env: [
          {"IMP_PATH", File.cwd!()},
          {"IMP_BANKING77_MIPRO_MODE", "disabled"},
          {"OPENROUTER_API_KEY", nil}
        ],
        stderr_to_stdout: true
      )

    receipt = output |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()
    assert receipt["status"] == "provider_disabled"
    assert receipt["provider_authority_used"] == false
    assert receipt["uses_ifbench_bridge"] == false
    assert receipt["condition"] == "imp-88sn-banking77-mipro-confirmatory-v1"
    assert receipt["seeds"] == [2_026_073_101, 2_026_073_102, 2_026_073_103]
    assert receipt["optimizer"]["categorical_trials"] == 15
    assert receipt["optimizer"]["startup_random_trials"] == 9
    assert receipt["optimizer"]["modeled_trials"] == 6
    assert receipt["optimizer"]["outer_repetitions"] == 3
    assert receipt["optimizer"]["internal_objectives"] == "single_pass"
    assert receipt["call_caps"]["stage"] == %{"task" => 5_064, "optimizer" => 30}
  end

  defp normalized_digest(text) do
    text
    |> String.normalize(:nfkc)
    |> String.downcase()
    |> String.split()
    |> Enum.join(" ")
    |> sha256()
  end

  defp sha256(bytes),
    do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
