defmodule Imp.Optimizer.InferRulesUpstreamDifferentialTest do
  use ExUnit.Case, async: false

  defmodule TwoPredictorProgram do
    defstruct [:first, :second]

    def optimizer_predictors(program), do: [first: program.first, second: program.second]
    def update_optimizer_predictor(program, name, update), do: Map.update!(program, name, update)

    def call(program, _inputs) do
      instructions = [program.first.signature.instructions, program.second.signature.instructions]

      answer =
        if Enum.at(instructions, 0) =~ "rule-0" and Enum.at(instructions, 1) =~ "rule-1",
          do: "best",
          else: "other"

      {:ok, Imp.Prediction.new(%{answer: answer})}
    end
  end

  @moduletag :evidence_infrastructure

  @python "tmp/dspy-parity-venv/bin/python"
  @dspy_root "tmp/dspy-3.2.1"
  @dspy_commit "29448ae12756abdd14bd8796c819247ebb83673c"
  @source_sha256 "4c641cfbbdac36925204b2b8ce7b16fa3f604c4c6939dcdf2c21d05a94d0b6b3"

  test "native formatting and rule updates match pinned DSPy 3.2.1" do
    assert exact_checkout?()
    upstream = upstream_observations()
    parent = self()

    task_lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          prompt = Enum.map_join(messages, "\n", & &1.content)

          if prompt =~ upstream["rules"],
            do: %{answer: "Paris"},
            else: %{answer: "unknown"}
        end
      )

    rule_lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          send(parent, {:rule_messages, messages})

          %{
            reasoning: "The mapping is explicit.",
            natural_language_rules: upstream["rules"]
          }
        end
      )

    trainset = [
      Imp.example(question: "France capital?", answer: "Paris")
      |> Imp.with_inputs(:question)
    ]

    optimizer =
      Imp.Optimizer.InferRules.new(Imp.exact_match(:answer),
        rule_lm: rule_lm,
        num_candidates: 1,
        num_rules: 1,
        max_bootstrapped_demos: 0,
        max_labeled_demos: 0
      )

    compiled =
      Imp.Optimizer.InferRules.compile(
        optimizer,
        Imp.predict("question -> answer", lm: task_lm),
        trainset,
        trainset
      )

    assert_receive {:rule_messages, messages}
    prompt = Enum.map_join(messages, "\n", & &1.content)
    assert prompt =~ upstream["formatted_examples"]

    assert Imp.Optimizer.InstructionSearch.current_instruction(compiled) ==
             upstream["updated_instruction"]

    predictor_reports =
      Enum.map(Imp.ProgramParameters.predictors(compiled), fn %{predictor: predictor} ->
        Imp.Optimizer.Report.fetch(predictor)
      end)

    [report] = Enum.uniq(predictor_reports)
    assert report.metadata.proposal_calls == 1
    assert report.metadata.proposal_attempts == 1
    assert report.metadata.implementation == :native_rule_induction
  end

  test "exact upstream compile exposes split, predictor traversal, scoring, and signature aliasing" do
    assert exact_checkout?()
    upstream = upstream_observations()["compile_loop"]

    assert upstream["induction_train_sizes"] == [2, 2, 2, 2]
    assert upstream["validation_sizes"] == [2, 2]
    assert upstream["evaluated_scores"] == [2.0, 1.0]
    assert Enum.at(upstream["evaluated_rules"], 0) == ["rule-0", "rule-1"]
    assert Enum.at(upstream["evaluated_rules"], 1) == ["rule-2", "rule-3"]

    # The exact 3.2.1 implementation logs candidate zero as best, but its
    # mutable signature-class aliases let candidate one rewrite the returned
    # program. Imp deliberately isolates candidate signatures instead.
    assert upstream["returned_rules"] == ["rule-2", "rule-3"]

    {:ok, responses} = Agent.start_link(fn -> ["rule-0", "rule-1", "rule-2", "rule-3"] end)

    rule_lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          Agent.get_and_update(responses, fn [next | rest] ->
            {%{reasoning: "controlled", natural_language_rules: next}, rest}
          end)
        end
      )

    task_lm = Imp.LM.Static.new(handler: fn _messages, _opts -> %{answer: "unused"} end)

    program = %TwoPredictorProgram{
      first: Imp.predict("question -> answer", lm: task_lm),
      second: Imp.predict("answer -> explanation", lm: task_lm)
    }

    trainset =
      for index <- 0..3 do
        Imp.example(question: "q#{index}", answer: "best", explanation: "e#{index}")
        |> Imp.with_inputs(:question)
      end

    compiled =
      Imp.Optimizer.InferRules.new(Imp.exact_match(:answer),
        rule_lm: rule_lm,
        num_candidates: 2,
        num_rules: 1,
        max_bootstrapped_demos: 0,
        max_labeled_demos: 0
      )
      |> Imp.Optimizer.InferRules.compile(program, trainset)

    predictor_reports =
      Enum.map(Imp.ProgramParameters.predictors(compiled), fn %{predictor: predictor} ->
        Imp.Optimizer.Report.fetch(predictor)
      end)

    [report] = Enum.uniq(predictor_reports)

    instructions =
      Enum.map(Imp.ProgramParameters.predictors(compiled), & &1.predictor.signature.instructions)

    assert report.metadata.trainset_size == 2
    assert report.metadata.validation_size == 2
    assert report.metadata.proposal_calls == 4
    assert report.metadata.proposal_attempts == 4
    assert Enum.map(report.candidates, & &1.score) == [0.0, 1.0, 0.0]
    assert Enum.at(instructions, 0) =~ "rule-0"
    assert Enum.at(instructions, 1) =~ "rule-1"
    assert Agent.get(responses, & &1) == []
  end

  test "exact upstream context recovery drops one trailing example per retry" do
    assert exact_checkout?()
    upstream = upstream_observations()["context_retry"]

    assert upstream["example_counts"] == [3, 2, 1]
    assert upstream["result"] == "recovered-rule"
  end

  defp exact_checkout? do
    File.exists?(@python) and File.dir?(Path.join(@dspy_root, ".git")) and
      git(["rev-parse", "HEAD"]) == @dspy_commit and git(["status", "--porcelain"]) == "" and
      file_sha256(Path.join(@dspy_root, "dspy/teleprompt/infer_rules.py")) == @source_sha256
  end

  defp upstream_observations do
    code = ~S"""
    import json
    import types
    import dspy
    from dspy.teleprompt.infer_rules import InferRules

    optimizer = InferRules.__new__(InferRules)
    signature = dspy.Signature("question -> answer")
    examples = [dspy.Example(question="France capital?", answer="Paris")]
    predictor = dspy.Predict(signature)
    rules = "Map France questions to Paris."
    formatted = optimizer.format_examples(examples, signature)
    optimizer.update_program_instructions(predictor, rules)

    class TwoPredictorProgram(dspy.Module):
        def __init__(self):
            self.first = dspy.Predict("question -> answer")
            self.second = dspy.Predict("answer -> explanation")

        def forward(self, question):
            first = self.first(question=question)
            return self.second(answer=first.answer)

    def metric(example, prediction, trace=None):
        return 1.0

    compile_optimizer = InferRules(
        metric=metric,
        num_candidates=2,
        num_rules=1,
        max_bootstrapped_demos=0,
        max_labeled_demos=0,
    )
    induced = []
    evaluated = []

    def controlled_induction(self, predictor, trainset):
        rule = f"rule-{len(induced)}"
        induced.append({"train_size": len(trainset), "rule": rule})
        return rule

    def controlled_evaluation(self, program, dataset):
        rules = [p.signature.instructions.rsplit("\n", 1)[-1] for p in program.predictors()]
        score = [2.0, 1.0][len(evaluated)]
        evaluated.append({"validation_size": len(dataset), "rules": rules, "score": score})
        return score

    compile_optimizer.induce_natural_language_rules = types.MethodType(
        controlled_induction, compile_optimizer
    )
    compile_optimizer.evaluate_program = types.MethodType(
        controlled_evaluation, compile_optimizer
    )
    split_rows = [
        dspy.Example(question=f"q{i}", answer=f"a{i}", explanation=f"e{i}").with_inputs("question")
        for i in range(4)
    ]
    compiled = compile_optimizer.compile(TwoPredictorProgram(), trainset=split_rows)

    class ControlledRuleProgram:
        def __init__(self):
            self.example_counts = []

        def __call__(self, examples_text):
            count = examples_text.count("Input Fields:")
            self.example_counts.append(count)
            if count > 1:
                raise ValueError("controlled context overflow")
            return "recovered-rule"

    retry_optimizer = InferRules.__new__(InferRules)
    retry_optimizer.rules_induction_program = ControlledRuleProgram()
    retry_rows = [
        dspy.Example(question=f"retry-{i}", answer=f"answer-{i}") for i in range(3)
    ]
    retry_result = retry_optimizer.induce_natural_language_rules(
        dspy.Predict(dspy.Signature("question -> answer")), retry_rows
    )

    payload = {
        "formatted_examples": formatted,
        "rules": rules,
        "updated_instruction": predictor.signature.instructions,
        "compile_loop": {
            "induction_train_sizes": [row["train_size"] for row in induced],
            "validation_sizes": [row["validation_size"] for row in evaluated],
            "evaluated_rules": [row["rules"] for row in evaluated],
            "evaluated_scores": [row["score"] for row in evaluated],
            "returned_rules": [p.signature.instructions.rsplit("\n", 1)[-1] for p in compiled.predictors()],
        },
        "context_retry": {
            "example_counts": retry_optimizer.rules_induction_program.example_counts,
            "result": retry_result,
        },
    }
    print("IMP_INFER_RULES_JSON=" + json.dumps(payload, sort_keys=True))
    """

    {output, 0} =
      System.cmd(Path.expand(@python), ["-c", code],
        env: [
          {"PYTHONPATH", Path.expand(@dspy_root)},
          {"PYTHONNOUSERSITE", "1"},
          {"PYTHON_DOTENV_DISABLED", "1"},
          {"DOTENV_DISABLED", "1"},
          {"HOME", System.tmp_dir!()}
        ],
        stderr_to_stdout: true
      )

    output
    |> String.split("\n")
    |> Enum.find_value(fn line ->
      case String.split(line, "IMP_INFER_RULES_JSON=", parts: 2) do
        ["", payload] -> Jason.decode!(payload)
        _other -> nil
      end
    end)
    |> case do
      nil -> flunk("pinned DSPy probe emitted no observation payload:\n#{output}")
      payload -> payload
    end
  end

  defp git(args) do
    {output, 0} = System.cmd("git", args, cd: @dspy_root, stderr_to_stdout: true)
    String.trim(output)
  end

  defp file_sha256(path) do
    path
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
