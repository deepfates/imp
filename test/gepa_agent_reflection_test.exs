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

      # The step's own `tools` input is the same roster as text; it is shown
      # once, as the native roster.
      assert length(String.split(example, "### tools\n")) == 2

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

  test "values that are not Imp's own structs render as their complete terms", ctx do
    lm = Imp.LM.Static.new(handler: fn _messages, _opts -> %{answer: "wrong"} end)
    program = Imp.predict("question, tags, pattern -> answer", lm: lm)

    data =
      Enum.map(ctx.data, fn example ->
        example
        |> Imp.Example.to_map()
        |> Map.merge(%{tags: MapSet.new(["red", "blue"]), pattern: ~r/v\d+/})
        |> Imp.example()
        |> Imp.with_inputs([:question, :tags, :pattern])
      end)

    optimizer =
      Imp.Optimizer.GEPA.new(Imp.exact_match(:answer),
        reflection_lm: ctx.reflection_lm,
        max_metric_calls: 8
      )

    Imp.Optimizer.GEPA.compile(optimizer, program, data, data)

    assert [prompt | _rest] = prompts(ctx.prompts)
    assert prompt =~ ~s|### tags\nMapSet.new(["blue", "red"])\n|
    assert prompt =~ "### pattern\n~r/v\\d+/\n"
    refute prompt =~ "#Reference"
  end

  test "a predictor given two histories is refused, as DSPy's GEPA asserts one", ctx do
    lm = Imp.LM.Static.new(handler: fn _messages, _opts -> %{answer: "wrong"} end)
    program = Imp.predict("question, history, notes -> answer", lm: lm)
    history = Imp.History.new([%{question: "earlier?", answer: "yes"}])

    data =
      Enum.map(ctx.data, fn example ->
        example
        |> Imp.Example.to_map()
        |> Map.merge(%{history: history, notes: history})
        |> Imp.example()
        |> Imp.with_inputs([:question, :history, :notes])
      end)

    optimizer =
      Imp.Optimizer.GEPA.new(Imp.exact_match(:answer),
        reflection_lm: ctx.reflection_lm,
        max_metric_calls: 8
      )

    assert_raise ArgumentError, ~r/one history input as Context.*\[:history, :notes\]/s, fn ->
      Imp.Optimizer.GEPA.compile(optimizer, program, data, data)
    end

    assert prompts(ctx.prompts) == []
  end

  describe "choosing the profile" do
    defp metric, do: Imp.exact_match(:answer)

    test "no profile is DSPy's GEPA with merge, and use_merge: false drops merge" do
      assert %{execution_profile: :gepa_v0_1_4_merge, use_merge: true} =
               Imp.Optimizer.GEPA.new(metric())

      assert %{execution_profile: :gepa_v0_1_4, use_merge: false} =
               Imp.Optimizer.GEPA.new(metric(), use_merge: false)

      assert %{execution_profile: :beam_native, use_merge: false} =
               Imp.Optimizer.GEPA.new(metric(), execution_profile: :beam_native)
    end

    test "an option the DSPy profiles fix names the default and :beam_native" do
      assert_raise ArgumentError,
                   ~r/^:execution_profile :gepa_v0_1_4_merge \(the default\) requires :combee: false; .*execution_profile: :beam_native$/,
                   fn -> Imp.Optimizer.GEPA.new(metric(), combee: true) end

      assert_raise ArgumentError,
                   ~r/^:execution_profile :gepa_v0_1_4 requires :module_selector: :round_robin; .*execution_profile: :beam_native$/,
                   fn ->
                     Imp.Optimizer.GEPA.new(metric(),
                       execution_profile: :gepa_v0_1_4,
                       module_selector: :all
                     )
                   end

      assert %{combee: %{}} =
               Imp.Optimizer.GEPA.new(metric(), execution_profile: :beam_native, combee: true)
    end

    test "a reflection strategy needs :beam_native" do
      strategy = fn _candidate, _dataset, _components -> %{new_texts: %{}} end

      assert_raise ArgumentError,
                   ~r/:reflection_strategy runs under execution_profile: :beam_native/,
                   fn -> Imp.Optimizer.GEPA.new(metric(), reflection_strategy: strategy) end

      assert %{reflection_strategy: kept} =
               Imp.Optimizer.GEPA.new(metric(),
                 execution_profile: :beam_native,
                 reflection_strategy: strategy
               )

      refute is_nil(kept)
    end

    test "the default derives the reflection limit and takes one budget" do
      assert_raise ArgumentError,
                   ~r/^:execution_profile :gepa_v0_1_4_merge \(the default\) derives :max_reflection_calls.*execution_profile: :beam_native$/,
                   fn -> Imp.Optimizer.GEPA.new(metric(), max_reflection_calls: 4) end

      assert_raise ArgumentError, ~r/takes one budget/, fn ->
        Imp.Optimizer.GEPA.new(metric(), max_metric_calls: 10, max_full_evaluations: 1)
      end

      assert %{max_reflection_calls: 4} =
               Imp.Optimizer.GEPA.new(metric(),
                 execution_profile: :beam_native,
                 max_reflection_calls: 4
               )
    end

    test "max_full_evaluations is a metric budget over both datasets, as DSPy's max_full_evals",
         ctx do
      lm = Imp.LM.Static.new(handler: fn _messages, _opts -> %{answer: "wrong"} end)
      program = Imp.predict("question -> answer", lm: lm)

      optimizer =
        Imp.Optimizer.GEPA.new(metric(),
          reflection_lm: ctx.reflection_lm,
          max_full_evaluations: 2
        )

      {_compiled, report} =
        Imp.Optimizer.GEPA.compile_with_report(optimizer, program, ctx.data, ctx.data)

      assert report.metadata.max_metric_calls == 2 * (4 + 4)
      assert report.metadata.max_full_evaluations == :infinity
    end
  end

  # Only a ReActV2 step's roster input gives way to its native roster; any
  # other predictor's input called `tools` is its own data and is shown.
  test "a predictor's own input named tools is kept", ctx do
    lm = Imp.LM.Static.new(handler: fn _messages, _opts -> "[[ ## answer ## ]]\nno" end)

    provider_tool = %{
      type: "function",
      function: %{
        name: "fetch",
        description: "Read a web page.",
        parameters: %{"type" => "object", "properties" => %{}}
      }
    }

    program =
      Imp.predict("question, tools -> answer", lm: lm, config: [tools: [provider_tool]])

    data =
      for i <- 0..3 do
        Imp.example(question: "version #{i}?", tools: "OWN-TOOLS-MARKER", answer: "1.2.3")
        |> Imp.with_inputs([:question, :tools])
      end

    optimizer =
      Imp.Optimizer.GEPA.new(Imp.exact_match(:answer),
        reflection_lm: ctx.reflection_lm,
        max_metric_calls: 8
      )

    Imp.Optimizer.GEPA.compile_with_report(optimizer, program, data, data)
    assert [prompt | _rest] = prompts(ctx.prompts)
    assert prompt =~ "### tools\nOWN-TOOLS-MARKER"
  end
end
