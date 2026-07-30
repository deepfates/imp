defmodule Imp.Optimizer.BootstrapFewShotTrajectoryTest do
  use ExUnit.Case, async: true

  defmodule TracedProgram do
    defstruct [:first, :second]

    def optimizer_predictors(program), do: [first: program.first, second: program.second]

    def update_optimizer_predictor(program, :first, update),
      do: %{program | first: update.(program.first)}

    def update_optimizer_predictor(program, :second, update),
      do: %{program | second: update.(program.second)}

    def call(_program, %{question: question}) do
      trace = [
        %{predictor: :first, inputs: %{question: question}, outputs: %{hint: "initial"}},
        %{
          predictor: :first,
          inputs: %{question: question <> " refined"},
          outputs: %{hint: "final"}
        },
        %{predictor: :second, inputs: %{hint: "final"}, outputs: %{answer: "generated"}}
      ]

      {:ok, Imp.Prediction.new(%{answer: "generated"}, metadata: %{optimizer_trace: trace})}
    end
  end

  defmodule UntracedProgram do
    defstruct [:main]

    def optimizer_predictors(program), do: [main: program.main]

    def update_optimizer_predictor(program, :main, update),
      do: %{program | main: update.(program.main)}

    def call(_program, _inputs), do: {:ok, Imp.Prediction.new(%{answer: "generated"})}
  end

  defmodule RepeatedCallProgram do
    defstruct [:main]

    def optimizer_predictors(program), do: [main: program.main]

    def update_optimizer_predictor(program, :main, update),
      do: %{program | main: update.(program.main)}

    def call(program, %{question: question}) do
      Enum.reduce_while(0..3, {:error, :empty_repeated_call_fixture}, fn call_index, _result ->
        case Imp.call(program.main, %{question: "#{question}-call-#{call_index}"}) do
          {:ok, _prediction} = result -> {:cont, result}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    end
  end

  defmodule ContextProbeAdapter do
    @behaviour Imp.Adapter

    @impl true
    def format(signature, inputs, opts) do
      settings = Imp.Settings.get()
      send(settings.bootstrap_test_pid, {:teacher_adapter, settings.adapter})
      Imp.Adapter.Chat.format(signature, inputs, opts)
    end

    @impl true
    def parse(signature, raw, opts), do: Imp.Adapter.Chat.parse(signature, raw, opts)
  end

  defmodule DemoInspectingProgram do
    defstruct [:main, :test_pid]

    def optimizer_predictors(program), do: [main: program.main]

    def update_optimizer_predictor(program, :main, update),
      do: %{program | main: update.(program.main)}

    def call(program, _inputs) do
      send(program.test_pid, {:teacher_demos, program.main.demos})
      {:ok, Imp.Prediction.new(answer: "accepted")}
    end
  end

  test "uses generated outputs rather than labeled outputs as demos" do
    # Dynamic LM via context: a Static-pinned program can no longer be dumped
    # (dee-i3s4 / P03 made that loud), and this test round-trips the compiled
    # program through Saving below.
    lm = %{module: Imp.LM.Static, opts: [handler: fn _, _ -> %{answer: "generated"} end]}
    program = Imp.predict("question -> answer")
    example = Imp.example(question: "q", answer: "gold") |> Imp.with_inputs(:question)
    metric = fn _example, prediction -> Imp.get(prediction, :answer) == "generated" end

    compiled =
      Imp.context([lm: lm], fn ->
        metric
        |> Imp.Optimizer.BootstrapFewShot.new(max_bootstrapped_demos: 1)
        |> Imp.Optimizer.BootstrapFewShot.compile(program, [example])
      end)

    assert [%Imp.Example{} = demo] = compiled.demos
    assert Imp.Example.to_map(demo) == %{question: "q", answer: "generated", augmented: true}
    refute :augmented in demo.input_keys
    refute :augmented in Imp.Signature.input_names(compiled.signature)
    refute :augmented in Imp.Signature.output_names(compiled.signature)

    rendered =
      compiled.signature
      |> Imp.Adapter.Chat.format(%{question: "next"}, demos: [demo])
      |> inspect()

    refute rendered =~ "augmented"

    restored = compiled |> Imp.Saving.dump() |> Imp.Saving.load()
    assert Imp.Example.get(hd(restored.demos), :augmented) == true
  end

  test "selects one deterministic traced invocation for each named predictor" do
    program = %TracedProgram{
      first: Imp.predict("question -> hint"),
      second: Imp.predict("hint -> answer")
    }

    example = Imp.example(question: "q", answer: "gold") |> Imp.with_inputs(:question)

    metric = fn _example, prediction, trace ->
      Imp.get(prediction, :answer) == "generated" and length(trace) == 3
    end

    compile = fn ->
      metric
      |> Imp.Optimizer.BootstrapFewShot.new(max_bootstrapped_demos: 1)
      |> Imp.Optimizer.BootstrapFewShot.compile(program, [example])
    end

    compiled = compile.()
    replayed = compile.()

    assert [first_demo] = compiled.first.demos

    assert Imp.Example.to_map(first_demo) in [
             %{question: "q", hint: "initial", augmented: true},
             %{question: "q refined", hint: "final", augmented: true}
           ]

    assert Enum.map(replayed.first.demos, &Imp.Example.to_map/1) ==
             Enum.map(compiled.first.demos, &Imp.Example.to_map/1)

    assert [second_demo] = compiled.second.demos

    assert Imp.Example.to_map(second_demo) == %{
             hint: "final",
             answer: "generated",
             augmented: true
           }

    report = Imp.Optimizer.Report.fetch(compiled.first)
    assert report.metadata.predictor_demo_counts == %{first: 1, second: 1}
    assert report.metadata.trace_selection_rng == :beam_sha256

    assert [selection] = report.metadata.repeated_call_selections
    assert selection.predictor == :first
    assert selection.trajectory_index == 0
    assert selection.call_count == 2

    expected_index =
      if Imp.Example.get(first_demo, :question) == "q",
        do: 0,
        else: 1

    assert selection.selected_index == expected_index
  end

  test "compile-driven SHA-256 selection smoke test covers both branches without gross skew" do
    optimizer =
      Imp.Optimizer.BootstrapFewShot.new(nil,
        max_bootstrapped_demos: 1,
        max_labeled_demos: 0
      )

    rows =
      Enum.map(0..511, fn sample_index ->
        question = "distribution-#{sample_index}"

        program = %RepeatedCallProgram{
          main:
            Imp.predict("question -> hint",
              lm: %{
                module: Imp.LM.Static,
                opts: [handler: fn _messages, _opts -> %{hint: "fixture-hint"} end]
              }
            )
        }

        example = Imp.example(question: question) |> Imp.with_inputs(:question)
        compiled = Imp.Optimizer.BootstrapFewShot.compile(optimizer, program, [example])

        assert [compiled_demo] = compiled.main.demos

        assert [selection] =
                 Imp.Optimizer.Report.fetch(compiled.main).metadata.repeated_call_selections

        selected_index =
          Enum.find(0..3, fn call_index ->
            Imp.Example.get(compiled_demo, :question) == "#{question}-call-#{call_index}"
          end)

        assert selection.selected_index == selected_index
        assert selection.trajectory_index == 0
        assert selection.call_count == 4
        assert selection.branch == if(selected_index == 3, do: :final, else: :earlier)

        {selection.branch, selected_index}
      end)

    earlier_count = Enum.count(rows, &match?({:earlier, _index}, &1))
    final_count = Enum.count(rows, &match?({:final, 3}, &1))

    # These broad bounds detect branch/index regressions; they are not a proof of uniformity.
    assert earlier_count in 200..312
    assert final_count in 200..312
    assert earlier_count + final_count == 512

    Enum.each(0..2, fn earlier_index ->
      count = Enum.count(rows, &(&1 == {:earlier, earlier_index}))
      assert count in 45..125
    end)
  end

  test "does not synthesize an augmented demo when a successful call has no predictor trace" do
    program = %UntracedProgram{main: Imp.predict("question -> answer")}
    example = Imp.example(question: "q", answer: "gold") |> Imp.with_inputs(:question)

    compiled =
      Imp.Optimizer.BootstrapFewShot.new(nil,
        max_bootstrapped_demos: 1,
        max_labeled_demos: 1
      )
      |> Imp.Optimizer.BootstrapFewShot.compile(program, [example])

    assert compiled.main.demos == []
    report = Imp.Optimizer.Report.fetch(compiled.main)
    assert report.metadata.selected_count == 1
    assert report.metadata.predictor_demo_counts == %{main: 0}
  end

  test "keeps teacher and student distinct, excludes self demos, and fills only unbootstrapped labels" do
    student =
      Imp.predict("question -> answer",
        lm: %{module: Imp.LM.Static, opts: [handler: fn _, _ -> %{answer: "student"} end]},
        demos: [Imp.example(question: "stale", answer: "stale") |> Imp.with_inputs(:question)]
      )

    teacher =
      Imp.predict("question -> answer",
        lm: %{module: Imp.LM.Static, opts: [handler: fn _, _ -> %{answer: "teacher"} end]}
      )

    trainset = [
      Imp.example(question: "boot", answer: "teacher") |> Imp.with_inputs(:question),
      Imp.example(question: "label", answer: "gold") |> Imp.with_inputs(:question)
    ]

    compiled =
      Imp.Optimizer.BootstrapFewShot.new(
        fn example, prediction -> Imp.get(prediction, :answer) == Imp.get(example, :answer) end,
        max_bootstrapped_demos: 1,
        max_labeled_demos: 2
      )
      |> Imp.Optimizer.BootstrapFewShot.compile(student, trainset, teacher: teacher)

    assert compiled.lm == student.lm

    assert Enum.map(compiled.demos, &Imp.Example.get(&1, :question)) |> Enum.sort() == [
             "boot",
             "label"
           ]

    refute Enum.any?(compiled.demos, &(Imp.Example.get(&1, :question) == "stale"))

    report = Imp.Optimizer.Report.fetch(compiled)
    assert report.metadata.selected_count == 1
    assert report.metadata.validation_size == 1
  end

  test "self-demo exclusion matches DSPy field-store equality" do
    nested_current = Imp.example(source: "current")
    nested_collision = Imp.example(source: "collision")

    current =
      Imp.example(question: "same", answer: "same")
      |> Imp.with_inputs(:question)
      |> Imp.Example.with_demos([nested_current])

    same_fields_different_identity =
      Imp.example(question: "same", answer: "same")
      |> Imp.with_inputs(:answer)
      |> Imp.Example.with_demos([nested_collision])

    assert Imp.Example.to_map(same_fields_different_identity) == Imp.Example.to_map(current)
    assert same_fields_different_identity.input_keys != current.input_keys
    assert same_fields_different_identity.demos != current.demos

    student = %DemoInspectingProgram{main: Imp.predict("question -> answer"), test_pid: self()}

    teacher = %DemoInspectingProgram{
      main:
        Imp.predict("question -> answer", demos: [current, same_fields_different_identity])
        |> Imp.Optimizer.Report.attach(Imp.Optimizer.Report.new(optimizer: :previous_optimizer)),
      test_pid: self()
    }

    Imp.Optimizer.BootstrapFewShot.new(nil,
      max_bootstrapped_demos: 1,
      max_labeled_demos: 1
    )
    |> Imp.Optimizer.BootstrapFewShot.compile(student, [current], teacher: teacher)

    assert_received {:teacher_demos, []}
  end

  test "a teacher-call failure records zero without invoking the metric" do
    parent = self()

    failing =
      Imp.predict("question -> answer",
        lm: %{
          module: Imp.LM.Static,
          opts: [handler: fn _messages, _opts -> raise "teacher failed" end]
        }
      )

    metric = fn _example, _prediction ->
      send(parent, :bootstrap_metric_called)
      true
    end

    example = Imp.example(question: "q", answer: "a") |> Imp.with_inputs(:question)

    report =
      Imp.Optimizer.BootstrapFewShot.new(metric,
        max_bootstrapped_demos: 1,
        max_labeled_demos: 0,
        max_errors: :infinity
      )
      |> Imp.Optimizer.BootstrapFewShot.compile(failing, [example])
      |> Imp.Optimizer.Report.fetch()

    refute_received :bootstrap_metric_called
    assert [%{passed?: false, selected?: false, feedback: nil} = attempt] = report.candidates
    assert attempt.score == 0.0
    assert [%{stage: :program_call}] = report.errors
  end

  test "an explicit nil teacher uses the student as the default teacher" do
    program =
      Imp.predict("question -> answer",
        lm: %{module: Imp.LM.Static, opts: [handler: fn _, _ -> %{answer: "generated"} end]}
      )

    example = Imp.example(question: "q", answer: "gold") |> Imp.with_inputs(:question)

    compiled =
      Imp.Optimizer.BootstrapFewShot.new(nil,
        max_bootstrapped_demos: 1,
        max_labeled_demos: 0
      )
      |> Imp.Optimizer.BootstrapFewShot.compile(program, [example], teacher: nil)

    assert [demo] = compiled.demos
    assert Imp.Example.get(demo, :answer) == "generated"
    assert Imp.Optimizer.Report.fetch(compiled).metadata.selected_count == 1
  end

  test "retries a failed row by round and honors a numeric metric threshold" do
    parent = self()
    cache = start_supervised!({Agent, fn -> %{} end})

    lm = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn messages, opts ->
          rollout_id = opts[:rollout_id]
          cache_key = {messages, rollout_id}

          {answer, cache_hit?} =
            Agent.get_and_update(cache, fn entries ->
              case Map.fetch(entries, cache_key) do
                {:ok, answer} ->
                  {{answer, true}, entries}

                :error ->
                  answer = if rollout_id == 1, do: "pass", else: "retry"
                  {{answer, false}, Map.put(entries, cache_key, answer)}
              end
            end)

          send(
            parent,
            {:bootstrap_round, rollout_id, opts[:temperature], cache_key, cache_hit?}
          )

          %{answer: answer}
        end
      ]
    }

    example = Imp.example(question: "q", answer: "pass") |> Imp.with_inputs(:question)

    compiled =
      Imp.context([lm: lm], fn ->
        Imp.Optimizer.BootstrapFewShot.new(
          fn _example, prediction ->
            if Imp.get(prediction, :answer) == "pass", do: 0.8, else: 0.7
          end,
          metric_threshold: 0.75,
          max_bootstrapped_demos: 1,
          max_labeled_demos: 0,
          max_rounds: 2
        )
        |> Imp.Optimizer.BootstrapFewShot.compile(Imp.predict("question -> answer"), [example])
      end)

    assert [%Imp.Example{}] = compiled.demos
    assert_received {:bootstrap_round, nil, nil, first_cache_key, false}
    assert_received {:bootstrap_round, 1, 1.0, second_cache_key, false}
    assert elem(first_cache_key, 0) == elem(second_cache_key, 0)
    assert first_cache_key != second_cache_key
    assert Imp.Optimizer.Report.fetch(compiled).metadata.bootstrap_attempts == 2
  end

  test "zero max_errors raises on the first failure while infinity records it" do
    failing =
      Imp.predict("question -> answer",
        lm: %{
          module: Imp.LM.Static,
          opts: [handler: fn _messages, _opts -> raise "provider failed" end]
        }
      )

    example = Imp.example(question: "q", answer: "a") |> Imp.with_inputs(:question)

    assert_raise RuntimeError, ~r/1 errors \(maximum 0\)/, fn ->
      Imp.Optimizer.BootstrapFewShot.new(nil,
        max_bootstrapped_demos: 1,
        max_labeled_demos: 0,
        max_errors: 0
      )
      |> Imp.Optimizer.BootstrapFewShot.compile(failing, [example])
    end

    report =
      Imp.Optimizer.BootstrapFewShot.new(nil,
        max_bootstrapped_demos: 1,
        max_labeled_demos: 0,
        max_errors: :infinity
      )
      |> Imp.Optimizer.BootstrapFewShot.compile(failing, [example])
      |> Imp.Optimizer.Report.fetch()

    assert report.metadata.max_errors == :infinity
    assert report.metadata.max_errors_source == :explicit
    assert [%{stage: :program_call}] = report.errors
  end

  test "accepts successful calls without a metric and inherits DSPy's error default" do
    optimizer =
      Imp.Optimizer.BootstrapFewShot.new(
        max_bootstrapped_demos: 1,
        max_labeled_demos: 0
      )

    assert optimizer.metric == nil
    assert optimizer.max_errors == nil

    program =
      Imp.predict("question -> answer",
        lm: %{module: Imp.LM.Static, opts: [handler: fn _, _ -> %{answer: "generated"} end]}
      )

    example = Imp.example(question: "q", answer: "gold") |> Imp.with_inputs(:question)
    compiled = Imp.Optimizer.BootstrapFewShot.compile(optimizer, program, [example])

    assert [demo] = compiled.demos
    assert Imp.Example.get(demo, :answer) == "generated"
    assert Imp.Optimizer.Report.fetch(compiled).metadata.max_errors == 10
    assert Imp.Optimizer.Report.fetch(compiled).metadata.max_errors_source == :settings
  end

  test "resets compiled student state without resetting the independent default teacher" do
    parent = self()

    old_demo =
      Imp.example(question: "compiled-teacher-demo", answer: "old")
      |> Imp.with_inputs(:question)

    old_report = Imp.Optimizer.Report.new(optimizer: :previous_optimizer)

    compiled_input =
      Imp.predict("question -> answer",
        demos: [old_demo],
        lm: %{
          module: Imp.LM.Static,
          opts: [
            handler: fn messages, _opts ->
              prompt = Enum.map_join(messages, "\n", & &1.content)
              send(parent, {:compiled_teacher_prompt, prompt})
              %{answer: "fresh"}
            end
          ]
        }
      )
      |> Imp.Optimizer.Report.attach(old_report)

    target = Imp.example(question: "target", answer: "fresh") |> Imp.with_inputs(:question)

    result =
      Imp.Optimizer.BootstrapFewShot.new(Imp.Metrics.exact_match(:answer),
        max_bootstrapped_demos: 1,
        max_labeled_demos: 1
      )
      |> Imp.Optimizer.BootstrapFewShot.compile(compiled_input, [target])

    assert_received {:compiled_teacher_prompt, prompt}
    assert prompt =~ "compiled-teacher-demo"
    assert Enum.map(result.demos, &Imp.Example.get(&1, :question)) == ["target"]

    report = Imp.Optimizer.Report.fetch(result)
    assert report.optimizer == :bootstrap_few_shot
    assert report != old_report
    assert report.metadata.teacher_preparation == :preserved_compiled_teacher
    assert report.metadata.student_preparation == :reset_demos_and_optimizer_report
  end

  test "applies teacher settings as inherited task context without changing predictor config" do
    parent = self()

    fallback_lm = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn _messages, _opts ->
          send(parent, :fallback_lm_called)
          %{answer: "wrong"}
        end
      ]
    }

    teacher_lm = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn _messages, opts ->
          settings = Imp.Settings.get()

          send(
            parent,
            {:teacher_lm, settings.inherited_marker, settings.teacher_marker, settings.adapter,
             opts}
          )

          %{answer: "teacher"}
        end
      ]
    }

    program = Imp.predict("question -> answer", config: [top_p: 0.2])
    example = Imp.example(question: "q", answer: "teacher") |> Imp.with_inputs(:question)

    compiled =
      Imp.context(
        [lm: fallback_lm, adapter: Imp.Adapter.Chat, inherited_marker: :outer],
        fn ->
          Imp.Optimizer.BootstrapFewShot.new(Imp.Metrics.exact_match(:answer),
            max_bootstrapped_demos: 1,
            max_labeled_demos: 0,
            teacher_settings: [
              lm: teacher_lm,
              adapter: ContextProbeAdapter,
              teacher_marker: :inner,
              bootstrap_test_pid: parent
            ]
          )
          |> Imp.Optimizer.BootstrapFewShot.compile(program, [example])
        end
      )

    assert_received {:teacher_adapter, ContextProbeAdapter}

    assert_received {:teacher_lm, :outer, :inner, ContextProbeAdapter, provider_opts}
    assert provider_opts[:top_p] == 0.2
    refute Keyword.has_key?(provider_opts, :teacher_marker)
    refute Keyword.has_key?(provider_opts, :adapter)
    refute Keyword.has_key?(provider_opts, :lm)
    refute_receive :fallback_lm_called
    assert compiled.config == [top_p: 0.2]
    refute Map.has_key?(Imp.Settings.get(), :teacher_marker)
  end

  test "process-local max_errors inheritance yields to an explicit optimizer value" do
    program = Imp.predict("question -> answer")
    trainset = [Imp.example(question: "q", answer: "a") |> Imp.with_inputs(:question)]

    inherited =
      Imp.context([max_errors: 3], fn ->
        Imp.Optimizer.BootstrapFewShot.new(max_bootstrapped_demos: 0)
        |> Imp.Optimizer.BootstrapFewShot.compile(program, trainset)
      end)
      |> Imp.Optimizer.Report.fetch()

    explicit =
      Imp.context([max_errors: 3], fn ->
        Imp.Optimizer.BootstrapFewShot.new(max_bootstrapped_demos: 0, max_errors: 7)
        |> Imp.Optimizer.BootstrapFewShot.compile(program, trainset)
      end)
      |> Imp.Optimizer.Report.fetch()

    teacher_context =
      Imp.context([max_errors: 3], fn ->
        Imp.Optimizer.BootstrapFewShot.new(
          max_bootstrapped_demos: 0,
          teacher_settings: [max_errors: 6]
        )
        |> Imp.Optimizer.BootstrapFewShot.compile(program, trainset)
      end)
      |> Imp.Optimizer.Report.fetch()

    assert {inherited.metadata.max_errors, inherited.metadata.max_errors_source} == {3, :settings}
    assert {explicit.metadata.max_errors, explicit.metadata.max_errors_source} == {7, :explicit}

    assert {teacher_context.metadata.max_errors, teacher_context.metadata.max_errors_source} ==
             {6, :teacher_settings}
  end

  test "a zero-valued threshold uses metric truthiness, including 0.0" do
    program =
      Imp.predict("question -> answer",
        lm: %{module: Imp.LM.Static, opts: [handler: fn _, _ -> %{answer: "generated"} end]}
      )

    example = Imp.example(question: "q", answer: "gold") |> Imp.with_inputs(:question)

    compiled =
      Imp.Optimizer.BootstrapFewShot.new(fn _example, _prediction -> -0.5 end,
        metric_threshold: 0.0,
        max_bootstrapped_demos: 1,
        max_labeled_demos: 0
      )
      |> Imp.Optimizer.BootstrapFewShot.compile(program, [example])

    assert [_demo] = compiled.demos
  end

  test "uses optimizer reports as the explicit compiled-teacher marker" do
    parent = self()

    manual =
      Imp.example(question: "manual-question", answer: "manual") |> Imp.with_inputs(:question)

    teacher = fn tag ->
      Imp.predict("question -> answer",
        demos: [manual],
        lm: %{
          module: Imp.LM.Static,
          opts: [
            handler: fn messages, _opts ->
              send(parent, {tag, Enum.map_join(messages, "\n", & &1.content)})
              %{answer: "teacher"}
            end
          ]
        }
      )
    end

    student = Imp.predict("question -> answer")
    example = Imp.example(question: "target", answer: "teacher") |> Imp.with_inputs(:question)

    optimizer =
      Imp.Optimizer.BootstrapFewShot.new(Imp.Metrics.exact_match(:answer),
        max_bootstrapped_demos: 1,
        max_labeled_demos: 1
      )

    Imp.Optimizer.BootstrapFewShot.compile(optimizer, student, [example],
      teacher: teacher.(:uncompiled)
    )

    compiled_teacher =
      teacher.(:compiled)
      |> Imp.Optimizer.Report.attach(Imp.Optimizer.Report.new(optimizer: :labeled_few_shot))

    Imp.Optimizer.BootstrapFewShot.compile(optimizer, student, [example],
      teacher: compiled_teacher
    )

    assert_received {:uncompiled, uncompiled_prompt}
    refute uncompiled_prompt =~ "manual-question"

    assert_received {:compiled, compiled_prompt}
    assert compiled_prompt =~ "manual-question"
  end

  test "a teacher-call failure preserves 3.2.1's unrestored self-demo removal" do
    parent = self()
    calls = start_supervised!({Agent, fn -> 0 end})

    teacher =
      Imp.predict("question -> answer",
        lm: %{
          module: Imp.LM.Static,
          opts: [
            handler: fn messages, _opts ->
              call = Agent.get_and_update(calls, fn count -> {count + 1, count + 1} end)
              prompt = Enum.map_join(messages, "\n", & &1.content)

              if call == 1 do
                raise "first teacher call failed"
              else
                send(parent, {:second_teacher_prompt, prompt})
                %{answer: "accepted"}
              end
            end
          ]
        }
      )

    trainset = [
      Imp.example(question: "failed-demo", answer: "unused") |> Imp.with_inputs(:question),
      Imp.example(question: "target", answer: "accepted") |> Imp.with_inputs(:question)
    ]

    Imp.Optimizer.BootstrapFewShot.new(Imp.Metrics.exact_match(:answer),
      max_bootstrapped_demos: 1,
      max_labeled_demos: 2,
      max_errors: 2
    )
    |> Imp.Optimizer.BootstrapFewShot.compile(Imp.predict("question -> answer"), trainset,
      teacher: teacher
    )

    assert_received {:second_teacher_prompt, prompt}
    refute prompt =~ "failed-demo"
  end

  test "resets the native RNG before chained predictor label sampling" do
    program = %TracedProgram{
      first: Imp.predict("question -> hint"),
      second: Imp.predict("hint -> answer")
    }

    trainset =
      Enum.map(1..6, fn index ->
        Imp.example(question: "q#{index}", hint: "h#{index}", answer: "a#{index}")
        |> Imp.with_inputs(:question)
      end)

    compiled =
      Imp.Optimizer.BootstrapFewShot.new(nil,
        max_bootstrapped_demos: 0,
        max_labeled_demos: 2
      )
      |> Imp.Optimizer.BootstrapFewShot.compile(program, trainset)

    {validation, _post_shuffle_rng} =
      Imp.Optimizer.Sampling.shuffle(trainset, Imp.Optimizer.Sampling.new(0))

    {first_pool, sampling_rng} =
      Imp.Optimizer.Sampling.shuffle(validation, Imp.Optimizer.Sampling.new(0))

    expected_first = Enum.take(first_pool, 2)
    {second_pool, _sampling_rng} = Imp.Optimizer.Sampling.shuffle(expected_first, sampling_rng)
    expected_second = Enum.take(second_pool, 2)

    assert Enum.map(compiled.first.demos, &Imp.Example.get(&1, :question)) ==
             Enum.map(expected_first, &Imp.Example.get(&1, :question))

    assert Enum.map(compiled.second.demos, &Imp.Example.get(&1, :question)) ==
             Enum.map(expected_second, &Imp.Example.get(&1, :question))

    report = Imp.Optimizer.Report.fetch(compiled.first)
    assert report.metadata.sampling_rng == :beam_native
    assert report.metadata.sampling_schedule == :dspy_3_2_1_seed_lifecycle
  end

  defmodule SlowTeacherProgram do
    defstruct [:main, sleep_ms: 200]

    def optimizer_predictors(program), do: [main: program.main]

    def update_optimizer_predictor(program, :main, update),
      do: %{program | main: update.(program.main)}

    def call(program, %{question: question}) do
      Process.sleep(program.sleep_ms)

      trace = [
        %{predictor: :main, inputs: %{question: question}, outputs: %{answer: "generated"}}
      ]

      {:ok, Imp.Prediction.new(%{answer: "generated"}, metadata: %{optimizer_trace: trace})}
    end
  end

  describe "teacher timeout threading" do
    test "a teacher slower than the configured timeout bootstraps nothing" do
      program = %SlowTeacherProgram{main: Imp.predict("question -> answer"), sleep_ms: 200}
      example = Imp.example(question: "q", answer: "generated") |> Imp.with_inputs(:question)

      compiled =
        Imp.Optimizer.BootstrapFewShot.new(nil, timeout: 20, max_labeled_demos: 0)
        |> Imp.Optimizer.BootstrapFewShot.compile(program, [example])

      report = Imp.Optimizer.Report.fetch(compiled.main)
      assert report.metadata.predictor_demo_counts == %{main: 0}
    end

    test "raising timeout past teacher latency bootstraps the demo (the 5s default was previously not threadable)" do
      program = %SlowTeacherProgram{main: Imp.predict("question -> answer"), sleep_ms: 200}
      example = Imp.example(question: "q", answer: "generated") |> Imp.with_inputs(:question)

      compiled =
        Imp.Optimizer.BootstrapFewShot.new(nil, timeout: 2_000, max_labeled_demos: 0)
        |> Imp.Optimizer.BootstrapFewShot.compile(program, [example])

      report = Imp.Optimizer.Report.fetch(compiled.main)
      assert report.metadata.predictor_demo_counts == %{main: 1}
    end

    test ":infinity is a valid teacher timeout" do
      assert %Imp.Optimizer.BootstrapFewShot{timeout: :infinity} =
               Imp.Optimizer.BootstrapFewShot.new(nil, timeout: :infinity)
    end
  end
end
