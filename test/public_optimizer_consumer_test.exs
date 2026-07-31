defmodule Imp.PublicOptimizerConsumerTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Provider-free public-facade coverage for optimizers advertised to ordinary
  Imp consumers. The distinct test rows are exercised only after compilation;
  this is an execution contract, not optimizer-effectiveness evidence.
  """

  defp metric, do: Imp.exact_match(:answer)

  defp program do
    Imp.predict("question -> answer",
      lm:
        Imp.LM.Static.new(
          handler: fn messages, opts ->
            prompt = Enum.map_join(messages, "\n", & &1.content)
            rollout_id = Keyword.get(opts, :rollout_id, -1)

            if prompt =~ "Answer consistently." or
                 (rollout_id >= 0 and rem(rollout_id, 2) == 0),
               do: %{answer: "yes"},
               else: %{answer: "unknown"}
          end
        )
    )
  end

  defp rows(prefix) do
    for index <- 1..2 do
      Imp.example(question: "#{prefix} question #{index}", answer: "yes")
      |> Imp.with_inputs(:question)
    end
  end

  defp prompt_lm(response) do
    Imp.LM.Static.new(handler: fn _messages, _opts -> response end)
  end

  defp optimizers do
    [
      copro:
        Imp.Optimizer.COPRO.new(metric(),
          breadth: 2,
          depth: 1,
          proposer_lm:
            prompt_lm(
              Jason.encode!(%{
                "proposed_instruction" => "Answer consistently.",
                "proposed_prefix_for_output_field" => "Answer:"
              })
            )
        ),
      mipro_v2:
        Imp.Optimizer.MIPROv2.new(metric(),
          auto: nil,
          num_candidates: 2,
          num_trials: 4,
          max_bootstrapped_demos: 0,
          max_labeled_demos: 0,
          minibatch: false,
          startup_trials: 1,
          prompt_lm: prompt_lm(%{"instructions" => ["Answer consistently."]})
        ),
      simba:
        Imp.Optimizer.SIMBA.new(metric(),
          bsize: 2,
          num_candidates: 2,
          max_steps: 1,
          max_demos: 0,
          seed: 11,
          prompt_lm:
            prompt_lm(%{
              discussion: "Keep the successful behavior.",
              module_advice: %{main: "Answer consistently."}
            })
        ),
      gepa:
        Imp.Optimizer.GEPA.new(metric(),
          generations: 1,
          minibatch_size: 2,
          seed: 11,
          reflection_lm: prompt_lm(%{instruction: "Answer consistently."})
        ),
      infer_rules:
        Imp.Optimizer.InferRules.new(metric(),
          num_candidates: 1,
          num_rules: 1,
          max_bootstrapped_demos: 0,
          max_labeled_demos: 0,
          rule_lm:
            prompt_lm(%{
              reasoning: "The outputs are consistent.",
              natural_language_rules: "Answer consistently."
            })
        )
    ]
  end

  @tag :tmp_dir
  test "advertised instruction optimizers compile and remain callable through public Imp APIs", %{
    tmp_dir: tmp_dir
  } do
    trainset = rows("train")
    selection_set = rows("selection")
    testset = rows("test")

    assert Imp.evaluate(program(), testset, metric()).score == 0.0

    for {family, optimizer} <- optimizers() do
      compiled = Imp.optimize!(program(), optimizer, trainset, selection_set)

      assert %Imp.Optimizer.Report{optimizer: ^family} =
               Imp.Optimizer.Report.fetch(compiled)

      assert {:ok, prediction} = Imp.call(compiled, %{question: "test call"})

      assert Imp.get(prediction, :answer) == "yes",
             "#{family} did not return the scripted candidate"

      assert Imp.evaluate(compiled, testset, metric()).score == 1.0,
             "#{family} did not remain executable on distinct test rows"

      if family in [:mipro_v2, :simba, :gepa] do
        artifact_path = Path.join(tmp_dir, "#{family}.json")

        compiled
        |> Imp.Optimizer.Artifact.from_optimized_program(artifact_id: "public-#{family}-selected")
        |> Imp.Optimizer.Artifact.write!(artifact_path)

        deployed =
          artifact_path
          |> Imp.Optimizer.Artifact.read!()
          |> Imp.Optimizer.Artifact.apply(program())

        deployed_report = Imp.Optimizer.Report.fetch(deployed)
        assert to_string(deployed_report.optimizer) == Atom.to_string(family)

        assert {:ok, prediction} = Imp.call(deployed, %{question: "fresh consumer call"})
        assert Imp.get(prediction, :answer) == "yes"
        assert Imp.evaluate(deployed, testset, metric()).score == 1.0
      end
    end
  end

  test "GEPA and COPRO refuse optimization without a real proposal source" do
    trainset = rows("train")
    selection_set = rows("selection")

    assert_raise ArgumentError,
                 ~r/GEPA optimization requires :reflection_lm or :reflection_strategy/,
                 fn ->
                   Imp.optimize!(
                     program(),
                     Imp.Optimizer.GEPA.new(metric(), generations: 1),
                     trainset,
                     selection_set
                   )
                 end

    assert_raise ArgumentError, ~r/COPRO requires :proposer_lm or an Imp settings :lm/, fn ->
      Imp.context([lm: nil], fn ->
        Imp.optimize!(
          program(),
          Imp.Optimizer.COPRO.new(metric(), breadth: 2, depth: 1),
          trainset,
          selection_set
        )
      end)
    end
  end
end
