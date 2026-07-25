defmodule Imp.Optimizer.InferRulesUpstreamDifferentialTest do
  use ExUnit.Case, async: false

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

    report = Imp.Optimizer.Report.fetch(compiled)
    assert report.metadata.proposal_calls == 1
    assert report.metadata.implementation == :native_rule_induction
  end

  defp exact_checkout? do
    File.exists?(@python) and File.dir?(Path.join(@dspy_root, ".git")) and
      git(["rev-parse", "HEAD"]) == @dspy_commit and git(["status", "--porcelain"]) == "" and
      file_sha256(Path.join(@dspy_root, "dspy/teleprompt/infer_rules.py")) == @source_sha256
  end

  defp upstream_observations do
    code = """
    import json
    import dspy
    from dspy.teleprompt.infer_rules import InferRules

    optimizer = InferRules.__new__(InferRules)
    signature = dspy.Signature("question -> answer")
    examples = [dspy.Example(question="France capital?", answer="Paris")]
    predictor = dspy.Predict(signature)
    rules = "Map France questions to Paris."
    formatted = optimizer.format_examples(examples, signature)
    optimizer.update_program_instructions(predictor, rules)
    print(json.dumps({
        "formatted_examples": formatted,
        "rules": rules,
        "updated_instruction": predictor.signature.instructions,
    }, sort_keys=True))
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

    Jason.decode!(output)
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
