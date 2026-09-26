defmodule BetterTogetherTest do
  use ExUnit.Case

  alias Imp.Optimizer.BetterTogether

  defmodule SetInstruction do
    @behaviour Imp.Optimizer
    defstruct [:instruction]

    @impl true
    def __optimizer__,
      do: %{
        kind: :program,
        datasets: %{trainset: :required, validation: :unsupported},
        result: :program
      }

    @impl true
    def run(%__MODULE__{instruction: instruction}, program, _opts),
      do: {:ok, Imp.Optimizer.InstructionSearch.put_instruction(program, instruction)}
  end

  defmodule PromptSequence do
    @behaviour Imp.Optimizer
    defstruct []

    @impl true
    def __optimizer__,
      do: %{
        kind: :program,
        datasets: %{trainset: :required, validation: :unsupported},
        result: :program
      }

    @impl true
    def run(%__MODULE__{}, program, _opts) do
      instruction = Imp.Optimizer.InstructionSearch.current_instruction(program)

      next =
        if instruction == "Answer neither question.",
          do: "Answer every question.",
          else: "Answer only the France question."

      {:ok, Imp.Optimizer.InstructionSearch.put_instruction(program, next)}
    end
  end

  defmodule FailingOptimizer do
    @behaviour Imp.Optimizer
    defstruct []

    @impl true
    def __optimizer__,
      do: %{
        kind: :program,
        datasets: %{trainset: :required, validation: :unsupported},
        result: :program
      }

    @impl true
    def run(%__MODULE__{}, _program, _opts), do: {:error, :compile_failed}
  end

  defmodule RaisingOptimizer do
    @behaviour Imp.Optimizer
    defstruct []

    @impl true
    def __optimizer__,
      do: %{
        kind: :program,
        datasets: %{trainset: :required, validation: :unsupported},
        result: :program
      }

    @impl true
    def run(%__MODULE__{}, _program, _opts), do: raise("compile exploded")
  end

  defmodule OperationalGuardOptimizer do
    @behaviour Imp.Optimizer
    defstruct []

    @impl true
    def __optimizer__,
      do: %{
        kind: :program,
        datasets: %{trainset: :required, validation: :unsupported},
        result: :program
      }

    @impl true
    def run(%__MODULE__{}, _program, _opts) do
      {:error,
       Imp.OperationalSafetyError.exception(
         kind: :transport,
         message: "composition transport guard",
         reason: :attempt_mismatch
       )}
    end
  end

  defmodule SpyOptimizer do
    @behaviour Imp.Optimizer
    defstruct [:owner]

    @impl true
    def __optimizer__,
      do: %{
        kind: :program,
        datasets: %{trainset: :required, validation: :unsupported},
        result: :program
      }

    @impl true
    def run(%__MODULE__{owner: owner}, program, _opts) do
      send(owner, :unexpected_later_step)
      {:ok, program}
    end
  end

  defmodule CaptureSets do
    @behaviour Imp.Optimizer
    defstruct [:owner]

    @impl true
    def __optimizer__,
      do: %{
        kind: :program,
        datasets: %{trainset: :required, validation: :required},
        result: :program
      }

    @impl true
    def run(%__MODULE__{owner: owner}, program, opts) do
      trainset = Keyword.fetch!(opts, :trainset)
      valset = Keyword.fetch!(opts, :validation)
      send(owner, {:prepared_sets, length(trainset), length(valset)})
      {:ok, program}
    end
  end

  defmodule CompileArgsOptimizer do
    @behaviour Imp.Optimizer
    defstruct [:owner]

    @impl true
    def __optimizer__,
      do: %{
        kind: :program,
        datasets: %{trainset: :required, validation: :optional},
        result: :program
      }

    @impl true
    def run(%__MODULE__{owner: owner}, program, opts) do
      send(owner, {:compile_args, opts})
      {:ok, program}
    end
  end

  defmodule TeacherCaptureOptimizer do
    @behaviour Imp.Optimizer
    defstruct [:owner, :label]

    @impl true
    def __optimizer__,
      do: %{
        kind: :program,
        datasets: %{trainset: :required, validation: :unsupported},
        result: :program
      }

    @impl true
    def run(%__MODULE__{owner: owner, label: label}, program, opts) do
      send(owner, {:generic_teacher, label, Keyword.get(opts, :teacher), opts[:marker]})
      {:ok, program}
    end
  end

  defmodule StatefulCapabilitiesOptimizer do
    @behaviour Imp.Optimizer
    defstruct [:owner]

    @impl true
    def __optimizer__ do
      key = {__MODULE__, :capability_probes}
      probes = Process.get(key, 0)
      Process.put(key, probes + 1)

      if probes == 0 do
        %{
          kind: :program,
          datasets: %{trainset: :required, validation: :unsupported},
          result: :program
        }
      else
        %{
          kind: :training,
          datasets: %{trainset: :required, validation: :unsupported},
          result: :training_result
        }
      end
    end

    @impl true
    def run(%__MODULE__{owner: owner}, program, _opts) do
      send(owner, :stateful_optimizer_ran)
      {:ok, program}
    end
  end

  defmodule GenericTrainingOptimizer do
    @behaviour Imp.Optimizer
    defstruct [:job, status: :job_created]

    @impl true
    def __optimizer__,
      do: %{
        kind: :training,
        datasets: %{trainset: :required, validation: :unsupported},
        result: :training_result
      }

    @impl true
    def run(%__MODULE__{job: job, status: status}, program, _opts),
      do:
        {:ok,
         %Imp.Optimizer.TrainingResult{
           program: program,
           job: job,
           status: status,
           metadata: %{optimizer: :generic_test}
         }}
  end

  defmodule MetadataProgram do
    @behaviour Imp.Module
    defstruct [:predict, metadata: %{}]

    @impl true
    def optimizer_predictors(program), do: [main: program.predict]

    @impl true
    def update_optimizer_predictor(program, :main, update),
      do: %{program | predict: update.(program.predict)}

    @impl true
    def call(program, inputs), do: Imp.Module.call(program.predict, inputs)
  end

  defmodule ReportlessProgram do
    @behaviour Imp.Module
    defstruct [:predict]

    @impl true
    def optimizer_predictors(program), do: [main: program.predict]

    @impl true
    def update_optimizer_predictor(program, :main, update),
      do: %{program | predict: update.(program.predict)}

    @impl true
    def call(program, inputs), do: Imp.Module.call(program.predict, inputs)
  end

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
        prediction =
          first
          |> Imp.Prediction.to_map()
          |> Map.merge(Imp.Prediction.to_map(second))
          |> Imp.Prediction.new()

        {:ok, prediction}
      end
    end
  end

  defmodule CompletingTrainingTransport do
    def request(:get, _url, _headers, _body, _opts) do
      {:ok,
       %{
         status: 200,
         headers: [],
         body: Jason.encode!(%{status: "succeeded", result_model: "trained-model"})
       }}
    end
  end

  defmodule ModelAwareLM do
    defstruct [:model]

    def generate(%__MODULE__{model: model}, _messages, _opts) do
      answer = if model == "trained-model", do: "trained", else: "base"
      {:ok, %{answer: answer}}
    end
  end

  defmodule SlowTrainingTransport do
    def request(:get, _url, _headers, _body, _opts) do
      if owner = Process.whereis(BetterTogetherTest.SlowTransportOwner) do
        send(owner, :slow_refresh_started)
      end

      Process.sleep(1_000)

      {:ok,
       %{
         status: 200,
         headers: [],
         body: Jason.encode!(%{status: "succeeded", result_model: "too-late"})
       }}
    end

    def request(:post, url, _headers, _body, _opts) do
      if owner = Process.whereis(BetterTogetherTest.SlowTransportOwner) do
        send(owner, {:slow_cancel_requested, url})
      end

      {:ok, %{status: 200, headers: [], body: Jason.encode!(%{status: "cancelled"})}}
    end
  end

  defmodule MixedTrainingTransport do
    def request(:get, url, _headers, _body, _opts) do
      cond do
        String.ends_with?(url, "/failed") ->
          {:ok,
           %{
             status: 200,
             headers: [],
             body: Jason.encode!(%{status: "failed", error: "provider rejected data"})
           }}

        String.ends_with?(url, "/blocked") ->
          if owner = Process.whereis(BetterTogetherTest.MixedTransportOwner) do
            send(owner, :mixed_blocking_refresh_started)
          end

          Process.sleep(1_000)

          {:ok,
           %{
             status: 200,
             headers: [],
             body: Jason.encode!(%{status: "running"})
           }}
      end
    end

    def request(:post, url, _headers, _body, _opts) do
      if owner = Process.whereis(BetterTogetherTest.MixedTransportOwner) do
        send(owner, {:mixed_cancel_requested, url})
      end

      {:ok, %{status: 200, headers: [], body: Jason.encode!(%{status: "cancelled"})}}
    end
  end

  defmodule FailureThenRefreshErrorTransport do
    def request(:get, url, _headers, _body, _opts) do
      cond do
        String.ends_with?(url, "/failed") ->
          {:ok,
           %{
             status: 200,
             headers: [],
             body: Jason.encode!(%{status: "failed", error: "provider rejected data"})
           }}

        String.ends_with?(url, "/refresh-error") ->
          if owner = Process.whereis(BetterTogetherTest.RefreshErrorOwner) do
            send(owner, :mixed_refresh_error_seen)
          end

          {:error, :provider_status_unavailable}
      end
    end

    def request(:post, url, _headers, _body, _opts) do
      if owner = Process.whereis(BetterTogetherTest.RefreshErrorOwner) do
        send(owner, {:mixed_refresh_cancel_requested, url})
      end

      {:ok, %{status: 200, headers: [], body: Jason.encode!(%{status: "cancelled"})}}
    end
  end

  defmodule HungCancellationTransport do
    def request(:post, url, _headers, _body, _opts) do
      if owner = Process.whereis(BetterTogetherTest.HungCancellationOwner) do
        send(owner, {:hung_cleanup_requested, url})
      end

      if String.ends_with?(url, "/hung/cancel") do
        Process.sleep(1_000)
      end

      {:ok, %{status: 200, headers: [], body: Jason.encode!(%{status: "cancelled"})}}
    end
  end

  defp metric, do: Imp.Metrics.exact_match(:answer)

  defp program do
    Imp.predict("question -> answer",
      lm:
        Imp.LM.Static.new(
          handler: fn messages, _opts ->
            prompt = Enum.map_join(messages, "\n", & &1.content)

            answer =
              cond do
                prompt =~ "Answer every question." and prompt =~ "Germany" -> "Berlin"
                prompt =~ "Answer every question." -> "Paris"
                prompt =~ "Answer only the France question." and prompt =~ "France" -> "Paris"
                true -> "unknown"
              end

            %{answer: answer}
          end
        )
    )
  end

  defp examples do
    [
      example("Capital of France?", "Paris"),
      example("Capital of Germany?", "Berlin")
    ]
  end

  defp example(question, answer) do
    Imp.example(question: question, answer: answer)
    |> Imp.Example.with_inputs(:question)
  end

  test "defaults to the upstream p -> w -> p strategy and selects the best prefix" do
    better =
      BetterTogether.new(metric(), %{
        p: %PromptSequence{},
        w: %SetInstruction{instruction: "Answer neither question."}
      })

    compiled = BetterTogether.compile(better, program(), examples(), examples())
    report = Imp.Optimizer.Report.fetch(compiled)

    assert Imp.Optimizer.InstructionSearch.current_instruction(compiled) ==
             "Answer every question."

    assert report.best_score == 1.0
    assert report.candidate_count == 4
    assert report.metadata.steps == ["p", "w", "p"]
    assert report.metadata.selected_strategy == "p -> w -> p"
    assert Enum.map(report.candidates, & &1.score) == [0.0, 0.5, 0.0, 1.0]
  end

  test "accepts trace-aware arity-three metrics" do
    owner = self()

    metric = fn example, prediction, _trace ->
      send(owner, :trace_metric_called)
      Imp.Example.get(example, :answer) == Imp.Prediction.get(prediction, :answer)
    end

    compiled =
      BetterTogether.new(metric, %{
        p: %SetInstruction{instruction: "Answer every question."}
      })
      |> BetterTogether.compile(program(), examples(), examples(), strategy: :p)

    assert_received :trace_metric_called
    assert Imp.Optimizer.Report.fetch(compiled).candidate_count == 2
  end

  test "retains and returns the baseline when optimization makes validation worse" do
    original =
      program()
      |> Imp.Optimizer.InstructionSearch.put_instruction("Answer every question.")

    compiled =
      metric()
      |> BetterTogether.new(%{p: %SetInstruction{instruction: "Answer neither question."}})
      |> BetterTogether.compile(original, examples(), examples(), strategy: :p)

    report = Imp.Optimizer.Report.fetch(compiled)

    assert Imp.Optimizer.InstructionSearch.current_instruction(compiled) ==
             Imp.Optimizer.InstructionSearch.current_instruction(original)

    assert report.metadata.selected_strategy == ""
    assert Enum.map(report.candidates, & &1.score) == [1.0, 0.0]
  end

  test "returns the latest successful candidate when validation is disabled" do
    compiled =
      metric()
      |> BetterTogether.new(%{p: %SetInstruction{instruction: "Answer every question."}})
      |> BetterTogether.compile(program(), examples(), nil, strategy: :p, valset_ratio: 0)

    report = Imp.Optimizer.Report.fetch(compiled)

    assert Imp.Optimizer.InstructionSearch.current_instruction(compiled) ==
             "Answer every question."

    assert report.best_score == nil
    assert report.metadata.selected_strategy == "p"
    assert Enum.map(report.candidates, & &1.score) == [nil, nil]
  end

  test "prepares a validation holdout without modifying the caller's trainset" do
    trainset = examples() ++ [example("France?", "Paris"), example("Germany?", "Berlin")]

    compiled =
      metric()
      |> BetterTogether.new(%{capture: %CaptureSets{owner: self()}})
      |> BetterTogether.compile(program(), trainset, nil,
        strategy: :capture,
        valset_ratio: 0.25,
        shuffle_trainset_between_steps: false
      )

    assert_receive {:prepared_sets, 3, 1}
    assert length(trainset) == 4

    report = Imp.Optimizer.Report.fetch(compiled)
    assert report.metadata.trainset_size == 3
    assert report.metadata.validation_size == 1
    assert Enum.all?(report.candidates, &(&1.evaluation.validation_size == 1))
  end

  test "the public facade keeps a real validation row for a small default split" do
    trainset = examples()

    original =
      program()
      |> Imp.Optimizer.InstructionSearch.put_instruction("Answer every question.")

    optimizer =
      BetterTogether.new(metric(), %{
        p: %SetInstruction{instruction: "Answer neither question."}
      })

    compiled = Imp.optimize!(original, optimizer, trainset)
    report = Imp.Optimizer.Report.fetch(compiled)

    assert report.metadata.trainset_size == 1
    assert report.metadata.validation_size == 1
    assert report.metadata.selected_strategy == ""
    assert report.best_score == 1.0

    assert Imp.Optimizer.InstructionSearch.current_instruction(compiled) ==
             "Answer every question."
  end

  test "a single training row remains usable when an automatic split is impossible" do
    trainset = [hd(examples())]

    compiled =
      metric()
      |> BetterTogether.new(%{capture: %CaptureSets{owner: self()}})
      |> BetterTogether.compile(program(), trainset, nil,
        strategy: :capture,
        shuffle_trainset_between_steps: false
      )

    assert_receive {:prepared_sets, 1, 0}
    report = Imp.Optimizer.Report.fetch(compiled)
    assert report.metadata.trainset_size == 1
    assert report.metadata.validation_size == 0
    assert report.metadata.selected_strategy == "capture"
  end

  test "preserves an explicitly empty validation split instead of carving a holdout" do
    trainset = examples() ++ [example("France?", "Paris"), example("Germany?", "Berlin")]

    compiled =
      metric()
      |> BetterTogether.new(%{capture: %CaptureSets{owner: self()}})
      |> BetterTogether.compile(program(), trainset, [],
        strategy: :capture,
        valset_ratio: 0.25,
        shuffle_trainset_between_steps: false
      )

    assert_receive {:prepared_sets, 4, 0}
    report = Imp.Optimizer.Report.fetch(compiled)
    assert report.metadata.trainset_size == 4
    assert report.metadata.validation_size == 0
  end

  test "forwards keyed compile arguments after applying per-step dataset overrides" do
    overridden_trainset = [hd(examples())]

    compiled =
      metric()
      |> BetterTogether.new(%{capture: %CompileArgsOptimizer{owner: self()}})
      |> BetterTogether.compile(program(), examples(), examples(),
        strategy: :capture,
        shuffle_trainset_between_steps: false,
        optimizer_compile_args: %{
          capture: [trainset: overridden_trainset, validation: [], marker: :per_step]
        }
      )

    assert_received {:compile_args, opts}
    assert opts[:trainset] == overridden_trainset
    assert opts[:validation] == []
    assert opts[:marker] == :per_step

    assert Enum.any?(Imp.Optimizer.Report.fetch(compiled).candidates, fn candidate ->
             candidate.strategy == "capture"
           end)
  end

  test "routes COPRO evaluation options through a composed prompt step" do
    # The task and proposal roles stay explicit inside the composed optimizer.
    Imp.Settings.context([lm: nil], fn ->
      proposer_lm =
        Imp.LM.Static.new(
          handler: fn _messages, _opts ->
            Jason.encode!(%{
              "proposed_instruction" => "Answer carefully.",
              "proposed_prefix_for_output_field" => "Answer:"
            })
          end
        )

      copro =
        Imp.Optimizer.COPRO.new(metric(),
          breadth: 2,
          depth: 1,
          proposer_lm: proposer_lm,
          proposal_max_concurrency: 1
        )

      assert {:ok, direct_copro} =
               Imp.Optimizer.run(copro, program(),
                 trainset: examples(),
                 validation: examples(),
                 num_threads: 1,
                 max_errors: :infinity
               )

      direct_report = Imp.Optimizer.Report.fetch(direct_copro)
      assert direct_report.metadata.max_errors == :infinity
      assert direct_report.metadata.max_errors_source == :explicit

      compiled =
        metric()
        |> BetterTogether.new(%{
          p: copro,
          after_p: %CompileArgsOptimizer{owner: self()}
        })
        |> BetterTogether.compile(program(), examples(), examples(),
          strategy: [:p, :after_p],
          max_errors: 1,
          max_concurrency: 1,
          shuffle_trainset_between_steps: false,
          optimizer_compile_args: %{
            p: [num_threads: 1, max_errors: :infinity],
            after_p: [marker: :after_copro]
          }
        )

      assert_received {:compile_args, after_opts}
      assert after_opts[:marker] == :after_copro
      refute Keyword.has_key?(after_opts, :num_threads)
      refute Keyword.has_key?(after_opts, :max_errors)

      report = Imp.Optimizer.Report.fetch(compiled)
      assert report.errors == []
      assert Enum.map(report.candidates, & &1.strategy) == ["", "p", "p -> after_p"]
    end)
  end

  test "rejects unsupported declared child options before baseline evaluation" do
    owner = self()

    observed_program =
      Imp.predict("question -> answer",
        lm:
          Imp.LM.Static.new(
            handler: fn _messages, _opts ->
              send(owner, :unexpected_baseline_call)
              %{answer: "Paris"}
            end
          )
      )

    optimizer =
      BetterTogether.new(metric(), %{
        p: Imp.Optimizer.COPRO.new(metric(), breadth: 2, depth: 1)
      })

    assert_raise ArgumentError,
                 ~r/invalid optimizer_compile_args.*unknown options.*unknown_control/s,
                 fn ->
                   BetterTogether.compile(optimizer, observed_program, examples(), examples(),
                     strategy: :p,
                     optimizer_compile_args: %{p: [unknown_control: true]}
                   )
                 end

    refute_received :unexpected_baseline_call
  end

  test "rejects unsupported MIPROv2 child options before baseline evaluation" do
    owner = self()

    observed_program =
      Imp.predict("question -> answer",
        lm:
          Imp.LM.Static.new(
            handler: fn _messages, _opts ->
              send(owner, :unexpected_mipro_baseline_call)
              %{answer: "Paris"}
            end
          )
      )

    prompt_lm =
      Imp.LM.Static.new(handler: fn _messages, _opts -> %{instructions: ["Answer."]} end)

    mipro =
      Imp.Optimizer.MIPROv2.new(metric(),
        auto: nil,
        num_candidates: 2,
        num_trials: 1,
        max_bootstrapped_demos: 0,
        max_labeled_demos: 0,
        minibatch: false,
        prompt_lm: prompt_lm
      )

    optimizer = BetterTogether.new(metric(), %{p: mipro})

    assert_raise ArgumentError,
                 ~r/invalid optimizer_compile_args.*unknown MIPROv2 invocation options.*unknown_control/s,
                 fn ->
                   BetterTogether.compile(optimizer, observed_program, examples(), examples(),
                     strategy: :p,
                     optimizer_compile_args: %{p: [unknown_control: true]}
                   )
                 end

    refute_received :unexpected_mipro_baseline_call
  end

  test "routes global and per-step teachers through a generic optimizer contract" do
    global_teacher = program()

    step_teacher =
      program()
      |> Imp.Optimizer.InstructionSearch.put_instruction("step teacher")

    compiled =
      BetterTogether.new(metric(), %{
        global: %TeacherCaptureOptimizer{owner: self(), label: :global},
        override: %TeacherCaptureOptimizer{owner: self(), label: :override}
      })
      |> BetterTogether.compile(program(), examples(), nil,
        strategy: [:global, :override],
        teacher: global_teacher,
        valset_ratio: 0,
        shuffle_trainset_between_steps: false,
        optimizer_compile_args: %{
          global: [marker: :global],
          override: [teacher: step_teacher, marker: :override]
        }
      )

    assert_received {:generic_teacher, :global, ^global_teacher, :global}
    assert_received {:generic_teacher, :override, ^step_teacher, :override}
    assert Imp.Optimizer.Report.fetch(compiled).metadata.selected_strategy == "global -> override"
  end

  test "executes a generic step under its single captured capability declaration" do
    key = {StatefulCapabilitiesOptimizer, :capability_probes}
    Process.delete(key)

    compiled =
      BetterTogether.new(metric(), %{
        stateful: %StatefulCapabilitiesOptimizer{owner: self()}
      })
      |> BetterTogether.compile(program(), examples(), nil,
        strategy: :stateful,
        valset_ratio: 0,
        shuffle_trainset_between_steps: false
      )

    assert_received :stateful_optimizer_ran
    assert Process.get(key) == 1
    assert Imp.Optimizer.Report.fetch(compiled).metadata.selected_strategy == "stateful"
  end

  test "awaits and rebinds an active generic training result" do
    trainable_program =
      Imp.with_lm(program(), Map.put(Imp.ProgramAccess.lm(program()), :model, "generic-base"))

    job =
      Imp.Clients.TrainingJob.new(%{
        id: "generic-active",
        provider: :test,
        model: "generic-base",
        status: :running,
        status_url: "https://training.example/jobs/generic-active",
        status_method: :get,
        transport: CompletingTrainingTransport
      })

    compiled =
      BetterTogether.new(metric(), %{g: %GenericTrainingOptimizer{job: job}})
      |> BetterTogether.compile(trainable_program, examples(), nil,
        strategy: :g,
        valset_ratio: 0,
        training_timeout: 100,
        training_poll_interval: 0,
        shuffle_trainset_between_steps: false
      )

    assert Imp.ProgramAccess.lm(compiled).model == "trained-model"

    assert Enum.any?(Imp.Optimizer.Report.fetch(compiled).candidates, fn candidate ->
             Map.get(candidate, :compile_metadata) == %{
               kind: :training,
               optimizer: GenericTrainingOptimizer,
               awaited: true,
               training_status: :completed
             }
           end)
  end

  test "cleans up an active generic training result when polling times out" do
    owner = self()

    cancel_transport = fn url, _headers, _body, _opts ->
      send(owner, {:generic_cancel_requested, url})
      {:ok, %{status: 200, headers: [], body: Jason.encode!(%{status: "cancelled"})}}
    end

    job =
      Imp.Clients.TrainingJob.new(%{
        id: "generic-cleanup-success",
        provider: :test,
        status: :running,
        transport: cancel_transport,
        cancel_url: "https://training.example/jobs/generic-cleanup-success/cancel",
        cancel_body: :empty,
        max_attempts: 1
      })

    compiled =
      BetterTogether.new(metric(), %{g: %GenericTrainingOptimizer{job: job}})
      |> BetterTogether.compile(program(), examples(), nil,
        strategy: :g,
        valset_ratio: 0,
        training_timeout: 0,
        training_cancellation_timeout: 100,
        shuffle_trainset_between_steps: false
      )

    assert_received {:generic_cancel_requested,
                     "https://training.example/jobs/generic-cleanup-success/cancel"}

    assert [%{error: {:training_step_timeout, GenericTrainingOptimizer, 0, [summary], [cleanup]}}] =
             Imp.Optimizer.Report.fetch(compiled).errors

    assert summary == %{job_id: "generic-cleanup-success", status: :running, metadata: %{}}

    assert cleanup == %{
             job_id: "generic-cleanup-success",
             prior_status: :running,
             status: :cancelled,
             result: :ok
           }
  end

  test "reports generic cleanup failure without claiming completion" do
    cancel_transport = fn _url, _headers, _body, _opts ->
      {:ok, %{status: 503, headers: [], body: Jason.encode!(%{error: "unavailable"})}}
    end

    job =
      Imp.Clients.TrainingJob.new(%{
        id: "generic-cleanup-failure",
        provider: :test,
        status: :running,
        transport: cancel_transport,
        cancel_url: "https://training.example/jobs/generic-cleanup-failure/cancel",
        cancel_body: :empty,
        max_attempts: 1
      })

    compiled =
      BetterTogether.new(metric(), %{g: %GenericTrainingOptimizer{job: job}})
      |> BetterTogether.compile(program(), examples(), nil,
        strategy: :g,
        valset_ratio: 0,
        training_timeout: 0,
        training_cancellation_timeout: 100,
        shuffle_trainset_between_steps: false
      )

    assert [
             %{
               error: {:training_step_timeout, GenericTrainingOptimizer, 0, [_summary], [cleanup]}
             }
           ] = Imp.Optimizer.Report.fetch(compiled).errors

    assert {:error, {:http_error, 503, _body}} = cleanup.result
    assert cleanup.status == :running
  end

  test "bounds generic cleanup when cancellation hangs" do
    owner = self()

    cancel_transport = fn url, _headers, _body, _opts ->
      send(owner, {:generic_hung_cancel_requested, url})
      Process.sleep(1_000)
      {:ok, %{status: 200, headers: [], body: Jason.encode!(%{status: "cancelled"})}}
    end

    job =
      Imp.Clients.TrainingJob.new(%{
        id: "generic-cleanup-timeout",
        provider: :test,
        status: :running,
        transport: cancel_transport,
        cancel_url: "https://training.example/jobs/generic-cleanup-timeout/cancel",
        cancel_body: :empty,
        max_attempts: 1
      })

    started_at = System.monotonic_time(:millisecond)

    compiled =
      BetterTogether.new(metric(), %{g: %GenericTrainingOptimizer{job: job}})
      |> BetterTogether.compile(program(), examples(), nil,
        strategy: :g,
        valset_ratio: 0,
        training_timeout: 0,
        training_cancellation_timeout: 25,
        shuffle_trainset_between_steps: false
      )

    assert System.monotonic_time(:millisecond) - started_at < 500

    assert_received {:generic_hung_cancel_requested,
                     "https://training.example/jobs/generic-cleanup-timeout/cancel"}

    assert [
             %{
               error: {:training_step_timeout, GenericTrainingOptimizer, 0, [_summary], [cleanup]}
             }
           ] =
             Imp.Optimizer.Report.fetch(compiled).errors

    assert {:error, {:training_cancel_timeout, timeout}} = cleanup.result
    assert timeout in 0..25
    assert cleanup.status == :running
  end

  test "handles known terminal generic jobs without polling or cancellation" do
    owner = self()

    transport = fn url, _headers, _body, _opts ->
      send(owner, {:unexpected_generic_lifecycle_request, url})
      {:ok, %{status: 200, headers: [], body: Jason.encode!(%{status: "running"})}}
    end

    base_program = program()

    trainable_program =
      Imp.with_lm(
        base_program,
        Map.put(Imp.ProgramAccess.lm(base_program), :model, "terminal-base")
      )

    for status <- [:succeeded, :failed, :cancelled, :artifact_missing] do
      attrs = %{
        id: "generic-terminal-#{status}",
        provider: :test,
        status: status,
        transport: transport,
        status_url: "https://training.example/jobs/terminal-#{status}",
        cancel_url: "https://training.example/jobs/terminal-#{status}/cancel",
        cancel_body: :empty
      }

      attrs =
        if status == :succeeded, do: Map.put(attrs, :result_model, "terminal-model"), else: attrs

      job = Imp.Clients.TrainingJob.new(attrs)

      compiled =
        BetterTogether.new(metric(), %{g: %GenericTrainingOptimizer{job: job}})
        |> BetterTogether.compile(trainable_program, examples(), nil,
          strategy: :g,
          valset_ratio: 0,
          training_timeout: 25,
          shuffle_trainset_between_steps: false
        )

      case status do
        :succeeded ->
          assert Imp.ProgramAccess.lm(compiled).model == "terminal-model"
          assert Imp.Optimizer.Report.fetch(compiled).errors == []

        _failure ->
          assert [%{error: {:training_failed, ^status, _metadata}}] =
                   Imp.Optimizer.Report.fetch(compiled).errors
      end
    end

    refute_received {:unexpected_generic_lifecycle_request, _}
  end

  test "fails closed without polling or cancelling an unknown generic job status" do
    owner = self()

    transport = fn url, _headers, _body, _opts ->
      send(owner, {:unexpected_unknown_lifecycle_request, url})
      {:ok, %{status: 200, headers: [], body: Jason.encode!(%{status: "cancelled"})}}
    end

    job =
      Imp.Clients.TrainingJob.new(%{
        id: "generic-unknown",
        provider: :test,
        status: {:unknown, "provider-paused"},
        transport: transport,
        status_url: "https://training.example/jobs/generic-unknown",
        cancel_url: "https://training.example/jobs/generic-unknown/cancel",
        cancel_body: :empty
      })

    compiled =
      BetterTogether.new(metric(), %{g: %GenericTrainingOptimizer{job: job}})
      |> BetterTogether.compile(program(), examples(), nil,
        strategy: :g,
        valset_ratio: 0,
        training_timeout: 25,
        shuffle_trainset_between_steps: false
      )

    assert [
             %{
               error:
                 {:unknown_training_status, GenericTrainingOptimizer,
                  {:unknown, "provider-paused"}, %{}}
             }
           ] = Imp.Optimizer.Report.fetch(compiled).errors

    refute_received {:unexpected_unknown_lifecycle_request, _}
  end

  test "boundedly cleans an active job attached to a noncanonical training result" do
    owner = self()

    cancel_transport = fn url, _headers, _body, _opts ->
      send(owner, {:malformed_result_cancel_requested, url})
      {:ok, %{status: 200, headers: [], body: Jason.encode!(%{status: "cancelled"})}}
    end

    job =
      Imp.Clients.TrainingJob.new(%{
        id: "malformed-active",
        provider: :test,
        status: :running,
        transport: cancel_transport,
        cancel_url: "https://training.example/jobs/malformed-active/cancel",
        cancel_body: :empty,
        max_attempts: 1
      })

    compiled =
      BetterTogether.new(metric(), %{
        g: %GenericTrainingOptimizer{job: job, status: :provider_specific}
      })
      |> BetterTogether.compile(program(), examples(), nil,
        strategy: :g,
        valset_ratio: 0,
        training_cancellation_timeout: 100,
        shuffle_trainset_between_steps: false
      )

    assert_received {:malformed_result_cancel_requested,
                     "https://training.example/jobs/malformed-active/cancel"}

    assert [
             %{
               error:
                 {:training_terminal_error,
                  {:invalid_training_result_status, GenericTrainingOptimizer, :provider_specific,
                   %{job_id: "malformed-active", status: :running, metadata: %{}}}, [cleanup]}
             }
           ] = Imp.Optimizer.Report.fetch(compiled).errors

    assert cleanup == %{
             job_id: "malformed-active",
             prior_status: :running,
             status: :cancelled,
             result: :ok
           }
  end

  test "does not accept completed while its attached provider job is still active" do
    owner = self()

    transport = fn url, _headers, _body, _opts ->
      send(owner, {:inconsistent_completed_cancel_requested, url})
      {:ok, %{status: 200, headers: [], body: Jason.encode!(%{status: "cancelled"})}}
    end

    job =
      Imp.Clients.TrainingJob.new(%{
        id: "inconsistent-completed",
        provider: :test,
        status: :running,
        transport: transport,
        cancel_url: "https://training.example/jobs/inconsistent-completed/cancel",
        cancel_body: :empty,
        max_attempts: 1
      })

    compiled =
      BetterTogether.new(metric(), %{
        g: %GenericTrainingOptimizer{job: job, status: :completed}
      })
      |> BetterTogether.compile(program(), examples(), nil,
        strategy: :g,
        valset_ratio: 0,
        training_cancellation_timeout: 100,
        shuffle_trainset_between_steps: false
      )

    assert_received {:inconsistent_completed_cancel_requested,
                     "https://training.example/jobs/inconsistent-completed/cancel"}

    assert [%{error: {:training_terminal_error, {:invalid_training_result, _, _}, [cleanup]}}] =
             Imp.Optimizer.Report.fetch(compiled).errors

    assert cleanup.status == :cancelled
    assert cleanup.result == :ok
  end

  test "noncanonical training results do not destructively clean terminal or unknown jobs" do
    owner = self()

    transport = fn url, _headers, _body, _opts ->
      send(owner, {:unexpected_malformed_result_request, url})
      {:ok, %{status: 200, headers: [], body: Jason.encode!(%{status: "cancelled"})}}
    end

    Enum.each([:failed, {:unknown, "provider-paused"}], fn status ->
      job =
        Imp.Clients.TrainingJob.new(%{
          id: "malformed-nondestructive",
          provider: :test,
          status: status,
          transport: transport,
          cancel_url: "https://training.example/jobs/malformed-nondestructive/cancel",
          cancel_body: :empty
        })

      compiled =
        BetterTogether.new(metric(), %{
          g: %GenericTrainingOptimizer{job: job, status: "job_created"}
        })
        |> BetterTogether.compile(program(), examples(), nil,
          strategy: :g,
          valset_ratio: 0,
          training_cancellation_timeout: 25,
          shuffle_trainset_between_steps: false
        )

      assert [
               %{
                 error:
                   {:invalid_training_result_status, GenericTrainingOptimizer, "job_created",
                    %{job_id: "malformed-nondestructive", status: ^status, metadata: %{}}}
               }
             ] = Imp.Optimizer.Report.fetch(compiled).errors
    end)

    refute_received {:unexpected_malformed_result_request, _}
  end

  test "explicitly rejects a function-valued generic optimizer" do
    owner = self()

    function_optimizer = fn _optimizer, _program, _opts ->
      send(owner, :function_optimizer_called)
      {:error, :unexpected_function_dispatch}
    end

    compiled =
      BetterTogether.new(metric(), %{callable: function_optimizer})
      |> BetterTogether.compile(program(), examples(), nil,
        strategy: :callable,
        valset_ratio: 0,
        shuffle_trainset_between_steps: false
      )

    refute_received :function_optimizer_called

    assert [%{error: {:not_an_optimizer, ^function_optimizer}}] =
             Imp.Optimizer.Report.fetch(compiled).errors
  end

  test "attaches reports to custom executable metadata carriers" do
    student = %MetadataProgram{predict: program()}

    compiled =
      BetterTogether.new(metric(), %{
        custom: %TeacherCaptureOptimizer{owner: self(), label: :carrier}
      })
      |> BetterTogether.compile(student, examples(), nil,
        strategy: :custom,
        valset_ratio: 0,
        shuffle_trainset_between_steps: false
      )

    assert_received {:generic_teacher, :carrier, nil, nil}
    assert %MetadataProgram{} = compiled
    assert Imp.Optimizer.Report.fetch(compiled).metadata.selected_strategy == "custom"
  end

  test "stores custom executable reports on report-capable predictors" do
    student = %ReportlessProgram{predict: program()}

    better =
      BetterTogether.new(metric(), %{
        custom: %SpyOptimizer{owner: self()}
      })

    compiled =
      BetterTogether.compile(better, student, examples(), nil,
        strategy: :custom,
        valset_ratio: 0
      )

    assert_received :unexpected_later_step
    assert %Imp.Optimizer.Report{} = Imp.Optimizer.Report.fetch(compiled)
  end

  test "routes an explicit teacher into BootstrapFewShot" do
    student_lm = Imp.LM.Static.new(handler: fn _messages, _opts -> %{answer: "student"} end)

    teacher_lm = Imp.LM.Static.new(handler: fn _messages, _opts -> %{answer: "teacher"} end)

    student = Imp.predict("question -> answer", lm: student_lm)
    teacher = Imp.predict("question -> answer", lm: teacher_lm)
    trainset = [example("Who answered?", "teacher")]

    optimizer =
      Imp.Optimizer.BootstrapFewShot.new(metric(),
        max_bootstrapped_demos: 1,
        max_labeled_demos: 0
      )

    compiled =
      BetterTogether.new(metric(), %{p: optimizer})
      |> BetterTogether.compile(student, trainset, nil,
        strategy: :p,
        teacher: teacher,
        valset_ratio: 0,
        shuffle_trainset_between_steps: false
      )

    assert [demo] = compiled.demos
    assert Imp.Example.get(demo, :answer) == "teacher"

    assert Enum.any?(Imp.Optimizer.Report.fetch(compiled).candidates, fn candidate ->
             get_in(candidate, [:compile_metadata, :teacher]) == :provided
           end)
  end

  test "routes an explicit teacher into BootstrapFinetune while training the student LM" do
    student_lm =
      Imp.LM.Static.new(
        model: "student-base",
        handler: fn _messages, _opts -> %{answer: "student"} end
      )

    teacher_lm =
      Imp.LM.Static.new(
        model: "teacher-base",
        handler: fn _messages, _opts -> %{answer: "teacher"} end
      )

    student = Imp.predict("question -> answer", lm: student_lm)
    teacher = Imp.predict("question -> answer", lm: teacher_lm)
    trainset = [example("Who answered?", "teacher")]

    trainer = fn training_lm, rows, _opts ->
      send(self(), {:teacher_training_rows, training_lm, rows})

      {:ok,
       Imp.Clients.TrainingJob.new(%{
         id: "teacher-sft",
         provider: :test,
         model: training_lm.model,
         status: :succeeded,
         result_model: "teacher-trained"
       })}
    end

    compiled =
      BetterTogether.new(metric(), %{
        w: Imp.Optimizer.BootstrapFinetune.new(metric(), trainer: trainer)
      })
      |> BetterTogether.compile(student, trainset, nil,
        strategy: :w,
        teacher: teacher,
        valset_ratio: 0,
        shuffle_trainset_between_steps: false
      )

    assert_received {:teacher_training_rows, ^student_lm, [row]}
    assert Imp.Example.get(row, :answer) == "teacher"
    assert Imp.ProgramAccess.lm(compiled).model == "teacher-trained"
  end

  test "rejects teacher propagation into GEPA before running it" do
    teacher = program()
    gepa = Imp.Optimizer.GEPA.new(metric(), generations: 0)

    compiled =
      BetterTogether.new(metric(), %{g: gepa})
      |> BetterTogether.compile(program(), examples(), examples(),
        strategy: :g,
        teacher: teacher
      )

    assert [%{error: {:teacher_not_supported, Imp.Optimizer.GEPA}}] =
             Imp.Optimizer.Report.fetch(compiled).errors
  end

  test "stops after the first failed step and reports the evaluated prefixes" do
    better =
      BetterTogether.new(metric(), %{
        p: %SetInstruction{instruction: "Answer only the France question."},
        bad: %FailingOptimizer{},
        later: %SpyOptimizer{owner: self()}
      })

    compiled =
      BetterTogether.compile(better, program(), examples(), examples(),
        strategy: [:p, :bad, :later]
      )

    refute_receive :unexpected_later_step

    report = Imp.Optimizer.Report.fetch(compiled)
    assert report.best_score == 0.5
    assert report.metadata.compilation_error_occurred
    assert report.metadata.stopped_early
    assert Enum.map(report.candidates, & &1.status) == [:ok, :ok, :error]
    assert List.last(report.candidates).error == :compile_failed
    assert report.errors == [%{index: 2, key: :bad, error: :compile_failed}]
  end

  test "converts a raised optimizer step into a terminal strategy error" do
    compiled =
      BetterTogether.new(metric(), %{
        bad: %RaisingOptimizer{},
        later: %SpyOptimizer{owner: self()}
      })
      |> BetterTogether.compile(program(), examples(), nil,
        strategy: [:bad, :later],
        valset_ratio: 0
      )

    refute_receive :unexpected_later_step

    assert [
             %{
               error:
                 {:optimizer_failed, RaisingOptimizer, %RuntimeError{message: "compile exploded"}}
             }
           ] =
             Imp.Optimizer.Report.fetch(compiled).errors
  end

  test "operational child guards abort composition instead of becoming failed prefixes" do
    better =
      BetterTogether.new(metric(), %{
        guarded: %OperationalGuardOptimizer{},
        later: %SpyOptimizer{owner: self()}
      })

    assert_raise Imp.OperationalSafetyError, "composition transport guard", fn ->
      BetterTogether.compile(better, program(), examples(), nil,
        strategy: [:guarded, :later],
        valset_ratio: 0
      )
    end

    refute_receive :unexpected_later_step
  end

  test "does not claim provider weight training succeeded when no trainer is available" do
    compiled =
      metric()
      |> BetterTogether.new(%{w: Imp.Optimizer.BootstrapFinetune.new(metric())})
      |> BetterTogether.compile(program(), examples(), examples(), strategy: :w)

    report = Imp.Optimizer.Report.fetch(compiled)

    assert report.metadata.compilation_error_occurred
    assert report.metadata.selected_strategy == ""

    assert [
             %{
               error: {:training_not_started, :trainer_required},
               diagnostics: %{
                 "optimizer" => "bootstrap_finetune",
                 "failure" => failure,
                 "report" => bootstrap_report
               }
             }
           ] = report.errors

    assert failure["__imp_type__"] == "map"
    assert bootstrap_report["candidate_count"] == length(examples())
    assert length(bootstrap_report["candidates"]) == length(examples())
    assert bootstrap_report["metadata"]["__imp_type__"] == "map"

    assert report.metadata.provider_training_semantics ==
             :bounded_await_and_atomic_rebind

    assert report.metadata.weight_provider_boundary == :explicit_trainer_required
  end

  test "composes a terminal successful weight step with the rebound program" do
    base_program = program()

    trainable_program =
      Imp.with_lm(base_program, Map.put(Imp.ProgramAccess.lm(base_program), :model, "base"))

    trainer = fn _lm, _examples, _opts ->
      {:ok,
       Imp.Clients.TrainingJob.new(%{
         id: "terminal-sft",
         provider: :test,
         model: "base",
         status: :succeeded,
         result_model: "trained-model"
       })}
    end

    compiled =
      metric()
      |> BetterTogether.new(%{
        w: Imp.Optimizer.BootstrapFinetune.new(metric(), trainer: trainer)
      })
      |> BetterTogether.compile(trainable_program, examples(), nil,
        strategy: :w,
        valset_ratio: 0
      )

    assert Imp.ProgramAccess.lm(compiled).model == "trained-model"
    report = Imp.Optimizer.Report.fetch(compiled)
    refute report.metadata.compilation_error_occurred
    assert report.metadata.selected_strategy == "w"

    assert Enum.any?(report.candidates, fn candidate ->
             get_in(candidate, [:compile_metadata, :training_status]) == :completed
           end)
  end

  test "public optimize runs and selects an executable local weight step" do
    student = Imp.predict("question -> answer", lm: %ModelAwareLM{model: "base-model"})
    teacher = Imp.predict("question -> answer", lm: %ModelAwareLM{model: "trained-model"})

    trainset = [example("training row", "trained")]
    selection = [example("selection row", "trained")]
    held_out = example("held-out row", "trained")

    trainer = fn %ModelAwareLM{model: "base-model"}, [row], _opts ->
      send(self(), {:local_weight_training, Imp.Example.get(row, :answer)})

      {:ok,
       Imp.Clients.TrainingJob.new(%{
         id: "local-better-together-sft",
         provider: :test,
         model: "base-model",
         status: :succeeded,
         result_model: "trained-model"
       })}
    end

    optimizer =
      BetterTogether.new(metric(), %{
        w: Imp.Optimizer.BootstrapFinetune.new(metric(), trainer: trainer)
      })

    compiled =
      Imp.optimize!(student, optimizer, trainset, selection,
        strategy: :w,
        teacher: teacher,
        shuffle_trainset_between_steps: false
      )

    assert_received {:local_weight_training, "trained"}
    assert %ModelAwareLM{model: "trained-model"} = Imp.ProgramAccess.lm(compiled)
    assert {:ok, prediction} = Imp.call(compiled, %{question: "held-out row"})
    assert Imp.Prediction.get(prediction, :answer) == "trained"

    report = Imp.Optimizer.Report.fetch(compiled)
    assert report.metadata.selected_strategy == "w"
    assert report.metadata.baseline_score == 0.0
    assert report.best_score == 1.0

    assert Enum.any?(report.candidates, fn candidate ->
             candidate.strategy == "w" and
               get_in(candidate, [:compile_metadata, :training_status]) == :completed
           end)

    assert Imp.Example.get(held_out, :answer) == "trained"
  end

  test "awaits an asynchronous weight job, rebinds, and continues the strategy" do
    base_program = program()

    trainable_program =
      Imp.with_lm(base_program, Map.put(Imp.ProgramAccess.lm(base_program), :model, "base"))

    trainer = fn training_lm, _examples, _opts ->
      {:ok,
       Imp.Clients.TrainingJob.new(%{
         id: "async-sft",
         provider: :test,
         model: training_lm.model,
         status: :running,
         status_url: "https://training.example/jobs/async-sft",
         status_method: :get,
         transport: CompletingTrainingTransport
       })}
    end

    compiled =
      BetterTogether.new(metric(), %{
        w: Imp.Optimizer.BootstrapFinetune.new(metric(), trainer: trainer),
        p: %SetInstruction{instruction: "Answer every question."}
      })
      |> BetterTogether.compile(trainable_program, examples(), nil,
        strategy: [:w, :p],
        valset_ratio: 0,
        training_timeout: 100,
        training_poll_interval: 0,
        shuffle_trainset_between_steps: false
      )

    assert Imp.ProgramAccess.lm(compiled).model == "trained-model"

    assert Imp.Optimizer.InstructionSearch.current_instruction(compiled) ==
             "Answer every question."

    report = Imp.Optimizer.Report.fetch(compiled)
    refute report.metadata.compilation_error_occurred
    assert report.metadata.selected_strategy == "w -> p"

    assert Enum.any?(report.candidates, fn candidate ->
             candidate.strategy == "w" and
               get_in(candidate, [:compile_metadata, :awaited]) == true
           end)
  end

  test "a pending weight job times out without running later steps" do
    base_program = program()

    trainable_program =
      Imp.with_lm(base_program, Map.put(Imp.ProgramAccess.lm(base_program), :model, "base"))

    owner = self()

    cancel_transport = fn url, _headers, _body, _opts ->
      send(owner, {:timeout_cancel_requested, url})
      {:ok, %{status: 200, headers: [], body: Jason.encode!(%{status: "cancelled"})}}
    end

    trainer = fn _lm, _examples, _opts ->
      {:ok,
       Imp.Clients.TrainingJob.new(%{
         id: "never-completes",
         provider: :test,
         model: "base",
         status: :running,
         transport: cancel_transport,
         cancel_url: "https://training.example/jobs/never-completes/cancel",
         cancel_body: :empty
       })}
    end

    compiled =
      BetterTogether.new(metric(), %{
        w: Imp.Optimizer.BootstrapFinetune.new(metric(), trainer: trainer),
        later: %SpyOptimizer{owner: self()}
      })
      |> BetterTogether.compile(trainable_program, examples(), nil,
        strategy: [:w, :later],
        valset_ratio: 0,
        training_timeout: 0,
        training_poll_interval: 0,
        shuffle_trainset_between_steps: false
      )

    refute_receive :unexpected_later_step

    assert_received {:timeout_cancel_requested,
                     "https://training.example/jobs/never-completes/cancel"}

    assert [
             %{
               error:
                 {:training_step_timeout, Imp.Optimizer.BootstrapFinetune, 0, [summary],
                  [cancellation]}
             }
           ] = Imp.Optimizer.Report.fetch(compiled).errors

    assert summary.job_id == "never-completes"
    assert summary.status == :cancelled
    assert cancellation.job_id == "never-completes"
    assert cancellation.prior_status == :running
    assert cancellation.status == :cancelled
    assert cancellation.result == :ok
  end

  test "timeout cleanup starts peers concurrently and bounds a hung cancellation" do
    Process.register(self(), BetterTogetherTest.HungCancellationOwner)

    on_exit(fn ->
      if Process.whereis(BetterTogetherTest.HungCancellationOwner) do
        Process.unregister(BetterTogetherTest.HungCancellationOwner)
      end
    end)

    hung_lm =
      Imp.LM.Static.new(
        model: "hung-base",
        handler: fn _messages, _opts -> %{first_answer: "first"} end
      )

    fast_lm =
      Imp.LM.Static.new(
        model: "fast-base",
        handler: fn _messages, _opts -> %{second_answer: "second"} end
      )

    student = %TwoPredictorProgram{
      first: Imp.predict("question -> first_answer", lm: hung_lm),
      second: Imp.predict("question -> second_answer", lm: fast_lm)
    }

    trainer = fn training_lm, _examples, _opts ->
      suffix = if training_lm.model == "hung-base", do: "hung", else: "fast"

      {:ok,
       Imp.Clients.TrainingJob.new(%{
         id: "cleanup-#{suffix}",
         status: :running,
         transport: HungCancellationTransport,
         cancel_url: "https://training.example/jobs/#{suffix}/cancel",
         cancel_body: :empty,
         max_attempts: 1
       })}
    end

    started_at = System.monotonic_time(:millisecond)

    compiled =
      BetterTogether.new(metric(), %{
        w: Imp.Optimizer.BootstrapFinetune.new(nil, trainer: trainer)
      })
      |> BetterTogether.compile(student, examples(), nil,
        strategy: :w,
        valset_ratio: 0,
        training_timeout: 0,
        training_cancellation_timeout: 25,
        shuffle_trainset_between_steps: false
      )

    elapsed = System.monotonic_time(:millisecond) - started_at

    assert elapsed < 500
    assert Process.alive?(self())

    assert_received {:hung_cleanup_requested, "https://training.example/jobs/hung/cancel"}

    assert_received {:hung_cleanup_requested, "https://training.example/jobs/fast/cancel"}

    assert [
             %{
               error:
                 {:training_step_timeout, Imp.Optimizer.BootstrapFinetune, 0,
                  [hung_summary, fast_summary], [hung_cleanup, fast_cleanup]}
             }
           ] = Imp.Optimizer.Report.fetch(compiled).errors

    assert {hung_summary.job_id, hung_summary.status} == {"cleanup-hung", :running}
    assert {fast_summary.job_id, fast_summary.status} == {"cleanup-fast", :cancelled}
    assert hung_cleanup.job_id == "cleanup-hung"
    assert hung_cleanup.status == :running
    assert {:error, {:training_cancel_timeout, timeout}} = hung_cleanup.result
    assert timeout in 0..25
    assert fast_cleanup.job_id == "cleanup-fast"
    assert fast_cleanup.status == :cancelled
    assert fast_cleanup.result == :ok
  end

  test "a provider-cancelled job cancels every still-running peer" do
    cancelled_lm =
      Imp.LM.Static.new(
        model: "cancelled-base",
        handler: fn _messages, _opts -> %{first_answer: "first"} end
      )

    running_lm =
      Imp.LM.Static.new(
        model: "running-base",
        handler: fn _messages, _opts -> %{second_answer: "second"} end
      )

    student = %TwoPredictorProgram{
      first: Imp.predict("question -> first_answer", lm: cancelled_lm),
      second: Imp.predict("question -> second_answer", lm: running_lm)
    }

    owner = self()

    cancel_transport = fn url, _headers, _body, _opts ->
      send(owner, {:peer_cancel_requested, url})
      {:ok, %{status: 200, headers: [], body: Jason.encode!(%{status: "cancelled"})}}
    end

    trainer = fn
      %{model: "cancelled-base"}, _examples, _opts ->
        {:ok,
         Imp.Clients.TrainingJob.new(%{
           id: "provider-cancelled",
           provider: :test,
           status: :cancelled,
           metadata: %{reason: :provider_cancelled, api_key: "diagnostic-secret-canary"}
         })}

      %{model: "running-base"}, _examples, _opts ->
        {:ok,
         Imp.Clients.TrainingJob.new(%{
           id: "running-peer",
           provider: :test,
           status: :running,
           transport: cancel_transport,
           cancel_url: "https://training.example/jobs/running-peer/cancel",
           cancel_body: :empty
         })}
    end

    compiled =
      BetterTogether.new(metric(), %{
        w: Imp.Optimizer.BootstrapFinetune.new(nil, trainer: trainer)
      })
      |> BetterTogether.compile(student, examples(), nil,
        strategy: :w,
        valset_ratio: 0,
        shuffle_trainset_between_steps: false
      )

    assert_received {:peer_cancel_requested, "https://training.example/jobs/running-peer/cancel"}

    assert [
             %{
               diagnostics: diagnostics,
               error:
                 {:training_plan_failed, [%{job_id: "provider-cancelled", status: :cancelled}],
                  _jobs, [%{job_id: "running-peer", status: :cancelled, result: :ok}]}
             }
           ] = Imp.Optimizer.Report.fetch(compiled).errors

    assert diagnostics["optimizer"] == "bootstrap_finetune"
    assert diagnostics["report"]["candidate_count"] == length(examples())
    assert diagnostics["report"]["errors"] != []
    assert diagnostics["report"]["metadata"]["__imp_type__"] == "map"
    refute diagnostics |> Jason.encode!() |> String.contains?("diagnostic-secret-canary")
  end

  test "the await deadline bounds a blocking provider refresh" do
    Process.register(self(), BetterTogetherTest.SlowTransportOwner)

    on_exit(fn ->
      if Process.whereis(BetterTogetherTest.SlowTransportOwner) do
        Process.unregister(BetterTogetherTest.SlowTransportOwner)
      end
    end)

    base_program = program()

    trainable_program =
      Imp.with_lm(base_program, Map.put(Imp.ProgramAccess.lm(base_program), :model, "base"))

    trainer = fn training_lm, _examples, _opts ->
      {:ok,
       Imp.Clients.TrainingJob.new(%{
         id: "slow-refresh",
         provider: :test,
         model: training_lm.model,
         status: :running,
         status_url: "https://training.example/jobs/slow-refresh",
         cancel_url: "https://training.example/jobs/slow-refresh/cancel",
         status_method: :get,
         cancel_body: :empty,
         max_attempts: 1,
         transport: SlowTrainingTransport
       })}
    end

    compiled =
      BetterTogether.new(metric(), %{
        w: Imp.Optimizer.BootstrapFinetune.new(metric(), trainer: trainer)
      })
      |> BetterTogether.compile(trainable_program, examples(), nil,
        strategy: :w,
        valset_ratio: 0,
        training_timeout: 25,
        training_poll_interval: 0,
        shuffle_trainset_between_steps: false
      )

    assert_received :slow_refresh_started
    assert_received {:slow_cancel_requested, "https://training.example/jobs/slow-refresh/cancel"}

    assert [
             %{
               error:
                 {:training_step_timeout, Imp.Optimizer.BootstrapFinetune, 25,
                  [%{status: :cancelled}], [%{status: :cancelled, result: :ok}]}
             }
           ] =
             Imp.Optimizer.Report.fetch(compiled).errors
  end

  test "provider failure wins when a later refresh returns an error" do
    Process.register(self(), BetterTogetherTest.RefreshErrorOwner)

    on_exit(fn ->
      if Process.whereis(BetterTogetherTest.RefreshErrorOwner) do
        Process.unregister(BetterTogetherTest.RefreshErrorOwner)
      end
    end)

    failed_lm =
      Imp.LM.Static.new(
        model: "failed-before-refresh-error",
        handler: fn _messages, _opts -> %{first_answer: "first"} end
      )

    refresh_error_lm =
      Imp.LM.Static.new(
        model: "refresh-error-base",
        handler: fn _messages, _opts -> %{second_answer: "second"} end
      )

    student = %TwoPredictorProgram{
      first: Imp.predict("question -> first_answer", lm: failed_lm),
      second: Imp.predict("question -> second_answer", lm: refresh_error_lm)
    }

    trainer = fn training_lm, _examples, _opts ->
      suffix =
        if training_lm.model == "failed-before-refresh-error",
          do: "failed",
          else: "refresh-error"

      {:ok,
       Imp.Clients.TrainingJob.new(%{
         id: "ordered-#{suffix}",
         provider: :test,
         model: training_lm.model,
         status: :running,
         status_url: "https://training.example/jobs/#{suffix}",
         cancel_url: "https://training.example/jobs/#{suffix}/cancel",
         status_method: :get,
         cancel_body: :empty,
         max_attempts: 1,
         transport: FailureThenRefreshErrorTransport
       })}
    end

    compiled =
      BetterTogether.new(metric(), %{
        w: Imp.Optimizer.BootstrapFinetune.new(nil, trainer: trainer)
      })
      |> BetterTogether.compile(student, examples(), nil,
        strategy: :w,
        valset_ratio: 0,
        training_timeout: 100,
        training_poll_interval: 0,
        shuffle_trainset_between_steps: false
      )

    assert_received :mixed_refresh_error_seen

    assert_received {:mixed_refresh_cancel_requested,
                     "https://training.example/jobs/refresh-error/cancel"}

    refute_received {:mixed_refresh_cancel_requested,
                     "https://training.example/jobs/failed/cancel"}

    assert [
             %{
               error:
                 {:training_plan_failed, [failed], all_jobs,
                  [%{job_id: "ordered-refresh-error", status: :cancelled, result: :ok}]}
             }
           ] = Imp.Optimizer.Report.fetch(compiled).errors

    assert failed.job_id == "ordered-failed"
    assert failed.status == :failed

    assert Enum.map(all_jobs, &{&1.job_id, &1.status}) == [
             {"ordered-failed", :failed},
             {"ordered-refresh-error", :running}
           ]
  end

  test "preserves a terminal provider failure when a later refresh blocks to timeout" do
    Process.register(self(), BetterTogetherTest.MixedTransportOwner)

    on_exit(fn ->
      if Process.whereis(BetterTogetherTest.MixedTransportOwner) do
        Process.unregister(BetterTogetherTest.MixedTransportOwner)
      end
    end)

    failed_lm =
      Imp.LM.Static.new(
        model: "failed-base",
        handler: fn _messages, _opts -> %{first_answer: "first"} end
      )

    blocked_lm =
      Imp.LM.Static.new(
        model: "blocked-base",
        handler: fn _messages, _opts -> %{second_answer: "second"} end
      )

    student = %TwoPredictorProgram{
      first: Imp.predict("question -> first_answer", lm: failed_lm),
      second: Imp.predict("question -> second_answer", lm: blocked_lm)
    }

    trainer = fn training_lm, _examples, _opts ->
      suffix = if training_lm.model == "failed-base", do: "failed", else: "blocked"

      {:ok,
       Imp.Clients.TrainingJob.new(%{
         id: "mixed-#{suffix}",
         provider: :test,
         model: training_lm.model,
         status: :running,
         status_url: "https://training.example/jobs/#{suffix}",
         cancel_url: "https://training.example/jobs/#{suffix}/cancel",
         status_method: :get,
         cancel_body: :empty,
         max_attempts: 1,
         transport: MixedTrainingTransport
       })}
    end

    compiled =
      BetterTogether.new(metric(), %{
        w: Imp.Optimizer.BootstrapFinetune.new(nil, trainer: trainer)
      })
      |> BetterTogether.compile(student, examples(), nil,
        strategy: :w,
        valset_ratio: 0,
        training_timeout: 25,
        training_poll_interval: 0,
        shuffle_trainset_between_steps: false
      )

    assert_received :mixed_blocking_refresh_started
    assert_received {:mixed_cancel_requested, "https://training.example/jobs/blocked/cancel"}

    assert [
             %{
               error:
                 {:training_plan_failed, [failed], all_jobs,
                  [%{job_id: "mixed-blocked", status: :cancelled, result: :ok}]}
             }
           ] = Imp.Optimizer.Report.fetch(compiled).errors

    assert failed.job_id == "mixed-failed"
    assert failed.status == :failed

    assert Enum.map(all_jobs, &{&1.job_id, &1.status}) == [
             {"mixed-failed", :failed},
             {"mixed-blocked", :running}
           ]
  end

  test "rejects empty training data and invalid holdout ratios during preparation" do
    better = BetterTogether.new(metric(), %{p: %SetInstruction{instruction: "unused"}})

    assert_raise ArgumentError, ~r/trainset cannot be empty/, fn ->
      BetterTogether.compile(better, program(), [], examples(), strategy: :p)
    end

    assert_raise ArgumentError, ~r/range \[0, 1\)/, fn ->
      BetterTogether.compile(better, program(), examples(), nil,
        strategy: :p,
        valset_ratio: 1.0
      )
    end
  end

  test "bounds the full BootstrapFinetune preparation and launch phase" do
    owner = self()

    student =
      Imp.predict("question -> answer",
        lm:
          Imp.LM.Static.new(
            model: "hung-teacher-trace",
            handler: fn _messages, _opts ->
              send(owner, :hung_training_preparation_started)
              receive do: (:never -> :ok)
            end
          )
      )

    trainer = fn _lm, _examples, _opts ->
      {:ok, Imp.Clients.TrainingJob.new(%{id: "must-not-launch", status: :running})}
    end

    started_at = System.monotonic_time(:millisecond)

    compiled =
      BetterTogether.new(metric(), %{
        w: Imp.Optimizer.BootstrapFinetune.new(metric(), trainer: trainer)
      })
      |> BetterTogether.compile(student, examples(), nil,
        strategy: :w,
        valset_ratio: 0,
        training_launch_timeout: 20,
        training_cancellation_timeout: 20,
        shuffle_trainset_between_steps: false
      )

    elapsed = System.monotonic_time(:millisecond) - started_at

    assert_received :hung_training_preparation_started
    assert elapsed < 500

    assert [
             %{
               error:
                 {:training_step_launch_timeout, Imp.Optimizer.BootstrapFinetune, 20, [], [],
                  :provider_acceptance_after_callback_timeout_cannot_be_observed}
             }
           ] = Imp.Optimizer.Report.fetch(compiled).errors
  end
end
