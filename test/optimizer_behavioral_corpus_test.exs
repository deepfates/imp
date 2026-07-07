defmodule OptimizerBehavioralCorpusTest do
  use ExUnit.Case

  defmodule ErrorLM do
    @behaviour DSEx.LM

    @impl true
    def generate(_messages, _opts), do: {:error, :offline_candidate}
  end

  defp metric, do: DSEx.Metrics.exact_match(:answer)

  defp evaluator(program),
    do: DSEx.Evaluate.run(DSEx.Evaluate.new(devset(), metric()), program)

  defp france_program do
    DSEx.predict("question -> answer",
      lm: %{
        module: DSEx.LM.Static,
        opts: [
          handler: fn messages, _opts ->
            prompt = Enum.map_join(messages, "\n", & &1.content)

            cond do
              prompt =~ "Always answer Paris" -> %{answer: "Paris"}
              prompt =~ "[[ ## answer ## ]]\nParis" -> %{answer: "Paris"}
              true -> %{answer: "unknown"}
            end
          end
        ]
      }
    )
  end

  defp trainset do
    [
      DSEx.example(question: "What is the capital of France?", answer: "Paris")
      |> DSEx.Example.with_inputs(:question)
    ]
  end

  defp devset do
    [
      DSEx.example(question: "Capital of France?", answer: "Paris")
      |> DSEx.Example.with_inputs(:question)
    ]
  end

  test "MIPROv2 searches categorical instruction and demo candidates without regressing baseline" do
    program = france_program()
    baseline_score = evaluator(program).score

    optimizer =
      DSEx.Optimizer.MIPROv2.new(metric(), trials: 5, demos_per_candidate: 1, cold_start: 2)

    compiled = DSEx.Optimizer.MIPROv2.compile(optimizer, program, trainset(), devset())
    report = DSEx.Optimizer.Report.fetch(compiled)

    assert report.optimizer == :mipro_v2
    assert report.metadata.search == :categorical_tpe
    assert report.metadata.acquisition == :laplace_density_ratio
    assert report.best_score >= baseline_score
    assert report.best_score == evaluator(compiled).score
    assert Enum.any?(report.candidates, &Map.get(&1, :baseline))
    assert Enum.any?(report.candidates, &(&1[:source] == :random_cold_start))
    assert Enum.any?(report.candidates, &(&1[:source] == :tpe_density_ratio))
    assert Enum.any?(report.candidates, &(not Enum.empty?(Map.get(&1, :demos, []))))
  end

  test "GEPA turns textual feedback into reflective candidates and keeps the best" do
    program = france_program()

    optimizer =
      DSEx.Optimizer.GEPA.new(metric(),
        generations: 2,
        feedback_fn: fn _trainset -> "Always answer Paris when asked about France." end
      )

    compiled = DSEx.Optimizer.GEPA.compile(optimizer, program, trainset(), devset())
    report = DSEx.Optimizer.Report.fetch(compiled)

    assert report.optimizer == :gepa
    assert report.best_score == 1.0
    assert report.best_score == evaluator(compiled).score
    assert report.metadata.feedback =~ "Always answer Paris"
    assert report.metadata.implementation == DSEx.Optimize.GEPA
    assert Enum.any?(report.candidates, &(&1.instruction =~ "Reflection"))
  end

  test "GEPA records program call failures as optimizer feedback instead of crashing" do
    broken_program =
      DSEx.predict("question -> answer",
        lm: %{module: ErrorLM, opts: []}
      )

    compiled =
      DSEx.Optimizer.GEPA.new(metric(),
        generations: 1,
        feedback_fn: fn _trainset -> "Recover from malformed candidate outputs." end
      )
      |> DSEx.Optimizer.GEPA.compile(broken_program, trainset(), devset())

    report = DSEx.Optimizer.Report.fetch(compiled)

    assert report.optimizer == :gepa
    assert report.best_score == 0.0

    assert Enum.any?(report.candidates, fn candidate ->
             candidate.mutation =~ "Program call failed"
           end)
  end

  test "SIMBA performs monotonic mini-batch ascent over candidate programs" do
    program = france_program()
    baseline_score = evaluator(program).score

    optimizer = DSEx.Optimizer.SIMBA.new(metric(), steps: 3, demos_per_step: 1)
    compiled = DSEx.Optimizer.SIMBA.compile(optimizer, program, trainset(), devset())
    report = DSEx.Optimizer.Report.fetch(compiled)

    assert report.optimizer == :simba
    assert report.metadata.policy == :monotonic_minibatch_ascent
    assert report.best_score >= baseline_score
    assert report.best_score == evaluator(compiled).score
    assert Enum.any?(report.candidates, & &1.accepted)
  end

  test "SIMBA can use introspective LM feedback for candidate instructions" do
    judge_lm = %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn messages, _opts ->
          send(self(), {:simba_judge, messages})
          %{instruction: "Always answer Paris when asked about France."}
        end
      ]
    }

    compiled =
      DSEx.Optimizer.SIMBA.new(metric(), steps: 1, demos_per_step: 1, judge_lm: judge_lm)
      |> DSEx.Optimizer.SIMBA.compile(france_program(), trainset(), devset())

    report = DSEx.Optimizer.Report.fetch(compiled)
    assert report.metadata.introspection
    assert report.best_score == 1.0
    assert_received {:simba_judge, _messages}
  end

  test "COPRO reports coordinate prompt optimization across breadth and depth" do
    program = france_program()

    optimizer =
      DSEx.Optimizer.COPRO.new(metric(),
        breadth: 6,
        depth: 2,
        extra_instructions: ["Always answer Paris when asked about France."]
      )

    compiled = DSEx.Optimizer.COPRO.compile(optimizer, program, trainset(), devset())
    report = DSEx.Optimizer.Report.fetch(compiled)

    assert report.optimizer == :copro
    assert report.best_score == 1.0
    assert report.best_score == evaluator(compiled).score
    assert report.metadata.breadth == 6
    assert report.metadata.depth == 2
    assert Enum.map(report.metadata.rounds, & &1.metadata.round) == [1, 2]
    assert Enum.any?(report.candidates, &(&1.instruction =~ "Always answer Paris"))
  end

  test "COPRO can use LM-generated score-informed instruction proposals" do
    proposer_lm = %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn messages, _opts ->
          send(self(), {:copro_proposer, messages})
          ~s(["Always answer Paris when asked about France."])
        end
      ]
    }

    compiled =
      DSEx.Optimizer.COPRO.new(metric(), breadth: 1, depth: 1, proposer_lm: proposer_lm)
      |> DSEx.Optimizer.COPRO.compile(france_program(), trainset(), devset())

    report = DSEx.Optimizer.Report.fetch(compiled)
    assert report.best_score == 1.0
    assert Enum.any?(report.candidates, &(&1.instruction =~ "Always answer Paris"))
    assert_received {:copro_proposer, messages}
    assert Enum.map_join(messages, "\n", & &1.content) =~ "scored_examples"
  end
end
