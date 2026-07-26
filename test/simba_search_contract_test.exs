defmodule Imp.Optimizer.SIMBA.SearchContractTest do
  use ExUnit.Case

  test "samples variable trajectories, registers all candidates, and validates finalists" do
    parent = self()

    task_lm = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn messages, opts ->
          send(parent, {:simba_task, messages})
          prompt = Enum.map_join(messages, "\n", & &1.content)
          rollout = Keyword.get(opts, :rollout_id, -1)

          if prompt =~ "Always answer Paris" or rem(max(rollout, 0), 2) == 0,
            do: %{answer: "Paris"},
            else: %{answer: "unknown"}
        end
      ]
    }

    prompt_lm = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn messages, _opts ->
          send(parent, {:simba_reflection, messages})

          %{
            discussion: "The successful trajectory answers directly.",
            module_advice: %{main: "Always answer Paris for questions about France."}
          }
        end
      ]
    }

    program = Imp.predict("question -> answer", lm: task_lm)

    trainset =
      for question <- ["Capital of France?", "Eiffel Tower city?"] do
        Imp.example(question: question, answer: "Paris") |> Imp.with_inputs(:question)
      end

    optimizer =
      Imp.Optimizer.SIMBA.new(Imp.Metrics.exact_match(:answer),
        bsize: 2,
        num_candidates: 2,
        max_steps: 2,
        max_demos: 2,
        prompt_lm: prompt_lm,
        seed: 4
      )

    compiled = Imp.Optimizer.SIMBA.compile(optimizer, program, trainset)
    report = Imp.Optimizer.Report.fetch(compiled)

    assert report.optimizer == :simba
    assert report.candidate_count > 0
    assert report.metadata.population_size == report.candidate_count + 1
    assert report.metadata.trajectory_calls == 8
    assert report.metadata.candidate_evaluation_calls > 0
    assert length(report.metadata.trial_logs) == 2
    assert Enum.all?(report.candidates, &is_list(&1.scores))
    assert report.metadata.upstream_commit == "b2829b7"
    assert report.best_score == Enum.max(Enum.map(report.metadata.final_candidates, & &1.score))

    final_scores = Enum.map(report.metadata.final_candidates, & &1.score)
    assert final_scores == Enum.sort(final_scores, :desc)

    assert Enum.all?(report.metadata.final_candidates, fn finalist ->
             [%{name: :main, instruction: instruction, demos: demos}] = finalist.parameters
             is_binary(instruction) and is_list(demos)
           end)

    assert Enum.all?(report.metadata.trial_logs, &Map.has_key?(&1, :train_score))

    assert_received {:simba_reflection, reflection_messages}
    reflection_prompt = Enum.map_join(reflection_messages, "\n", & &1.content)
    assert reflection_prompt =~ "defmodule Imp.Predict.Predict"
    assert reflection_prompt =~ "Module main"
    assert reflection_prompt =~ "Input Fields"
    assert reflection_prompt =~ "better_program_trajectory"

    task_messages =
      Stream.repeatedly(fn ->
        receive do
          {:simba_task, messages} -> messages
        after
          0 -> :done
        end
      end)
      |> Enum.take_while(&(&1 != :done))

    if Enum.any?(report.metadata.final_candidates, fn finalist ->
         Enum.any?(finalist.parameters, &(&1.demos != []))
       end) do
      assert Enum.any?(task_messages, fn messages ->
               length(messages) >= 4 and Enum.any?(messages, &(&1.role == :assistant))
             end)
    end
  end

  test "does not register skipped identity programs as optimizer candidates" do
    lm =
      Imp.LM.Static.new(handler: fn _messages, _opts -> %{answer: "Paris"} end)

    program = Imp.predict("question -> answer", lm: lm)

    trainset = [
      Imp.example(question: "Capital of France?", answer: "Paris")
      |> Imp.with_inputs(:question)
    ]

    compiled =
      Imp.Optimizer.SIMBA.new(Imp.Metrics.exact_match(:answer),
        bsize: 1,
        num_candidates: 2,
        max_steps: 1,
        max_demos: 0,
        prompt_lm: lm,
        seed: 0
      )
      |> Imp.Optimizer.SIMBA.compile(program, trainset, trainset)

    report = Imp.Optimizer.Report.fetch(compiled)
    assert report.candidate_count == 0
    assert report.candidates == []
    assert report.metadata.population_size == 1
    assert report.metadata.candidate_evaluation_calls == 0
    assert [%{candidate_ids: [], candidate_scores: []}] = report.metadata.trial_logs
  end

  test "prepares teacher-first rollout models from the baseline rollout id" do
    parent = self()

    base_lm = %{
      module: Imp.LM.Static,
      opts: [
        rollout_id: 17,
        temperature: 0.25,
        handler: fn _, opts ->
          send(parent, {:base_rollout, opts})
          %{answer: "yes"}
        end
      ]
    }

    teacher_lm = %{
      module: Imp.LM.Static,
      opts: [
        temperature: 0.7,
        handler: fn _, opts ->
          send(parent, {:teacher_rollout, opts})
          %{answer: "yes"}
        end
      ]
    }

    prompt_lm = %{
      module: Imp.LM.Static,
      opts: [handler: fn _, _ -> %{discussion: "unused", module_advice: %{}} end]
    }

    program = Imp.predict("question -> answer", lm: base_lm)

    example = Imp.example(question: "q", answer: "yes") |> Imp.with_inputs(:question)

    Imp.Optimizer.SIMBA.new(Imp.Metrics.exact_match(:answer),
      bsize: 1,
      num_candidates: 2,
      max_steps: 1,
      max_demos: 0,
      prompt_lm: prompt_lm,
      teacher_lm: teacher_lm,
      max_concurrency: 1,
      seed: 2
    )
    |> Imp.Optimizer.SIMBA.compile(program, [example])

    assert_receive {:teacher_rollout, teacher_opts}
    assert teacher_opts[:rollout_id] == 17
    assert teacher_opts[:temperature] == 0.7

    assert_receive {:base_rollout, base_opts}
    assert base_opts[:rollout_id] == 18
    assert base_opts[:temperature] == 1.0
  end

  test "suppresses one side of tied eligible rule trajectories with upstream N/A values" do
    parent = self()

    task_lm = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn messages, opts ->
          prompt = Enum.map_join(messages, "\n", & &1.content)
          rollout_id = Keyword.get(opts, :rollout_id, 0)

          if prompt =~ "tie",
            do: %{answer: "tie"},
            else: %{answer: Integer.to_string(rollout_id)}
        end
      ]
    }

    prompt_lm = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn messages, _opts ->
          send(parent, {:reflection_payload, messages})
          %{discussion: "contrast", module_advice: %{main: "Keep the successful behavior."}}
        end
      ]
    }

    metric = fn example, prediction ->
      case Imp.Example.to_map(example).question do
        "tie" -> 0.5
        "spread" -> if(Imp.get(prediction, :answer) == "0", do: 0.0, else: 1.0)
      end
    end

    program = Imp.predict("question -> answer", lm: task_lm)

    trainset =
      Enum.map(["tie", "spread"], fn question ->
        Imp.example(question: question, answer: "unused") |> Imp.with_inputs(:question)
      end)

    Imp.Optimizer.SIMBA.new(metric,
      bsize: 2,
      num_candidates: 3,
      max_steps: 1,
      max_demos: 0,
      prompt_lm: prompt_lm,
      max_concurrency: 1,
      seed: 3
    )
    |> Imp.Optimizer.SIMBA.compile(program, trainset)

    payloads =
      for _ <- 1..2 do
        assert_receive {:reflection_payload, messages}
        Enum.map_join(messages, "\n", & &1.content)
      end

    assert Enum.any?(payloads, &(&1 =~ "N/A" and &1 =~ "Prediction not available"))
  end

  test "passes normalized metric feedback and metadata into rule reflection" do
    parent = self()

    task_lm = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn _messages, opts ->
          if rem(Keyword.get(opts, :rollout_id, 0), 2) == 0,
            do: %{answer: "correct"},
            else: %{answer: "wrong"}
        end
      ]
    }

    prompt_lm = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn messages, _opts ->
          send(parent, {:reflection_with_reward_info, messages})
          %{discussion: "use the metric guidance", module_advice: %{main: "Answer correctly."}}
        end
      ]
    }

    metric = fn _example, prediction ->
      answer = Imp.get(prediction, :answer)
      score = if answer == "correct", do: 1.0, else: 0.0

      %{
        score: score,
        feedback:
          "The answer #{answer} is #{if(score == 1.0, do: "acceptable", else: "incorrect")}",
        metadata: %{criterion: "exact semantic answer"}
      }
    end

    program = Imp.predict("question -> answer", lm: task_lm)
    example = Imp.example(question: "q", answer: "correct") |> Imp.with_inputs(:question)

    Imp.Optimizer.SIMBA.new(metric,
      bsize: 1,
      num_candidates: 2,
      max_steps: 1,
      max_demos: 0,
      prompt_lm: prompt_lm,
      max_concurrency: 1,
      seed: 0
    )
    |> Imp.Optimizer.SIMBA.compile(program, [example], [example])

    assert_receive {:reflection_with_reward_info, messages}
    prompt = Enum.map_join(messages, "\n", & &1.content)
    assert prompt =~ "The answer correct is acceptable"
    assert prompt =~ "The answer wrong is incorrect"
    assert prompt =~ "exact semantic answer"
  end

  test "truncates demo input representations by Unicode characters with the upstream marker" do
    parent = self()

    task_lm = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn messages, opts ->
          prompt = Enum.map_join(messages, "\n", & &1.content)
          if prompt =~ "TRUNCATED FOR BREVITY", do: send(parent, {:truncated_demo, prompt})

          if Keyword.get(opts, :rollout_id, 0) == 0,
            do: %{answer: "yes"},
            else: %{answer: "no"}
        end
      ]
    }

    prompt_lm = %{
      module: Imp.LM.Static,
      opts: [handler: fn _, _ -> %{discussion: "unused", module_advice: %{}} end]
    }

    program = Imp.predict("text, context -> answer", lm: task_lm)

    example =
      Imp.example(text: "ééé", context: [1, 2, 3], answer: "yes")
      |> Imp.with_inputs([:text, :context])

    Imp.Optimizer.SIMBA.new(Imp.Metrics.exact_match(:answer),
      bsize: 1,
      num_candidates: 2,
      max_steps: 1,
      max_demos: 1,
      demo_input_field_maxlen: 2,
      prompt_lm: prompt_lm,
      max_concurrency: 1,
      seed: 0
    )
    |> Imp.Optimizer.SIMBA.compile(program, [example])

    assert_receive {:truncated_demo, prompt}
    assert prompt =~ "éé\n\t\t... <TRUNCATED FOR BREVITY>"
    assert prompt =~ "[1\n\t\t... <TRUNCATED FOR BREVITY>"
  end

  test "same seed reproduces batches and candidate state" do
    task_lm = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn _, opts ->
          %{answer: if(rem(Keyword.get(opts, :rollout_id, 0), 2) == 0, do: "yes", else: "no")}
        end
      ]
    }

    prompt_lm = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn _, _ ->
          %{discussion: "Prefer the successful answer.", module_advice: %{main: "Answer yes."}}
        end
      ]
    }

    program = Imp.predict("question -> answer", lm: task_lm)

    examples =
      for index <- 1..4 do
        Imp.example(question: "q#{index}", answer: "yes") |> Imp.with_inputs(:question)
      end

    run = fn seed ->
      Imp.Optimizer.SIMBA.new(Imp.Metrics.exact_match(:answer),
        bsize: 2,
        num_candidates: 2,
        max_steps: 2,
        prompt_lm: prompt_lm,
        seed: seed
      )
      |> Imp.Optimizer.SIMBA.compile(program, examples)
      |> Imp.Optimizer.Report.fetch()
      |> then(&%{logs: &1.metadata.trial_logs, candidates: &1.candidates})
    end

    assert run.(12) == run.(12)
  end

  test "enforces upstream dataset and prompt-model boundaries" do
    program = Imp.predict("question -> answer")
    example = Imp.example(question: "q", answer: "a") |> Imp.with_inputs(:question)

    assert_raise ArgumentError, ~r/trainset too small/, fn ->
      Imp.Optimizer.SIMBA.new(Imp.Metrics.exact_match(:answer),
        bsize: 2,
        prompt_lm: Imp.LM.Static
      )
      |> Imp.Optimizer.SIMBA.compile(program, [example])
    end

    assert_raise ArgumentError, ~r/requires :prompt_lm/, fn ->
      Imp.Optimizer.SIMBA.new(Imp.Metrics.exact_match(:answer), bsize: 1)
      |> Imp.Optimizer.SIMBA.compile(program, [example])
    end
  end
end
