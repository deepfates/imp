defmodule Imp.Optimizer.GEPA.AgentReflectionTest do
  use ExUnit.Case, async: true

  # What GEPA's reflection model reads when it optimizes an agent loop or a
  # program with a history input, with GEPA's default options.

  defmodule PlannerOnly do
    @moduledoc false
    @behaviour Imp.Module
    defstruct [:planner, :writer]

    @impl true
    def call(program, inputs) do
      with {:ok, plan} <- Imp.call(program.planner, %{question: inputs.question}) do
        {:ok, Imp.Prediction.new(%{answer: Imp.get(plan, :plan)})}
      end
    end

    @impl true
    def optimizer_predictors(program), do: [planner: program.planner, writer: program.writer]

    @impl true
    def update_optimizer_predictor(program, :planner, update),
      do: %{program | planner: update.(program.planner)}

    def update_optimizer_predictor(program, :writer, update),
      do: %{program | writer: update.(program.writer)}
  end

  setup do
    {:ok, prompts} = Agent.start_link(fn -> [] end)

    reflection_lm =
      Imp.LM.Static.new(
        handler: fn [%{content: content}], _opts ->
          Agent.update(prompts, &[content | &1])
          "```\nNew instruction.\n```"
        end
      )

    data =
      for i <- 0..3 do
        Imp.example(question: "version #{i}?", answer: "1.2.3") |> Imp.with_inputs(:question)
      end

    %{prompts: prompts, reflection_lm: reflection_lm, data: data}
  end

  defp instructed(signature, instructions),
    do: %{Imp.Signature.ensure(signature) | instructions: instructions}

  defp prompts(agent), do: agent |> Agent.get(& &1) |> Enum.reverse()

  defp agent do
    fetch =
      Imp.tool(
        :fetch,
        "Read a web page as text.",
        fn %{"url" => _url} -> "PAGE-BODY-MARKER 1.2.3" end,
        schema: %{
          "type" => "object",
          "properties" => %{"url" => %{"type" => "string"}},
          "required" => ["url"]
        }
      )

    lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          if inspect(messages, limit: :infinity, printable_limit: :infinity) =~
               "PAGE-BODY-MARKER",
             do: "FINAL-ANSWER-MARKER",
             else: %{
               tool_calls: [%{name: "fetch", arguments: %{"url" => "https://example.com/v"}}]
             }
        end
      )

    Imp.react("question -> answer", [fetch], lm: lm, max_iters: 4)
  end

  test "the default reflection on an agent reads the whole run and the agent's tools", ctx do
    optimizer =
      Imp.Optimizer.GEPA.new(Imp.exact_match(:answer),
        reflection_lm: ctx.reflection_lm,
        max_metric_calls: 16
      )

    {_compiled, report} =
      Imp.Optimizer.GEPA.compile_with_report(optimizer, agent(), ctx.data, ctx.data)

    assert report.metadata.execution_profile == :gepa_v0_1_4_merge
    assert [prompt | _rest] = prompts(ctx.prompts)

    # Every example shows the whole run, whichever step was drawn: the tool
    # result and the final answer come after the first step, and the answer
    # after the last, so they reach the prompt only through the finished
    # history.
    examples = prompt |> String.split("# Example ") |> tl()
    assert length(examples) == 3

    for example <- examples do
      assert example =~ "### Context\n```json\n  0: "
      assert example =~ ~s("result": "PAGE-BODY-MARKER 1.2.3")
      assert example =~ ~s("answer": "FINAL-ANSWER-MARKER")
      assert example =~ ~s("url": "https://example.com/v")

      assert example =~
               ~s(### tools\n[{"name": "fetch", "description": "Read a web page as text.", "args": {"url": {"type": "string"}}}])

      assert example =~ "## Feedback\nThis trajectory got a score of 0.0."
    end

    # The reflected step is drawn among the loop's steps, not always the
    # first: with seed 0 one of these examples reflects on the answering step.
    assert Enum.any?(
             examples,
             &(&1 =~ "## Generated Outputs\n### next_thought\nFINAL-ANSWER-MARKER")
           )

    refute prompt =~ "%Imp."
  end

  test "a score-only metric gives DSPy's default feedback line", ctx do
    lm = Imp.LM.Static.new(handler: fn _messages, _opts -> %{answer: "wrong"} end)
    program = Imp.predict("question -> answer", lm: lm)

    optimizer =
      Imp.Optimizer.GEPA.new(Imp.exact_match(:answer),
        reflection_lm: ctx.reflection_lm,
        max_metric_calls: 8
      )

    Imp.Optimizer.GEPA.compile(optimizer, program, ctx.data, ctx.data)

    assert [prompt | _rest] = prompts(ctx.prompts)
    assert prompt =~ "## Feedback\nThis trajectory got a score of 0.0.\n"
    refute prompt =~ "improve"
  end

  for profile <- [:default, :beam_native] do
    test "a history input reaches the reflection model as its turns (#{profile})", ctx do
      lm = Imp.LM.Static.new(handler: fn _messages, _opts -> %{answer: "wrong"} end)
      program = Imp.predict("question, history -> answer", lm: lm)
      history = Imp.History.new([%{question: "earlier?", answer: "HISTORY-TURN-MARKER"}])

      data =
        Enum.map(ctx.data, fn example ->
          example
          |> Imp.Example.to_map()
          |> Map.put(:history, history)
          |> Imp.example()
          |> Imp.with_inputs([:question, :history])
        end)

      profile_opts =
        if unquote(profile) == :default, do: [], else: [execution_profile: unquote(profile)]

      optimizer =
        Imp.Optimizer.GEPA.new(
          Imp.exact_match(:answer),
          [reflection_lm: ctx.reflection_lm, max_metric_calls: 8, generations: 1] ++
            profile_opts
        )

      Imp.Optimizer.GEPA.compile(optimizer, program, data, data)

      assert [prompt | _rest] = prompts(ctx.prompts)
      assert prompt =~ "HISTORY-TURN-MARKER"
      refute prompt =~ "%Imp.History"

      if unquote(profile) == :default do
        assert prompt =~
                 ~s(### Context\n```json\n  0: {"question": "earlier?", "answer": "HISTORY-TURN-MARKER"}\n```)
      end
    end
  end

  test "a component with no reflection records is not reflected on", ctx do
    lm = Imp.LM.Static.new(handler: fn _messages, _opts -> %{plan: "wrong"} end)

    program =
      struct(PlannerOnly,
        planner: Imp.predict(instructed("question -> plan", "PLANNER-INSTRUCTION"), lm: lm),
        writer: Imp.predict(instructed("question, plan -> answer", "WRITER-INSTRUCTION"), lm: lm)
      )

    optimizer =
      Imp.Optimizer.GEPA.new(Imp.exact_match(:answer),
        reflection_lm: ctx.reflection_lm,
        max_metric_calls: 40
      )

    {_compiled, report} =
      Imp.Optimizer.GEPA.compile_with_report(optimizer, program, ctx.data, ctx.data)

    prompts = prompts(ctx.prompts)

    # Round robin reaches the writer, which the program never calls, so its
    # iterations end without a reflection call.
    assert report.metadata.reflection_calls == length(prompts)
    assert Enum.any?(prompts, &(&1 =~ "PLANNER-INSTRUCTION"))
    refute Enum.any?(prompts, &(&1 =~ "WRITER-INSTRUCTION"))
  end
end
