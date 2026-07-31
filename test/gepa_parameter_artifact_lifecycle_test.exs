defmodule Imp.GEPAParameterArtifactLifecycleTest do
  use ExUnit.Case, async: false

  alias Imp.BenchmarkTruth.{GepaMetrics, HoverMultiHop, Papillon}
  alias Imp.Optimizer.{Artifact, GEPA}
  alias Imp.TestSupport.TwoStageOptimizerProgram

  setup do
    root =
      Path.join(System.tmp_dir!(), "imp-gepa-artifact-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "ordinary multi-predictor GEPA result persists and executes in a fresh OS process", %{
    root: root
  } do
    selected_classifier = "Use the selected classifier instruction."
    selected_analyzer = "Extract the decisive payment evidence."
    program = TwoStageOptimizerProgram.new(runtime_lm("parent-runtime", selected_classifier))
    example = example()

    metric = fn received, prediction ->
      if Imp.get(received, :route) == Imp.get(prediction, :route), do: 1.0, else: 0.0
    end

    proposer = fn _candidate, _reflective_dataset, components ->
      instructions = %{
        analyze_intent: selected_analyzer,
        classify_route: selected_classifier
      }

      %{new_texts: Map.take(instructions, components)}
    end

    {selected, report, artifact} =
      GEPA.new(metric,
        generations: 1,
        module_selector: :all,
        reflection_strategy: proposer
      )
      |> GEPA.compile_with_artifact(program, [example], [example],
        artifact_id: "banking77-router-v1",
        provenance: %{dataset: "synthetic-lifecycle"}
      )

    assert report.best_score == 1.0

    assert GEPA.Candidate.from_program(selected) == %{
             analyze_intent: selected_analyzer,
             classify_route: selected_classifier
           }

    assert {:ok, prediction} = Imp.call(selected, %{utterance: Imp.get(example, :utterance)})
    assert Imp.get(prediction, :route) == "R42"

    assert %{
             champion_id: "banking77-router-v1",
             candidates: [%{"score" => 1.0}],
             provenance: provenance
           } = Artifact.inspect(artifact)

    assert provenance["dataset"] == "synthetic-lifecycle"
    assert provenance["optimizer"] == "gepa"

    artifact_path = Path.join(root, "selected-parameters.json")
    receipt_path = Path.join(root, "fresh-receipt.json")
    :ok = Artifact.write!(artifact, artifact_path)

    encoded = File.read!(artifact_path)
    refute encoded =~ "parent-runtime"
    refute encoded =~ inspect(TwoStageOptimizerProgram)

    code = """
    alias Imp.Optimizer.Artifact
    alias Imp.TestSupport.TwoStageOptimizerProgram

    selected_classifier = #{inspect(selected_classifier)}
    lm = Imp.LM.Static.new(
      runtime_marker: "fresh-child-runtime",
      handler: fn messages, _opts ->
        rendered = Enum.map_join(messages, "\\n", & &1.content)
        if String.contains?(rendered, "`route`"),
          do: %{route: if(String.contains?(rendered, selected_classifier), do: "R42", else: "R17")},
          else: %{evidence: "card payment was not recognized"}
      end
    )

    fresh = TwoStageOptimizerProgram.new(lm)
    applied = #{inspect(artifact_path)} |> Artifact.read!() |> Artifact.apply(fresh)
    {:ok, prediction} = Imp.call(applied, %{utterance: "I do not recognize this card payment"})

    payload = %{
      route: Imp.get(prediction, :route),
      instructions: Enum.map(Imp.ProgramParameters.predictors(applied), & &1.predictor.signature.instructions),
      runtime_preserved: Enum.all?(Imp.ProgramParameters.predictors(applied), &(&1.predictor.lm === lm))
    }

    File.write!(#{inspect(receipt_path)}, Jason.encode!(payload))
    """

    {output, 0} =
      System.cmd("mix", ["run", "--no-compile", "--no-deps-check", "-e", code],
        cd: File.cwd!(),
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert output == ""

    assert %{
             "instructions" => [^selected_analyzer, ^selected_classifier],
             "route" => "R42",
             "runtime_preserved" => true
           } = Jason.decode!(File.read!(receipt_path))
  end

  test "artifact options reject unsupported or empty identities before evaluation" do
    owner = self()

    metric = fn _example, _prediction ->
      send(owner, :metric_called)
      1.0
    end

    optimizer = GEPA.new(metric, generations: 0)
    program = TwoStageOptimizerProgram.new(runtime_lm("runtime", "unused"))

    assert_raise ArgumentError, ~r/artifact_id.*non-empty string/, fn ->
      GEPA.compile_with_artifact(optimizer, program, [example()], [example()], artifact_id: "")
    end

    assert_raise ArgumentError, ~r/unknown options.*unknown/, fn ->
      GEPA.compile_with_artifact(optimizer, program, [example()], [example()], unknown: true)
    end

    refute_received :metric_called
  end

  test "released HoVer and Papillon graphs rebind task clients and judge in a fresh BEAM", %{
    root: root
  } do
    lm = released_task_lm("parent")
    retriever = released_hover_retriever("parent")
    hover = HoverMultiHop.from_retriever(lm, retriever)
    hover_example = hover_example()

    hover_metric =
      GepaMetrics.metric(%{"upstream_metric" => "hover_utils.discrete_retrieval_eval"})

    {_hover_selected, hover_report, hover_artifact} =
      GEPA.new(hover_metric, generations: 0)
      |> GEPA.compile_with_artifact(hover, [hover_example], [hover_example],
        artifact_id: "hover-readiness",
        provenance: %{authority: "gepa-artifact-cbefbc1"}
      )

    papillon = Papillon.new(released_untrusted_lm("parent"), lm: lm)
    papillon_example = papillon_example()
    papillon_metric = papillon_metric(released_judge_lm())

    {_papillon_selected, papillon_report, papillon_artifact} =
      GEPA.new(papillon_metric, generations: 0)
      |> GEPA.compile_with_artifact(papillon, [papillon_example], [papillon_example],
        artifact_id: "papillon-readiness",
        provenance: %{authority: "gepa-artifact-cbefbc1"}
      )

    for {report, artifact, id} <- [
          {hover_report, hover_artifact, "hover-readiness"},
          {papillon_report, papillon_artifact, "papillon-readiness"}
        ] do
      assert report.candidate_count == 1
      assert [%{id: "baseline", scores: [score], score: score}] = report.candidates
      assert report.metadata.metric_calls == 1

      assert %{champion_id: ^id, candidates: [%{"report" => saved_report}]} =
               Artifact.inspect(artifact)

      assert saved_report["candidate_count"] == 1
      assert Jason.encode!(saved_report) =~ "metric_calls"
    end

    hover_path = Path.join(root, "hover.json")
    papillon_path = Path.join(root, "papillon.json")
    receipt_path = Path.join(root, "released-task-receipt.json")
    :ok = Artifact.write!(hover_artifact, hover_path)
    :ok = Artifact.write!(papillon_artifact, papillon_path)

    code = """
    alias Imp.BenchmarkTruth.{GepaMetrics, HoverMultiHop, Papillon}
    alias Imp.Optimizer.Artifact

    lm = #{released_task_lm_source("fresh")}
    retriever = #{released_hover_retriever_source("fresh")}
    hover = HoverMultiHop.from_retriever(lm, retriever)
    hover = #{inspect(hover_path)} |> Artifact.read!() |> Artifact.apply(hover)
    {:ok, hover_prediction} = Imp.call(hover, %{claim: "Alpha connects to Gamma"})

    papillon = Papillon.new(#{released_untrusted_lm_source("fresh")}, lm: lm)
    papillon = #{inspect(papillon_path)} |> Artifact.read!() |> Artifact.apply(papillon)
    example = #{inspect(papillon_example)}
    {:ok, papillon_prediction} = Imp.call(papillon, Imp.Example.inputs(example) |> Imp.Example.to_map())
    judge = #{released_judge_lm_source()}
    metric = GepaMetrics.metric(%{"upstream_metric" => "papillon_utils.compute_overall_score"}, judge_lm: judge)
    score = Imp.Metrics.score(metric.(example, papillon_prediction))

    payload = %{
      hover_docs: Imp.get(hover_prediction, :retrieved_docs),
      papillon: Imp.Prediction.to_map(papillon_prediction),
      papillon_score: score,
      hover_runtime_preserved: Enum.all?(Imp.ProgramParameters.predictors(hover), &(&1.predictor.lm === lm)),
      papillon_runtime_preserved: Enum.all?(Imp.ProgramParameters.predictors(papillon), &(&1.predictor.lm === lm))
    }

    File.write!(#{inspect(receipt_path)}, Jason.encode!(payload))
    """

    {output, 0} =
      System.cmd("mix", ["run", "--no-compile", "--no-deps-check", "-e", code],
        cd: File.cwd!(),
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert output == ""

    receipt = Jason.decode!(File.read!(receipt_path))
    assert receipt["hover_runtime_preserved"]
    assert receipt["papillon_runtime_preserved"]
    assert receipt["papillon_score"] == 1.0
    assert receipt["papillon"]["llm_response"] == "fresh untrusted answer"
    assert Enum.all?(receipt["hover_docs"], &String.contains?(&1, "fresh"))
  end

  defp example do
    Imp.example(
      utterance: "I do not recognize this card payment",
      route: "R42"
    )
    |> Imp.with_inputs(:utterance)
  end

  defp runtime_lm(marker, selected_classifier) do
    Imp.LM.Static.new(
      runtime_marker: marker,
      handler: fn messages, _opts ->
        rendered = Enum.map_join(messages, "\n", & &1.content)

        if String.contains?(rendered, "`route`") do
          route = if String.contains?(rendered, selected_classifier), do: "R42", else: "R17"
          %{route: route}
        else
          %{evidence: "card payment was not recognized"}
        end
      end
    )
  end

  defp hover_example do
    Imp.example(claim: "Alpha connects to Gamma", supporting_facts: [%{key: "Gamma fresh"}])
    |> Imp.with_inputs(:claim)
  end

  defp papillon_example do
    Imp.example(
      user_query: "Help alice@example.com recover access",
      target_response: "Use the recovery form",
      pii_str: "alice@example.com"
    )
    |> Imp.with_inputs(:user_query)
  end

  defp papillon_metric(judge_lm) do
    GepaMetrics.metric(
      %{"upstream_metric" => "papillon_utils.compute_overall_score"},
      judge_lm: judge_lm
    )
  end

  defp released_task_lm(marker), do: Code.eval_string(released_task_lm_source(marker)) |> elem(0)

  defp released_task_lm_source(marker) do
    """
    Imp.LM.Static.new(handler: fn messages, _opts ->
      prompt = Enum.map_join(messages, "\\n", &to_string(&1.content))
      cond do
        String.contains?(prompt, "`summary`") -> %{reasoning: "#{marker}", summary: "#{marker} summary"}
        String.contains?(prompt, "`query`") -> %{reasoning: "#{marker}", query: "#{marker} query"}
        String.contains?(prompt, "`response`") -> %{response: "Use the recovery form"}
        true -> %{reasoning: "redact", llm_request: "recover access"}
      end
    end)
    """
  end

  defp released_untrusted_lm(marker),
    do: Code.eval_string(released_untrusted_lm_source(marker)) |> elem(0)

  defp released_untrusted_lm_source(marker) do
    "Imp.LM.Static.new(handler: fn _messages, _opts -> \"#{marker} untrusted answer\" end)"
  end

  defp released_judge_lm, do: Code.eval_string(released_judge_lm_source()) |> elem(0)

  defp released_judge_lm_source do
    """
    Imp.LM.Static.new(handler: fn messages, _opts ->
      prompt = Enum.map_join(messages, "\\n", &to_string(&1.content))
      if String.contains?(prompt, "num_pii_leaked"),
        do: %{reasoning: "none", num_pii_leaked: 0},
        else: %{reasoning: "equivalent", judgment: true}
    end)
    """
  end

  defp released_hover_retriever(marker),
    do: Code.eval_string(released_hover_retriever_source(marker)) |> elem(0)

  defp released_hover_retriever_source(marker) do
    """
    fn _query, _opts ->
      {:ok, [
        %{title: "Alpha #{marker}", text: "one"},
        %{title: "Beta #{marker}", text: "two"},
        %{title: "Gamma #{marker}", text: "three"}
      ]}
    end
    """
  end
end
