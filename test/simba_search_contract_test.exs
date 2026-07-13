defmodule DSEx.Optimizer.SIMBA.SearchContractTest do
  use ExUnit.Case

  test "samples variable trajectories, registers all candidates, and validates finalists" do
    parent = self()

    task_lm = %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn messages, opts ->
          prompt = Enum.map_join(messages, "\n", & &1.content)
          rollout = Keyword.get(opts, :rollout_id, -1)

          if prompt =~ "Always answer Paris" or rem(max(rollout, 0), 2) == 0,
            do: %{answer: "Paris"},
            else: %{answer: "unknown"}
        end
      ]
    }

    prompt_lm = %{
      module: DSEx.LM.Static,
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

    program = DSEx.predict("question -> answer", lm: task_lm)

    trainset =
      for question <- ["Capital of France?", "Eiffel Tower city?"] do
        DSEx.example(question: question, answer: "Paris") |> DSEx.with_inputs(:question)
      end

    optimizer =
      DSEx.Optimizer.SIMBA.new(DSEx.Metrics.exact_match(:answer),
        bsize: 2,
        num_candidates: 2,
        max_steps: 2,
        max_demos: 2,
        prompt_lm: prompt_lm,
        seed: 4
      )

    compiled = DSEx.Optimizer.SIMBA.compile(optimizer, program, trainset)
    report = DSEx.Optimizer.Report.fetch(compiled)

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
    assert Enum.all?(report.metadata.trial_logs, &Map.has_key?(&1, :train_score))

    assert_received {:simba_reflection, reflection_messages}
    reflection_prompt = Enum.map_join(reflection_messages, "\n", & &1.content)
    assert reflection_prompt =~ "defmodule DSEx.Predict.Predict"
    assert reflection_prompt =~ "Module main"
    assert reflection_prompt =~ "Input Fields"
    assert reflection_prompt =~ "better_program_trajectory"
  end

  test "prepares teacher-first rollout models from the baseline rollout id" do
    parent = self()

    base_lm = %{
      module: DSEx.LM.Static,
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
      module: DSEx.LM.Static,
      opts: [
        temperature: 0.7,
        handler: fn _, opts ->
          send(parent, {:teacher_rollout, opts})
          %{answer: "yes"}
        end
      ]
    }

    prompt_lm = %{
      module: DSEx.LM.Static,
      opts: [handler: fn _, _ -> %{discussion: "unused", module_advice: %{}} end]
    }

    program = DSEx.predict("question -> answer", lm: base_lm)

    example = DSEx.example(question: "q", answer: "yes") |> DSEx.with_inputs(:question)

    DSEx.Optimizer.SIMBA.new(DSEx.Metrics.exact_match(:answer),
      bsize: 1,
      num_candidates: 2,
      max_steps: 1,
      max_demos: 0,
      prompt_lm: prompt_lm,
      teacher_lm: teacher_lm,
      max_concurrency: 1,
      seed: 2
    )
    |> DSEx.Optimizer.SIMBA.compile(program, [example])

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
      module: DSEx.LM.Static,
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
      module: DSEx.LM.Static,
      opts: [
        handler: fn messages, _opts ->
          send(parent, {:reflection_payload, messages})
          %{discussion: "contrast", module_advice: %{main: "Keep the successful behavior."}}
        end
      ]
    }

    metric = fn example, prediction ->
      case DSEx.Example.to_map(example).question do
        "tie" -> 0.5
        "spread" -> if(DSEx.get(prediction, :answer) == "0", do: 0.0, else: 1.0)
      end
    end

    program = DSEx.predict("question -> answer", lm: task_lm)

    trainset =
      Enum.map(["tie", "spread"], fn question ->
        DSEx.example(question: question, answer: "unused") |> DSEx.with_inputs(:question)
      end)

    DSEx.Optimizer.SIMBA.new(metric,
      bsize: 2,
      num_candidates: 3,
      max_steps: 1,
      max_demos: 0,
      prompt_lm: prompt_lm,
      max_concurrency: 1,
      seed: 3
    )
    |> DSEx.Optimizer.SIMBA.compile(program, trainset)

    payloads =
      for _ <- 1..2 do
        assert_receive {:reflection_payload, messages}
        Enum.map_join(messages, "\n", & &1.content)
      end

    assert Enum.any?(payloads, &(&1 =~ "N/A" and &1 =~ "Prediction not available"))
  end

  test "truncates demo input representations by Unicode characters with the upstream marker" do
    parent = self()

    task_lm = %{
      module: DSEx.LM.Static,
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
      module: DSEx.LM.Static,
      opts: [handler: fn _, _ -> %{discussion: "unused", module_advice: %{}} end]
    }

    program = DSEx.predict("text, context -> answer", lm: task_lm)

    example =
      DSEx.example(text: "ééé", context: [1, 2, 3], answer: "yes")
      |> DSEx.with_inputs([:text, :context])

    DSEx.Optimizer.SIMBA.new(DSEx.Metrics.exact_match(:answer),
      bsize: 1,
      num_candidates: 2,
      max_steps: 1,
      max_demos: 1,
      demo_input_field_maxlen: 2,
      prompt_lm: prompt_lm,
      max_concurrency: 1,
      seed: 0
    )
    |> DSEx.Optimizer.SIMBA.compile(program, [example])

    assert_receive {:truncated_demo, prompt}
    assert prompt =~ "éé\n\t\t... <TRUNCATED FOR BREVITY>"
    assert prompt =~ "[1\n\t\t... <TRUNCATED FOR BREVITY>"
  end

  test "same seed reproduces batches and candidate state" do
    task_lm = %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn _, opts ->
          %{answer: if(rem(Keyword.get(opts, :rollout_id, 0), 2) == 0, do: "yes", else: "no")}
        end
      ]
    }

    prompt_lm = %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn _, _ ->
          %{discussion: "Prefer the successful answer.", module_advice: %{main: "Answer yes."}}
        end
      ]
    }

    program = DSEx.predict("question -> answer", lm: task_lm)

    examples =
      for index <- 1..4 do
        DSEx.example(question: "q#{index}", answer: "yes") |> DSEx.with_inputs(:question)
      end

    run = fn seed ->
      DSEx.Optimizer.SIMBA.new(DSEx.Metrics.exact_match(:answer),
        bsize: 2,
        num_candidates: 2,
        max_steps: 2,
        prompt_lm: prompt_lm,
        seed: seed
      )
      |> DSEx.Optimizer.SIMBA.compile(program, examples)
      |> DSEx.Optimizer.Report.fetch()
      |> then(&%{logs: &1.metadata.trial_logs, candidates: &1.candidates})
    end

    assert run.(12) == run.(12)
  end

  test "enforces upstream dataset and prompt-model boundaries" do
    program = DSEx.predict("question -> answer")
    example = DSEx.example(question: "q", answer: "a") |> DSEx.with_inputs(:question)

    assert_raise ArgumentError, ~r/trainset too small/, fn ->
      DSEx.Optimizer.SIMBA.new(DSEx.Metrics.exact_match(:answer),
        bsize: 2,
        prompt_lm: DSEx.LM.Static
      )
      |> DSEx.Optimizer.SIMBA.compile(program, [example])
    end

    assert_raise ArgumentError, ~r/requires :prompt_lm/, fn ->
      DSEx.Optimizer.SIMBA.new(DSEx.Metrics.exact_match(:answer), bsize: 1)
      |> DSEx.Optimizer.SIMBA.compile(program, [example])
    end
  end
end
