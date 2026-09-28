defmodule OptimizerBehavioralCorpusTest do
  use ExUnit.Case

  defmodule ErrorLM do
    @behaviour Imp.LM

    @impl true
    def generate(_lm, _messages, _opts), do: {:error, :offline_candidate}
  end

  defp metric, do: Imp.Metrics.exact_match(:answer)

  defp reflection_lm(instruction \\ "Always answer Paris when asked about France.") do
    Imp.LM.Static.new(handler: fn _messages, _opts -> %{instruction: instruction} end)
  end

  defp copro_proposer_lm(instruction \\ "Always answer Paris when asked about France.") do
    Imp.LM.Static.new(
      handler: fn _messages, _opts ->
        Jason.encode!(%{
          "proposed_instruction" => instruction,
          "proposed_prefix_for_output_field" => "Answer:"
        })
      end
    )
  end

  defp evaluator(program),
    do: Imp.Evaluate.run(Imp.Evaluate.new(devset(), metric()), program)

  defp france_program do
    Imp.predict("question -> answer",
      lm:
        Imp.LM.Static.new(
          handler: fn messages, _opts ->
            prompt = Enum.map_join(messages, "\n", & &1.content)

            cond do
              prompt =~ "Always answer Paris" -> %{answer: "Paris"}
              prompt =~ "[[ ## answer ## ]]\nParis" -> %{answer: "Paris"}
              true -> %{answer: "unknown"}
            end
          end
        )
    )
  end

  defp trainset do
    [
      Imp.example(question: "What is the capital of France?", answer: "Paris")
      |> Imp.Example.with_inputs(:question)
    ]
  end

  defp devset do
    [
      Imp.example(question: "Capital of France?", answer: "Paris")
      |> Imp.Example.with_inputs(:question)
    ]
  end

  test "MIPROv2 searches categorical instruction and demo candidates without regressing baseline" do
    program = france_program()
    baseline_score = evaluator(program).score

    optimizer =
      Imp.Optimizer.MIPROv2.new(metric(),
        auto: nil,
        num_candidates: 5,
        num_trials: 5,
        max_bootstrapped_demos: 0,
        max_labeled_demos: 1,
        minibatch: false,
        startup_trials: 2
      )

    compiled = Imp.Optimizer.MIPROv2.compile(optimizer, program, trainset(), devset())
    report = Imp.Optimizer.Report.fetch(compiled)

    assert report.optimizer == :mipro_v2
    assert report.metadata.algorithm == :mipro_v2
    assert report.metadata.sampler == :joint_categorical_parzen
    assert report.metadata.upstream_sampler == :optuna_multivariate_tpe
    refute Map.has_key?(report.metadata, :compatibility)
    refute report.metadata.exact_sampler_sequence_parity
    assert report.best_score >= baseline_score
    assert report.best_score == evaluator(compiled).score
    assert report.candidate_count == 5
    assert length(report.metadata.full_evaluations) == 6
    assert Enum.any?(report.metadata.full_evaluations, &(&1.kind == :baseline))
    assert report.metadata.search_space["atom:main:demos"] >= 1
    assert Enum.all?(report.candidates, &is_map(&1.params))
  end

  test "MIPROv2 treats zero search counts as baseline-only compile" do
    program = france_program()
    baseline_score = evaluator(program).score

    compiled =
      Imp.Optimizer.MIPROv2.new(metric(),
        auto: nil,
        num_candidates: 1,
        num_trials: 0,
        max_bootstrapped_demos: 0,
        max_labeled_demos: 0,
        minibatch: false,
        startup_trials: 0
      )
      |> Imp.Optimizer.MIPROv2.compile(program, trainset(), devset())

    report = Imp.Optimizer.Report.fetch(compiled)

    assert report.optimizer == :mipro_v2
    assert report.best_score == baseline_score
    assert report.candidate_count == 0
    assert report.candidates == []

    assert [%{kind: :baseline, trial: 0, score: ^baseline_score}] =
             report.metadata.full_evaluations

    assert report.metadata.effective_config.num_trials == 0
  end

  test "MIPROv2 rejects invalid devsets at the public boundary" do
    program = france_program()

    assert_raise ArgumentError, ~r/valset must be enumerable/, fn ->
      Imp.Optimizer.MIPROv2.new(metric(),
        auto: nil,
        num_candidates: 2,
        num_trials: 2,
        max_bootstrapped_demos: 0,
        max_labeled_demos: 1,
        minibatch: false
      )
      |> Imp.Optimizer.MIPROv2.compile(program, trainset(), :not_an_enumerable_devset)
    end
  end

  test "MIPROv2 rejects invalid trainsets at the public boundary" do
    program = france_program()

    assert_raise ArgumentError, ~r/trainset must be enumerable/, fn ->
      Imp.Optimizer.MIPROv2.new(metric(),
        auto: nil,
        num_candidates: 1,
        num_trials: 1,
        max_bootstrapped_demos: 0,
        max_labeled_demos: 1,
        minibatch: false
      )
      |> Imp.Optimizer.MIPROv2.compile(program, :not_an_enumerable_trainset, devset())
    end
  end

  test "GEPA turns textual feedback into reflective candidates and keeps the best" do
    program = france_program()

    optimizer =
      Imp.Optimizer.GEPA.new(metric(),
        execution_profile: :beam_native,
        generations: 2,
        reflection_lm: reflection_lm(),
        max_metric_calls: 20,
        max_full_evaluations: 5,
        feedback_fn: fn _trainset -> "Always answer Paris when asked about France." end
      )

    compiled = Imp.Optimizer.GEPA.compile(optimizer, program, trainset(), devset())
    report = Imp.Optimizer.Report.fetch(compiled)

    assert report.optimizer == :gepa
    assert report.best_score == 1.0
    assert report.best_score == evaluator(compiled).score
    assert report.metadata.feedback =~ "Always answer Paris"
    assert report.metadata.implementation == Imp.Optimizer.GEPA
    assert report.metadata.max_metric_calls == 20
    assert report.metadata.max_full_evaluations == 5
    assert Enum.any?(report.candidates, &(&1.instruction =~ "Always answer Paris"))
  end

  test "GEPA treats zero generations as a baseline-only compile" do
    program = france_program()
    baseline_score = evaluator(program).score

    compiled =
      Imp.Optimizer.GEPA.new(metric(),
        execution_profile: :beam_native,
        generations: 0,
        feedback_fn: fn _trainset -> "Always answer Paris when asked about France." end
      )
      |> Imp.Optimizer.GEPA.compile(program, trainset(), devset())

    report = Imp.Optimizer.Report.fetch(compiled)

    assert report.optimizer == :gepa
    assert report.best_score == baseline_score
    assert report.candidate_count == 1
    assert [%{id: "baseline", mutation: "baseline", score: ^baseline_score}] = report.candidates
    assert report.metadata.generations == 0
  end

  test "GEPA reports metric feedback as feedback, not as failed program calls" do
    # Feedback of any shape - text, a map, a tagged tuple - is the metric's
    # judgement of a row that ran, not a failure.
    for feedback_for <- [
          fn score -> "This trajectory got a score of #{score}." end,
          fn score -> %{verdict: "wrong", score: score} end,
          fn _score -> {:error, "judge says wrong"} end
        ] do
      feedback_metric = fn example, prediction ->
        score = Imp.Metrics.normalize_result(metric().(example, prediction)).score
        %{score: score, feedback: feedback_for.(score)}
      end

      report =
        Imp.Optimizer.GEPA.new(feedback_metric,
          execution_profile: :beam_native,
          generations: 1,
          reflection_lm: reflection_lm("Answer in one word."),
          feedback_fn: fn _trainset -> "Answer in one word." end
        )
        |> Imp.Optimizer.GEPA.compile(france_program(), trainset(), devset())
        |> Imp.Optimizer.Report.fetch()

      assert report.metadata.rejected_candidates > 0
      assert report.errors == []
      assert report.metadata.status == :ok
      assert Enum.all?(report.candidates, &(&1.diagnostics == []))
      refute Enum.any?(report.candidates, &(&1.mutation =~ "Program call failed"))
    end
  end

  test "GEPA reports a metric result it cannot read as an error" do
    for {value, expected} <- [
          {{:ok, 1.0}, "invalid metric result: {:ok, 1.0}"},
          {nil, "invalid metric result: nil"}
        ] do
      report =
        Imp.Optimizer.GEPA.new(fn _example, _prediction -> value end,
          execution_profile: :beam_native,
          generations: 0
        )
        |> Imp.Optimizer.GEPA.compile(france_program(), trainset(), devset())
        |> Imp.Optimizer.Report.fetch()

      assert report.metadata.status == :with_errors
      assert [%{candidate_id: "baseline", diagnostics: [^expected]}] = report.errors
    end
  end

  test "GEPA records program failures diagnostically without using them as instruction advice" do
    broken_program =
      Imp.predict("question -> answer",
        lm: ErrorLM
      )

    compiled =
      Imp.Optimizer.GEPA.new(metric(),
        execution_profile: :beam_native,
        generations: 1,
        reflection_lm: reflection_lm("Recover from malformed candidate outputs."),
        feedback_fn: fn _trainset -> "Recover from malformed candidate outputs." end
      )
      |> Imp.Optimizer.GEPA.compile(broken_program, trainset(), devset())

    report = Imp.Optimizer.Report.fetch(compiled)

    assert report.optimizer == :gepa
    assert report.best_score == 0.0
    assert report.metadata.status == :with_errors
    assert [%{candidate_id: "baseline", diagnostics: ["offline_candidate"]}] = report.errors

    assert Enum.any?(report.candidates, fn candidate ->
             candidate.mutation =~ "Program call failed"
           end)

    refute Enum.any?(report.candidates, fn candidate ->
             candidate.instruction =~ "Program call failed"
           end)
  end

  test "GEPA reports a program that raises as an error" do
    raising_program =
      Imp.predict("question -> answer",
        lm: Imp.Test.FunLM.new(fn _messages, _opts -> raise "candidate crashed" end)
      )

    report =
      Imp.Optimizer.GEPA.new(metric(),
        execution_profile: :beam_native,
        generations: 1,
        reflection_lm: reflection_lm("Answer in one word.")
      )
      |> Imp.Optimizer.GEPA.compile(raising_program, trainset(), devset())
      |> Imp.Optimizer.Report.fetch()

    assert report.metadata.status == :with_errors
    assert [%{candidate_id: "baseline", diagnostics: [diagnostic]}] = report.errors
    assert diagnostic =~ "candidate crashed"
  end

  test "GEPA reports a metric that raises, throws or exits as an error, redacted" do
    for {metric, expected} <- [
          {fn _example, _prediction -> throw(:judge_down) end, "{:throw, :judge_down}"},
          {fn _example, _prediction -> exit(:judge_gone) end, "{:exit, :judge_gone}"},
          {fn _example, _prediction -> throw("judge down") end, ~s({:throw, "judge down"})},
          {fn _example, _prediction -> throw(%{api_key: "sk-judge-secret"}) end,
           ~s({:throw, %{api_key: "[REDACTED]"}})},
          {fn _example, _prediction -> raise "judge rejected sk-judge-secret0" end, "[REDACTED]"}
        ] do
      report =
        Imp.Optimizer.GEPA.new(metric, execution_profile: :beam_native, generations: 0)
        |> Imp.Optimizer.GEPA.compile(france_program(), trainset(), devset())
        |> Imp.Optimizer.Report.fetch()

      assert report.metadata.status == :with_errors
      assert [%{candidate_id: "baseline", diagnostics: [^expected]}] = report.errors
    end
  end

  test "GEPA names a failed proposal as a proposal failure, not a program call failure" do
    program =
      Imp.predict("question -> answer",
        lm:
          Imp.LM.Static.new(
            handler: fn messages, _opts ->
              prompt = Enum.map_join(messages, "\n", & &1.content)
              if prompt =~ "Answer in one word", do: %{answer: "one"}, else: %{answer: "unknown"}
            end
          )
      )

    # The proposed program's rows carry objective scores GEPA cannot accept, so
    # evaluating the proposal raises; with `raise_on_exception: false` the
    # proposal is rejected with that error and the run continues.
    metric = fn _example, prediction ->
      if Imp.Prediction.get(prediction, :answer) == "one",
        do: %{score: 0.0, metadata: %{objective_scores: %{accuracy: "not a number"}}},
        else: 0.0
    end

    report =
      Imp.Optimizer.GEPA.new(metric,
        execution_profile: :beam_native,
        generations: 1,
        proposal_concurrency: 2,
        raise_on_exception: false,
        reflection_lm: reflection_lm("Answer in one word.")
      )
      |> Imp.Optimizer.GEPA.compile(program, trainset(), devset())
      |> Imp.Optimizer.Report.fetch()

    assert [%{instruction: "Answer in one word."} = rejected] =
             Enum.reject(report.candidates, &(&1.id == "baseline"))

    assert rejected.diagnostics == ["GEPA objective scores must be maps with numeric values"]

    assert rejected.mutation ==
             "Proposal failed: GEPA objective scores must be maps with numeric values"
  end

  # A program whose rows carry objective scores GEPA cannot accept once its
  # instruction is "Answer in one word.", so evaluating that proposal raises.
  defp one_word_program do
    Imp.predict("question -> answer",
      lm:
        Imp.LM.Static.new(
          handler: fn messages, _opts ->
            prompt = Enum.map_join(messages, "\n", & &1.content)
            if prompt =~ "Answer in one word", do: %{answer: "one"}, else: %{answer: "unknown"}
          end
        )
    )
  end

  defp unscorable_proposal_metric do
    fn _example, prediction ->
      if Imp.Prediction.get(prediction, :answer) == "one",
        do: %{score: 0.0, metadata: %{objective_scores: %{accuracy: "not a number"}}},
        else: 0.0
    end
  end

  defp run_gepa(metric, program, opts) do
    {:ok, compiled} =
      Imp.Optimizer.GEPA.new(metric, opts)
      |> Imp.Optimizer.run(program, trainset: trainset(), validation: devset())

    {compiled, Imp.Optimizer.Report.fetch(compiled)}
  end

  test "GEPA reports every failed proposal when it continues past all of them" do
    down_lm = Imp.Test.FunLM.new(fn _messages, _opts -> {:error, :reflection_down} end)
    evaluation_failure = "GEPA objective scores must be maps with numeric values"
    reflection_failure = "{:reflection_lm_failed, :reflection_down}"

    cases =
      for profile <- [
            [execution_profile: :gepa_v0_1_4_merge],
            [execution_profile: :beam_native, generations: 3],
            [execution_profile: :beam_native, generations: 3, proposal_concurrency: 2]
          ],
          {metric, reflection, failure} <- [
            {unscorable_proposal_metric(), reflection_lm("Answer in one word."),
             evaluation_failure},
            {metric(), down_lm, reflection_failure}
          ],
          do: {profile, metric, reflection, failure}

    for {profile, metric, reflection, failure} <- cases do
      {compiled, report} =
        run_gepa(
          metric,
          one_word_program(),
          profile ++
            [raise_on_exception: false, reflection_lm: reflection, max_metric_calls: 12]
        )

      label = inspect({profile, failure})

      # The run returns the baseline program; its report cannot be read as a
      # clean run that found nothing better.
      assert Imp.Optimizer.GEPA.Candidate.from_program(compiled) ==
               Imp.Optimizer.GEPA.Candidate.from_program(one_word_program()),
             label

      assert report.metadata.status == :with_errors, label
      assert report.metadata.failed_proposals > 0, label
      assert report.metadata.failed_proposals == report.metadata.rejected_candidates, label
      assert length(report.errors) == report.metadata.failed_proposals, label

      for error <- report.errors do
        assert %{iteration: iteration, diagnostics: [^failure]} = error, label
        assert is_integer(iteration) and iteration > 0, label
      end
    end
  end

  test "GEPA with raise_on_exception left on still raises when a proposal fails" do
    for profile <- [:gepa_v0_1_4_merge, :beam_native] do
      assert {:error,
              {:optimizer_failed, Imp.Optimizer.GEPA,
               %ArgumentError{message: "GEPA objective scores must be maps with numeric values"}}} =
               Imp.Optimizer.GEPA.new(unscorable_proposal_metric(),
                 execution_profile: profile,
                 generations: 3,
                 reflection_lm: reflection_lm("Answer in one word."),
                 max_metric_calls: 12
               )
               |> Imp.Optimizer.run(one_word_program(),
                 trainset: trainset(),
                 validation: devset()
               )
    end
  end

  test "GEPA returns the improved program and reports the failures when only some proposals fail" do
    for profile <- [:gepa_v0_1_4_merge, :beam_native] do
      calls = :counters.new(1, [])

      # The first two reflection calls fail, the rest propose the instruction
      # that solves the task.
      flaky_lm =
        Imp.Test.FunLM.new(fn _messages, _opts ->
          :counters.add(calls, 1, 1)

          if :counters.get(calls, 1) <= 2,
            do: {:error, :reflection_down},
            else: {:ok, %{instruction: "Always answer Paris when asked about France."}}
        end)

      {compiled, report} =
        run_gepa(metric(), france_program(),
          execution_profile: profile,
          generations: 4,
          raise_on_exception: false,
          reflection_lm: flaky_lm,
          max_metric_calls: 20
        )

      assert report.best_score == 1.0, inspect(profile)
      assert evaluator(compiled).score == 1.0, inspect(profile)
      assert report.metadata.status == :with_errors, inspect(profile)
      assert report.metadata.failed_proposals > 0, inspect(profile)

      assert Enum.all?(
               report.errors,
               &(&1.diagnostics == ["{:reflection_lm_failed, :reflection_down}"])
             ),
             inspect(profile)

      # The run returned a program, so it finished, with errors.
      assert %Imp.Observability.Status{state: :succeeded_with_errors} =
               Imp.Observability.status(report)
    end
  end

  test "GEPA under the DSPy profile reports an iteration that raised and continued" do
    # A component feedback callback that raises fails the whole iteration.
    report =
      Imp.Optimizer.GEPA.new(metric(),
        execution_profile: :gepa_v0_1_4_merge,
        raise_on_exception: false,
        component_feedback: %{main: fn _context -> raise "feedback service down" end},
        reflection_lm: reflection_lm("Answer in one word."),
        max_metric_calls: 6
      )
      |> Imp.Optimizer.GEPA.compile(france_program(), trainset(), devset())
      |> Imp.Optimizer.Report.fetch()

    assert report.metadata.status == :with_errors
    assert report.metadata.failed_proposals > 0
    assert report.metadata.failed_proposals == report.metadata.rejected_candidates

    for error <- report.errors do
      assert %{
               candidate_id: nil,
               diagnostics: ["GEPA component feedback failed for :main: feedback service down"]
             } = error
    end
  end

  test "GEPA stops on an operational safety refusal whatever raise_on_exception says" do
    calls = :counters.new(1, [])

    refusing_program =
      Imp.predict("question -> answer",
        lm:
          Imp.LM.Static.new(
            handler: fn messages, _opts ->
              prompt = Enum.map_join(messages, "\n", & &1.content)

              if prompt =~ "Answer in one word" do
                :counters.add(calls, 1, 1)

                raise Imp.OperationalSafetyError.exception(
                        kind: :budget,
                        message: "provider budget exhausted"
                      )
              else
                %{answer: "unknown"}
              end
            end
          )
      )

    for profile <- [
          [execution_profile: :gepa_v0_1_4_merge],
          [execution_profile: :beam_native, generations: 3],
          [execution_profile: :beam_native, generations: 3, proposal_concurrency: 2],
          [
            execution_profile: :beam_native,
            generations: 3,
            proposal_concurrency: 2,
            sampling_strategy: {:same_parent, 1}
          ]
        ],
        raise_on_exception <- [true, false] do
      :counters.put(calls, 1, 0)

      assert_raise Imp.OperationalSafetyError, "provider budget exhausted", fn ->
        Imp.Optimizer.GEPA.new(
          metric(),
          profile ++
            [
              raise_on_exception: raise_on_exception,
              reflection_lm: reflection_lm("Answer in one word."),
              max_metric_calls: 12
            ]
        )
        |> Imp.Optimizer.GEPA.compile(refusing_program, trainset(), devset())
      end

      # The first refused iteration ends the run: only its concurrent slots ran.
      assert :counters.get(calls, 1) <= Keyword.get(profile, :proposal_concurrency, 1),
             inspect({profile, raise_on_exception})
    end
  end

  test "GEPA under beam_native records iterations that threw or exited" do
    for {selector, expected} <- [
          {fn _state, _trajectories, _scores, _index, _candidate -> throw(:selector_gone) end,
           "{:throw, :selector_gone}"},
          {fn _state, _trajectories, _scores, _index, _candidate -> exit(:selector_gone) end,
           "{:exit, :selector_gone}"}
        ],
        profile <- [
          [generations: 2],
          [generations: 2, proposal_concurrency: 2, sampling_strategy: {:same_parent, 1}]
        ] do
      report =
        Imp.Optimizer.GEPA.new(
          metric(),
          profile ++
            [
              execution_profile: :beam_native,
              raise_on_exception: false,
              module_selector: selector,
              reflection_lm: reflection_lm("Answer in one word."),
              max_metric_calls: 12
            ]
        )
        |> Imp.Optimizer.GEPA.compile(france_program(), trainset(), devset())
        |> Imp.Optimizer.Report.fetch()

      assert report.metadata.status == :with_errors
      assert report.metadata.failed_proposals == 2
      assert Enum.all?(report.errors, &(&1.diagnostics == [expected])), inspect(report.errors)
    end
  end

  test "a cancelled run stops GEPA although raise_on_exception is false" do
    parent = self()

    blocking_metric = fn _example, prediction ->
      if Imp.Prediction.get(prediction, :answer) == "one" do
        send(parent, {:proposal_metric, self()})
        Process.sleep(:infinity)
      end

      0.0
    end

    optimizer =
      Imp.Optimizer.GEPA.new(blocking_metric,
        execution_profile: :beam_native,
        generations: 3,
        proposal_concurrency: 2,
        sampling_strategy: {:same_parent, 1},
        raise_on_exception: false,
        reflection_lm: reflection_lm("Answer in one word."),
        max_metric_calls: 20
      )

    program = one_word_program()

    host =
      Imp.predict("question -> answer",
        lm:
          Imp.Test.FunLM.new(fn _messages, _opts ->
            Imp.Optimizer.GEPA.compile(optimizer, program, trainset(), devset())
            send(parent, :gepa_returned)
            {:ok, %{answer: "done"}}
          end)
      )

    assert {:ok, run} = Imp.start_run(host, %{question: "q"})
    assert_receive {:proposal_metric, metric_pid}, 5_000
    metric_ref = Process.monitor(metric_pid)
    task_ref = Process.monitor(run.task.pid)

    assert :ok = Imp.Run.cancel(run, :test_cancel, 1_000)
    assert_receive {:DOWN, ^task_ref, :process, _pid, _reason}, 5_000
    assert_receive {:DOWN, ^metric_ref, :process, _pid, _reason}, 5_000
    refute_receive :gepa_returned, 200
    refute_receive {:proposal_metric, _pid}, 200
  end

  test "a shutdown exit inside a proposal stops GEPA although raise_on_exception is false" do
    parent = self()

    # A host that traps exits hands its parent's shutdown to the code it runs
    # as an exit, as Imp's interruptible sleeps do.
    await_shutdown = fn fallback ->
      send(parent, {:hook, self()})
      [host_parent | _] = Process.get(:"$ancestors")

      receive do
        {:EXIT, ^host_parent, reason} -> exit(reason)
      after
        300 -> fallback
      end
    end

    for hook <- [
          module_selector: fn _state, _trajectories, _scores, _index, _candidate ->
            await_shutdown.([:main])
          end,
          reflection_strategy: fn _candidate, _dataset, _components ->
            await_shutdown.(%{new_texts: %{main: "Answer in one word."}})
          end
        ] do
      {:ok, supervisor} = Task.Supervisor.start_link()

      host =
        Task.Supervisor.async_nolink(supervisor, fn ->
          Process.flag(:trap_exit, true)

          {_compiled, report} =
            Imp.Optimizer.GEPA.new(
              metric(),
              [
                execution_profile: :beam_native,
                generations: 4,
                raise_on_exception: false,
                reflection_lm: reflection_lm("Answer in one word."),
                max_metric_calls: 40
              ] ++ [hook]
            )
            |> Imp.Optimizer.GEPA.compile_with_report(france_program(), trainset(), devset())

          send(parent, {:returned, report.errors})
        end)

      assert_receive {:hook, _pid}, 5_000
      host_ref = Process.monitor(host.pid)
      :ok = Task.Supervisor.terminate_child(supervisor, host.pid)

      assert_receive {:DOWN, ^host_ref, :process, _pid, :shutdown}, 5_000
      refute_received {:returned, _errors}
      refute_received {:hook, _pid}
    end
  end

  test "an exit asking GEPA's process to stop goes on up from each hook" do
    for reason <- [:shutdown, {:shutdown, :bye}],
        hook <- [
          module_selector: fn _state, _trajectories, _scores, _index, _candidate ->
            exit(reason)
          end,
          reflection_strategy: fn _candidate, _dataset, _components -> exit(reason) end
        ] do
      assert catch_exit(
               Imp.Optimizer.GEPA.new(
                 metric(),
                 [
                   execution_profile: :beam_native,
                   generations: 2,
                   raise_on_exception: false,
                   reflection_lm: reflection_lm("Answer in one word."),
                   max_metric_calls: 20
                 ] ++ [hook]
               )
               |> Imp.Optimizer.GEPA.compile(france_program(), trainset(), devset())
             ) == reason
    end
  end

  test "an operational safety refusal inside a ComBee profiling trial ends the run" do
    refusing_program =
      Imp.predict("question -> answer",
        lm:
          Imp.LM.Static.new(
            handler: fn messages, _opts ->
              prompt = Enum.map_join(messages, "\n", & &1.content)

              if prompt =~ "Answer in one word",
                do:
                  raise(
                    Imp.OperationalSafetyError.exception(
                      kind: :budget,
                      message: "provider budget exhausted"
                    )
                  ),
                else: %{answer: "unknown"}
            end
          )
      )

    trainset =
      for index <- 1..8 do
        Imp.example(question: "q#{index}", answer: "Paris") |> Imp.Example.with_inputs(:question)
      end

    # The profiling trial runs a whole iteration in a coordinator worker.
    assert_raise Imp.OperationalSafetyError, "provider budget exhausted", fn ->
      Imp.Optimizer.GEPA.new(metric(),
        execution_profile: :beam_native,
        generations: 3,
        raise_on_exception: false,
        combee: [
          max_concurrency: 1,
          batch_controller: [
            candidate_batch_sizes: [2, 4],
            max_batch_size: 4,
            profiling_timeout: 10_000
          ]
        ],
        reflection_lm: reflection_lm("Answer in one word."),
        max_metric_calls: 60
      )
      |> Imp.Optimizer.GEPA.compile(refusing_program, trainset, trainset)
    end
  end

  test "GEPA counts a slot cancelled by a sibling's failure as cancelled, not failed" do
    slow_reflection =
      Imp.Test.FunLM.new(fn _messages, _opts ->
        Process.sleep(400)
        {:ok, %{instruction: "Always answer Paris when asked about France."}}
      end)

    report =
      Imp.Optimizer.GEPA.new(metric(),
        execution_profile: :beam_native,
        generations: 2,
        proposal_concurrency: 2,
        proposal_timeout: 100,
        raise_on_exception: false,
        reflection_lm: slow_reflection,
        max_metric_calls: 12
      )
      |> Imp.Optimizer.GEPA.compile(france_program(), trainset(), devset())
      |> Imp.Optimizer.Report.fetch()

    assert report.metadata.status == :with_errors
    assert report.metadata.failed_proposals > 0
    assert report.metadata.rejected_candidates > report.metadata.failed_proposals
    assert Enum.all?(report.errors, &(&1.diagnostics == ["timeout"])), inspect(report.errors)
  end

  test "GEPA redacts failure reasons when it records them" do
    secret = "sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG"
    parent = self()

    for opts <- [
          [
            module_selector: fn _state, _trajectories, _scores, _index, _candidate ->
              raise "selector saw #{secret}"
            end,
            reflection_lm: reflection_lm("Answer in one word.")
          ],
          [
            module_selector: fn _state, _trajectories, _scores, _index, _candidate ->
              throw({:token, secret})
            end,
            reflection_lm: reflection_lm("Answer in one word.")
          ],
          [
            module_selector: fn _state, _trajectories, _scores, _index, _candidate ->
              exit({:closed, "api_key=#{secret}"})
            end,
            reflection_lm: reflection_lm("Answer in one word.")
          ],
          [reflection_lm: Imp.Test.FunLM.new(fn _m, _o -> {:error, "bad key #{secret}"} end)],
          [
            proposal_concurrency: 2,
            reflection_lm: Imp.Test.FunLM.new(fn _m, _o -> {:error, "bad key #{secret}"} end)
          ]
        ] do
      {_compiled, report} =
        Imp.Optimizer.GEPA.new(
          metric(),
          [
            execution_profile: :beam_native,
            generations: 2,
            raise_on_exception: false,
            max_metric_calls: 12
          ] ++ opts
        )
        |> Imp.Optimizer.GEPA.compile_with_report(france_program(), trainset(), devset(),
          checkpoint_fn: fn dumped ->
            send(parent, {:checkpoint, dumped})
            :ok
          end
        )

      assert report.metadata.failed_proposals == 2
      checkpoints = collect_checkpoints([])
      assert Enum.any?(checkpoints, &(Jason.encode!(&1) =~ "proposal_error"))
      refute Enum.any?(checkpoints, &(Jason.encode!(&1) =~ "abcdefghijklmnop"))
    end
  end

  defmodule UnloadedFieldError do
    defexception [:message, :gepa_fresh_vm_only_field]
  end

  test "a checkpoint with a custom exception's failure resumes in a fresh VM" do
    parent = self()

    {_compiled, report} =
      Imp.Optimizer.GEPA.new(metric(),
        execution_profile: :beam_native,
        generations: 1,
        raise_on_exception: false,
        module_selector: fn _state, _trajectories, _scores, _index, _candidate ->
          raise UnloadedFieldError, message: "custom exploded", gepa_fresh_vm_only_field: 1
        end,
        reflection_lm: reflection_lm("Answer in one word."),
        max_metric_calls: 20
      )
      |> Imp.Optimizer.GEPA.compile_with_report(france_program(), trainset(), devset(),
        checkpoint_fn: fn dumped ->
          send(parent, {:checkpoint, dumped})
          :ok
        end
      )

    assert [%{diagnostics: ["custom exploded"]}] = report.errors
    checkpoint = collect_checkpoints([]) |> hd()

    path =
      Path.join(
        System.tmp_dir!(),
        "gepa-custom-exception-#{System.unique_integer([:positive])}.json"
      )

    File.write!(path, Jason.encode!(checkpoint))
    on_exit(fn -> File.rm(path) end)

    # The fresh VM has neither the test module nor its field atom; it resumes
    # with a selector that raises an ordinary error. It loads Imp's own
    # modules first, since a checkpoint also names atoms Imp defines outside
    # the modules a resume loads.
    expression = """
    {:ok, _} = Application.ensure_all_started(:imp)
    Enum.each(Application.spec(:imp, :modules), &Code.ensure_loaded/1)
    resume_state = System.argv() |> hd() |> File.read!() |> Jason.decode!()

    program =
      Imp.predict("question -> answer",
        lm: Imp.LM.Static.new(handler: fn _messages, _opts -> %{answer: "unknown"} end)
      )

    train = [
      Imp.example(question: "What is the capital of France?", answer: "Paris")
      |> Imp.Example.with_inputs(:question)
    ]

    dev = [
      Imp.example(question: "Capital of France?", answer: "Paris")
      |> Imp.Example.with_inputs(:question)
    ]

    {_compiled, report} =
      Imp.Optimizer.GEPA.new(Imp.Metrics.exact_match(:answer),
        execution_profile: :beam_native,
        generations: 2,
        raise_on_exception: false,
        module_selector: fn _state, _trajectories, _scores, _index, _candidate ->
          raise "second exploded"
        end,
        reflection_lm: Imp.LM.Static.new(handler: fn _messages, _opts -> %{instruction: "x"} end),
        max_metric_calls: 20
      )
      |> Imp.Optimizer.GEPA.compile_with_report(program, train, dev, resume_state: resume_state)

    IO.puts(inspect(Enum.map(report.errors, & &1.diagnostics)))
    """

    args =
      "_build/test/lib/*/ebin"
      |> Path.wildcard()
      |> Enum.flat_map(&["-pa", &1])
      |> Kernel.++(["-e", expression, path])

    {output, status} = System.cmd("elixir", args, stderr_to_stdout: true)
    assert status == 0, output
    assert output =~ ~s([["custom exploded"], ["second exploded"]])
  end

  test "a GEPA report stopped by a consecutive-outcome stopper loads in a fresh VM" do
    {_compiled, report} =
      Imp.Optimizer.GEPA.new(metric(),
        execution_profile: :beam_native,
        generations: 6,
        raise_on_exception: false,
        stopper: Imp.Optimizer.GEPA.Stopper.consecutive_outcome(:proposal_error, 2),
        reflection_lm: Imp.Test.FunLM.new(fn _messages, _opts -> {:error, :down} end)
      )
      |> Imp.Optimizer.GEPA.compile_with_report(france_program(), trainset(), devset())

    assert {:stopper, [{:consecutive_outcome, :proposal_error, 2, 2, 2}]} =
             report.metadata.stop_reason

    path =
      Path.join(
        System.tmp_dir!(),
        "gepa-stopper-report-#{System.unique_integer([:positive])}.json"
      )

    File.write!(path, report |> Imp.Optimizer.Report.dump() |> Jason.encode!())
    on_exit(fn -> File.rm(path) end)

    # The expression names no metadata atom itself, so the fresh VM has only
    # the atoms Imp defines.
    expression = """
    report = System.argv() |> hd() |> File.read!() |> Jason.decode!() |> Imp.Optimizer.Report.load!()
    IO.puts(inspect(report.metadata, limit: :infinity))
    """

    args =
      "_build/test/lib/*/ebin"
      |> Path.wildcard()
      |> Enum.flat_map(&["-pa", &1])
      |> Kernel.++(["-e", expression, path])

    {output, status} = System.cmd("elixir", args, stderr_to_stdout: true)
    assert status == 0, output
    assert output =~ "stop_reason: {:stopper, [{:consecutive_outcome, :proposal_error, 2, 2, 2}]}"
    assert output =~ "failed_proposals: #{report.metadata.failed_proposals}"
    assert output =~ "status: :with_errors"
  end

  defp collect_checkpoints(acc) do
    receive do
      {:checkpoint, dumped} -> collect_checkpoints([dumped | acc])
    after
      0 -> acc
    end
  end

  test "GEPA keeps truncated multibyte diagnostics valid UTF-8" do
    reason = String.duplicate("é", 241)

    broken_program =
      Imp.predict("question -> answer",
        lm: Imp.Test.FunLM.new(fn _messages, _opts -> {:error, reason} end)
      )

    compiled =
      Imp.Optimizer.GEPA.new(metric(),
        generations: 1,
        reflection_lm: reflection_lm("Keep diagnostics UTF-8 safe.")
      )
      |> Imp.Optimizer.GEPA.compile(broken_program, trainset(), devset())

    report = Imp.Optimizer.Report.fetch(compiled)

    assert Enum.all?(report.candidates, fn candidate ->
             String.valid?(candidate.instruction) and String.valid?(candidate.mutation)
           end)
  end

  test "GEPA reports feedback callback failures and falls back to default feedback" do
    compiled =
      Imp.Optimizer.GEPA.new(metric(),
        execution_profile: :beam_native,
        generations: 1,
        reflection_lm: reflection_lm(),
        feedback_fn: fn _trainset -> raise "feedback service offline" end
      )
      |> Imp.Optimizer.GEPA.compile(france_program(), trainset(), devset())

    report = Imp.Optimizer.Report.fetch(compiled)

    assert report.optimizer == :gepa
    assert report.metadata.status == :with_errors
    assert report.metadata.feedback =~ "Use observed examples carefully"

    assert [
             %{
               stage: :feedback,
               error: "feedback service offline",
               fallback: fallback
             }
           ] = report.errors

    assert fallback == report.metadata.feedback
  end

  test "GEPA preserves artifact-level evaluator diagnostics in optimizer report" do
    exploding_metric = fn _example, _prediction -> raise "metric unavailable" end

    compiled =
      Imp.Optimizer.GEPA.new(exploding_metric,
        execution_profile: :beam_native,
        generations: 1,
        reflection_lm: reflection_lm("Try to improve."),
        feedback_fn: fn _trainset -> "Try to improve." end
      )
      |> Imp.Optimizer.GEPA.compile(france_program(), trainset(), devset())

    report = Imp.Optimizer.Report.fetch(compiled)

    assert report.optimizer == :gepa
    assert report.best_score == 0.0
    assert report.metadata.status == :with_errors
    assert Enum.any?(report.candidates, &(&1.diagnostics == ["metric unavailable"]))

    assert Enum.any?(report.errors, fn error ->
             error.candidate_id in ["baseline", "gepa-1"] and
               error.diagnostics == ["metric unavailable"]
           end)
  end

  test "SIMBA performs stochastic trajectory sampling without regressing final selection" do
    program = france_program()
    baseline_score = evaluator(program).score

    optimizer =
      Imp.Optimizer.SIMBA.new(metric(),
        bsize: 1,
        num_candidates: 1,
        max_steps: 3,
        max_demos: 1
      )

    compiled = Imp.Optimizer.SIMBA.compile(optimizer, program, trainset(), devset())
    report = Imp.Optimizer.Report.fetch(compiled)

    assert report.optimizer == :simba
    assert report.metadata.algorithm == :stochastic_introspective_minibatch_ascent
    assert report.best_score >= baseline_score
    assert report.best_score == evaluator(compiled).score
    assert length(report.metadata.trial_logs) == 3
    assert report.metadata.trajectory_calls == 3
  end

  test "SIMBA treats zero steps as a baseline-only compile" do
    program = france_program()
    baseline_score = evaluator(program).score

    compiled =
      Imp.Optimizer.SIMBA.new(metric(), bsize: 1, max_steps: 0, max_demos: 0)
      |> Imp.Optimizer.SIMBA.compile(program, trainset(), devset())

    report = Imp.Optimizer.Report.fetch(compiled)

    assert report.optimizer == :simba
    assert report.best_score == baseline_score
    assert report.candidate_count == 0
    assert report.candidates == []
    assert report.metadata.baseline_score == baseline_score
    assert report.metadata.status == :ok
    assert report.errors == []
  end

  test "SIMBA records an explicitly configured reflection model" do
    prompt_lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          send(self(), {:simba_judge, messages})
          %{instruction: "Always answer Paris when asked about France."}
        end
      )

    compiled =
      Imp.Optimizer.SIMBA.new(metric(),
        bsize: 1,
        max_steps: 1,
        max_demos: 1,
        prompt_lm: prompt_lm
      )
      |> Imp.Optimizer.SIMBA.compile(france_program(), trainset(), devset())

    report = Imp.Optimizer.Report.fetch(compiled)
    refute Map.has_key?(report.metadata, :compatibility)
    assert report.best_score >= 0.0
    refute_received {:simba_judge, _messages}
  end

  test "SIMBA rejects invalid final sets at the public boundary" do
    program = france_program()

    assert_raise ArgumentError, ~r/final_set must be enumerable/, fn ->
      Imp.Optimizer.SIMBA.new(metric(), max_steps: 2, max_demos: 1)
      |> Imp.Optimizer.SIMBA.compile(program, trainset(), :not_an_enumerable_devset)
    end
  end

  test "SIMBA rejects invalid trainsets at the public boundary" do
    program = france_program()

    assert_raise ArgumentError, ~r/trainset must be enumerable/, fn ->
      Imp.Optimizer.SIMBA.new(metric(), max_steps: 1, max_demos: 1)
      |> Imp.Optimizer.SIMBA.compile(program, :not_an_enumerable_trainset, devset())
    end
  end

  test "COPRO reports coordinate prompt optimization across breadth and depth" do
    program = france_program()

    optimizer =
      Imp.Optimizer.COPRO.new(metric(),
        breadth: 6,
        depth: 2,
        proposer_lm: copro_proposer_lm(),
        extra_instructions: ["Always answer Paris when asked about France."]
      )

    compiled =
      Imp.context([lm: nil], fn ->
        Imp.Optimizer.COPRO.compile(optimizer, program, trainset(), devset())
      end)

    report = Imp.Optimizer.Report.fetch(compiled)

    assert report.optimizer == :copro
    assert report.best_score == 100.0
    assert report.best_score == evaluator(compiled).score * 100.0
    assert report.metadata.breadth == 6
    assert report.metadata.depth == 2
    assert Enum.map(report.metadata.rounds, & &1.depth) == [0, 1]
    assert Enum.any?(report.candidates, &(&1.instruction =~ "Always answer Paris"))
  end

  test "COPRO preserves DSPy's breadth lower bound" do
    assert_raise ArgumentError, "Breadth must be greater than 1", fn ->
      Imp.Optimizer.COPRO.new(metric(), breadth: 1, depth: 0)
    end
  end

  test "COPRO preserves evaluation failures with a real proposer" do
    program = france_program()

    compiled =
      Imp.context([lm: nil], fn ->
        Imp.Optimizer.COPRO.new(metric(),
          breadth: 2,
          depth: 1,
          proposer_lm: copro_proposer_lm()
        )
        |> Imp.Optimizer.COPRO.compile(program, [:not_an_example], devset())
      end)

    report = Imp.Optimizer.Report.fetch(compiled)

    assert report.optimizer == :copro
    assert report.metadata.status == :with_errors
    assert report.metadata.depth == 1
    assert [%{depth: 0}] = report.metadata.rounds
    assert length(report.errors) == 2
    assert Enum.any?(report.candidates, &(&1.depth == 0))
  end

  test "advanced optimizer constructors reject invalid option containers at the boundary" do
    assert_raise ArgumentError,
                 ~r/Imp\.Optimizer\.COPRO\.new\/2: expected keyword options/,
                 fn ->
                   Imp.Optimizer.COPRO.new(metric(), %{depth: 1})
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Optimizer\.MIPROv2\.new\/2: expected keyword options/,
                 fn ->
                   Imp.Optimizer.MIPROv2.new(metric(), %{num_trials: 1})
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Optimizer\.SIMBA\.new\/2: expected keyword options/,
                 fn ->
                   Imp.Optimizer.SIMBA.new(metric(), %{steps: 1})
                 end

    assert_raise ArgumentError, ~r/Imp\.Optimizer\.GEPA\.new\/2: expected keyword options/, fn ->
      Imp.Optimizer.GEPA.new(metric(), %{generations: 1})
    end

    assert_raise ArgumentError,
                 ~r/Imp\.Optimizer\.COPRO\.new\/2: invalid value for :depth option: expected non negative integer/,
                 fn ->
                   Imp.Optimizer.COPRO.new(metric(), depth: -1)
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Optimizer\.COPRO\.new\/2: invalid value for :breadth option: expected non negative integer/,
                 fn ->
                   Imp.Optimizer.COPRO.new(metric(), breadth: -1)
                 end

    assert_raise ArgumentError,
                 ~r/num_trials must be a non-negative integer/,
                 fn ->
                   Imp.Optimizer.MIPROv2.new(metric(), num_trials: -1)
                 end

    assert_raise ArgumentError,
                 ~r/max_labeled_demos must be a non-negative integer/,
                 fn ->
                   Imp.Optimizer.MIPROv2.new(metric(), max_labeled_demos: -1)
                 end

    assert_raise ArgumentError,
                 ~r/startup_trials must be a non-negative integer/,
                 fn ->
                   Imp.Optimizer.MIPROv2.new(metric(), startup_trials: -1)
                 end

    for alias <- [:trials, :demos_per_candidate, :cold_start] do
      assert_raise ArgumentError, ~r/unknown MIPROv2 options/, fn ->
        Imp.Optimizer.MIPROv2.new(metric(), [{alias, 1}])
      end
    end

    assert_raise ArgumentError,
                 ~r/max_steps must be an integer >= 0/,
                 fn ->
                   Imp.Optimizer.SIMBA.new(metric(), max_steps: -1)
                 end

    assert_raise ArgumentError,
                 ~r/max_demos must be an integer >= 0/,
                 fn ->
                   Imp.Optimizer.SIMBA.new(metric(), max_demos: -1)
                 end

    assert_raise ArgumentError,
                 ~r/Imp\.Optimizer\.GEPA\.new\/2: invalid value for :generations option: expected non negative integer/,
                 fn ->
                   Imp.Optimizer.GEPA.new(metric(), generations: -1)
                 end
  end

  test "advanced optimizer constructors reject invalid callback contracts at the boundary" do
    assert_raise ArgumentError,
                 ~r/Imp\.Optimizer\.COPRO\.new\/2 expects a metric function with arity 2 or 3/,
                 fn -> Imp.Optimizer.COPRO.new(fn _example -> true end) end

    assert_raise ArgumentError,
                 ~r/Imp\.Optimizer\.MIPROv2\.new\/2 expects a metric function with arity 2 or 3/,
                 fn -> Imp.Optimizer.MIPROv2.new(fn _example -> true end) end

    assert_raise ArgumentError,
                 ~r/Imp\.Optimizer\.SIMBA\.new\/2 expects a metric function with arity 2 or 3/,
                 fn -> Imp.Optimizer.SIMBA.new(fn _example -> true end) end

    assert_raise ArgumentError,
                 ~r/Imp\.Optimizer\.GEPA\.new\/2 expects a metric function with arity 2 or 3/,
                 fn -> Imp.Optimizer.GEPA.new(fn _example -> true end) end

    assert_raise ArgumentError,
                 ~r/Imp\.Optimizer\.GEPA\.new\/2: invalid value for :feedback_fn option: expected nil or an arity-1 function/,
                 fn -> Imp.Optimizer.GEPA.new(metric(), feedback_fn: fn -> "feedback" end) end

    assert_raise ArgumentError,
                 ~r/Imp\.Optimizer\.COPRO\.new\/2: invalid value for :proposer_lm option: expected nil, or an LM struct or module/,
                 fn -> Imp.Optimizer.COPRO.new(metric(), proposer_lm: %{provider: :missing}) end

    assert_raise ArgumentError,
                 ~r/prompt_lm expected/,
                 fn -> Imp.Optimizer.SIMBA.new(metric(), prompt_lm: %{provider: :missing}) end
  end

  test "SIMBA rejects deprecated option aliases" do
    for alias <- [:steps, :demos_per_step, :judge_lm] do
      assert_raise ArgumentError, ~r/unknown SIMBA options/, fn ->
        Imp.Optimizer.SIMBA.new(metric(), [{alias, 1}])
      end
    end
  end

  test "COPRO can use LM-generated score-informed instruction proposals" do
    proposer_lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          send(self(), {:copro_proposer, messages})
          ~s(["Always answer Paris when asked about France."])
        end
      )

    compiled =
      Imp.Optimizer.COPRO.new(metric(), breadth: 2, depth: 1, proposer_lm: proposer_lm)
      |> Imp.Optimizer.COPRO.compile(france_program(), trainset(), devset())

    report = Imp.Optimizer.Report.fetch(compiled)
    assert report.best_score == 100.0
    assert Enum.any?(report.candidates, &(&1.instruction =~ "Always answer Paris"))
    assert_received {:copro_proposer, messages}
    assert Enum.map_join(messages, "\n", & &1.content) =~ "attempted_instructions"
  end
end
