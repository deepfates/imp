defmodule Imp.Optimizer.InferRulesCompileOptionsTest do
  use ExUnit.Case, async: true

  alias Imp.Optimizer.InferRules

  defmodule ContextStringLM do
    defstruct [:owner]

    def generate(%__MODULE__{owner: owner}, messages, _opts) do
      prompt = Enum.map_join(messages, "\n", & &1.content)
      example_count = length(Regex.scan(~r/Input Fields:/, prompt))
      send(owner, {:rule_example_count, example_count})

      if example_count > 1 do
        {:error, "ContextWindowExceededError: controlled context overflow"}
      else
        {:ok,
         %{
           reasoning: "One example fits.",
           natural_language_rules: "Return the exact expected answer."
         }}
      end
    end
  end

  test "direct compile rejects unsupported options before bootstrap or task activity" do
    owner = self()

    lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          send(owner, :unexpected_lm_call)
          %{answer: "yes"}
        end
      )

    program = Imp.predict("question -> answer", lm: lm)
    example = Imp.example(question: "q", answer: "yes") |> Imp.with_inputs(:question)

    optimizer =
      InferRules.new(Imp.exact_match(:answer),
        candidates: ["Return yes."],
        max_bootstrapped_demos: 0,
        max_labeled_demos: 0
      )

    assert_raise ArgumentError, ~r/unknown options.*techer/, fn ->
      InferRules.compile(optimizer, program, [example], [example], techer: program)
    end

    refute_received :unexpected_lm_call
  end

  test "compile and composition validation share one teacher-only option contract" do
    metric = Imp.exact_match(:answer)
    optimizer = InferRules.new(metric, candidates: ["Return yes."])

    assert :ok = InferRules.validate_invocation_options(teacher: Imp.predict("q -> a"))

    assert {:error, message} = InferRules.validate_invocation_options(max_trials: 1)
    assert message =~ "unknown options"
    assert message =~ "max_trials"

    assert_raise ArgumentError, ~r/expects keyword options/, fn ->
      InferRules.compile(optimizer, Imp.predict("q -> a"), [], [], %{teacher: nil})
    end
  end

  test "provider-rendered context-window errors follow the pinned drop-one-example schedule" do
    owner = self()

    task_lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          prompt = Enum.map_join(messages, "\n", & &1.content)

          if prompt =~ "Return the exact expected answer.",
            do: %{answer: "yes"},
            else: %{answer: "no"}
        end
      )

    program = Imp.predict("question -> answer", lm: task_lm)

    trainset =
      for index <- 1..3 do
        Imp.example(question: "train-#{index}", answer: "yes")
        |> Imp.with_inputs(:question)
      end

    validation = [
      Imp.example(question: "validation", answer: "yes") |> Imp.with_inputs(:question)
    ]

    compiled =
      InferRules.new(Imp.exact_match(:answer),
        rule_lm: %ContextStringLM{owner: owner},
        num_candidates: 1,
        num_rules: 1,
        max_bootstrapped_demos: 0,
        max_labeled_demos: 0
      )
      |> InferRules.compile(program, trainset, validation)

    assert_receive {:rule_example_count, 3}
    assert_receive {:rule_example_count, 2}
    assert_receive {:rule_example_count, 1}

    report = Imp.Optimizer.Report.fetch(compiled)
    assert report.metadata.proposal_calls == 1
    assert report.metadata.proposal_attempts == 3
    assert report.best_score == 1.0
    assert compiled.signature.instructions =~ "Return the exact expected answer."
  end
end
