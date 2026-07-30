defmodule BootstrapFinetuneTest do
  use ExUnit.Case

  alias Imp.Clients.TrainingJob
  alias Imp.Optimizer.BootstrapFinetune
  alias Imp.Optimizer.BootstrapFinetune.TrainingPlan
  alias Imp.Optimizer.{TrainingError, TrainingResult}

  defmodule TwoPredictorProgram do
    @behaviour Imp.Module

    defstruct [:first, :second, metadata: %{}]

    @impl true
    def optimizer_predictors(program), do: [first: program.first, second: program.second]

    @impl true
    def update_optimizer_predictor(program, name, update),
      do: Map.update!(program, name, update)

    @impl true
    def call(program, inputs) do
      with {:ok, first} <- Imp.Module.call(program.first, inputs),
           {:ok, second} <- Imp.Module.call(program.second, inputs) do
        {:ok,
         Imp.Prediction.new(
           Map.merge(Imp.Prediction.to_map(first), Imp.Prediction.to_map(second))
         )}
      end
    end
  end

  defmodule ThreePredictorProgram do
    @behaviour Imp.Module

    defstruct [:first, :second, :third, metadata: %{}]

    @impl true
    def optimizer_predictors(program),
      do: [first: program.first, second: program.second, third: program.third]

    @impl true
    def update_optimizer_predictor(program, name, update),
      do: Map.update!(program, name, update)

    @impl true
    def call(program, inputs) do
      with {:ok, first} <- Imp.Module.call(program.first, inputs),
           {:ok, second} <- Imp.Module.call(program.second, inputs),
           {:ok, third} <- Imp.Module.call(program.third, inputs) do
        prediction =
          first
          |> Imp.Prediction.to_map()
          |> Map.merge(Imp.Prediction.to_map(second))
          |> Map.merge(Imp.Prediction.to_map(third))
          |> Imp.Prediction.new()

        {:ok, prediction}
      end
    end
  end

  defp train_example(question \\ "question") do
    Imp.example(question: question)
    |> Imp.Example.with_inputs(:question)
  end

  defp demo(output_field, value) do
    Imp.Example.new(%{output_field => value, question: "demo"})
    |> Imp.Example.with_inputs(:question)
  end

  defp lm(model, output) do
    %{
      module: Imp.LM.Static,
      model: model,
      opts: [handler: fn _messages, _opts -> output end]
    }
  end

  defp two_predictor_program(first_lm, second_lm, opts \\ []) do
    %TwoPredictorProgram{
      first:
        Imp.predict("question -> first_answer",
          lm: first_lm,
          demos: Keyword.get(opts, :first_demos, [])
        ),
      second:
        Imp.predict("question -> second_answer",
          lm: second_lm,
          demos: Keyword.get(opts, :second_demos, [])
        )
    }
  end

  defp slow_lm(sleep_ms) do
    %{
      module: Imp.LM.Static,
      model: "slow-base",
      opts: [
        handler: fn _messages, _opts ->
          Process.sleep(sleep_ms)
          %{answer: "ok"}
        end
      ]
    }
  end

  defp always_pass(_example, _prediction), do: 1.0

  defp tagged_rows(examples) do
    Enum.map(examples, fn example ->
      cond do
        value = Imp.Example.get(example, :first_answer) -> {:first, value}
        value = Imp.Example.get(example, :second_answer) -> {:second, value}
      end
    end)
  end

  defp predictor_lms(program) do
    Map.new(Imp.ProgramParameters.predictors(program), &{&1.name, &1.predictor.lm})
  end

  describe "teacher timeout threading" do
    test "defaults to 5000ms and accepts :infinity" do
      assert BootstrapFinetune.new(&always_pass/2).timeout == 5_000

      assert %BootstrapFinetune{timeout: :infinity} =
               BootstrapFinetune.new(&always_pass/2, timeout: :infinity)
    end

    test "a teacher slower than the configured timeout selects no traces" do
      program = Imp.predict("question -> answer", lm: slow_lm(200))

      trainer = fn _lm, _examples, _opts ->
        {:ok, TrainingJob.new(%{id: "slow-job", status: :running})}
      end

      optimizer = BootstrapFinetune.new(&always_pass/2, trainer: trainer, timeout: 20)
      result = BootstrapFinetune.compile(optimizer, program, [train_example()])

      assert %{plan: %TrainingPlan{selected_trace_count: 0}} = result
    end

    test "raising the timeout past teacher latency selects the trace (5s default was previously not threadable)" do
      program = Imp.predict("question -> answer", lm: slow_lm(200))

      trainer = fn _lm, _examples, _opts ->
        {:ok, TrainingJob.new(%{id: "slow-job", status: :running})}
      end

      optimizer = BootstrapFinetune.new(&always_pass/2, trainer: trainer, timeout: 2_000)
      result = BootstrapFinetune.compile(optimizer, program, [train_example()])

      assert %{plan: %TrainingPlan{selected_trace_count: 1}} = result
    end
  end

  test "successful trace data is unbounded by default and limiting is opt-in" do
    training_lm = lm("single-base", %{answer: "ok"})
    program = Imp.predict("question -> answer", lm: training_lm)
    trainset = Enum.map(1..40, &train_example("question-#{&1}"))

    all_trainer = fn _lm, examples, _opts ->
      send(self(), {:all_trace_rows, length(examples)})
      {:ok, TrainingJob.new(%{id: "all-traces", status: :running})}
    end

    optimizer = BootstrapFinetune.new(&always_pass/2, trainer: all_trainer)
    assert optimizer.max_demos == :infinity

    assert %{plan: %TrainingPlan{selected_trace_count: 40}} =
             BootstrapFinetune.compile(optimizer, program, trainset)

    assert_received {:all_trace_rows, 40}

    limited_trainer = fn _lm, examples, _opts ->
      send(self(), {:limited_trace_rows, length(examples)})
      {:ok, TrainingJob.new(%{id: "limited-traces", status: :running})}
    end

    assert %{plan: %TrainingPlan{selected_trace_count: 3}} =
             BootstrapFinetune.new(&always_pass/2,
               trainer: limited_trainer,
               max_demos: 3
             )
             |> BootstrapFinetune.compile(program, trainset)

    assert_received {:limited_trace_rows, 3}
  end

  test "nil metric retains every executable trace" do
    training_lm = lm("single-base", %{answer: "generated"})
    program = Imp.predict("question -> answer", lm: training_lm)
    trainset = [train_example("first"), train_example("second")]

    trainer = fn _lm, examples, _opts ->
      send(self(), {:unfiltered_rows, examples})
      {:ok, TrainingJob.new(%{id: "no-metric", status: :running})}
    end

    assert %{plan: %TrainingPlan{selected_trace_count: 2}} =
             BootstrapFinetune.new(nil, trainer: trainer)
             |> BootstrapFinetune.compile(program, trainset)

    assert_received {:unfiltered_rows, examples}

    assert Enum.map(examples, &Imp.Example.get(&1, :question)) |> Enum.sort() ==
             ["first", "second"]
  end

  test "multitask groups predictors sharing one LM into one all-call job" do
    shared_lm = lm("shared-base", %{first_answer: "one", second_answer: "two"})
    program = two_predictor_program(shared_lm, shared_lm)

    trainer = fn training_lm, examples, opts ->
      send(self(), {:finetune, training_lm, examples, opts})
      {:ok, TrainingJob.new(%{id: "shared-job", status: :running})}
    end

    result =
      BootstrapFinetune.new(&always_pass/2, trainer: trainer)
      |> BootstrapFinetune.compile(program, [train_example()])

    assert %{
             plan: %TrainingPlan{
               multitask: true,
               entries: [
                 %{
                   key: {^shared_lm, nil},
                   predictor_indices: [0, 1],
                   predictor_names: [:first, :second],
                   rows: rows,
                   job: %TrainingJob{id: "shared-job"}
                 }
               ]
             }
           } = result

    assert Enum.sort(Enum.map(rows, & &1.predictor_name)) == [:first, :second]
    assert_received {:finetune, ^shared_lm, examples, [method: :sft]}
    assert Enum.sort(tagged_rows(examples)) == [first: "one", second: "two"]
  end

  test "multitask starts one all-call job per distinct LM in predictor order" do
    first_lm = lm("first-base", %{first_answer: "one"})
    second_lm = lm("second-base", %{second_answer: "two"})
    program = two_predictor_program(first_lm, second_lm)

    trainer = fn training_lm, examples, _opts ->
      send(self(), {:finetune, training_lm, examples})
      {:ok, TrainingJob.new(%{id: "job-#{training_lm.model}", status: :pending})}
    end

    result =
      BootstrapFinetune.new(&always_pass/2, trainer: trainer)
      |> BootstrapFinetune.compile(program, [train_example()])

    assert %TrainingPlan{entries: [first_entry, second_entry]} = result.plan
    assert first_entry.key == {first_lm, nil}
    assert first_entry.predictor_names == [:first]
    assert second_entry.key == {second_lm, nil}
    assert second_entry.predictor_names == [:second]
    assert Enum.map(first_entry.rows, & &1.id) == Enum.map(second_entry.rows, & &1.id)

    assert_received {:finetune, ^first_lm, first_examples}
    assert_received {:finetune, ^second_lm, second_examples}
    assert tagged_rows(first_examples) == tagged_rows(second_examples)
    assert Enum.sort(tagged_rows(first_examples)) == [first: "one", second: "two"]
  end

  test "multitask false intentionally fixes the 3.2.1 pred_ind shadowing bug" do
    shared_lm = lm("shared-base", %{first_answer: "one", second_answer: "two"})
    program = two_predictor_program(shared_lm, shared_lm)

    trainer = fn training_lm, examples, _opts ->
      send(self(), {:finetune, training_lm, examples})
      {:ok, TrainingJob.new(%{id: "job-#{System.unique_integer()}", status: :created})}
    end

    result =
      BootstrapFinetune.new(&always_pass/2, trainer: trainer, multitask: false)
      |> BootstrapFinetune.compile(program, [train_example()])

    assert %TrainingPlan{
             multitask: false,
             entries: [
               %{key: {^shared_lm, 0}, predictor_names: [:first]},
               %{key: {^shared_lm, 1}, predictor_names: [:second]}
             ]
           } = result.plan

    assert_received {:finetune, ^shared_lm, first_examples}
    assert_received {:finetune, ^shared_lm, second_examples}
    assert tagged_rows(first_examples) == [first: "one"]
    assert tagged_rows(second_examples) == [second: "two"]
  end

  test "trace concurrency also bounds the number of provider jobs" do
    first_lm = lm("first-base", %{first_answer: "one"})
    second_lm = lm("second-base", %{second_answer: "two"})
    program = two_predictor_program(first_lm, second_lm)

    trainer = fn _lm, _examples, _opts ->
      send(self(), :unexpected_training)
      {:ok, TrainingJob.new(%{id: "unexpected", status: :running})}
    end

    assert %{
             program: ^program,
             error: {:bootstrap_finetune_job_concurrency_exceeded, 2, 1}
           } =
             BootstrapFinetune.new(&always_pass/2,
               trainer: trainer,
               max_concurrency: 1
             )
             |> BootstrapFinetune.compile(program, [train_example()])

    refute_received :unexpected_training
  end

  test "adapter and training options can be selected per unique LM" do
    first_lm = lm("first-base", %{first_answer: "one"})
    second_lm = lm("second-base", %{second_answer: "two"})
    program = two_predictor_program(first_lm, second_lm)

    train_kwargs = Map.new([{first_lm, [epochs: 1]}, {second_lm, [epochs: 2]}])

    adapters =
      Map.new([{first_lm, Imp.Adapter.Chat}, {second_lm, Imp.Adapter.JSON}])

    trainer = fn training_lm, _examples, opts ->
      send(self(), {:lm_config, training_lm, opts})
      {:ok, TrainingJob.new(%{id: "configured-#{training_lm.model}", status: :running})}
    end

    result =
      BootstrapFinetune.new(&always_pass/2,
        trainer: trainer,
        adapter: adapters,
        train_kwargs: train_kwargs,
        max_concurrency: 2
      )
      |> BootstrapFinetune.compile(program, [train_example()])

    assert %TrainingPlan{entries: [first_entry, second_entry]} = result.plan
    assert first_entry.adapter == Imp.Adapter.Chat
    assert first_entry.train_kwargs == [epochs: 1]
    assert second_entry.adapter == Imp.Adapter.JSON
    assert second_entry.train_kwargs == [epochs: 2]

    assert_received {:lm_config, ^first_lm, first_opts}
    assert first_opts[:method] == :sft
    assert first_opts[:adapter] == Imp.Adapter.Chat
    assert first_opts[:epochs] == 1

    assert_received {:lm_config, ^second_lm, second_opts}
    assert second_opts[:method] == :sft
    assert second_opts[:adapter] == Imp.Adapter.JSON
    assert second_opts[:epochs] == 2
  end

  test "training rows retain their explicit teacher predictor attribution" do
    student_lm = lm("student-base", %{first_answer: "student-1", second_answer: "student-2"})
    student = two_predictor_program(student_lm, student_lm)

    first_demo = demo(:first_answer, "first-demo")
    second_demo = demo(:second_answer, "second-demo")

    teacher =
      two_predictor_program(
        lm("teacher-first", %{first_answer: "teacher-1"}),
        lm("teacher-second", %{second_answer: "teacher-2"}),
        first_demos: [first_demo],
        second_demos: [second_demo]
      )

    trainer = fn training_lm, examples, _opts ->
      send(self(), {:finetune, training_lm, examples})
      {:ok, TrainingJob.new(%{id: "teacher-data", status: :running})}
    end

    result =
      BootstrapFinetune.new(&always_pass/2, teacher: teacher, trainer: trainer)
      |> BootstrapFinetune.compile(student, [train_example()])

    assert %{plan: %TrainingPlan{teacher_count: 1, entries: [%{rows: rows}]}} = result
    assert_received {:finetune, ^student_lm, examples}

    first = Enum.find(examples, &Imp.Example.get(&1, :first_answer))
    second = Enum.find(examples, &Imp.Example.get(&1, :second_answer))

    assert Imp.Example.get(first, :first_answer) == "teacher-1"
    assert first.demos == [first_demo]
    assert Imp.Example.get(second, :second_answer) == "teacher-2"
    assert second.demos == [second_demo]

    assert Enum.find(rows, &(&1.predictor_name == :first)).source_predictor == teacher.first
    assert Enum.find(rows, &(&1.predictor_name == :second)).source_predictor == teacher.second
  end

  test "teacher structural mismatch is rejected before any job starts" do
    shared_lm = lm("shared-base", %{first_answer: "one", second_answer: "two"})
    student = two_predictor_program(shared_lm, shared_lm)
    teacher = Imp.predict("question -> first_answer", lm: shared_lm)

    trainer = fn _lm, _examples, _opts ->
      send(self(), :unexpected_training)
      {:ok, TrainingJob.new(%{id: "unexpected"})}
    end

    assert %{program: ^student, error: :bootstrap_finetune_teacher_structure_mismatch} =
             BootstrapFinetune.new(&always_pass/2, teacher: teacher, trainer: trainer)
             |> BootstrapFinetune.compile(student, [train_example()])

    refute_received :unexpected_training
  end

  test "exact-equal teacher predictor values are rejected as shared on BEAM" do
    shared_lm = lm("shared-base", %{first_answer: "one", second_answer: "two"})
    student = two_predictor_program(shared_lm, shared_lm)
    teacher = %{student | second: %{student.second | demos: [demo(:second_answer, "changed")]}}

    trainer = fn _lm, _examples, _opts ->
      send(self(), :unexpected_training)
      {:ok, TrainingJob.new(%{id: "unexpected"})}
    end

    assert %{program: ^student, error: :bootstrap_finetune_teacher_shares_student_predictors} =
             BootstrapFinetune.new(&always_pass/2, teacher: teacher, trainer: trainer)
             |> BootstrapFinetune.compile(student, [train_example()])

    refute_received :unexpected_training
  end

  test "partial terminal job failure is aggregated before any predictor is rebound" do
    first_lm = lm("first-base", %{first_answer: "one"})
    second_lm = lm("second-base", %{second_answer: "two"})
    program = two_predictor_program(first_lm, second_lm)

    trainer = fn
      %{model: "first-base"} = training_lm, _examples, _opts ->
        {:ok,
         TrainingJob.new(%{
           id: "first-ok",
           model: training_lm.model,
           status: :succeeded,
           result_model: "first-ft"
         })}

      %{model: "second-base"} = training_lm, _examples, _opts ->
        {:ok,
         TrainingJob.new(%{
           id: "second-failed",
           model: training_lm.model,
           status: :failed,
           metadata: %{error: :provider_rejected}
         })}
    end

    optimizer = BootstrapFinetune.new(&always_pass/2, trainer: trainer)

    assert {:error,
            %TrainingError{
              reason: {:training_plan_failed, [failed], all_jobs} = reason,
              program: reported,
              job: %TrainingPlan{},
              status: :failed,
              metadata: %{status: :failed}
            }} =
             Imp.train(program, optimizer, [train_example()])

    assert failed.predictor_names == [:second]
    assert failed.status == :failed

    assert Enum.map(all_jobs, &{&1.predictor_names, &1.status}) == [
             {[:first], :succeeded},
             {[:second], :failed}
           ]

    assert predictor_lms(program) == %{first: first_lm, second: second_lm}
    assert predictor_lms(reported) == %{first: first_lm, second: second_lm}

    report = Imp.Optimizer.Report.fetch(reported)
    assert report.metadata.status == :error
    assert report.metadata.terminal_reason == reason

    assert Enum.any?(report.errors, fn error ->
             error.stage == :training_terminal and error.reason == reason
           end)
  end

  test "direct Imp.train cancels running peers after provider failure or cancellation" do
    Enum.each([:failed, :cancelled], fn terminal_status ->
      first_lm = lm("terminal-base", %{first_answer: "one"})
      second_lm = lm("running-base", %{second_answer: "two"})
      program = two_predictor_program(first_lm, second_lm)
      owner = self()

      cancel_transport = fn url, _headers, _body, _opts ->
        send(owner, {:direct_terminal_cancel, terminal_status, url})
        {:ok, %{status: 200, headers: [], body: Jason.encode!(%{status: "cancelled"})}}
      end

      trainer = fn
        %{model: "terminal-base"}, _examples, _opts ->
          {:ok,
           TrainingJob.new(%{
             id: "terminal-#{terminal_status}",
             status: terminal_status,
             transport: cancel_transport,
             cancel_url: "https://trainer.test/jobs/terminal/cancel",
             cancel_body: :empty
           })}

        %{model: "running-base"}, _examples, _opts ->
          {:ok,
           TrainingJob.new(%{
             id: "running-#{terminal_status}",
             status: :running,
             transport: cancel_transport,
             cancel_url: "https://trainer.test/jobs/running/cancel",
             cancel_body: :empty
           })}
      end

      optimizer = BootstrapFinetune.new(&always_pass/2, trainer: trainer)

      assert {:error,
              %TrainingError{
                reason:
                  {:training_plan_failed, [failed], all_jobs,
                   [%{job_id: running_job_id} = cancellation]},
                program: reported,
                job: %TrainingPlan{entries: terminal_entries}
              }} =
               Imp.train(program, optimizer, [train_example()])

      assert running_job_id == "running-#{terminal_status}"
      assert failed.job_id == "terminal-#{terminal_status}"
      assert failed.status == terminal_status

      assert Enum.map(all_jobs, &{&1.job_id, &1.status}) == [
               {"terminal-#{terminal_status}", terminal_status},
               {"running-#{terminal_status}", :running}
             ]

      assert cancellation.prior_status == :running
      assert cancellation.status == :cancelled
      assert cancellation.result == :ok

      assert Enum.map(terminal_entries, &{&1.job.id, &1.job.status}) == [
               {"terminal-#{terminal_status}", terminal_status},
               {"running-#{terminal_status}", :cancelled}
             ]

      report = Imp.Optimizer.Report.fetch(reported)
      assert report.metadata.status == :error
      assert report.metadata.cancellations == [cancellation]

      assert_received {:direct_terminal_cancel, ^terminal_status,
                       "https://trainer.test/jobs/running/cancel"}

      refute_received {:direct_terminal_cancel, ^terminal_status,
                       "https://trainer.test/jobs/terminal/cancel"}
    end)
  end

  test "direct Imp.train fails closed without cancelling an unknown provider status" do
    training_lm = lm("unknown-base", %{answer: "answer"})
    program = Imp.predict("question -> answer", lm: training_lm)
    owner = self()

    cancel_transport = fn url, _headers, _body, _opts ->
      send(owner, {:unknown_status_cancel, url})
      {:ok, %{status: 200, headers: [], body: Jason.encode!(%{status: "cancelled"})}}
    end

    trainer = fn _lm, _examples, _opts ->
      {:ok,
       TrainingJob.new(%{
         id: "provider-validating",
         status: {:unknown, "validating"},
         transport: cancel_transport,
         cancel_url: "https://trainer.test/jobs/provider-validating/cancel",
         cancel_body: :empty
       })}
    end

    optimizer = BootstrapFinetune.new(&always_pass/2, trainer: trainer)

    assert {:error,
            %TrainingError{
              reason: {:training_failed, {:unknown, "validating"}, %{}},
              program: reported,
              job: %TrainingPlan{entries: [%{job: unknown_job}]}
            }} =
             Imp.train(program, optimizer, [train_example()])

    refute_received {:unknown_status_cancel, _url}
    assert unknown_job.status == {:unknown, "validating"}
    assert Imp.Optimizer.Report.fetch(reported).metadata.status == :error
  end

  test "OpenAI validating_files remains an active training job" do
    training_lm = lm("validating-base", %{answer: "answer"})
    program = Imp.predict("question -> answer", lm: training_lm)

    trainer = fn _lm, _examples, _opts ->
      {:ok,
       TrainingJob.new(%{
         id: "provider-validating-files",
         provider: :openai,
         status: "validating_files"
       })}
    end

    optimizer = BootstrapFinetune.new(&always_pass/2, trainer: trainer)

    assert {:ok,
            %TrainingResult{
              status: :job_created,
              job: %TrainingJob{status: :pending}
            }} = Imp.train(program, optimizer, [train_example()])
  end

  test "direct cleanup reports a provider-accepted but nonterminal cancellation" do
    failed_lm = lm("failed-base", %{first_answer: "one"})
    running_lm = lm("running-base", %{second_answer: "two"})
    program = two_predictor_program(failed_lm, running_lm)

    cancel_transport = fn _url, _headers, _body, _opts ->
      {:ok,
       %{
         status: 200,
         headers: [],
         body: Jason.encode!(%{status: "running", request_accepted: true})
       }}
    end

    trainer = fn
      %{model: "failed-base"}, _examples, _opts ->
        {:ok, TrainingJob.new(%{id: "provider-failed", status: :failed})}

      %{model: "running-base"}, _examples, _opts ->
        {:ok,
         TrainingJob.new(%{
           id: "still-running",
           status: :running,
           transport: cancel_transport,
           cancel_url: "https://trainer.test/jobs/still-running/cancel",
           cancel_body: :empty,
           max_attempts: 1
         })}
    end

    optimizer = BootstrapFinetune.new(&always_pass/2, trainer: trainer)

    assert {:error,
            %TrainingError{
              reason:
                {:training_plan_failed, [_failed], _jobs,
                 [%{job_id: "still-running"} = cancellation]},
              program: reported,
              job: %TrainingPlan{entries: [_failed_entry, %{job: updated_job}]}
            }} = Imp.train(program, optimizer, [train_example()])

    assert cancellation.status == :running

    assert cancellation.result ==
             {:error,
              {:training_cancel_incomplete, :running,
               %{
                 "last_status_response" => %{
                   "request_accepted" => true,
                   "status" => "running"
                 }
               }}}

    assert updated_job.status == :running
    assert updated_job.metadata["last_status_response"]["request_accepted"]
    assert Imp.Optimizer.Report.fetch(reported).metadata.cancellations == [cancellation]
  end

  test "mixed succeeded and pending jobs stay pending without partial rebinding" do
    first_demo = demo(:first_answer, "keep-first")
    second_demo = demo(:second_answer, "keep-second")
    first_lm = lm("first-base", %{first_answer: "one"})
    second_lm = lm("second-base", %{second_answer: "two"})

    program =
      two_predictor_program(first_lm, second_lm,
        first_demos: [first_demo],
        second_demos: [second_demo]
      )

    trainer = fn
      %{model: "first-base"} = training_lm, _examples, _opts ->
        {:ok,
         TrainingJob.new(%{
           id: "first-ok",
           model: training_lm.model,
           status: :succeeded,
           result_model: "first-ft"
         })}

      %{model: "second-base"} = training_lm, _examples, _opts ->
        {:ok,
         TrainingJob.new(%{
           id: "second-running",
           model: training_lm.model,
           status: :running
         })}
    end

    optimizer =
      BootstrapFinetune.new(&always_pass/2, trainer: trainer, exclude_demos: true)

    assert {:ok,
            %TrainingResult{
              status: :job_created,
              program: pending_program,
              job: %TrainingPlan{entries: entries}
            }} = Imp.train(program, optimizer, [train_example()])

    assert Enum.map(entries, & &1.job.status) == [:succeeded, :running]
    assert predictor_lms(pending_program) == %{first: first_lm, second: second_lm}
    assert pending_program.first.demos == [first_demo]
    assert pending_program.second.demos == [second_demo]
  end

  test "successful artifacts rebind deterministically by predictor name" do
    first_demo = demo(:first_answer, "clear-first")
    second_demo = demo(:second_answer, "clear-second")
    first_lm = lm("first-base", %{first_answer: "one"})
    second_lm = lm("second-base", %{second_answer: "two"})

    program =
      two_predictor_program(first_lm, second_lm,
        first_demos: [first_demo],
        second_demos: [second_demo]
      )

    trainer = fn training_lm, _examples, _opts ->
      result_model = if training_lm.model == "first-base", do: "z-first-ft", else: "a-second-ft"

      {:ok,
       TrainingJob.new(%{
         id: "job-#{training_lm.model}",
         model: training_lm.model,
         status: :succeeded,
         result_model: result_model
       })}
    end

    optimizer =
      BootstrapFinetune.new(&always_pass/2, trainer: trainer, exclude_demos: true)

    assert {:ok,
            %TrainingResult{
              status: :completed,
              program: rebound,
              job: %TrainingPlan{entries: entries},
              metadata: %{grouping: :unique_lm, job_count: 2, jobs: jobs}
            }} = Imp.train(program, optimizer, [train_example()])

    assert Enum.map(entries, & &1.predictor_names) == [[:first], [:second]]
    assert Enum.map(jobs, & &1.predictor_names) == [[:first], [:second]]
    assert rebound.first.lm.model == "z-first-ft"
    assert rebound.second.lm.model == "a-second-ft"
    assert rebound.first.metadata.training_artifact.job_id == "job-first-base"
    assert rebound.second.metadata.training_artifact.job_id == "job-second-base"
    assert rebound.first.demos == []
    assert rebound.second.demos == []
  end

  test "one shared-LM artifact rebinds every predictor in its group" do
    shared_lm = lm("shared-base", %{first_answer: "one", second_answer: "two"})
    program = two_predictor_program(shared_lm, shared_lm)

    trainer = fn training_lm, _examples, _opts ->
      {:ok,
       TrainingJob.new(%{
         id: "shared-complete",
         model: training_lm.model,
         status: :succeeded,
         result_model: "shared-ft"
       })}
    end

    optimizer = BootstrapFinetune.new(&always_pass/2, trainer: trainer)

    assert {:ok,
            %TrainingResult{
              status: :completed,
              program: rebound,
              job: %TrainingJob{id: "shared-complete"},
              metadata: %{grouping: :unique_lm, job_count: 1}
            }} = Imp.train(program, optimizer, [train_example()])

    assert rebound.first.lm.model == "shared-ft"
    assert rebound.second.lm.model == "shared-ft"
    assert rebound.first.metadata.training_artifact.job_id == "shared-complete"
    assert rebound.second.metadata.training_artifact.job_id == "shared-complete"
  end

  test "a later launch error cancels and reports every already-started provider job" do
    first_lm = lm("first-base", %{first_answer: "one"})
    second_lm = lm("second-base", %{second_answer: "two"})
    third_lm = lm("third-base", %{third_answer: "three"})

    program = %ThreePredictorProgram{
      first: Imp.predict("question -> first_answer", lm: first_lm),
      second: Imp.predict("question -> second_answer", lm: second_lm),
      third: Imp.predict("question -> third_answer", lm: third_lm)
    }

    owner = self()

    cancel_transport = fn url, _headers, _body, _opts ->
      send(owner, {:cancel_requested, url})

      {:ok, %{status: 200, headers: [], body: Jason.encode!(%{status: "cancelled"})}}
    end

    trainer = fn
      %{model: model}, _examples, _opts when model in ["first-base", "second-base"] ->
        {:ok,
         TrainingJob.new(%{
           id: "started-#{model}",
           status: :running,
           transport: cancel_transport,
           cancel_url: "https://trainer.test/jobs/#{model}/cancel",
           cancel_body: :empty
         })}

      %{model: "third-base"}, _examples, _opts ->
        {:error, :provider_capacity}
    end

    optimizer = BootstrapFinetune.new(&always_pass/2, trainer: trainer)

    assert {:error,
            {:training_plan_start_failed,
             {:bootstrap_finetune_training_start_failed, _key, :provider_capacity, cancellations},
             summaries, compiled}} =
             Imp.train(program, optimizer, [train_example()])

    assert_received {:cancel_requested, "https://trainer.test/jobs/first-base/cancel"}
    assert_received {:cancel_requested, "https://trainer.test/jobs/second-base/cancel"}

    assert Enum.map(summaries, &{&1.job_id, &1.status}) == [
             {"started-first-base", :cancelled},
             {"started-second-base", :cancelled},
             {nil, :not_started}
           ]

    assert Enum.map(cancellations, &{&1.job_id, &1.prior_status, &1.status, &1.result}) == [
             {"started-first-base", :running, :cancelled, :ok},
             {"started-second-base", :running, :cancelled, :ok}
           ]

    report = Imp.Optimizer.Report.fetch(compiled)
    assert report.metadata.status == :error
    assert report.metadata.cancellations == cancellations
    assert List.last(report.errors) == %{stage: :training_cancellation, outcomes: cancellations}
  end

  test "launch failure never cancels succeeded or artifact-missing peers" do
    first_lm = lm("first-base", %{first_answer: "one"})
    second_lm = lm("second-base", %{second_answer: "two"})
    third_lm = lm("third-base", %{third_answer: "three"})

    program = %ThreePredictorProgram{
      first: Imp.predict("question -> first_answer", lm: first_lm),
      second: Imp.predict("question -> second_answer", lm: second_lm),
      third: Imp.predict("question -> third_answer", lm: third_lm)
    }

    owner = self()

    cancel_transport = fn url, _headers, _body, _opts ->
      send(owner, {:unexpected_terminal_cancel, url})
      {:ok, %{status: 200, headers: [], body: Jason.encode!(%{status: "cancelled"})}}
    end

    trainer = fn
      %{model: "first-base"}, _examples, _opts ->
        {:ok,
         TrainingJob.new(%{
           id: "already-succeeded",
           status: :succeeded,
           result_model: "first-ft",
           transport: cancel_transport,
           cancel_url: "https://trainer.test/jobs/succeeded/cancel",
           cancel_body: :empty
         })}

      %{model: "second-base"}, _examples, _opts ->
        {:ok,
         TrainingJob.new(%{
           id: "artifact-missing",
           status: :artifact_missing,
           transport: cancel_transport,
           cancel_url: "https://trainer.test/jobs/artifact-missing/cancel",
           cancel_body: :empty
         })}

      %{model: "third-base"}, _examples, _opts ->
        {:error, :provider_capacity}
    end

    optimizer = BootstrapFinetune.new(&always_pass/2, trainer: trainer)

    assert {:error,
            {:training_plan_start_failed,
             {:bootstrap_finetune_training_start_failed, failed_key, :provider_capacity, []},
             summaries, reported}} = Imp.train(program, optimizer, [train_example()])

    assert Enum.map(summaries, &{&1.job_id, &1.status}) == [
             {"already-succeeded", :succeeded},
             {"artifact-missing", :artifact_missing},
             {nil, :not_started}
           ]

    refute_received {:unexpected_terminal_cancel, _url}

    report = Imp.Optimizer.Report.fetch(reported)
    assert report.metadata.status == :error
    refute Map.has_key?(report.metadata, :cancellations)

    assert report.metadata.terminal_reason ==
             {:bootstrap_finetune_training_start_failed, failed_key, :provider_capacity, []}
  end

  test "direct training bounds a provider callback that never returns" do
    owner = self()
    training_lm = lm("hung-launch", %{answer: "answer"})
    program = Imp.predict("question -> answer", lm: training_lm)

    trainer = fn _lm, _examples, _opts ->
      send(owner, :hung_launch_started)
      receive do: (:never -> :ok)
    end

    optimizer =
      BootstrapFinetune.new(&always_pass/2,
        trainer: trainer,
        launch_timeout: 20,
        cancellation_timeout: 20
      )

    started_at = System.monotonic_time(:millisecond)
    result = BootstrapFinetune.compile(optimizer, program, [train_example()])
    elapsed = System.monotonic_time(:millisecond) - started_at

    assert_received :hung_launch_started
    assert elapsed < 500

    assert %{
             error:
               {:bootstrap_finetune_training_start_failed, _key,
                {:bootstrap_finetune_launch_timeout, 20}, []}
           } = result
  end

  test "direct multi-job launch uses one aggregate deadline" do
    first_lm = lm("aggregate-first", %{first_answer: "one"})
    second_lm = lm("aggregate-second", %{second_answer: "two"})
    program = two_predictor_program(first_lm, second_lm)

    trainer = fn training_lm, _examples, _opts ->
      Process.sleep(30)
      {:ok, TrainingJob.new(%{id: training_lm.model, status: :running})}
    end

    optimizer =
      BootstrapFinetune.new(&always_pass/2,
        trainer: trainer,
        launch_timeout: 45,
        cancellation_timeout: 20
      )

    started_at = System.monotonic_time(:millisecond)
    result = BootstrapFinetune.compile(optimizer, program, [train_example()])
    elapsed = System.monotonic_time(:millisecond) - started_at

    assert %{
             error:
               {:bootstrap_finetune_training_start_failed, _key,
                {:bootstrap_finetune_launch_timeout, 45}, _cancellations}
           } = result

    assert elapsed < 100
  end

  test "direct terminal cleanup bounds a provider cancellation that never returns" do
    failed_lm = lm("failed-cleanup", %{first_answer: "one"})
    running_lm = lm("hung-cleanup", %{second_answer: "two"})
    program = two_predictor_program(failed_lm, running_lm)
    owner = self()

    trainer = fn
      %{model: "failed-cleanup"}, _examples, _opts ->
        {:ok, TrainingJob.new(%{id: "failed-cleanup", status: :failed})}

      %{model: "hung-cleanup"}, _examples, _opts ->
        {:ok,
         TrainingJob.new(%{
           id: "hung-cleanup",
           status: :running,
           cancel_url: "https://training.example/jobs/hung-cleanup/cancel",
           cancel_body: :empty,
           max_attempts: 1,
           transport: fn _url, _headers, _body, _opts ->
             send(owner, :hung_direct_cleanup_started)
             receive do: (:never -> :ok)
           end
         })}
    end

    optimizer =
      BootstrapFinetune.new(&always_pass/2,
        trainer: trainer,
        cancellation_timeout: 20
      )

    started_at = System.monotonic_time(:millisecond)
    result = Imp.train(program, optimizer, [train_example()])
    elapsed = System.monotonic_time(:millisecond) - started_at

    assert_received :hung_direct_cleanup_started
    assert elapsed < 500

    assert {:error,
            %TrainingError{
              reason:
                {:training_plan_failed, [_failed], _jobs,
                 [%{result: {:error, {:training_cancel_timeout, timeout}}}]}
            }} = result

    assert timeout in 0..20
  end
end
