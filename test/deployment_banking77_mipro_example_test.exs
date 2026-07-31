defmodule DeploymentBanking77MIPROExampleTest do
  use ExUnit.Case, async: true

  @root Path.expand("../examples/deployment", __DIR__)
  @data Path.join(@root, "data/banking77-mipro-stage1.json")
  @script Path.join(@root, "banking77_mipro.exs")
  @data_sha "4934ebc54b06614343461c2fe79c7ca4807892c1b645cbb30790e945dcb2c34a"

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

    assert payload["condition_id"] == "imp-88sn-banking77-mipro-v1"
    assert payload["source"]["revision"] == "796a4623935746f71378f0ebd435635a8ce08e50"

    assert payload["source"]["snapshot_sha256"] ==
             "5b2420944b57c674ec91b330bd5ab015d4637873488556cbf743c14291f46d00"

    assert payload["digests"] == %{
             "train" => "sha256:ec42891dc7c5bece39bf0f059ede3213b482a1276ab15b7a634e7d0974071e44",
             "selection" =>
               "sha256:3312228c66b7890b9d632529ffde2a398f56a8fe2d1f0b6600bd041351d45ddd",
             "test" => "sha256:dc921b772196f885e051678b5db228e8b0ade676eeea1bb85dafdaf12ae2e502"
           }

    assert payload["exposure"]["files_considered"] == 85
    assert payload["exposure"]["files_readable"] == 85
    assert payload["exposure"]["errors"] == []
    assert payload["exposure"]["coordinate_count"] == 240
    assert payload["exposure"]["normalized_text_digest_count"] == 240

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

  test "MIPRO opportunity and legal transport ceiling are frozen before providers" do
    lm = Imp.LM.Static.new(handler: fn _messages, _opts -> %{} end)
    optimizer = Banking77MIPRO.optimizer(lm, lm, hd(Banking77MIPRO.seeds()))

    assert optimizer.config.num_candidates == 3
    assert optimizer.config.num_trials == 6
    assert optimizer.config.max_bootstrapped_demos == 2
    assert optimizer.config.max_labeled_demos == 2
    assert optimizer.config.proposer_fidelity == :dspy_3_2_1
    assert optimizer.config.search_fidelity == :dspy_3_2_1_optuna_4_9_0
    assert optimizer.startup_trials == 2
    assert optimizer.max_errors == 10

    caps = Banking77MIPRO.transport_caps()
    assert caps.per_seed.task == 48 + 48 + 48 + 6 * 48 + 48 + 2 * 48 * 2 + 4 * 2
    assert caps.per_seed.optimizer == 4 + 2 * 3
    assert caps.stage == %{task: 2_040, optimizer: 30}
    assert_in_delta caps.reservation_usd, 2_040 * 0.007104 + 30 * 0.08064, 1.0e-12

    # Outside bootstrap, 632 task transports are fixed per seed. The single
    # calling bootstrap arm may accept two rows immediately (4 transports) or
    # scan all 24 two-stage rows (48 transports), so expected usage is outcome
    # dependent while 680 remains the legal maximum.
    assert 636 == 632 + 4
    assert 680 == 632 + 48
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
    assert receipt["call_caps"]["stage"] == %{"task" => 2_040, "optimizer" => 30}
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
