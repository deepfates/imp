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
end
