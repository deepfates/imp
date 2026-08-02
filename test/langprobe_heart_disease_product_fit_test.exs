defmodule Imp.BenchmarkTruth.LangProBeHeartDiseaseProductFitTest do
  use ExUnit.Case, async: false

  alias Imp.BenchmarkTruth.LangProBeHeartDisease, as: Heart
  alias Imp.BenchmarkTruth.LangProBeHeartDiseaseMiproCurrent, as: Plan

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

  test "current matched preregistration binds the exact hidden MIPRO opportunity" do
    plan = Plan.call_plan()

    assert plan.executable == false
    assert plan.full_opportunity_claimed == false
    assert plan.task.periodic_full_evaluations == 5_440
    assert plan.per_runtime_run == %{task: 15_904, proposer: 147}
    assert plan.study == %{task: 159_040, proposer: 1_470}
    assert length(Plan.seeds()) == 5
    assert Plan.acceptance().test == :two_sided_wilcoxon_signed_rank
    assert Plan.historical_context().mipro_lift == 0.0526

    assert Plan.historical_context().scope ==
             :single_historical_run_context_not_acceptance_standard

    assert Plan.adapter_semantics().dspy.use_json_adapter_fallback == false
    assert_in_delta Plan.planning_reservation().total_usd, 588.0225792, 1.0e-9
    assert Plan.planning_reservation().status == :planning_only_not_legal_ceiling
  end

  @tag :evidence_infrastructure
  test "exact C12 setup executes all 147 grounded proposer calls" do
    data = Heart.data!()

    task_calls =
      start_supervised!(
        {Agent, fn -> [] end},
        id: {:heart_task_calls, System.unique_integer([:positive])}
      )

    captured_task_lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          Agent.update(task_calls, &(&1 ++ [messages]))
          %{reasoning: "provider-free clinical reasoning", answer: "no"}
        end
      )

    calls =
      start_supervised!(
        {Agent, fn -> [] end},
        id: {:heart_proposer_calls, System.unique_integer([:positive])}
      )

    prompt_lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          Agent.update(calls, &(&1 ++ [messages]))

          %{
            observations: "provider-free Heart Disease observations",
            summary: "provider-free Heart Disease summary",
            program_description: "three opinions followed by one vote",
            module_description: "one named stage in the four-call program",
            proposed_instruction: "provider-free candidate instruction"
          }
        end
      )

    compiled =
      Plan.optimizer(captured_task_lm, prompt_lm, hd(Plan.seeds()))
      |> Imp.Optimizer.MIPROv2.compile(
        Plan.program(captured_task_lm),
        data.train,
        data.selection,
        max_trials: 0
      )

    recorded_calls = Agent.get(calls, & &1)

    assert length(recorded_calls) == 147

    assert Plan.proposer_prompt_census!(recorded_calls) == %{
             calls: 147,
             max_bytes: 5_165,
             min_bytes: 978,
             ordered_sha256: "4c367dfa9eb821ae48a4996e14d5aee2e238a23b7e74e5df926d3be846d60f24",
             p95_bytes: 4_278
           }

    report = Imp.Optimizer.Report.fetch(compiled)

    artifacts =
      report.metadata.resume_state["payload"]["artifacts"] |> Imp.Optimizer.Report.decode_term()

    assert Plan.task_prompt_census!(artifacts.search_demos) == %{
             calls: 14_544,
             demo_arm_sizes: %{
               opinion_1: [0, 2, 4, 2, 3, 2, 2, 3, 4, 2, 3, 2],
               opinion_2: [0, 2, 4, 2, 3, 2, 2, 3, 4, 2, 3, 2],
               opinion_3: [0, 2, 4, 2, 3, 2, 2, 3, 4, 2, 3, 2],
               vote: [0, 2, 4, 2, 3, 2, 2, 3, 4, 2, 3, 2]
             },
             max_bytes: 5_462,
             min_bytes: 1_622,
             ordered_sha256: "f57a00f05f27a00ccebdd9f4472ca1f8e9a0b1f268e4d54af909e4b6bd315236",
             p95_bytes: 4_616,
             source: :actual_pinned_search_demo_arms
           }

    task_sizes = Agent.get(task_calls, & &1) |> Enum.map(&byte_size(Jason.encode!(&1)))
    assert length(task_sizes) == 652
    assert Enum.min(task_sizes) == 1_633
    assert Enum.max(task_sizes) == 3_368
  end

  @tag :evidence_infrastructure
  test "pinned DSPy separately censes every C12 demo-bearing task and proposer wire" do
    python = Path.expand("tmp/dspy-parity-venv/bin/python")
    dspy_root = Path.expand("tmp/dspy-3.2.1")
    script = Path.expand("scripts/langprobe_heart_disease_product_fit_upstream.py")

    {output, status} =
      System.cmd(
        python,
        [
          script,
          "--prereg-census",
          "--dspy-root",
          dspy_root,
          "--dataset",
          Path.expand(Heart.dataset_path()),
          "--split",
          Path.expand(Heart.split_path())
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output
    result = output |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()

    assert result["proposer"] == %{
             "calls" => 147,
             "max_bytes" => 10_927,
             "min_bytes" => 978,
             "ordered_sha256" =>
               "7b3d48a902452bb05d668520e100981848eab36336565e8bd0d201743abc0e17",
             "p95_bytes" => 10_881
           }

    assert result["task"] == %{
             "calls" => 14_544,
             "demo_arm_sizes" =>
               Map.new(0..3, &{Integer.to_string(&1), [0, 2, 4, 2, 3, 2, 2, 3, 4, 2, 3, 2]}),
             "max_bytes" => 6_187,
             "min_bytes" => 2_311,
             "ordered_sha256" =>
               "ae53916c489da54baec12bc0e48aa2b296ca1e79052bc1dfc83c40e4537d4e88",
             "p95_bytes" => 5_341
           }

    refute result["full_opportunity_claimed"]
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
