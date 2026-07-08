defmodule OptimizerReportTest do
  use ExUnit.Case

  defmodule ErrorOptimizer do
    defstruct []

    def compile(%__MODULE__{}, _program, _trainset, _devset), do: {:error, :optimizer_declined}
  end

  defp lm do
    %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn messages, _opts ->
          prompt = Enum.map_join(messages, "\n", & &1.content)

          if prompt =~ "[[ ## answer ## ]]\nParis" or prompt =~ "Always answer Paris",
            do: %{answer: "Paris"},
            else: %{answer: "unknown"}
        end
      ]
    }
  end

  defp sets do
    train = [
      DSEx.example(question: "France capital?", answer: "Paris")
      |> DSEx.Example.with_inputs(:question)
    ]

    dev = [
      DSEx.example(question: "Capital of France?", answer: "Paris")
      |> DSEx.Example.with_inputs(:question)
    ]

    {train, dev}
  end

  test "random search attaches candidate history and best score" do
    {train, dev} = sets()
    metric = DSEx.Metrics.exact_match(:answer)
    program = DSEx.predict("question -> answer", lm: lm())

    compiled =
      metric
      |> DSEx.Optimizer.RandomSearch.new(candidates: 3, demos_per_candidate: 1)
      |> DSEx.Optimizer.RandomSearch.compile(program, train, dev)

    report = DSEx.Optimizer.Report.fetch(compiled)

    assert %DSEx.Optimizer.Report{
             optimizer: :random_search,
             best_score: 1.0,
             candidate_count: 3
           } =
             report

    assert Enum.all?(report.candidates, &Map.has_key?(&1, :score))
  end

  test "labeled few-shot reports selected demonstrations without scoring them" do
    {train, _dev} = sets()
    program = DSEx.predict("question -> answer", lm: lm())

    compiled =
      DSEx.Optimizer.LabeledFewShot.new(k: 1)
      |> DSEx.Optimizer.LabeledFewShot.compile(program, train)

    report = DSEx.Optimizer.Report.fetch(compiled)

    assert report.optimizer == :labeled_few_shot
    assert report.best_score == nil
    assert report.candidate_count == 1
    assert report.metadata.requested_k == 1
    assert report.metadata.selected_count == 1
    assert [%{index: 0, selected?: true, example: example}] = report.candidates
    assert DSEx.Example.get(example, :answer) == "Paris"
    assert length(compiled.demos) == 1
  end

  test "few-shot optimizers attach demos through wrapper programs" do
    {train, _dev} = sets()

    pot =
      "question -> answer"
      |> DSEx.program_of_thought()
      |> then(
        &DSEx.Optimizer.LabeledFewShot.compile(DSEx.Optimizer.LabeledFewShot.new(k: 1), &1, train)
      )

    assert [%DSEx.Example{}] = pot.predict.demos
    assert DSEx.Optimizer.Report.fetch(pot).optimizer == :labeled_few_shot

    code_act =
      "question -> answer"
      |> DSEx.code_act()
      |> then(
        &DSEx.Optimizer.LabeledFewShot.compile(DSEx.Optimizer.LabeledFewShot.new(k: 1), &1, train)
      )

    assert [%DSEx.Example{}] = code_act.program_of_thought.predict.demos
    assert DSEx.Optimizer.Report.fetch(code_act).optimizer == :labeled_few_shot

    rag =
      "question, context -> answer"
      |> DSEx.predict()
      |> DSEx.rag(DSEx.Retrieve.Memory.new([%{text: "France: Paris."}]))
      |> then(
        &DSEx.Optimizer.LabeledFewShot.compile(DSEx.Optimizer.LabeledFewShot.new(k: 1), &1, train)
      )

    assert [%DSEx.Example{}] = rag.program.demos
    assert DSEx.Optimizer.Report.fetch(rag).optimizer == :labeled_few_shot
  end

  test "instruction search helpers traverse wrapper programs" do
    pot =
      "question -> answer"
      |> DSEx.program_of_thought()
      |> DSEx.Optimizer.InstructionSearch.put_instruction("Answer briefly.")

    assert DSEx.Optimizer.InstructionSearch.current_instruction(pot) == "Answer briefly."
    assert pot.signature.instructions == "Answer briefly."
    assert pot.predict.signature.instructions == "Answer briefly."

    code_act =
      "question -> answer"
      |> DSEx.code_act()
      |> DSEx.Optimizer.InstructionSearch.put_instruction("Use code sparingly.")

    assert DSEx.Optimizer.InstructionSearch.current_instruction(code_act) == "Use code sparingly."
    assert code_act.program_of_thought.signature.instructions == "Use code sparingly."
    assert code_act.program_of_thought.predict.signature.instructions == "Use code sparingly."

    rag =
      "question, context -> answer"
      |> DSEx.predict()
      |> DSEx.rag(DSEx.Retrieve.Memory.new([%{text: "France: Paris."}]))
      |> DSEx.Optimizer.InstructionSearch.put_instruction("Use retrieved context.")

    assert DSEx.Optimizer.InstructionSearch.current_instruction(rag) == "Use retrieved context."
    assert rag.program.signature.instructions == "Use retrieved context."
  end

  test "instruction search updates wrapper task signatures as well as LM signatures" do
    pot =
      "x, context -> doubled"
      |> DSEx.program_of_thought(output_field: :doubled)
      |> DSEx.rag(DSEx.Retrieve.Memory.new([%{text: "double x"}]))
      |> DSEx.Optimizer.InstructionSearch.put_instruction("Double with retrieved context.")

    assert pot
           |> DSEx.ProgramAccess.task_signature()
           |> Map.fetch!(:instructions) == "Double with retrieved context."

    assert pot
           |> DSEx.ProgramAccess.lm_signature()
           |> Map.fetch!(:instructions) == "Double with retrieved context."

    assert "x, context -> doubled" =
             pot
             |> DSEx.ProgramAccess.task_signature()
             |> DSEx.Signature.to_spec()

    assert "x, context -> program, tool, arguments" =
             pot
             |> DSEx.ProgramAccess.lm_signature()
             |> DSEx.Signature.to_spec()
  end

  test "optimizer reports attach and fetch through wrapper programs" do
    report = DSEx.Optimizer.Report.new(%{optimizer: :wrapper_probe, metadata: %{status: :ok}})

    pot = DSEx.program_of_thought("question -> answer")
    pot = DSEx.Optimizer.Report.attach(pot, report)
    assert DSEx.Optimizer.Report.fetch(pot).optimizer == :wrapper_probe
    assert pot.predict.metadata.optimizer_report.metadata.status == :ok

    code_act = DSEx.code_act("question -> answer")
    code_act = DSEx.Optimizer.Report.attach(code_act, report)
    assert DSEx.Optimizer.Report.fetch(code_act).optimizer == :wrapper_probe
    assert code_act.program_of_thought.predict.metadata.optimizer_report.metadata.status == :ok

    rag =
      "question, context -> answer"
      |> DSEx.predict()
      |> DSEx.rag(DSEx.Retrieve.Memory.new([%{text: "France: Paris."}]))
      |> DSEx.Optimizer.Report.attach(report)

    assert DSEx.Optimizer.Report.fetch(rag).optimizer == :wrapper_probe
    assert rag.program.metadata.optimizer_report.metadata.status == :ok
  end

  test "optimizer reports serialize with embedded examples and restore as reports" do
    {train, _dev} = sets()

    report =
      DSEx.Optimizer.Report.new(%{
        optimizer: :labeled_few_shot,
        candidate_count: 1,
        candidates: [%{index: 0, selected?: true, example: hd(train)}],
        metadata: %{status: :ok, note: "keep strings as strings"}
      })

    restored =
      report
      |> DSEx.Optimizer.Report.json_safe()
      |> Jason.encode!()
      |> Jason.decode!()
      |> DSEx.Optimizer.Report.restore_json_safe()

    assert %DSEx.Optimizer.Report{} = restored
    assert restored.optimizer == :labeled_few_shot
    assert restored.metadata.status == :ok
    assert restored.metadata.note == "keep strings as strings"
    assert [%{example: example, selected?: true}] = restored.candidates
    assert %DSEx.Example{} = example
    assert DSEx.Example.get(example, :question) == "France capital?"
    assert DSEx.Example.inputs(example).fields == %{question: "France capital?"}
  end

  test "labeled few-shot reports trainset enumeration failures" do
    program = DSEx.predict("question -> answer", lm: lm())

    compiled =
      DSEx.Optimizer.LabeledFewShot.new(k: 1)
      |> DSEx.Optimizer.LabeledFewShot.compile(program, :not_an_enumerable_trainset)

    report = DSEx.Optimizer.Report.fetch(compiled)

    assert report.optimizer == :labeled_few_shot
    assert report.candidate_count == 0
    assert report.candidates == []
    assert [%{stage: :trainset, reason: reason}] = report.errors
    assert String.contains?(reason, "Enumerable")
    assert compiled.demos == []
  end

  test "labeled few-shot preserves existing demos when trainset enumeration fails" do
    {train, _dev} = sets()
    [existing_demo] = train

    program =
      "question -> answer"
      |> DSEx.predict(lm: lm())
      |> DSEx.Predict.Predict.with_demos([existing_demo])

    compiled =
      DSEx.Optimizer.LabeledFewShot.new(k: 1)
      |> DSEx.Optimizer.LabeledFewShot.compile(program, :not_an_enumerable_trainset)

    report = DSEx.Optimizer.Report.fetch(compiled)

    assert compiled.demos == [existing_demo]
    assert report.metadata.status == :trainset_error
    assert report.metadata.selected_count == 0
    assert [%{stage: :trainset, reason: reason}] = report.errors
    assert String.contains?(reason, "Enumerable")
  end

  test "random search treats zero requested trials as a baseline-only compile" do
    {train, dev} = sets()
    metric = DSEx.Metrics.exact_match(:answer)
    program = DSEx.predict("question -> answer", lm: lm())

    compiled =
      metric
      |> DSEx.Optimizer.RandomSearch.new(candidates: 0, demos_per_candidate: 1)
      |> DSEx.Optimizer.RandomSearch.compile(program, train, dev)

    report = DSEx.Optimizer.Report.fetch(compiled)

    assert report.optimizer == :random_search
    assert report.best_score == 0.0
    assert report.candidate_count == 0
    assert report.errors == []
    assert report.metadata.baseline_score == 0.0
    assert Enum.map(report.candidates, & &1.index) == [:baseline]
  end

  test "optimizer constructors reject invalid option containers at the boundary" do
    metric = DSEx.Metrics.exact_match(:answer)

    assert_raise ArgumentError,
                 ~r/DSEx\.Optimizer\.LabeledFewShot\.new\/1: expected keyword options/,
                 fn ->
                   DSEx.Optimizer.LabeledFewShot.new(%{k: 1})
                 end

    assert_raise ArgumentError,
                 ~r/DSEx\.Optimizer\.RandomSearch\.new\/2: expected keyword options/,
                 fn ->
                   DSEx.Optimizer.RandomSearch.new(metric, %{candidates: 1})
                 end

    assert_raise ArgumentError,
                 ~r/DSEx\.Optimizer\.BootstrapFewShot\.new\/2: expected keyword options/,
                 fn ->
                   DSEx.Optimizer.BootstrapFewShot.new(metric, %{max_bootstrapped_demos: 1})
                 end

    assert_raise ArgumentError,
                 ~r/DSEx\.Optimizer\.LabeledFewShot\.new\/1: invalid value for :k option: expected non negative integer/,
                 fn ->
                   DSEx.Optimizer.LabeledFewShot.new(k: -1)
                 end

    assert_raise ArgumentError,
                 ~r/DSEx\.Optimizer\.RandomSearch\.new\/2: invalid value for :candidates option: expected non negative integer/,
                 fn ->
                   DSEx.Optimizer.RandomSearch.new(metric, candidates: -1)
                 end

    assert_raise ArgumentError,
                 ~r/DSEx\.Optimizer\.RandomSearch\.new\/2: invalid value for :demos_per_candidate option: expected non negative integer/,
                 fn ->
                   DSEx.Optimizer.RandomSearch.new(metric, demos_per_candidate: -1)
                 end

    assert_raise ArgumentError,
                 ~r/DSEx\.Optimizer\.BootstrapFewShot\.new\/2: invalid value for :max_bootstrapped_demos option: expected non negative integer/,
                 fn ->
                   DSEx.Optimizer.BootstrapFewShot.new(metric, max_bootstrapped_demos: -1)
                 end

    assert_raise ArgumentError,
                 ~r/DSEx\.Optimizer\.KNNFewShot\.new\/3: expected keyword options/,
                 fn ->
                   DSEx.Optimizer.KNNFewShot.new(1, [], %{field: :question})
                 end
  end

  test "search optimizer constructors reject invalid metric callbacks at the boundary" do
    assert_raise ArgumentError,
                 ~r/DSEx\.Optimizer\.RandomSearch\.new\/2 expects a metric function with arity 2 or 3/,
                 fn ->
                   DSEx.Optimizer.RandomSearch.new(fn _example -> true end)
                 end

    assert_raise ArgumentError,
                 ~r/DSEx\.Optimizer\.BootstrapFewShot\.new\/2 expects a metric function with arity 2/,
                 fn ->
                   DSEx.Optimizer.BootstrapFewShot.new(fn _example, _prediction, _trace ->
                     true
                   end)
                 end
  end

  test "random search returns the original program with diagnostics when all trials fail" do
    {train, _dev} = sets()
    metric = DSEx.Metrics.exact_match(:answer)
    program = DSEx.predict("question -> answer", lm: lm())

    compiled =
      metric
      |> DSEx.Optimizer.RandomSearch.new(candidates: 2, demos_per_candidate: 1)
      |> DSEx.Optimizer.RandomSearch.compile(program, train, :not_an_enumerable_devset)

    report = DSEx.Optimizer.Report.fetch(compiled)

    assert report.optimizer == :random_search
    assert report.best_score == nil
    assert report.candidate_count == 0
    assert report.candidates == []
    assert report.metadata.status == :all_candidates_failed
    assert length(report.errors) == 3
    assert Enum.map(report.errors, & &1.metadata.index) == [1, 2, :baseline]
    assert Enum.all?(report.errors, &String.contains?(&1.error, "Enumerable"))
  end

  test "bootstrap few-shot reports selected and rejected train examples" do
    {train, _dev} = sets()
    metric = DSEx.Metrics.exact_match(:answer)
    program = DSEx.predict("question -> answer", lm: lm())

    compiled =
      metric
      |> DSEx.Optimizer.BootstrapFewShot.new(max_bootstrapped_demos: 1)
      |> DSEx.Optimizer.BootstrapFewShot.compile(program, train)

    report = DSEx.Optimizer.Report.fetch(compiled)

    assert report.optimizer == :bootstrap_few_shot
    assert report.best_score == 0.0
    assert report.metadata.selected_count == 0
    assert report.metadata.trainset_size == 1
    assert [%{passed?: false, selected?: false} = candidate] = report.candidates
    assert candidate.score == 0.0
    assert report.errors == []
    assert compiled.demos == []
  end

  test "bootstrap few-shot captures metric failures as optimizer diagnostics" do
    {train, _dev} = sets()
    program = DSEx.predict("question -> answer", lm: lm())
    metric = fn _example, _prediction -> raise "metric exploded" end

    compiled =
      metric
      |> DSEx.Optimizer.BootstrapFewShot.new(max_bootstrapped_demos: 1)
      |> DSEx.Optimizer.BootstrapFewShot.compile(program, train)

    report = DSEx.Optimizer.Report.fetch(compiled)

    assert report.optimizer == :bootstrap_few_shot
    assert report.metadata.selected_count == 0
    assert [%{stage: :metric, reason: "metric exploded"}] = report.errors

    assert [%{passed?: false, selected?: false, feedback: {:metric_error, "metric exploded"}}] =
             report.candidates
  end

  test "bootstrap few-shot reports trainset failures without erasing existing demos" do
    {train, _dev} = sets()
    [existing_demo] = train

    program =
      "question -> answer"
      |> DSEx.predict(lm: lm())
      |> DSEx.Predict.Predict.with_demos([existing_demo])

    compiled =
      DSEx.Optimizer.BootstrapFewShot.new(DSEx.Metrics.exact_match(:answer),
        max_bootstrapped_demos: 1
      )
      |> DSEx.Optimizer.BootstrapFewShot.compile(program, :not_an_enumerable_trainset)

    report = DSEx.Optimizer.Report.fetch(compiled)

    assert compiled.demos == [existing_demo]
    assert report.optimizer == :bootstrap_few_shot
    assert report.best_score == 0.0
    assert report.candidate_count == 0
    assert report.candidates == []
    assert report.metadata.status == :with_errors
    assert report.metadata.trainset_size == 0
    assert [%{stage: :trainset, reason: reason}] = report.errors
    assert String.contains?(reason, "Enumerable")
  end

  test "instruction search attaches candidate score report" do
    {_train, dev} = sets()
    metric = DSEx.Metrics.exact_match(:answer)
    program = DSEx.predict("question -> answer", lm: lm())

    compiled =
      DSEx.Optimizer.InstructionSearch.compile(program, metric, [], dev, [
        "Answer unknown.",
        "Always answer Paris."
      ])

    report = DSEx.Optimizer.Report.fetch(compiled)
    assert report.optimizer == :instruction_search
    assert report.best_score == 1.0
    assert Enum.any?(report.candidates, &(&1.instruction == "Always answer Paris."))
  end

  test "instruction search keeps the baseline when candidates regress" do
    {_train, dev} = sets()
    metric = DSEx.Metrics.exact_match(:answer)

    program =
      "question -> answer"
      |> DSEx.predict(lm: lm())
      |> DSEx.Optimizer.InstructionSearch.put_instruction("Always answer Paris.")

    compiled =
      DSEx.Optimizer.InstructionSearch.compile(program, metric, [], dev, [
        "Answer unknown."
      ])

    report = DSEx.Optimizer.Report.fetch(compiled)

    assert report.best_score == 1.0
    assert report.metadata.baseline_score == 1.0
    assert Enum.any?(report.candidates, &(&1.baseline and &1.score == 1.0))

    assert DSEx.Optimizer.InstructionSearch.current_instruction(compiled) ==
             "Always answer Paris."
  end

  test "instruction search reports all failed evaluations without crashing" do
    metric = DSEx.Metrics.exact_match(:answer)
    program = DSEx.predict("question -> answer", lm: lm())

    compiled =
      DSEx.Optimizer.InstructionSearch.compile(program, metric, [], :not_an_enumerable_devset, [
        "Always answer Paris."
      ])

    report = DSEx.Optimizer.Report.fetch(compiled)

    assert report.optimizer == :instruction_search
    assert report.best_score == nil
    assert report.candidates == []
    assert report.metadata.status == :all_candidates_failed

    assert Enum.map(report.errors, & &1.instruction) == [
             "Always answer Paris.",
             "Given the fields `question`, produce the fields `answer`."
           ]

    assert Enum.all?(report.errors, &String.contains?(&1.error, "Enumerable"))
  end

  test "better together reports unknown strategy keys without crashing" do
    {train, dev} = sets()
    metric = DSEx.Metrics.exact_match(:answer)
    program = DSEx.predict("question -> answer", lm: lm())

    compiled =
      metric
      |> DSEx.Optimizer.BetterTogether.new(%{p: DSEx.Optimizer.LabeledFewShot.new(k: 1)})
      |> DSEx.Optimizer.BetterTogether.compile(program, train, dev, strategy: "missing")

    assert {:ok, prediction} = DSEx.Predict.Predict.call(compiled, %{question: "Capital?"})
    assert DSEx.Prediction.get(prediction, :answer) == "unknown"

    report = DSEx.Optimizer.Report.fetch(compiled)
    assert report.optimizer == :better_together
    assert report.candidate_count == 1

    assert [%{key: "missing", status: :error, error: {:unknown_optimizer, "missing"}}] =
             report.candidates

    assert [%{key: "missing", error: {:unknown_optimizer, "missing"}}] = report.errors
  end

  test "better together rejects malformed strategy shapes at the boundary" do
    {train, dev} = sets()
    metric = DSEx.Metrics.exact_match(:answer)
    program = DSEx.predict("question -> answer", lm: lm())

    better =
      DSEx.Optimizer.BetterTogether.new(metric, %{p: DSEx.Optimizer.LabeledFewShot.new(k: 1)})

    assert_raise ArgumentError,
                 ~r/DSEx\.Optimizer\.BetterTogether\.compile\/5: invalid value for :strategy option: expected a non-empty optimizer key/,
                 fn ->
                   DSEx.Optimizer.BetterTogether.compile(better, program, train, dev,
                     strategy: ""
                   )
                 end

    assert_raise ArgumentError,
                 ~r/DSEx\.Optimizer\.BetterTogether\.compile\/5: invalid value for :strategy option: expected a non-empty optimizer key/,
                 fn ->
                   DSEx.Optimizer.BetterTogether.compile(better, program, train, dev,
                     strategy: []
                   )
                 end

    assert_raise ArgumentError,
                 ~r/DSEx\.Optimizer\.BetterTogether\.compile\/5: invalid value for :strategy option: expected a non-empty optimizer key/,
                 fn ->
                   DSEx.Optimizer.BetterTogether.compile(better, program, train, dev,
                     strategy: %{p: true}
                   )
                 end
  end

  test "better together reports invalid optimizer values without crashing" do
    {train, dev} = sets()
    metric = DSEx.Metrics.exact_match(:answer)
    program = DSEx.predict("question -> answer", lm: lm())

    compiled =
      metric
      |> DSEx.Optimizer.BetterTogether.new(%{bad: :not_an_optimizer})
      |> DSEx.Optimizer.BetterTogether.compile(program, train, dev, strategy: :bad)

    report = DSEx.Optimizer.Report.fetch(compiled)

    assert report.optimizer == :better_together

    assert [%{key: :bad, status: :error, error: {:invalid_optimizer, :not_an_optimizer}}] =
             report.candidates

    assert [%{key: :bad, error: {:invalid_optimizer, :not_an_optimizer}}] = report.errors
  end

  test "better together reports optimizer error tuples instead of treating them as compiled programs" do
    {train, dev} = sets()
    metric = DSEx.Metrics.exact_match(:answer)
    program = DSEx.predict("question -> answer", lm: lm())

    compiled =
      metric
      |> DSEx.Optimizer.BetterTogether.new(%{bad: %ErrorOptimizer{}})
      |> DSEx.Optimizer.BetterTogether.compile(program, train, dev, strategy: :bad)

    assert {:ok, prediction} = DSEx.Predict.Predict.call(compiled, %{question: "Capital?"})
    assert DSEx.Prediction.get(prediction, :answer) == "unknown"

    report = DSEx.Optimizer.Report.fetch(compiled)

    assert [%{key: :bad, status: :error, error: :optimizer_declined}] = report.candidates
    assert [%{key: :bad, error: :optimizer_declined}] = report.errors
  end

  test "better together reports unloaded optimizer modules explicitly" do
    {train, dev} = sets()
    metric = DSEx.Metrics.exact_match(:answer)
    program = DSEx.predict("question -> answer", lm: lm())
    unloaded = %{__struct__: :"Elixir.MissingOptimizer"}

    compiled =
      metric
      |> DSEx.Optimizer.BetterTogether.new(%{missing: unloaded})
      |> DSEx.Optimizer.BetterTogether.compile(program, train, dev, strategy: :missing)

    report = DSEx.Optimizer.Report.fetch(compiled)

    assert [
             %{
               key: :missing,
               status: :error,
               error: {:optimizer_not_loaded, :"Elixir.MissingOptimizer"}
             }
           ] = report.candidates

    assert [%{key: :missing, error: {:optimizer_not_loaded, :"Elixir.MissingOptimizer"}}] =
             report.errors
  end

  test "instruction proposer accepts LM-generated scored candidates" do
    lm = %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn messages, _opts ->
          send(self(), {:proposer_messages, messages})
          ~s(["Always answer Paris.", "Mention evidence."])
        end
      ]
    }

    {train, _dev} = sets()
    program = DSEx.predict("question -> answer", lm: lm)

    assert ["Always answer Paris.", "Mention evidence."] =
             DSEx.Optimizer.InstructionSearch.candidate_instructions(program, train,
               lm: lm,
               scores: [%{score: 1.0}]
             )

    assert_received {:proposer_messages, messages}
    assert Enum.map_join(messages, "\n", & &1.content) =~ "scored_examples"
  end

  test "instruction proposer includes signatures from composed program wrappers" do
    lm = %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn messages, _opts ->
          send(self(), {:wrapped_proposer_messages, messages})
          ~s(["Double the number using context."])
        end
      ]
    }

    {train, _dev} = sets()

    program =
      "x, context -> doubled"
      |> DSEx.program_of_thought(lm: lm, output_field: :doubled)
      |> DSEx.rag(DSEx.Retrieve.Memory.new([%{text: "double x"}]), query_field: :x, k: 1)

    assert ["Double the number using context."] =
             DSEx.Optimizer.InstructionProposer.propose(program, train, lm: lm, count: 1)

    assert_received {:wrapped_proposer_messages, messages}
    [%{role: :system}, %{role: :user, content: payload}] = messages
    decoded = Jason.decode!(payload)

    assert decoded["signature"] == "x, context -> doubled"
    assert decoded["lm_signature"] == "x, context -> program, tool, arguments"

    assert decoded["current_instruction"] ==
             "Given the fields `x`, `context`, produce the fields `doubled`."
  end

  test "instruction proposer falls back for malformed training rows" do
    program = DSEx.predict("question -> answer", lm: lm())

    candidates =
      DSEx.Optimizer.InstructionProposer.propose(program, [:not_an_example],
        extra_instructions: ["Use the safe fallback."]
      )

    assert Enum.any?(candidates, &String.contains?(&1, "Given the fields"))
    assert "Use the safe fallback." in candidates
  end

  test "instruction proposer falls back when proposer LM crashes" do
    lm = %{
      module: DSEx.LM.Static,
      opts: [handler: fn _messages, _opts -> raise "proposal provider offline" end]
    }

    {train, _dev} = sets()
    program = DSEx.predict("question -> answer", lm: lm())

    candidates =
      DSEx.Optimizer.InstructionProposer.propose(program, train,
        lm: lm,
        scores: :not_enumerable_scores
      )

    assert Enum.any?(candidates, &String.contains?(&1, "Given the fields"))
    assert Enum.any?(candidates, &String.contains?(&1, "Return only fields requested"))
  end
end
