defmodule Imp.Test.SIMBAMetricResumeOS do
  alias Imp.Optimizer.{Report, SIMBA}

  def run(["create", checkpoint_path, result_path]) do
    {:ok, state} = Agent.start_link(fn -> counters() end)

    {program, optimizer, trainset, final_set} =
      fixture(state, identity("exact"), "credential-before")

    report =
      optimizer
      |> SIMBA.compile(program, trainset, final_set, max_steps: 1)
      |> Report.fetch()

    write!(checkpoint_path, report.metadata.resume_state)
    write!(result_path, %{status: "created", counters: Agent.get(state, & &1)})
    :ok
  end

  def run(["resume", checkpoint_path, result_path, mode]) when mode in ["same", "drift"] do
    {:ok, state} = Agent.start_link(fn -> counters() end)
    config = if mode == "same", do: "exact", else: "case_insensitive"

    {program, optimizer, trainset, final_set} =
      fixture(state, identity(config), "credential-after")

    checkpoint = checkpoint_path |> File.read!() |> Jason.decode!()

    try do
      report =
        optimizer
        |> SIMBA.compile(program, trainset, final_set,
          resume_state: checkpoint,
          max_steps: 0
        )
        |> Report.fetch()

      write!(result_path, %{
        status: "resumed",
        resumed: report.metadata.resumed,
        completed_steps: report.metadata.completed_steps,
        metric_identity: report.metadata.metric_identity,
        counters: Agent.get(state, & &1)
      })

      :ok
    rescue
      error ->
        write!(result_path, %{
          status: "refused",
          error: Exception.message(error),
          counters: Agent.get(state, & &1)
        })

        {:error, error}
    end
  end

  defp fixture(state, identity, credential) do
    task_lm =
      Imp.LM.Static.new(
        api_key: credential,
        handler: fn messages, opts ->
          Agent.update(state, &Map.update!(&1, :task_calls, fn count -> count + 1 end))
          rendered = Enum.map_join(messages, "\n", & &1.content)

          if rendered =~ "Answer yes." or rem(Keyword.get(opts, :rollout_id, 0), 2) == 0,
            do: %{answer: "yes"},
            else: %{answer: "no"}
        end
      )

    prompt_lm =
      Imp.LM.Static.new(
        api_key: credential,
        handler: fn _messages, _opts ->
          Agent.update(state, &Map.update!(&1, :prompt_calls, fn count -> count + 1 end))
          %{discussion: "Prefer success.", module_advice: %{main: "Answer yes."}}
        end
      )

    metric = fn example, prediction ->
      _ = Agent.get(state, & &1.task_calls)
      Imp.Metrics.exact_match(:answer).(example, prediction)
    end

    program = Imp.predict("question -> answer", lm: task_lm)

    trainset =
      for index <- 1..2 do
        Imp.example(question: "train #{index}", answer: "yes") |> Imp.with_inputs(:question)
      end

    final_set =
      [Imp.example(question: "final", answer: "yes") |> Imp.with_inputs(:question)]

    optimizer =
      SIMBA.new(metric,
        bsize: 1,
        num_candidates: 2,
        max_steps: 2,
        max_demos: 0,
        prompt_lm: prompt_lm,
        num_threads: 1,
        metric_identity: identity,
        seed: 73
      )

    {program, optimizer, trainset, final_set}
  end

  defp identity(mode) do
    %{
      "id" => "fresh-os-exact-answer",
      "version" => 1,
      "config" => %{"field" => "answer", "mode" => mode}
    }
  end

  defp counters, do: %{task_calls: 0, prompt_calls: 0}
  defp write!(path, value), do: File.write!(path, Jason.encode!(value, pretty: true) <> "\n")
end
