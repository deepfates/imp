defmodule Imp.Test.InferRulesResumeOS do
  @moduledoc false

  alias Imp.Optimizer.{InferRules, Report}

  def run(["create", checkpoint_path, result_path]) do
    {program, optimizer, trainset, devset, counter} = fixture()

    report =
      optimizer
      |> InferRules.compile(program, trainset, devset, max_operations: 4)
      |> Report.fetch()

    File.write!(checkpoint_path, Jason.encode!(report.metadata.resume_state))
    write_result(result_path, report, counter)
  end

  def run(["resume", checkpoint_path, result_path]) do
    {program, optimizer, trainset, devset, counter} = fixture()
    checkpoint = checkpoint_path |> File.read!() |> Jason.decode!()

    report =
      optimizer
      |> InferRules.compile(program, trainset, devset, resume_state: checkpoint)
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
      InferRules.new(metric,
        candidates: ["Return yes.", "Answer exactly."],
        metric_identity: %{
          "id" => "infer-rules-exact-answer",
          "version" => 1,
          "config" => %{"field" => "answer"}
        },
        max_bootstrapped_demos: 1,
        max_labeled_demos: 0
      )

    program = Imp.predict("question -> answer", lm: task_lm)
    row = Imp.example(question: "q", answer: "yes") |> Imp.with_inputs(:question)
    {program, optimizer, [row], [row], counter}
  end

  defp write_result(path, report, counter) do
    result = %{
      status: report.metadata.run_status,
      resumed: report.metadata.resumed,
      completed_operations: report.metadata.completed_operations,
      candidate_count: report.candidate_count,
      best_score: report.best_score,
      task_calls: Agent.get(counter, & &1)
    }

    File.write!(path, Jason.encode!(result))
    :ok
  end
end
