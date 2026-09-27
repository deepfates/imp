defmodule Imp.ExampleInputsDeclaredTest do
  use ExUnit.Case, async: true

  @moduledoc """
  An example that never declared its inputs cannot say which fields are
  labels, so asking for its inputs is an error rather than a view that hands
  the labels to the program. Evaluation and every optimizer that runs a
  program on examples surface that error instead of scoring on leaked labels.
  """

  @undeclared ~r/Imp\.with_inputs\/2/

  defp undeclared_rows do
    for index <- 1..2, do: Imp.example(question: "question #{index}", answer: "secret")
  end

  defp declared_rows, do: Enum.map(undeclared_rows(), &Imp.with_inputs(&1, :question))

  # The program reports every input map it is called with, so a test can show
  # that no call carried the label.
  defp program(owner) do
    Imp.predict("question -> answer",
      lm:
        Imp.LM.Static.new(
          handler: fn messages, _opts ->
            send(owner, {:lm_prompt, Enum.map_join(messages, "\n", & &1.content)})
            %{answer: "secret"}
          end
        )
    )
  end

  defp prompt_lm(response), do: Imp.LM.Static.new(handler: fn _messages, _opts -> response end)

  defp refute_label_reached_program do
    receive do
      {:lm_prompt, prompt} ->
        refute prompt =~ "secret"
        refute_label_reached_program()
    after
      0 -> :ok
    end
  end

  describe "Imp.Example" do
    test "inputs and labels raise until inputs are declared" do
      example = Imp.example(question: "2+2?", answer: "4")

      assert_raise ArgumentError, @undeclared, fn -> Imp.Example.inputs(example) end
      assert_raise ArgumentError, @undeclared, fn -> Imp.Example.labels(example) end

      declared = Imp.with_inputs(example, :question)
      assert Imp.Example.to_map(Imp.Example.inputs(declared)) == %{question: "2+2?"}
      assert Imp.Example.to_map(Imp.Example.labels(declared)) == %{answer: "4"}
    end

    test "a field given as both an atom and a string is refused" do
      assert_raise ArgumentError, ~r/"answer" more than once/, fn ->
        Imp.Example.new(%{"answer" => "4", answer: "5"})
      end

      assert_raise ArgumentError, ~r/"answer" more than once/, fn ->
        Imp.Example.new([{"answer", "4"}, {:answer, "5"}])
      end

      assert_raise ArgumentError, ~r/"answer" more than once/, fn ->
        Imp.Example.new(answer: "4", answer: "5")
      end
    end
  end

  test "Imp.Signature.new applies new instructions to an existing signature" do
    signature = Imp.Signature.new("question -> answer", "OLD")

    assert Imp.Signature.new(signature, "NEW").instructions == "NEW"
    assert Imp.signature(signature, "NEW").instructions == "NEW"
    assert Imp.Signature.new(signature).instructions == "OLD"
  end

  describe "Imp.evaluate" do
    test "raises before calling the program" do
      for num_threads <- [1, 2],
          rows <- [undeclared_rows(), Enum.map(undeclared_rows(), &Imp.Example.to_map/1)] do
        assert_raise ArgumentError, @undeclared, fn ->
          Imp.evaluate(program(self()), rows, Imp.exact_match(:answer), num_threads: num_threads)
        end
      end

      refute_received {:lm_prompt, _prompt}
    end
  end

  describe "optimizers" do
    defp optimizers do
      metric = Imp.exact_match(:answer)

      [
        bootstrap_few_shot: {Imp.Optimizer.BootstrapFewShot.new(metric), false},
        random_search:
          {Imp.Optimizer.BootstrapFewShotWithRandomSearch.new(metric,
             num_candidate_programs: 1,
             max_bootstrapped_demos: 1,
             max_labeled_demos: 0
           ), false},
        copro:
          {Imp.Optimizer.COPRO.new(metric,
             breadth: 2,
             depth: 1,
             proposer_lm:
               prompt_lm(
                 Jason.encode!(%{
                   "proposed_instruction" => "Answer.",
                   "proposed_prefix_for_output_field" => "Answer:"
                 })
               )
           ), false},
        mipro_v2:
          {Imp.Optimizer.MIPROv2.new(metric,
             auto: nil,
             num_candidates: 2,
             num_trials: 2,
             max_bootstrapped_demos: 0,
             max_labeled_demos: 0,
             minibatch: false,
             startup_trials: 1,
             prompt_lm: prompt_lm(%{"instructions" => ["Answer."]})
           ), true},
        simba:
          {Imp.Optimizer.SIMBA.new(metric,
             bsize: 2,
             num_candidates: 2,
             max_steps: 1,
             max_demos: 0,
             seed: 11,
             prompt_lm: prompt_lm(%{discussion: "ok", module_advice: %{main: "Answer."}})
           ), false},
        gepa:
          {Imp.Optimizer.GEPA.new(metric,
             generations: 1,
             minibatch_size: 2,
             seed: 11,
             reflection_lm: prompt_lm(%{instruction: "Answer."})
           ), true},
        infer_rules:
          {Imp.Optimizer.InferRules.new(metric,
             num_candidates: 1,
             num_rules: 1,
             max_bootstrapped_demos: 0,
             max_labeled_demos: 0,
             rule_lm: prompt_lm(%{reasoning: "ok", natural_language_rules: "Answer."})
           ), false},
        signature_optimizer:
          {Imp.Optimizer.SignatureOptimizer.new(metric, candidates: ["Answer."]), true}
      ]
    end

    test "raise instead of scoring on leaked labels" do
      for {family, {optimizer, needs_validation?}} <- optimizers() do
        run = fn ->
          if needs_validation?,
            do: Imp.optimize!(program(self()), optimizer, undeclared_rows(), undeclared_rows()),
            else: Imp.optimize!(program(self()), optimizer, undeclared_rows())
        end

        try do
          run.()
          flunk("#{family} ran on examples without declared inputs")
        rescue
          error in ArgumentError ->
            assert Exception.message(error) =~ @undeclared,
                   "#{family}: #{Exception.message(error)}"
        end

        refute_label_reached_program()
      end
    end

    @tag :tmp_dir
    test "GRPO refuses before the trainer starts", %{tmp_dir: root} do
      optimizer =
        Imp.Optimizer.GRPO.new(fn _example, _prediction -> 1.0 end,
          trainer: %Imp.Test.FileGRPOTrainer{root: root, runtime_mode: :normal},
          num_train_steps: 1
        )

      assert {:error, {:optimizer_failed, Imp.Optimizer.GRPO, %ArgumentError{} = error}} =
               Imp.train(program(self()), optimizer, undeclared_rows())

      assert Exception.message(error) =~ @undeclared
      assert Imp.Test.FileGRPOTrainer.events(root) == []
      refute_received {:lm_prompt, _prompt}
    end

    test "run when the same rows declare their inputs" do
      for {family, {optimizer, needs_validation?}} <- optimizers() do
        compiled =
          if needs_validation?,
            do: Imp.optimize!(program(self()), optimizer, declared_rows(), declared_rows()),
            else: Imp.optimize!(program(self()), optimizer, declared_rows())

        assert {:ok, _prediction} = Imp.call(compiled, %{question: "q"}), "#{family}"
      end
    end
  end
end
