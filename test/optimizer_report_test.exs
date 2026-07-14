defmodule OptimizerReportTest do
  use ExUnit.Case

  defmodule ErrorOptimizer do
    defstruct []

    @behaviour Imp.Optimizer

    @impl true
    def __optimizer__ do
      %{
        kind: :program,
        datasets: %{trainset: :required, validation: :optional},
        result: :program
      }
    end

    @impl true
    def run(%__MODULE__{}, _program, _opts), do: {:error, :optimizer_declined}
  end

  defp lm do
    %{
      module: Imp.LM.Static,
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
      Imp.example(question: "France capital?", answer: "Paris")
      |> Imp.Example.with_inputs(:question)
    ]

    dev = [
      Imp.example(question: "Capital of France?", answer: "Paris")
      |> Imp.Example.with_inputs(:question)
    ]

    {train, dev}
  end

  test "JSON-safe optimizer values preserve structured tuple errors" do
    value = %{error: {:metric_error, {:provider, :offline}}, lineage: [nil, {:parent, 2}]}

    encoded = Imp.Optimizer.Report.json_safe(value)

    assert Jason.encode!(encoded) |> Jason.decode!() |> Imp.Optimizer.Report.restore_json_safe() ==
             value
  end

  test "random search attaches candidate history and best score" do
    {train, dev} = sets()
    metric = Imp.Metrics.exact_match(:answer)
    program = Imp.predict("question -> answer", lm: lm())

    compiled =
      metric
      |> Imp.Optimizer.RandomSearch.new(candidates: 3, demos_per_candidate: 1)
      |> Imp.Optimizer.RandomSearch.compile(program, train, dev)

    report = Imp.Optimizer.Report.fetch(compiled)

    assert %Imp.Optimizer.Report{
             optimizer: :random_search,
             best_score: 1.0,
             candidate_count: 3
           } =
             report

    assert Enum.all?(report.candidates, &Map.has_key?(&1, :score))
  end

  test "upstream bootstrap random-search aliases delegate to the canonical optimizer" do
    metric = Imp.Metrics.exact_match(:answer)

    assert %Imp.Optimizer.RandomSearch{candidates: 2, demos_per_candidate: 1} =
             Imp.Optimizer.BootstrapRS.new(metric, candidates: 2, demos_per_candidate: 1)

    assert %Imp.Optimizer.RandomSearch{candidates: 3, demos_per_candidate: 2} =
             Imp.Optimizer.BootstrapFewShotWithRandomSearch.new(metric,
               candidates: 3,
               demos_per_candidate: 2
             )
  end

  test "InferRules preserves upstream name while using signature optimization" do
    {_train, dev} = sets()
    metric = Imp.Metrics.exact_match(:answer)
    program = Imp.predict("question -> answer", lm: lm())

    compiled =
      metric
      |> Imp.Optimizer.InferRules.new(candidates: ["Always answer Paris."])
      |> Imp.Optimizer.InferRules.compile(program, [], dev)

    report = Imp.Optimizer.Report.fetch(compiled)

    assert report.optimizer == :infer_rules
    assert report.metadata.implementation == Imp.Optimizer.SignatureOptimizer
    assert report.metadata.adapter == Imp.Optimizer.InferRules
  end

  test "labeled few-shot reports selected demonstrations without scoring them" do
    {train, _dev} = sets()
    program = Imp.predict("question -> answer", lm: lm())

    compiled =
      Imp.Optimizer.LabeledFewShot.new(k: 1)
      |> Imp.Optimizer.LabeledFewShot.compile(program, train)

    report = Imp.Optimizer.Report.fetch(compiled)

    assert report.optimizer == :labeled_few_shot
    assert report.best_score == nil
    assert report.candidate_count == 1
    assert report.metadata.requested_k == 1
    assert report.metadata.selected_count == 1
    assert [%{index: 0, selected?: true, example: example}] = report.candidates
    assert Imp.Example.get(example, :answer) == "Paris"
    assert length(compiled.demos) == 1
  end

  test "few-shot optimizers attach demos through wrapper programs" do
    {train, _dev} = sets()

    pot =
      "question -> answer"
      |> Imp.program_of_thought()
      |> then(
        &Imp.Optimizer.LabeledFewShot.compile(Imp.Optimizer.LabeledFewShot.new(k: 1), &1, train)
      )

    assert [%Imp.Example{}] = pot.predict.demos
    assert Imp.Optimizer.Report.fetch(pot).optimizer == :labeled_few_shot

    code_act =
      "question -> answer"
      |> Imp.code_act()
      |> then(
        &Imp.Optimizer.LabeledFewShot.compile(Imp.Optimizer.LabeledFewShot.new(k: 1), &1, train)
      )

    assert [%Imp.Example{}] = code_act.program_of_thought.predict.demos
    assert Imp.Optimizer.Report.fetch(code_act).optimizer == :labeled_few_shot

    rag =
      "question, context -> answer"
      |> Imp.predict()
      |> Imp.rag(Imp.Retrieve.Memory.new([%{text: "France: Paris."}]))
      |> then(
        &Imp.Optimizer.LabeledFewShot.compile(Imp.Optimizer.LabeledFewShot.new(k: 1), &1, train)
      )

    assert [%Imp.Example{}] = rag.program.demos
    assert Imp.Optimizer.Report.fetch(rag).optimizer == :labeled_few_shot
  end

  test "instruction search helpers traverse wrapper programs" do
    pot =
      "question -> answer"
      |> Imp.program_of_thought()
      |> Imp.Optimizer.InstructionSearch.put_instruction("Answer briefly.")

    assert Imp.Optimizer.InstructionSearch.current_instruction(pot) == "Answer briefly."
    assert pot.signature.instructions == "Answer briefly."
    assert pot.predict.signature.instructions == "Answer briefly."

    code_act =
      "question -> answer"
      |> Imp.code_act()
      |> Imp.Optimizer.InstructionSearch.put_instruction("Use code sparingly.")

    assert Imp.Optimizer.InstructionSearch.current_instruction(code_act) == "Use code sparingly."
    assert code_act.program_of_thought.signature.instructions == "Use code sparingly."
    assert code_act.program_of_thought.predict.signature.instructions == "Use code sparingly."

    rag =
      "question, context -> answer"
      |> Imp.predict()
      |> Imp.rag(Imp.Retrieve.Memory.new([%{text: "France: Paris."}]))
      |> Imp.Optimizer.InstructionSearch.put_instruction("Use retrieved context.")

    assert Imp.Optimizer.InstructionSearch.current_instruction(rag) == "Use retrieved context."
    assert rag.program.signature.instructions == "Use retrieved context."
  end

  test "instruction search updates wrapper task signatures as well as LM signatures" do
    pot =
      "x, context -> doubled"
      |> Imp.program_of_thought(output_field: :doubled)
      |> Imp.rag(Imp.Retrieve.Memory.new([%{text: "double x"}]))
      |> Imp.Optimizer.InstructionSearch.put_instruction("Double with retrieved context.")

    assert pot
           |> Imp.ProgramAccess.task_signature()
           |> Map.fetch!(:instructions) == "Double with retrieved context."

    assert pot
           |> Imp.ProgramAccess.lm_signature()
           |> Map.fetch!(:instructions) == "Double with retrieved context."

    assert "x, context -> doubled" =
             pot
             |> Imp.ProgramAccess.task_signature()
             |> Imp.Signature.to_spec()

    assert "x, context -> program, tool, arguments" =
             pot
             |> Imp.ProgramAccess.lm_signature()
             |> Imp.Signature.to_spec()
  end

  test "instruction search optimizer metadata attaches through wrapper programs" do
    {_train, dev} = sets()
    metric = Imp.Metrics.exact_match(:answer)

    program =
      "question, context -> answer"
      |> Imp.predict(lm: lm())
      |> Imp.rag(Imp.Retrieve.Memory.new([%{text: "France: Paris."}]))

    compiled =
      Imp.Optimizer.InstructionSearch.compile(program, metric, [], dev, [
        "Always answer Paris."
      ])

    assert compiled.program.metadata.trainset_size == 0
    assert compiled.program.metadata.candidate_count == 1
    assert Imp.Optimizer.Report.fetch(compiled).optimizer == :instruction_search
  end

  test "optimizer reports attach and fetch through wrapper programs" do
    report = Imp.Optimizer.Report.new(%{optimizer: :wrapper_probe, metadata: %{status: :ok}})

    pot = Imp.program_of_thought("question -> answer")
    pot = Imp.Optimizer.Report.attach(pot, report)
    assert Imp.Optimizer.Report.fetch(pot).optimizer == :wrapper_probe
    assert pot.predict.metadata.optimizer_report.metadata.status == :ok

    code_act = Imp.code_act("question -> answer")
    code_act = Imp.Optimizer.Report.attach(code_act, report)
    assert Imp.Optimizer.Report.fetch(code_act).optimizer == :wrapper_probe
    assert code_act.program_of_thought.predict.metadata.optimizer_report.metadata.status == :ok

    rag =
      "question, context -> answer"
      |> Imp.predict()
      |> Imp.rag(Imp.Retrieve.Memory.new([%{text: "France: Paris."}]))
      |> Imp.Optimizer.Report.attach(report)

    assert Imp.Optimizer.Report.fetch(rag).optimizer == :wrapper_probe
    assert rag.program.metadata.optimizer_report.metadata.status == :ok
  end

  test "optimizer reports serialize with embedded examples and restore as reports" do
    {train, _dev} = sets()

    report =
      Imp.Optimizer.Report.new(%{
        optimizer: :labeled_few_shot,
        candidate_count: 1,
        candidates: [%{index: 0, selected?: true, example: hd(train)}],
        metadata: %{status: :ok, note: "keep strings as strings"}
      })

    restored =
      report
      |> Imp.Optimizer.Report.json_safe()
      |> Jason.encode!()
      |> Jason.decode!()
      |> Imp.Optimizer.Report.restore_json_safe()

    assert %Imp.Optimizer.Report{} = restored
    assert restored.optimizer == :labeled_few_shot
    assert restored.metadata.status == :ok
    assert restored.metadata.note == "keep strings as strings"
    assert [%{example: example, selected?: true}] = restored.candidates
    assert %Imp.Example{} = example
    assert Imp.Example.get(example, :question) == "France capital?"
    assert Imp.Example.inputs(example).fields == %{question: "France capital?"}
  end

  test "optimizer reports accept decoded attrs and reject malformed attrs clearly" do
    report =
      Imp.Optimizer.Report.new(%{
        "optimizer" => "provider_search",
        "best_score" => 0.75,
        "candidate_count" => 2,
        "candidates" => [%{"score" => 0.75}],
        "errors" => [%{"error" => "candidate failed"}],
        "metadata" => %{"source" => "decoded-json"}
      })

    assert report.optimizer == "provider_search"
    assert report.best_score == 0.75
    assert report.candidate_count == 2
    assert report.candidates == [%{"score" => 0.75}]
    assert report.errors == [%{"error" => "candidate failed"}]
    assert report.metadata == %{"source" => "decoded-json"}

    assert Imp.Optimizer.Report.new(optimizer: :keyword_report).optimizer == :keyword_report

    assert_raise ArgumentError,
                 ~r/Imp.Optimizer.Report\.new\/1 expects a map or keyword list/,
                 fn ->
                   Imp.Optimizer.Report.new(:not_attrs)
                 end

    assert_raise ArgumentError,
                 ~r/Imp.Optimizer.Report\.new\/1 expects attrs as atom or string keyed pairs/,
                 fn ->
                   Imp.Optimizer.Report.new([{123, "bad"}])
                 end
  end

  test "labeled few-shot reports trainset enumeration failures" do
    program = Imp.predict("question -> answer", lm: lm())

    compiled =
      Imp.Optimizer.LabeledFewShot.new(k: 1)
      |> Imp.Optimizer.LabeledFewShot.compile(program, :not_an_enumerable_trainset)

    report = Imp.Optimizer.Report.fetch(compiled)

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
      |> Imp.predict(lm: lm())
      |> Imp.Predict.Predict.with_demos([existing_demo])

    compiled =
      Imp.Optimizer.LabeledFewShot.new(k: 1)
      |> Imp.Optimizer.LabeledFewShot.compile(program, :not_an_enumerable_trainset)

    report = Imp.Optimizer.Report.fetch(compiled)

    assert compiled.demos == [existing_demo]
    assert report.metadata.status == :trainset_error
    assert report.metadata.selected_count == 0
    assert [%{stage: :trainset, reason: reason}] = report.errors
    assert String.contains?(reason, "Enumerable")
  end

  test "random search treats zero requested trials as a baseline-only compile" do
    {train, dev} = sets()
    metric = Imp.Metrics.exact_match(:answer)
    program = Imp.predict("question -> answer", lm: lm())

    compiled =
      metric
      |> Imp.Optimizer.RandomSearch.new(candidates: 0, demos_per_candidate: 1)
      |> Imp.Optimizer.RandomSearch.compile(program, train, dev)

    report = Imp.Optimizer.Report.fetch(compiled)

    assert report.optimizer == :random_search
    assert report.best_score == 0.0
    assert report.candidate_count == 0
    assert report.errors == []
    assert report.metadata.baseline_score == 0.0
    assert Enum.map(report.candidates, & &1.index) == [:baseline]
  end

  test "optimizer constructors reject invalid option containers at the boundary" do
    metric = Imp.Metrics.exact_match(:answer)

    assert_raise ArgumentError,
                 ~r/Imp\.Optimizer\.LabeledFewShot\.new\/1: expected keyword options/,
                 fn ->
                   Imp.Optimizer.LabeledFewShot.new(%{k: 1})
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Optimizer\.RandomSearch\.new\/2: expected keyword options/,
                 fn ->
                   Imp.Optimizer.RandomSearch.new(metric, %{candidates: 1})
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Optimizer\.BootstrapFewShot\.new\/2: expected keyword options/,
                 fn ->
                   Imp.Optimizer.BootstrapFewShot.new(metric, %{max_bootstrapped_demos: 1})
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Optimizer\.LabeledFewShot\.new\/1: invalid value for :k option: expected non negative integer/,
                 fn ->
                   Imp.Optimizer.LabeledFewShot.new(k: -1)
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Optimizer\.RandomSearch\.new\/2: invalid value for :candidates option: expected non negative integer/,
                 fn ->
                   Imp.Optimizer.RandomSearch.new(metric, candidates: -1)
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Optimizer\.RandomSearch\.new\/2: invalid value for :demos_per_candidate option: expected non negative integer/,
                 fn ->
                   Imp.Optimizer.RandomSearch.new(metric, demos_per_candidate: -1)
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Optimizer\.BootstrapFewShot\.new\/2: invalid value for :max_bootstrapped_demos option: expected non negative integer/,
                 fn ->
                   Imp.Optimizer.BootstrapFewShot.new(metric, max_bootstrapped_demos: -1)
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Optimizer\.KNNFewShot\.new\/3: expected keyword options/,
                 fn ->
                   Imp.Optimizer.KNNFewShot.new(1, [], %{field: :question})
                 end
  end

  test "search optimizer constructors reject invalid metric callbacks at the boundary" do
    assert_raise ArgumentError,
                 ~r/Imp\.Optimizer\.RandomSearch\.new\/2 expects a metric function with arity 2 or 3/,
                 fn ->
                   Imp.Optimizer.RandomSearch.new(fn _example -> true end)
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Optimizer\.BootstrapFewShot\.new\/2 expects a metric function with arity 2 or 3/,
                 fn ->
                   Imp.Optimizer.BootstrapFewShot.new(fn _example -> true end)
                 end
  end

  test "random search returns the original program with diagnostics when all trials fail" do
    {train, _dev} = sets()
    metric = Imp.Metrics.exact_match(:answer)
    program = Imp.predict("question -> answer", lm: lm())

    compiled =
      metric
      |> Imp.Optimizer.RandomSearch.new(candidates: 2, demos_per_candidate: 1)
      |> Imp.Optimizer.RandomSearch.compile(program, train, :not_an_enumerable_devset)

    report = Imp.Optimizer.Report.fetch(compiled)

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
    metric = Imp.Metrics.exact_match(:answer)
    program = Imp.predict("question -> answer", lm: lm())

    compiled =
      metric
      |> Imp.Optimizer.BootstrapFewShot.new(max_bootstrapped_demos: 1)
      |> Imp.Optimizer.BootstrapFewShot.compile(program, train)

    report = Imp.Optimizer.Report.fetch(compiled)

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
    program = Imp.predict("question -> answer", lm: lm())
    metric = fn _example, _prediction -> raise "metric exploded" end

    compiled =
      metric
      |> Imp.Optimizer.BootstrapFewShot.new(max_bootstrapped_demos: 1)
      |> Imp.Optimizer.BootstrapFewShot.compile(program, train)

    report = Imp.Optimizer.Report.fetch(compiled)

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
      |> Imp.predict(lm: lm())
      |> Imp.Predict.Predict.with_demos([existing_demo])

    compiled =
      Imp.Optimizer.BootstrapFewShot.new(Imp.Metrics.exact_match(:answer),
        max_bootstrapped_demos: 1
      )
      |> Imp.Optimizer.BootstrapFewShot.compile(program, :not_an_enumerable_trainset)

    report = Imp.Optimizer.Report.fetch(compiled)

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
    metric = Imp.Metrics.exact_match(:answer)
    program = Imp.predict("question -> answer", lm: lm())

    compiled =
      Imp.Optimizer.InstructionSearch.compile(program, metric, [], dev, [
        "Answer unknown.",
        "Always answer Paris."
      ])

    report = Imp.Optimizer.Report.fetch(compiled)
    assert report.optimizer == :instruction_search
    assert report.best_score == 1.0
    assert Enum.any?(report.candidates, &(&1.instruction == "Always answer Paris."))
  end

  test "instruction search keeps the baseline when candidates regress" do
    {_train, dev} = sets()
    metric = Imp.Metrics.exact_match(:answer)

    program =
      "question -> answer"
      |> Imp.predict(lm: lm())
      |> Imp.Optimizer.InstructionSearch.put_instruction("Always answer Paris.")

    compiled =
      Imp.Optimizer.InstructionSearch.compile(program, metric, [], dev, [
        "Answer unknown."
      ])

    report = Imp.Optimizer.Report.fetch(compiled)

    assert report.best_score == 1.0
    assert report.metadata.baseline_score == 1.0
    assert Enum.any?(report.candidates, &(&1.baseline and &1.score == 1.0))

    assert Imp.Optimizer.InstructionSearch.current_instruction(compiled) ==
             "Always answer Paris."
  end

  test "instruction search reports all failed evaluations without crashing" do
    metric = Imp.Metrics.exact_match(:answer)
    program = Imp.predict("question -> answer", lm: lm())

    compiled =
      Imp.Optimizer.InstructionSearch.compile(program, metric, [], :not_an_enumerable_devset, [
        "Always answer Paris."
      ])

    report = Imp.Optimizer.Report.fetch(compiled)

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

  test "instruction search does not hide malformed demo payloads" do
    {_train, dev} = sets()
    metric = Imp.Metrics.exact_match(:answer)
    program = Imp.predict("question -> answer", lm: lm())

    assert_raise ArgumentError,
                 ~r/Imp.Predict.Predict.with_demos\/2 expects demos as Imp.Example structs/,
                 fn ->
                   Imp.Optimizer.InstructionSearch.compile(
                     program,
                     metric,
                     [],
                     dev,
                     ["Always answer Paris."],
                     demos: [:not_a_demo]
                   )
                 end
  end

  test "better together reports unknown strategy keys without crashing" do
    {train, dev} = sets()
    metric = Imp.Metrics.exact_match(:answer)
    program = Imp.predict("question -> answer", lm: lm())

    compiled =
      metric
      |> Imp.Optimizer.BetterTogether.new(%{p: Imp.Optimizer.LabeledFewShot.new(k: 1)})
      |> Imp.Optimizer.BetterTogether.compile(program, train, dev, strategy: "missing")

    assert {:ok, prediction} = Imp.Predict.Predict.call(compiled, %{question: "Capital?"})
    assert Imp.Prediction.get(prediction, :answer) == "unknown"

    report = Imp.Optimizer.Report.fetch(compiled)
    assert report.optimizer == :better_together
    assert report.candidate_count == 1

    assert [%{key: "missing", status: :error, error: {:unknown_optimizer, "missing"}}] =
             report.candidates

    assert [%{key: "missing", error: {:unknown_optimizer, "missing"}}] = report.errors
  end

  test "better together rejects malformed strategy shapes at the boundary" do
    {train, dev} = sets()
    metric = Imp.Metrics.exact_match(:answer)
    program = Imp.predict("question -> answer", lm: lm())

    better =
      Imp.Optimizer.BetterTogether.new(metric, %{p: Imp.Optimizer.LabeledFewShot.new(k: 1)})

    assert_raise ArgumentError,
                 ~r/Imp\.Optimizer\.BetterTogether\.compile\/5: invalid value for :strategy option: expected a non-empty optimizer key/,
                 fn ->
                   Imp.Optimizer.BetterTogether.compile(better, program, train, dev, strategy: "")
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Optimizer\.BetterTogether\.compile\/5: invalid value for :strategy option: expected a non-empty optimizer key/,
                 fn ->
                   Imp.Optimizer.BetterTogether.compile(better, program, train, dev, strategy: [])
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Optimizer\.BetterTogether\.compile\/5: invalid value for :strategy option: expected a non-empty optimizer key/,
                 fn ->
                   Imp.Optimizer.BetterTogether.compile(better, program, train, dev,
                     strategy: %{p: true}
                   )
                 end
  end

  test "better together reports invalid optimizer values without crashing" do
    {train, dev} = sets()
    metric = Imp.Metrics.exact_match(:answer)
    program = Imp.predict("question -> answer", lm: lm())

    compiled =
      metric
      |> Imp.Optimizer.BetterTogether.new(%{bad: :not_an_optimizer})
      |> Imp.Optimizer.BetterTogether.compile(program, train, dev, strategy: :bad)

    report = Imp.Optimizer.Report.fetch(compiled)

    assert report.optimizer == :better_together

    assert [%{key: :bad, status: :error, error: {:not_an_optimizer, :not_an_optimizer}}] =
             report.candidates

    assert [%{key: :bad, error: {:not_an_optimizer, :not_an_optimizer}}] = report.errors
  end

  test "better together reports optimizer error tuples instead of treating them as compiled programs" do
    {train, dev} = sets()
    metric = Imp.Metrics.exact_match(:answer)
    program = Imp.predict("question -> answer", lm: lm())

    compiled =
      metric
      |> Imp.Optimizer.BetterTogether.new(%{bad: %ErrorOptimizer{}})
      |> Imp.Optimizer.BetterTogether.compile(program, train, dev, strategy: :bad)

    assert {:ok, prediction} = Imp.Predict.Predict.call(compiled, %{question: "Capital?"})
    assert Imp.Prediction.get(prediction, :answer) == "unknown"

    report = Imp.Optimizer.Report.fetch(compiled)

    assert [%{key: :bad, status: :error, error: :optimizer_declined}] = report.candidates
    assert [%{key: :bad, error: :optimizer_declined}] = report.errors
  end

  test "better together rejects unloaded optimizer modules through the canonical contract" do
    {train, dev} = sets()
    metric = Imp.Metrics.exact_match(:answer)
    program = Imp.predict("question -> answer", lm: lm())
    unloaded = %{__struct__: :"Elixir.MissingOptimizer"}

    compiled =
      metric
      |> Imp.Optimizer.BetterTogether.new(%{missing: unloaded})
      |> Imp.Optimizer.BetterTogether.compile(program, train, dev, strategy: :missing)

    report = Imp.Optimizer.Report.fetch(compiled)

    assert [
             %{
               key: :missing,
               status: :error,
               error: {:not_an_optimizer, :"Elixir.MissingOptimizer"}
             }
           ] = report.candidates

    assert [%{key: :missing, error: {:not_an_optimizer, :"Elixir.MissingOptimizer"}}] =
             report.errors
  end

  test "instruction proposer accepts LM-generated scored candidates" do
    lm = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn messages, _opts ->
          send(self(), {:proposer_messages, messages})
          ~s(["Always answer Paris.", "Mention evidence."])
        end
      ]
    }

    {train, _dev} = sets()
    program = Imp.predict("question -> answer", lm: lm)

    assert ["Always answer Paris.", "Mention evidence."] =
             Imp.Optimizer.InstructionSearch.candidate_instructions(program, train,
               lm: lm,
               scores: [%{score: 1.0}]
             )

    assert_received {:proposer_messages, messages}
    assert Enum.map_join(messages, "\n", & &1.content) =~ "scored_examples"
  end

  test "instruction proposer includes signatures from composed program wrappers" do
    lm = %{
      module: Imp.LM.Static,
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
      |> Imp.program_of_thought(lm: lm, output_field: :doubled)
      |> Imp.rag(Imp.Retrieve.Memory.new([%{text: "double x"}]), query_field: :x, k: 1)

    assert ["Double the number using context."] =
             Imp.Optimizer.InstructionProposer.propose(program, train, lm: lm, count: 1)

    assert_received {:wrapped_proposer_messages, messages}
    [%{role: :system}, %{role: :user, content: payload}] = messages
    decoded = Jason.decode!(payload)

    assert get_in(decoded, ["program", "signature"]) == "x, context -> doubled"

    assert get_in(decoded, ["program", "lm_signature"]) ==
             "x, context -> program, tool, arguments"

    assert decoded["current_instruction"] ==
             "Given the fields `x`, `context`, produce the fields `doubled`."
  end

  test "instruction proposer falls back for malformed training rows" do
    program = Imp.predict("question -> answer", lm: lm())

    candidates =
      Imp.Optimizer.InstructionProposer.propose(program, [:not_an_example],
        extra_instructions: ["Use the safe fallback."]
      )

    assert Enum.any?(candidates, &String.contains?(&1, "Given the fields"))
    assert "Use the safe fallback." in candidates
  end

  test "instruction proposer falls back when proposer LM crashes" do
    lm = %{
      module: Imp.LM.Static,
      opts: [handler: fn _messages, _opts -> raise "proposal provider offline" end]
    }

    {train, _dev} = sets()
    program = Imp.predict("question -> answer", lm: lm())

    candidates =
      Imp.Optimizer.InstructionProposer.propose(program, train,
        lm: lm,
        scores: :not_enumerable_scores
      )

    assert Enum.any?(candidates, &String.contains?(&1, "Given the fields"))
    assert Enum.any?(candidates, &String.contains?(&1, "Return only fields requested"))
  end
end
