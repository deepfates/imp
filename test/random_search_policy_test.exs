defmodule RandomSearchPolicyTest do
  use ExUnit.Case, async: true

  alias Imp.Optimizer.{RandomSearch, Report}

  defmodule ReportAwareProgram do
    defstruct [:main]

    def optimizer_predictors(program), do: [main: program.main]

    def update_optimizer_predictor(program, :main, update),
      do: %{program | main: update.(program.main)}

    def call(program, _inputs) do
      answer = if match?(%Report{}, Report.fetch(program.main)), do: "stale", else: "reset"
      {:ok, Imp.Prediction.new(answer: answer)}
    end
  end

  defp program do
    Imp.predict("question -> answer",
      lm: Imp.LM.Static.new(handler: fn _messages, _opts -> %{answer: "constant"} end)
    )
  end

  defp trainset do
    Enum.map(1..8, fn index ->
      Imp.example(question: "question-#{index}", answer: "constant") |> Imp.with_inputs(:question)
    end)
  end

  defp compile(opts \\ []) do
    RandomSearch.new(
      Imp.Metrics.exact_match(:answer),
      Keyword.merge(
        [num_candidate_programs: 3, max_bootstrapped_demos: 3, max_labeled_demos: 2],
        opts
      )
    )
    |> RandomSearch.compile(program(), trainset(), trainset())
  end

  defp compiled_report_aware_program do
    old_demo = Imp.example(question: "old", answer: "old") |> Imp.with_inputs(:question)

    %ReportAwareProgram{
      main:
        Imp.predict("question -> answer", demos: [old_demo])
        |> Report.attach(Report.new(optimizer: :previous_optimizer))
    }
  end

  defp report_reset_rows do
    [Imp.example(question: "q", answer: "reset") |> Imp.with_inputs(:question)]
  end

  test "enumerates DSPy's zero-shot, labels-only, and bootstrap seed schedule" do
    compiled = compile()
    report = Report.fetch(compiled)

    assert report.optimizer == :random_search
    assert report.metadata.score_scale == :percentage
    assert report.metadata.candidate_seeds == [-3, -2, -1, 0, 1, 2]
    assert Enum.map(report.candidates, & &1.seed) == [-3, -2, -1, 0, 1, 2]
    assert compiled.demos == []

    assert Enum.map(report.candidates, & &1.kind) == [
             :zero_shot,
             :labels_only,
             :unshuffled_bootstrap,
             :shuffled_bootstrap,
             :shuffled_bootstrap,
             :shuffled_bootstrap
           ]

    assert %{main: []} = Enum.find(report.candidates, &(&1.seed == -3)).demos
    assert %{main: labels} = Enum.find(report.candidates, &(&1.seed == -2)).demos
    assert length(labels) == 2
  end

  test "zero-shot resets demos and the compiled marker before evaluation" do
    result =
      RandomSearch.new(Imp.Metrics.exact_match(:answer), num_candidate_programs: 0)
      |> RandomSearch.compile(
        compiled_report_aware_program(),
        report_reset_rows(),
        report_reset_rows(),
        restrict: [-3]
      )

    report = Report.fetch(result.main)
    assert report.best_score == 100.0
    assert [%{kind: :zero_shot, demos: %{main: []}}] = report.candidates
    assert report.optimizer == :random_search
  end

  test "labels-only resets the compiled marker before attaching labels" do
    result =
      RandomSearch.new(Imp.Metrics.exact_match(:answer),
        num_candidate_programs: 0,
        max_labeled_demos: 1
      )
      |> RandomSearch.compile(
        compiled_report_aware_program(),
        report_reset_rows(),
        report_reset_rows(),
        restrict: [-2]
      )

    report = Report.fetch(result.main)
    assert report.best_score == 100.0
    assert [%{kind: :labels_only, demos: %{main: [_label]}}] = report.candidates
    assert report.optimizer == :random_search
  end

  test "the optional stop score terminates after the first qualifying candidate" do
    report = compile(stop_at_score: 100.0) |> Report.fetch()

    assert report.metadata.candidate_seeds == [-3]
    assert [%{seed: -3, score: 100.0, subscores: subscores}] = report.candidates
    assert subscores == List.duplicate(1.0, 8)
  end

  test "uses DSPy's percentage scale while retaining raw per-example subscores" do
    valset = [
      Imp.example(question: "pass", answer: "constant") |> Imp.with_inputs(:question),
      Imp.example(question: "fail", answer: "different") |> Imp.with_inputs(:question)
    ]

    report =
      RandomSearch.new(Imp.Metrics.exact_match(:answer), num_candidate_programs: 0)
      |> RandomSearch.compile(program(), trainset(), valset, restrict: [-3])
      |> Report.fetch()

    assert report.best_score == 50.0
    assert [%{score: 50.0, subscores: subscores}] = report.candidates
    assert subscores == [1.0, 0.0]
  end

  test "uses Python's ties-to-even rounding for percentage scores" do
    valset =
      Enum.map(1..32, fn index ->
        answer = if index == 1, do: "constant", else: "different"
        Imp.example(question: "q#{index}", answer: answer) |> Imp.with_inputs(:question)
      end)

    report =
      RandomSearch.new(Imp.Metrics.exact_match(:answer), num_candidate_programs: 0)
      |> RandomSearch.compile(program(), trainset(), valset, restrict: [-3])
      |> Report.fetch()

    assert report.best_score == 3.12
  end

  test "fails scoring when both valset and fallback trainset are empty" do
    assert_raise ArithmeticError, ~r/cannot score an empty dataset/, fn ->
      RandomSearch.new(Imp.Metrics.exact_match(:answer), num_candidate_programs: 0)
      |> RandomSearch.compile(program(), [], [], restrict: [-3])
    end
  end

  test "an empty valset falls back to trainset like Python's falsy list" do
    report =
      RandomSearch.new(Imp.Metrics.exact_match(:answer), num_candidate_programs: 0)
      |> RandomSearch.compile(program(), trainset(), [], restrict: [-3])
      |> Report.fetch()

    assert report.best_score == 100.0
    assert report.metadata.valset_size == 8
  end

  test "legacy Imp seed does not perturb DSPy's candidate seed schedule" do
    first = compile(seed: 19) |> Report.fetch()
    second = compile(seed: -711) |> Report.fetch()

    assert first.metadata.candidate_seeds == second.metadata.candidate_seeds

    assert Enum.map(first.candidates, &Map.take(&1, [:seed, :kind, :bootstrap_size])) ==
             Enum.map(second.candidates, &Map.take(&1, [:seed, :kind, :bootstrap_size]))
  end

  test "restrict selects source candidate seeds rather than an ordinal trial number" do
    report =
      RandomSearch.new(Imp.Metrics.exact_match(:answer), num_candidate_programs: 4)
      |> RandomSearch.compile(program(), trainset(), trainset(), restrict: [-2, 1])
      |> Report.fetch()

    assert report.metadata.candidate_seeds == [-2, 1]
  end

  test "restricting out every source seed fails instead of returning an unevaluated student" do
    assert_raise RuntimeError, ~r/restrict excluded every DSPy candidate seed/, fn ->
      RandomSearch.new(Imp.Metrics.exact_match(:answer), num_candidate_programs: 0)
      |> RandomSearch.compile(program(), trainset(), trainset(), restrict: [99])
    end
  end

  test "inherits DSPy's default error budget and aborts at the configured threshold" do
    optimizer = RandomSearch.new(Imp.Metrics.exact_match(:answer), num_candidate_programs: 0)
    assert optimizer.max_errors == nil
    assert optimizer.num_threads == nil

    failing =
      Imp.predict("question -> answer",
        lm: Imp.LM.Static.new(handler: fn _messages, _opts -> raise "provider failed" end)
      )

    assert_raise RuntimeError, ~r/error budget exhausted: 1 errors \(maximum 1\)/, fn ->
      RandomSearch.new(Imp.Metrics.exact_match(:answer),
        num_candidate_programs: 0,
        max_errors: 1
      )
      |> RandomSearch.compile(failing, trainset(), [hd(trainset())], restrict: [-3])
    end

    assert_raise RuntimeError, ~r/error budget exhausted: 1 errors \(maximum 0\)/, fn ->
      RandomSearch.new(Imp.Metrics.exact_match(:answer),
        num_candidate_programs: 0,
        max_errors: 0
      )
      |> RandomSearch.compile(failing, trainset(), [hd(trainset())], restrict: [-3])
    end

    report =
      RandomSearch.new(Imp.Metrics.exact_match(:answer),
        num_candidate_programs: 0,
        max_errors: :infinity
      )
      |> RandomSearch.compile(failing, trainset(), [hd(trainset())], restrict: [-3])
      |> Report.fetch()

    assert report.metadata.max_errors == :infinity
    assert report.metadata.max_errors_source == :explicit
    assert length(report.errors) == 1
  end

  test "compatibility seed still validates as an integer" do
    assert_raise ArgumentError, ~r/invalid value for :seed option: expected integer/, fn ->
      RandomSearch.new(Imp.Metrics.exact_match(:answer), seed: 1.5)
    end
  end
end

defmodule RandomSearchGlobalSettingsTest do
  use ExUnit.Case, async: false

  alias Imp.Optimizer.{RandomSearch, Report}

  setup do
    Imp.Settings.reset()
    on_exit(&Imp.Settings.reset/0)
    :ok
  end

  test "nil max_errors is ten while an explicit value wins" do
    lm = Imp.LM.Static.new(handler: fn _, _ -> %{answer: "a"} end)
    program = Imp.predict("question -> answer", lm: lm)
    rows = [Imp.example(question: "q", answer: "a") |> Imp.with_inputs(:question)]
    metric = Imp.Metrics.exact_match(:answer)

    defaulted =
      RandomSearch.new(metric, num_candidate_programs: 0)
      |> RandomSearch.compile(program, rows, rows, restrict: [-3])
      |> Report.fetch()

    explicit =
      RandomSearch.new(metric, num_candidate_programs: 0, max_errors: 8)
      |> RandomSearch.compile(program, rows, rows, restrict: [-3])
      |> Report.fetch()

    assert {defaulted.metadata.max_errors, defaulted.metadata.max_errors_source} == {10, :default}
    assert {explicit.metadata.max_errors, explicit.metadata.max_errors_source} == {8, :explicit}
  end
end
