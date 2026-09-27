defmodule Imp.ExampleInputsDeclaredTest do
  use ExUnit.Case, async: true

  @moduledoc """
  An example that never declared its inputs cannot say which fields are
  labels, so asking for its inputs is an error rather than a view that hands
  the labels to the program. Evaluation, experiments and every optimizer that
  runs a program on examples refuse such a dataset before any model call.
  """

  @undeclared ~r/Imp\.with_inputs\/2/

  defp undeclared_rows do
    for index <- 1..2, do: Imp.example(question: "question #{index}", answer: "secret")
  end

  defp declared_rows, do: Enum.map(undeclared_rows(), &Imp.with_inputs(&1, :question))

  # Every model in these tests reports each call, so a test can show that a
  # refused dataset cost no call at all.
  defp counting_lm(owner, response) do
    Imp.LM.Static.new(
      handler: fn _messages, _opts ->
        send(owner, :lm_call)
        response
      end
    )
  end

  defp program(owner),
    do: Imp.predict("question -> answer", lm: counting_lm(owner, %{answer: "secret"}))

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
      plain = Enum.map(undeclared_rows(), &Imp.Example.to_map/1)

      for num_threads <- [1, 2], rows <- [undeclared_rows(), plain] do
        assert_raise ArgumentError, @undeclared, fn ->
          Imp.evaluate(program(self()), rows, Imp.exact_match(:answer), num_threads: num_threads)
        end
      end

      refute_received :lm_call
    end

    test "the error names the function called and the row, and no field values" do
      [declared, _declared] = declared_rows()
      [_undeclared, undeclared] = undeclared_rows()

      error =
        assert_raise ArgumentError, fn ->
          Imp.evaluate(program(self()), [declared, undeclared], Imp.exact_match(:answer))
        end

      assert Exception.message(error) =~ "Imp.evaluate/4: devset row 1 does not declare"
      refute Exception.message(error) =~ "secret"

      error =
        assert_raise ArgumentError, fn ->
          [declared, %{question: "private question", answer: "secret"}]
          |> Imp.Evaluate.new(Imp.exact_match(:answer))
          |> Imp.Evaluate.run(program(self()))
        end

      assert Exception.message(error) =~ "Imp.Evaluate.run/2: devset row 1 is a plain map"
      assert Exception.message(error) =~ "[:answer, :question]"
      refute Exception.message(error) =~ "secret"
      refute Exception.message(error) =~ "private question"
    end

    test "enumerates a lazy devset once" do
      owner = self()
      devset = Stream.map(declared_rows(), fn row -> send(owner, :row_produced) && row end)

      assert Imp.evaluate(program(owner), devset, Imp.exact_match(:answer)).score == 1.0
      assert_received :row_produced
      assert_received :row_produced
      refute_received :row_produced
    end

    test "evaluates every row of a one-shot stream" do
      rows =
        for index <- 1..3,
            do: Imp.example(question: "q#{index}", answer: "secret") |> Imp.with_inputs(:question)

      {:ok, agent} = Agent.start_link(fn -> rows end)

      one_shot =
        Stream.resource(
          fn -> agent end,
          fn agent ->
            case Agent.get_and_update(agent, fn rows -> {rows, []} end) do
              [] -> {:halt, agent}
              rows -> {rows, agent}
            end
          end,
          fn _agent -> :ok end
        )

      result = Imp.evaluate(program(self()), one_shot, Imp.exact_match(:answer))
      assert length(result.rows) == 3
      assert result.score == 1.0
    end
  end

  test "Imp.Experiment.Data refuses rows that cannot declare inputs" do
    [declared, other] = declared_rows()

    error =
      assert_raise ArgumentError, fn ->
        Imp.Experiment.Data.new(
          train: [declared],
          selection: [%{question: "private question", answer: "secret"}],
          test: [other]
        )
      end

    assert Exception.message(error) =~ "Imp.Experiment.Data.new/1: selection row 0 is a plain map"
    refute Exception.message(error) =~ "secret"

    [undeclared, _undeclared] = undeclared_rows()

    assert_raise ArgumentError, ~r/test row 0 does not declare its inputs/, fn ->
      Imp.Experiment.Data.new(train: [declared], selection: [other], test: [undeclared])
    end
  end

  describe "optimizers" do
    # {name, optimizer, program builder, datasets it takes}
    defp optimizers(owner) do
      metric = Imp.exact_match(:answer)
      lm = &counting_lm(owner, &1)
      predict = fn -> program(owner) end

      avatar = fn ->
        Imp.avatar("question -> answer", [Imp.tool(:lookup, "Look up", fn _ -> "x" end)],
          lm: lm.(%{action: %{tool_name: "Finish", tool_input_query: %{}}, answer: "secret"}),
          max_iters: 2
        )
      end

      [
        {"BootstrapFewShot", Imp.Optimizer.BootstrapFewShot.new(metric), predict, [:trainset]},
        {"BootstrapFewShotWithRandomSearch",
         Imp.Optimizer.BootstrapFewShotWithRandomSearch.new(metric,
           num_candidate_programs: 1,
           max_bootstrapped_demos: 1,
           max_labeled_demos: 0
         ), predict, [:trainset, :valset]},
        {"COPRO",
         Imp.Optimizer.COPRO.new(metric,
           breadth: 2,
           depth: 1,
           proposer_lm:
             lm.(
               Jason.encode!(%{
                 "proposed_instruction" => "Answer.",
                 "proposed_prefix_for_output_field" => "Answer:"
               })
             )
         ), predict, [:trainset]},
        {"MIPROv2",
         Imp.Optimizer.MIPROv2.new(metric,
           auto: nil,
           num_candidates: 2,
           num_trials: 2,
           max_bootstrapped_demos: 0,
           max_labeled_demos: 0,
           minibatch: false,
           startup_trials: 1,
           prompt_lm: lm.(%{"instructions" => ["Answer."]})
         ), predict, [:trainset, :valset]},
        {"SIMBA",
         Imp.Optimizer.SIMBA.new(metric,
           bsize: 2,
           num_candidates: 2,
           max_steps: 1,
           max_demos: 0,
           seed: 11,
           prompt_lm: lm.(%{discussion: "ok", module_advice: %{main: "Answer."}})
         ), predict, [:trainset]},
        {"GEPA",
         Imp.Optimizer.GEPA.new(metric,
           generations: 1,
           minibatch_size: 2,
           seed: 11,
           reflection_lm: lm.(%{instruction: "Answer."})
         ), predict, [:trainset, :valset]},
        {"GEPA",
         Imp.Optimizer.GEPA.new(metric,
           execution_profile: :beam_native,
           generations: 1,
           minibatch_size: 2,
           seed: 11,
           reflection_lm: lm.(%{instruction: "Answer."})
         ), predict, [:trainset, :valset]},
        {"InferRules",
         Imp.Optimizer.InferRules.new(metric,
           num_candidates: 1,
           num_rules: 1,
           max_bootstrapped_demos: 0,
           max_labeled_demos: 0,
           rule_lm: lm.(%{reasoning: "ok", natural_language_rules: "Answer."})
         ), predict, [:trainset, :valset]},
        {"SignatureOptimizer",
         Imp.Optimizer.SignatureOptimizer.new(metric, candidates: ["Answer."]), predict,
         [:trainset, :valset]},
        {"BetterTogether",
         Imp.Optimizer.BetterTogether.new(metric, %{p: Imp.Optimizer.BootstrapFewShot.new(metric)}),
         predict, [:trainset, :valset]},
        {"Avatar",
         Imp.Optimizer.Avatar.new(metric,
           max_iters: 1,
           comparator_lm: lm.(%{feedback: "f"}),
           rewrite_lm: lm.(%{new_instruction: "n"})
         ), avatar, [:trainset]}
      ]
    end

    defp optimize(optimizer, program, datasets, trainset, valset) do
      if :valset in datasets,
        do: Imp.optimize!(program, optimizer, trainset, valset),
        else: Imp.optimize!(program, optimizer, trainset)
    end

    test "refuse each dataset without declared inputs before any model call" do
      for {name, optimizer, program, datasets} <- optimizers(self()),
          undeclared <- datasets do
        {trainset, valset} =
          if undeclared == :trainset,
            do: {undeclared_rows(), declared_rows()},
            else: {declared_rows(), undeclared_rows()}

        try do
          optimize(optimizer, program.(), datasets, trainset, valset)
          flunk("#{name} ran with an undeclared #{undeclared}")
        rescue
          error in ArgumentError ->
            message = Exception.message(error)
            assert message =~ "Imp.Optimizer.#{name}.compile: ", "#{name}: #{message}"
            assert message =~ "row 0 does not declare its inputs", "#{name}: #{message}"
        end

        refute_received :lm_call, "#{name} called a model before refusing its #{undeclared}"
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

      assert Exception.message(error) =~ "Imp.Optimizer.GRPO.compile: trainset row 0"
      assert Imp.Test.FileGRPOTrainer.events(root) == []
      refute_received :lm_call
    end

    test "InstructionSearch refuses a devset without declared inputs before any model call" do
      assert_raise ArgumentError,
                   ~r/Imp\.Optimizer\.InstructionSearch\.compile: devset row 0 does not declare/,
                   fn ->
                     Imp.Optimizer.InstructionSearch.compile(
                       program(self()),
                       Imp.exact_match(:answer),
                       declared_rows(),
                       undeclared_rows(),
                       ["Answer."]
                     )
                   end

      refute_received :lm_call
    end

    test "BootstrapFinetune returns the refusal as its error before any model call" do
      assert %{error: {:bootstrap_finetune_prepare_failed, message}} =
               Imp.Optimizer.BootstrapFinetune.new(Imp.exact_match(:answer))
               |> Imp.Optimizer.BootstrapFinetune.compile(program(self()), undeclared_rows())

      assert message =~ "Imp.Optimizer.BootstrapFinetune.compile: trainset row 0"
      refute_received :lm_call
    end

    test "run when the same rows declare their inputs" do
      for {name, optimizer, program, datasets} <- optimizers(self()) do
        compiled = optimize(optimizer, program.(), datasets, declared_rows(), declared_rows())
        assert {:ok, _prediction} = Imp.call(compiled, %{question: "q"}), name
      end
    end
  end
end
