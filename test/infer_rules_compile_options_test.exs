defmodule Imp.Optimizer.InferRulesCompileOptionsTest do
  use ExUnit.Case, async: true

  alias Imp.Optimizer.InferRules

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
end
