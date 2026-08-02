defmodule Imp.BenchmarkTruth.LangProBeHeartDiseaseProductFitTest do
  use ExUnit.Case, async: false

  alias Imp.BenchmarkTruth.LangProBeHeartDisease, as: Heart

  defp row do
    %{
      age: "63",
      sex: "male",
      cp: "typical angina",
      trestbps: "145",
      chol: "233",
      fbs: "true",
      restecg: "left ventricular hypertrophy",
      thalach: "150",
      exang: "no",
      oldpeak: "2.3",
      slope: "downsloping",
      ca: "0",
      thal: "fixed defect"
    }
  end

  defp task_lm do
    Imp.LM.Static.new(
      handler: fn messages, _opts ->
        rendered = Enum.map_join(messages, "\n", & &1.content)
        candidate? = rendered =~ "Diagnose consistently."

        %{
          reasoning: if(candidate?, do: "the candidate applies the evidence", else: "baseline"),
          answer: if(candidate?, do: "yes", else: "no")
        }
      end
    )
  end

  defp proposer_lm do
    Imp.LM.Static.new(
      handler: fn _messages, _opts -> %{"instructions" => ["Diagnose consistently."]} end
    )
  end

  defp examples do
    for split <- [:train, :selection, :test] do
      Heart.example("heart-#{split}", row(), "yes")
    end
  end

  test "recognized four-call program exposes four independently optimizable predictors" do
    program = Heart.new(task_lm())

    assert Enum.map(Imp.ProgramParameters.predictors(program), & &1.name) == [
             :opinion_1,
             :opinion_2,
             :opinion_3,
             :vote
           ]

    assert {:ok, prediction} = Imp.call(program, row())
    assert Imp.get(prediction, :answer) == "no"

    authority = Heart.authority()
    assert authority.status == :provider_free_product_fit_only

    assert authority.dataset.equivalence == %{
             status: :falsified,
             exact_feature_matches: 297,
             unmatched_benchmark_rows: 6,
             matched_target_rule: :uci_severity_greater_than_or_equal_to_2,
             disclosed_prompt_label_mismatch: true
           }
  end

  test "pinned LangProBe split is a disjoint exact-source partition" do
    data = Heart.data!()

    assert Enum.map([:train, :selection, :test], &length(data[&1])) == [15, 136, 152]

    ids =
      Enum.flat_map(
        [:train, :selection, :test],
        &Enum.map(data[&1], fn row -> Imp.get(row, :id) end)
      )

    assert length(ids) == 303
    assert MapSet.size(MapSet.new(ids)) == 303
    assert Imp.get(hd(data.train), :id) == "heart-source-203"
    assert Imp.get(hd(data.selection), :id) == "heart-source-231"
    assert Imp.get(hd(data.test), :id) == "heart-source-201"

    assert get_in(data.receipt, ["splits", "train", "ordered_canonical_jsonl_sha256"]) ==
             "3923fc709c3ba8349d50f6617cab8553da2b50117965dfc195bcc7698bdef362"
  end

  @tag :evidence_infrastructure
  test "pinned DSPy 3.2.1 runs the same four-predictor product shape and fresh state" do
    python = Path.expand("tmp/dspy-parity-venv/bin/python")
    dspy_root = Path.expand("tmp/dspy-3.2.1")
    script = Path.expand("scripts/langprobe_heart_disease_product_fit_upstream.py")

    assert File.regular?(python)
    assert File.dir?(dspy_root)

    {output, status} =
      System.cmd(python, [script, "--dspy-root", dspy_root], stderr_to_stdout: true)

    assert status == 0, output
    result = output |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()
    assert result["dspy_commit"] == "29448ae12756abdd14bd8796c819247ebb83673c"

    assert result["predictors"] == [
             "opinion_1.predict",
             "opinion_2.predict",
             "opinion_3.predict",
             "vote.predict"
           ]

    assert result["selected"] == "optimized"
    assert result["changed_instruction_count"] == 3
    assert result["fresh_predictions"] == ["yes", "yes", "yes", "yes"]
    refute result["full_opportunity_claimed"]
  end

  @tag :tmp_dir
  test "ordinary MIPRO selection persists all four mutations into a fresh trusted program", %{
    tmp_dir: tmp_dir
  } do
    [train, selection, test] = examples()
    baseline = Heart.new(task_lm())

    optimizer =
      Imp.Optimizer.MIPROv2.new(&Heart.metric/2,
        auto: nil,
        num_candidates: 2,
        num_trials: 2,
        startup_trials: 0,
        max_bootstrapped_demos: 0,
        max_labeled_demos: 0,
        minibatch: false,
        program_aware_proposer: false,
        data_aware_proposer: false,
        tip_aware_proposer: false,
        fewshot_aware_proposer: false,
        prompt_lm: proposer_lm(),
        seed: 17
      )

    data =
      Imp.Experiment.Data.new(
        train: [train],
        selection: [selection],
        test: [test],
        id: :id
      )

    assert {:ok, result} =
             Imp.Experiment.check(baseline, optimizer, data, &Heart.metric/2,
               artifact_id: "langprobe-heart-provider-free",
               compare_baseline_on_test: true
             )

    assert result.selected == :optimized
    assert result.baseline_selection.score == 0.0
    assert result.optimized_selection.score == 1.0
    assert result.test.score == 1.0

    before =
      Map.new(Imp.ProgramParameters.predictors(baseline), fn item ->
        {item.name, item.predictor.signature.instructions}
      end)

    assert Enum.all?(Imp.ProgramParameters.predictors(result.program), fn item ->
             item.predictor.signature.instructions != before[item.name]
           end)

    artifact_path = Path.join(tmp_dir, "heart-artifact.json")
    :ok = Imp.Optimizer.Artifact.write!(result.artifact, artifact_path)

    deployed =
      artifact_path
      |> Imp.Optimizer.Artifact.read!()
      |> Imp.Optimizer.Artifact.apply(Heart.new(task_lm()))

    assert {:ok, prediction} = Imp.call(deployed, row())
    assert Imp.get(prediction, :answer) == "yes"

    receipt_path = Path.join(tmp_dir, "fresh-service.json")

    code = """
    Code.require_file("examples/deployment/lib/imp_deployment/program_server.ex")
    lm = Imp.LM.Static.new(handler: fn messages, _opts ->
      rendered = Enum.map_join(messages, "\\n", & &1.content)
      candidate? = rendered =~ "Diagnose consistently."
      %{reasoning: if(candidate?, do: "candidate", else: "baseline"), answer: if(candidate?, do: "yes", else: "no")}
    end)
    program = Imp.Optimizer.Artifact.apply(
      Imp.Optimizer.Artifact.read!(#{inspect(artifact_path)}),
      Imp.BenchmarkTruth.LangProBeHeartDisease.new(lm)
    )
    {:ok, supervisor} = Task.Supervisor.start_link()
    {:ok, server} = ImpDeployment.ProgramServer.start_link(
      program: program,
      lm: lm,
      task_supervisor: supervisor,
      executor: fn selected, _lm, inputs -> Imp.call(selected, inputs) end,
      name: nil
    )
    calls = 1..4 |> Task.async_stream(fn _ -> ImpDeployment.ProgramServer.call(server, #{inspect(row())}, 5_000) end) |> Enum.to_list()
    answers = Enum.map(calls, fn {:ok, {:ok, prediction}} -> Imp.get(prediction, :answer) end)
    File.write!(#{inspect(receipt_path)}, Jason.encode!(answers))
    """

    {output, status} =
      System.cmd(System.find_executable("mix"), ["run", "-e", code],
        cd: File.cwd!(),
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert Jason.decode!(File.read!(receipt_path)) == ["yes", "yes", "yes", "yes"]
  end
end
