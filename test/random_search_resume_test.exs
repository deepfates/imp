defmodule Imp.Optimizer.BootstrapFewShotWithRandomSearch.ResumeTest do
  use ExUnit.Case, async: false

  alias Imp.Optimizer.{BootstrapFewShotWithRandomSearch, Report}

  def exact_metric(example, prediction),
    do: Imp.Metrics.exact_match(:answer).(example, prediction)

  test "resume preserves the DSPy seed schedule without repeating sealed candidates" do
    uninterrupted_counter = start_supervised!({Agent, fn -> 0 end}, id: :random_full_counter)
    {program, optimizer, trainset, devset} = fixture(uninterrupted_counter)

    uninterrupted =
      optimizer
      |> BootstrapFewShotWithRandomSearch.compile(program, trainset, devset,
        restrict: [-3, -2, -1, 0]
      )
      |> Report.fetch()

    uninterrupted_calls = Agent.get(uninterrupted_counter, & &1)

    resumed_counter = start_supervised!({Agent, fn -> 0 end}, id: :random_resumed_counter)
    {program, optimizer, trainset, devset} = fixture(resumed_counter)

    paused =
      optimizer
      |> BootstrapFewShotWithRandomSearch.compile(program, trainset, devset,
        restrict: [-3, -2, -1, 0],
        max_candidates: 2
      )
      |> Report.fetch()

    assert paused.metadata.run_status == :paused
    assert paused.metadata.completed_candidates == 2
    assert paused.metadata.candidate_seeds == [-3, -2]
    assert paused.candidate_count == 2
    calls_after_pause = Agent.get(resumed_counter, & &1)
    assert calls_after_pause == 2

    checkpoint = paused.metadata.resume_state |> Jason.encode!() |> Jason.decode!()

    resumed =
      optimizer
      |> BootstrapFewShotWithRandomSearch.compile(program, trainset, devset,
        restrict: [-3, -2, -1, 0],
        resume_state: checkpoint
      )
      |> Report.fetch()

    assert resumed.metadata.resumed
    assert resumed.metadata.run_status == :complete
    assert resumed.metadata.candidate_seeds == [-3, -2, -1, 0]
    assert resumed.candidates == uninterrupted.candidates
    assert resumed.best_score == uninterrupted.best_score
    assert Agent.get(resumed_counter, & &1) == uninterrupted_calls
    assert Agent.get(resumed_counter, & &1) > calls_after_pause
  end

  test "metric, program, dataset, and optimizer drift fail before candidate work" do
    counter = start_supervised!({Agent, fn -> 0 end})
    {program, optimizer, trainset, devset} = fixture(counter)

    checkpoint =
      optimizer
      |> BootstrapFewShotWithRandomSearch.compile(program, trainset, devset,
        restrict: [-3, -2],
        max_candidates: 0
      )
      |> Report.fetch()
      |> then(& &1.metadata.resume_state)
      |> Jason.encode!()
      |> Jason.decode!()

    drifted_metric =
      random_optimizer(
        captured_metric(counter),
        metric_identity(%{"field" => "answer", "mode" => "case_insensitive"})
      )

    assert_refused(fn ->
      BootstrapFewShotWithRandomSearch.compile(drifted_metric, program, trainset, devset,
        restrict: [-3, -2],
        resume_state: checkpoint,
        max_candidates: 0
      )
    end)

    assert_refused(fn ->
      BootstrapFewShotWithRandomSearch.compile(
        optimizer,
        %{program | config: [temperature: 0.2]},
        trainset,
        devset,
        restrict: [-3, -2],
        resume_state: checkpoint,
        max_candidates: 0
      )
    end)

    changed_devset = [
      Imp.example(question: "changed", answer: "yes") |> Imp.with_inputs(:question)
    ]

    assert_refused(fn ->
      BootstrapFewShotWithRandomSearch.compile(optimizer, program, trainset, changed_devset,
        restrict: [-3, -2],
        resume_state: checkpoint,
        max_candidates: 0
      )
    end)

    assert_refused(fn ->
      BootstrapFewShotWithRandomSearch.compile(
        %{optimizer | max_rounds: 2},
        program,
        trainset,
        devset,
        restrict: [-3, -2],
        resume_state: checkpoint,
        max_candidates: 0
      )
    end)

    assert Agent.get(counter, & &1) == 0
  end

  test "an explicit max_errors equal to the default resumes a run that had none" do
    counter = start_supervised!({Agent, fn -> 0 end})
    {program, optimizer, trainset, devset} = fixture(counter)
    optimizer = %{optimizer | max_errors: nil}

    checkpoint =
      optimizer
      |> RandomSearch.compile(program, trainset, devset, restrict: [-3, -2], max_candidates: 0)
      |> Report.fetch()
      |> then(& &1.metadata.resume_state)
      |> Jason.encode!()
      |> Jason.decode!()

    resumed =
      %{optimizer | max_errors: 10}
      |> RandomSearch.compile(program, trainset, devset,
        restrict: [-3, -2],
        resume_state: checkpoint
      )
      |> Report.fetch()

    assert resumed.metadata.resumed
    assert resumed.metadata.max_errors_source == :explicit

    assert_refused(fn ->
      RandomSearch.compile(%{optimizer | max_errors: 9}, program, trainset, devset,
        restrict: [-3, -2],
        resume_state: checkpoint,
        max_candidates: 0
      )
    end)
  end

  test "public optimize front door can pause before the first candidate" do
    counter = start_supervised!({Agent, fn -> 0 end})
    {program, optimizer, trainset, devset} = fixture(counter)

    paused =
      Imp.optimize!(program, optimizer, trainset, devset,
        restrict: [-3, -2],
        max_candidates: 0
      )

    report = Report.fetch(paused)
    assert report.metadata.run_status == :paused
    assert report.metadata.completed_candidates == 0
    assert report.candidate_count == 0
    assert is_map(report.metadata.resume_state)
    assert Agent.get(counter, & &1) == 0
  end

  test "anonymous metrics remain full-run-only and explicitly non-durable" do
    counter = start_supervised!({Agent, fn -> 0 end})
    {program, _optimizer, trainset, devset} = fixture(counter)
    optimizer = random_optimizer(Imp.Metrics.exact_match(:answer), nil)

    report =
      optimizer
      |> BootstrapFewShotWithRandomSearch.compile(program, trainset, devset, restrict: [-3, -2])
      |> Report.fetch()

    refute report.metadata.durable
    assert is_nil(report.metadata.metric_identity)
    assert is_nil(report.metadata.resume_state)

    assert_raise ArgumentError, ~r/requires :metric_identity/, fn ->
      BootstrapFewShotWithRandomSearch.compile(optimizer, program, trainset, devset,
        restrict: [-3, -2],
        max_candidates: 0
      )
    end
  end

  @tag :tmp_dir
  test "fresh OS resumes with only the remaining seed schedule", %{tmp_dir: tmp_dir} do
    checkpoint = Path.join(tmp_dir, "checkpoint.json")
    created = Path.join(tmp_dir, "created.json")
    resumed = Path.join(tmp_dir, "resumed.json")

    assert {_output, 0} = fresh_os(["create", checkpoint, created])
    assert {_output, 0} = fresh_os(["resume", checkpoint, resumed])

    assert created |> File.read!() |> Jason.decode!() == %{
             "best_score" => 100.0,
             "completed_candidates" => 2,
             "resumed" => false,
             "seeds" => [-3, -2],
             "status" => "paused",
             "task_calls" => 2
           }

    assert resumed |> File.read!() |> Jason.decode!() == %{
             "best_score" => 100.0,
             "completed_candidates" => 4,
             "resumed" => true,
             "seeds" => [-3, -2, -1, 0],
             "status" => "complete",
             "task_calls" => 4
           }
  end

  defp fixture(counter) do
    task_lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          Agent.update(counter, &(&1 + 1))
          %{answer: "yes"}
        end
      )

    program = Imp.predict("question -> answer", lm: task_lm)

    trainset =
      for question <- ["q1", "q2"] do
        Imp.example(question: question, answer: "yes") |> Imp.with_inputs(:question)
      end

    {program, random_optimizer(captured_metric(counter), metric_identity()), trainset,
     [hd(trainset)]}
  end

  defp random_optimizer(metric, identity) do
    BootstrapFewShotWithRandomSearch.new(metric,
      metric_identity: identity,
      num_candidate_programs: 1,
      max_bootstrapped_demos: 1,
      max_labeled_demos: 1,
      max_rounds: 1,
      max_errors: :infinity
    )
  end

  defp captured_metric(counter) do
    fn example, prediction ->
      _ = Agent.get(counter, & &1)
      exact_metric(example, prediction)
    end
  end

  defp metric_identity(config \\ %{"field" => "answer", "mode" => "exact"}) do
    %{"id" => "random-search-exact-answer", "version" => 1, "config" => config}
  end

  defp assert_refused(fun) do
    assert_raise ArgumentError,
                 ~r/does not match the program runtime, datasets, or configuration/,
                 fun
  end

  defp fresh_os(args) do
    expression = "Imp.Test.RandomSearchResumeOS.run(System.argv())"

    System.cmd("mix", ["run", "--no-compile", "--no-deps-check", "-e", expression, "--" | args],
      env: [{"MIX_ENV", "test"}],
      stderr_to_stdout: true
    )
  end
end
