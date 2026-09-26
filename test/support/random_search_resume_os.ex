defmodule Imp.Test.RandomSearchResumeOS do
  @moduledoc false

  alias Imp.Optimizer.{BootstrapFewShotWithRandomSearch, Report}

  def run(["create", checkpoint_path, result_path]) do
    {program, optimizer, trainset, devset, counter} = fixture()

    report =
      optimizer
      |> BootstrapFewShotWithRandomSearch.compile(program, trainset, devset,
        restrict: [-3, -2, -1, 0],
        max_candidates: 2
      )
      |> Report.fetch()

    File.write!(checkpoint_path, Jason.encode!(report.metadata.resume_state))
    write_result(result_path, report, counter)
  end

  def run(["resume", checkpoint_path, result_path]) do
    {program, optimizer, trainset, devset, counter} = fixture()
    checkpoint = checkpoint_path |> File.read!() |> Jason.decode!()

    report =
      optimizer
      |> BootstrapFewShotWithRandomSearch.compile(program, trainset, devset,
        restrict: [-3, -2, -1, 0],
        resume_state: checkpoint
      )
      |> Report.fetch()

    write_result(result_path, report, counter)
  end

  defp fixture do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    task_lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          Agent.update(counter, &(&1 + 1))
          %{answer: "yes"}
        end
      )

    metric = fn example, prediction ->
      _ = Agent.get(counter, & &1)
      Imp.Metrics.exact_match(:answer).(example, prediction)
    end

    optimizer =
      BootstrapFewShotWithRandomSearch.new(metric,
        metric_identity: %{
          "id" => "random-search-exact-answer",
          "version" => 1,
          "config" => %{"field" => "answer"}
        },
        num_candidate_programs: 1,
        max_bootstrapped_demos: 1,
        max_labeled_demos: 1,
        max_rounds: 1,
        max_errors: :infinity
      )

    program = Imp.predict("question -> answer", lm: task_lm)

    trainset =
      for question <- ["q1", "q2"] do
        Imp.example(question: question, answer: "yes") |> Imp.with_inputs(:question)
      end

    {program, optimizer, trainset, [hd(trainset)], counter}
  end

  defp write_result(path, report, counter) do
    result = %{
      status: report.metadata.run_status,
      resumed: report.metadata.resumed,
      completed_candidates: report.metadata.completed_candidates,
      seeds: report.metadata.candidate_seeds,
      best_score: report.best_score,
      task_calls: Agent.get(counter, & &1)
    }

    File.write!(path, Jason.encode!(result))
    :ok
  end
end
