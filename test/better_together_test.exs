defmodule BetterTogetherTest do
  use ExUnit.Case

  alias DSEx.Optimizer.BetterTogether

  defmodule SetInstruction do
    @behaviour DSEx.Optimizer
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
      do: {:ok, DSEx.Optimizer.InstructionSearch.put_instruction(program, instruction)}
  end

  defmodule PromptSequence do
    @behaviour DSEx.Optimizer
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
      instruction = DSEx.Optimizer.InstructionSearch.current_instruction(program)

      next =
        if instruction == "Answer neither question.",
          do: "Answer every question.",
          else: "Answer only the France question."

      {:ok, DSEx.Optimizer.InstructionSearch.put_instruction(program, next)}
    end
  end

  defmodule FailingOptimizer do
    @behaviour DSEx.Optimizer
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

  defmodule SpyOptimizer do
    @behaviour DSEx.Optimizer
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
    @behaviour DSEx.Optimizer
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

  defp metric, do: DSEx.Metrics.exact_match(:answer)

  defp program do
    DSEx.predict("question -> answer",
      lm: %{
        module: DSEx.LM.Static,
        opts: [
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
        ]
      }
    )
  end

  defp examples do
    [
      example("Capital of France?", "Paris"),
      example("Capital of Germany?", "Berlin")
    ]
  end

  defp example(question, answer) do
    DSEx.example(question: question, answer: answer)
    |> DSEx.Example.with_inputs(:question)
  end

  test "defaults to the upstream p -> w -> p strategy and selects the best prefix" do
    better =
      BetterTogether.new(metric(), %{
        p: %PromptSequence{},
        w: %SetInstruction{instruction: "Answer neither question."}
      })

    compiled = BetterTogether.compile(better, program(), examples(), examples())
    report = DSEx.Optimizer.Report.fetch(compiled)

    assert DSEx.Optimizer.InstructionSearch.current_instruction(compiled) ==
             "Answer every question."

    assert report.best_score == 1.0
    assert report.candidate_count == 4
    assert report.metadata.steps == ["p", "w", "p"]
    assert report.metadata.selected_strategy == "p -> w -> p"
    assert Enum.map(report.candidates, & &1.score) == [0.0, 0.5, 0.0, 1.0]
  end

  test "retains and returns the baseline when optimization makes validation worse" do
    original =
      program()
      |> DSEx.Optimizer.InstructionSearch.put_instruction("Answer every question.")

    compiled =
      metric()
      |> BetterTogether.new(%{p: %SetInstruction{instruction: "Answer neither question."}})
      |> BetterTogether.compile(original, examples(), examples(), strategy: :p)

    report = DSEx.Optimizer.Report.fetch(compiled)

    assert DSEx.Optimizer.InstructionSearch.current_instruction(compiled) ==
             DSEx.Optimizer.InstructionSearch.current_instruction(original)

    assert report.metadata.selected_strategy == ""
    assert Enum.map(report.candidates, & &1.score) == [1.0, 0.0]
  end

  test "returns the latest successful candidate when validation is disabled" do
    compiled =
      metric()
      |> BetterTogether.new(%{p: %SetInstruction{instruction: "Answer every question."}})
      |> BetterTogether.compile(program(), examples(), nil, strategy: :p, valset_ratio: 0)

    report = DSEx.Optimizer.Report.fetch(compiled)

    assert DSEx.Optimizer.InstructionSearch.current_instruction(compiled) ==
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

    report = DSEx.Optimizer.Report.fetch(compiled)
    assert report.metadata.trainset_size == 3
    assert report.metadata.validation_size == 1
    assert Enum.all?(report.candidates, &(&1.evaluation.validation_size == 1))
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

    report = DSEx.Optimizer.Report.fetch(compiled)
    assert report.best_score == 0.5
    assert report.metadata.compilation_error_occurred
    assert report.metadata.stopped_early
    assert Enum.map(report.candidates, & &1.status) == [:ok, :ok, :error]
    assert List.last(report.candidates).error == :compile_failed
    assert report.errors == [%{index: 2, key: :bad, error: :compile_failed}]
  end

  test "does not claim provider weight training succeeded when no trainer is available" do
    compiled =
      metric()
      |> BetterTogether.new(%{w: DSEx.Optimizer.BootstrapFinetune.new(metric())})
      |> BetterTogether.compile(program(), examples(), examples(), strategy: :w)

    report = DSEx.Optimizer.Report.fetch(compiled)

    assert report.metadata.compilation_error_occurred
    assert report.metadata.selected_strategy == ""

    assert [%{error: {:training_not_started, :trainer_required, _compiled}}] = report.errors

    assert report.metadata.provider_training_semantics ==
             :completed_training_results_only
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
end
