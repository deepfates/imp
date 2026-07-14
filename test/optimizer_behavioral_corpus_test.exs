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
      DSEx.Optimizer.MIPROv2.new(metric(),
        auto: nil,
        num_candidates: 5,
        num_trials: 5,
        max_bootstrapped_demos: 0,
        max_labeled_demos: 1,
        minibatch: false,
        startup_trials: 2
      )

    compiled = DSEx.Optimizer.MIPROv2.compile(optimizer, program, trainset(), devset())
    report = DSEx.Optimizer.Report.fetch(compiled)

    assert report.optimizer == :mipro_v2
    assert report.metadata.algorithm == :mipro_v2
    assert report.metadata.sampler == :joint_categorical_parzen
    assert report.metadata.upstream_sampler == :optuna_multivariate_tpe
    refute Map.has_key?(report.metadata, :compatibility)
    refute report.metadata.exact_sampler_sequence_parity
    assert report.best_score >= baseline_score
    assert report.best_score == evaluator(compiled).score
    assert report.candidate_count == 5
    assert length(report.metadata.full_evaluations) == 6
    assert Enum.any?(report.metadata.full_evaluations, &(&1.kind == :baseline))
    assert report.metadata.search_space["atom:main:demos"] >= 1
    assert Enum.all?(report.candidates, &is_map(&1.params))
  end

  test "MIPROv2 treats zero search counts as baseline-only compile" do
    program = france_program()
    baseline_score = evaluator(program).score

    compiled =
      DSEx.Optimizer.MIPROv2.new(metric(),
        auto: nil,
        num_candidates: 1,
        num_trials: 0,
        max_bootstrapped_demos: 0,
        max_labeled_demos: 0,
        minibatch: false,
        startup_trials: 0
      )
      |> DSEx.Optimizer.MIPROv2.compile(program, trainset(), devset())

    report = DSEx.Optimizer.Report.fetch(compiled)

    assert report.optimizer == :mipro_v2
    assert report.best_score == baseline_score
    assert report.candidate_count == 0
    assert report.candidates == []

    assert [%{kind: :baseline, trial: 0, score: ^baseline_score}] =
             report.metadata.full_evaluations

    assert report.metadata.effective_config.num_trials == 0
  end

  test "MIPROv2 rejects invalid devsets at the public boundary" do
    program = france_program()

    assert_raise ArgumentError, ~r/valset must be enumerable/, fn ->
      DSEx.Optimizer.MIPROv2.new(metric(),
        auto: nil,
        num_candidates: 2,
        num_trials: 2,
        max_bootstrapped_demos: 0,
        max_labeled_demos: 1,
        minibatch: false
      )
      |> DSEx.Optimizer.MIPROv2.compile(program, trainset(), :not_an_enumerable_devset)
    end
  end

  test "MIPROv2 rejects invalid trainsets at the public boundary" do
    program = france_program()

    assert_raise ArgumentError, ~r/trainset must be enumerable/, fn ->
      DSEx.Optimizer.MIPROv2.new(metric(),
        auto: nil,
        num_candidates: 1,
        num_trials: 1,
        max_bootstrapped_demos: 0,
        max_labeled_demos: 1,
        minibatch: false
      )
      |> DSEx.Optimizer.MIPROv2.compile(program, :not_an_enumerable_trainset, devset())
    end
  end

  test "GEPA turns textual feedback into reflective candidates and keeps the best" do
    program = france_program()

    optimizer =
      DSEx.Optimizer.GEPA.new(metric(),
        generations: 2,
        max_metric_calls: 20,
        max_full_evaluations: 5,
        feedback_fn: fn _trainset -> "Always answer Paris when asked about France." end
      )

    compiled = DSEx.Optimizer.GEPA.compile(optimizer, program, trainset(), devset())
    report = DSEx.Optimizer.Report.fetch(compiled)

    assert report.optimizer == :gepa
    assert report.best_score == 1.0
    assert report.best_score == evaluator(compiled).score
    assert report.metadata.feedback =~ "Always answer Paris"
    assert report.metadata.implementation == DSEx.Optimizer.GEPA
    assert report.metadata.max_metric_calls == 20
    assert report.metadata.max_full_evaluations == 5
    assert Enum.any?(report.candidates, &(&1.instruction =~ "Reflection"))
  end

  test "GEPA treats zero generations as a baseline-only compile" do
    program = france_program()
    baseline_score = evaluator(program).score

    compiled =
      DSEx.Optimizer.GEPA.new(metric(),
        generations: 0,
        feedback_fn: fn _trainset -> "Always answer Paris when asked about France." end
      )
      |> DSEx.Optimizer.GEPA.compile(program, trainset(), devset())

    report = DSEx.Optimizer.Report.fetch(compiled)

    assert report.optimizer == :gepa
    assert report.best_score == baseline_score
    assert report.candidate_count == 1
    assert [%{id: "baseline", mutation: "baseline", score: ^baseline_score}] = report.candidates
    assert report.metadata.generations == 0
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

  test "GEPA keeps truncated multibyte diagnostics valid UTF-8" do
    reason = String.duplicate("é", 241)

    broken_program =
      DSEx.predict("question -> answer",
        lm: fn _messages, _opts -> {:error, reason} end
      )

    compiled =
      DSEx.Optimizer.GEPA.new(metric(), generations: 1)
      |> DSEx.Optimizer.GEPA.compile(broken_program, trainset(), devset())

    report = DSEx.Optimizer.Report.fetch(compiled)

    assert Enum.all?(report.candidates, fn candidate ->
             String.valid?(candidate.instruction) and String.valid?(candidate.mutation)
           end)
  end

  test "GEPA reports feedback callback failures and falls back to default feedback" do
    compiled =
      DSEx.Optimizer.GEPA.new(metric(),
        generations: 1,
        feedback_fn: fn _trainset -> raise "feedback service offline" end
      )
      |> DSEx.Optimizer.GEPA.compile(france_program(), trainset(), devset())

    report = DSEx.Optimizer.Report.fetch(compiled)

    assert report.optimizer == :gepa
    assert report.metadata.status == :with_errors
    assert report.metadata.feedback =~ "Use observed examples carefully"

    assert [
             %{
               stage: :feedback,
               error: "feedback service offline",
               fallback: fallback
             }
           ] = report.errors

    assert fallback == report.metadata.feedback
  end

  test "GEPA preserves artifact-level evaluator diagnostics in optimizer report" do
    exploding_metric = fn _example, _prediction -> raise "metric unavailable" end

    compiled =
      DSEx.Optimizer.GEPA.new(exploding_metric,
        generations: 1,
        feedback_fn: fn _trainset -> "Try to improve." end
      )
      |> DSEx.Optimizer.GEPA.compile(france_program(), trainset(), devset())

    report = DSEx.Optimizer.Report.fetch(compiled)

    assert report.optimizer == :gepa
    assert report.best_score == 0.0
    assert report.metadata.status == :with_errors
    assert Enum.any?(report.candidates, &(&1.diagnostics == ["metric unavailable"]))

    assert Enum.any?(report.errors, fn error ->
             error.candidate_id in ["baseline", "gepa-1"] and
               error.diagnostics == ["metric unavailable"]
           end)
  end

  test "SIMBA performs stochastic trajectory sampling without regressing final selection" do
    program = france_program()
    baseline_score = evaluator(program).score

    optimizer =
      DSEx.Optimizer.SIMBA.new(metric(),
        bsize: 1,
        num_candidates: 1,
        max_steps: 3,
        max_demos: 1
      )

    compiled = DSEx.Optimizer.SIMBA.compile(optimizer, program, trainset(), devset())
    report = DSEx.Optimizer.Report.fetch(compiled)

    assert report.optimizer == :simba
    assert report.metadata.algorithm == :stochastic_introspective_minibatch_ascent
    assert report.best_score >= baseline_score
    assert report.best_score == evaluator(compiled).score
    assert length(report.metadata.trial_logs) == 3
    assert report.metadata.trajectory_calls == 3
  end

  test "SIMBA treats zero steps as a baseline-only compile" do
    program = france_program()
    baseline_score = evaluator(program).score

    compiled =
      DSEx.Optimizer.SIMBA.new(metric(), bsize: 1, max_steps: 0, max_demos: 0)
      |> DSEx.Optimizer.SIMBA.compile(program, trainset(), devset())

    report = DSEx.Optimizer.Report.fetch(compiled)

    assert report.optimizer == :simba
    assert report.best_score == baseline_score
    assert report.candidate_count == 0
    assert report.candidates == []
    assert report.metadata.baseline_score == baseline_score
    assert report.metadata.status == :ok
    assert report.errors == []
  end

  test "SIMBA records an explicitly configured reflection model" do
    prompt_lm = %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn messages, _opts ->
          send(self(), {:simba_judge, messages})
          %{instruction: "Always answer Paris when asked about France."}
        end
      ]
    }

    compiled =
      DSEx.Optimizer.SIMBA.new(metric(),
        bsize: 1,
        max_steps: 1,
        max_demos: 1,
        prompt_lm: prompt_lm
      )
      |> DSEx.Optimizer.SIMBA.compile(france_program(), trainset(), devset())

    report = DSEx.Optimizer.Report.fetch(compiled)
    refute Map.has_key?(report.metadata, :compatibility)
    assert report.best_score >= 0.0
    refute_received {:simba_judge, _messages}
  end

  test "SIMBA rejects invalid final sets at the public boundary" do
    program = france_program()

    assert_raise ArgumentError, ~r/final_set must be enumerable/, fn ->
      DSEx.Optimizer.SIMBA.new(metric(), max_steps: 2, max_demos: 1)
      |> DSEx.Optimizer.SIMBA.compile(program, trainset(), :not_an_enumerable_devset)
    end
  end

  test "SIMBA rejects invalid trainsets at the public boundary" do
    program = france_program()

    assert_raise ArgumentError, ~r/trainset must be enumerable/, fn ->
      DSEx.Optimizer.SIMBA.new(metric(), max_steps: 1, max_demos: 1)
      |> DSEx.Optimizer.SIMBA.compile(program, :not_an_enumerable_trainset, devset())
    end
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

  test "COPRO treats zero depth as a baseline-only compile" do
    program = france_program()
    baseline_score = evaluator(program).score

    compiled =
      DSEx.Optimizer.COPRO.new(metric(), breadth: 0, depth: 0)
      |> DSEx.Optimizer.COPRO.compile(program, trainset(), devset())

    report = DSEx.Optimizer.Report.fetch(compiled)

    assert report.optimizer == :copro
    assert report.best_score == baseline_score
    assert report.candidate_count == 0
    assert report.candidates == []
    assert report.metadata.breadth == 0
    assert report.metadata.depth == 0
    assert report.metadata.rounds == []
    assert report.metadata.status == :baseline_only
  end

  test "COPRO uses safe instruction proposal fallback for malformed training rows" do
    program = france_program()

    compiled =
      DSEx.Optimizer.COPRO.new(metric(), breadth: 2, depth: 1)
      |> DSEx.Optimizer.COPRO.compile(program, [:not_an_example], devset())

    report = DSEx.Optimizer.Report.fetch(compiled)

    assert report.optimizer == :copro
    assert report.metadata.status == :ok
    assert report.metadata.depth == 1
    assert [_round] = report.metadata.rounds
    assert report.errors == []
    assert Enum.any?(report.candidates, &(&1.round == 1))
  end

  test "advanced optimizer constructors reject invalid option containers at the boundary" do
    assert_raise ArgumentError,
                 ~r/DSEx\.Optimizer\.COPRO\.new\/2: expected keyword options/,
                 fn ->
                   DSEx.Optimizer.COPRO.new(metric(), %{depth: 1})
                 end

    assert_raise ArgumentError,
                 ~r/DSEx\.Optimizer\.MIPROv2\.new\/2: expected keyword options/,
                 fn ->
                   DSEx.Optimizer.MIPROv2.new(metric(), %{num_trials: 1})
                 end

    assert_raise ArgumentError,
                 ~r/DSEx\.Optimizer\.SIMBA\.new\/2: expected keyword options/,
                 fn ->
                   DSEx.Optimizer.SIMBA.new(metric(), %{steps: 1})
                 end

    assert_raise ArgumentError, ~r/DSEx\.Optimizer\.GEPA\.new\/2: expected keyword options/, fn ->
      DSEx.Optimizer.GEPA.new(metric(), %{generations: 1})
    end

    assert_raise ArgumentError,
                 ~r/DSEx\.Optimizer\.COPRO\.new\/2: invalid value for :depth option: expected non negative integer/,
                 fn ->
                   DSEx.Optimizer.COPRO.new(metric(), depth: -1)
                 end

    assert_raise ArgumentError,
                 ~r/DSEx\.Optimizer\.COPRO\.new\/2: invalid value for :breadth option: expected non negative integer/,
                 fn ->
                   DSEx.Optimizer.COPRO.new(metric(), breadth: -1)
                 end

    assert_raise ArgumentError,
                 ~r/num_trials must be a non-negative integer/,
                 fn ->
                   DSEx.Optimizer.MIPROv2.new(metric(), num_trials: -1)
                 end

    assert_raise ArgumentError,
                 ~r/max_labeled_demos must be a non-negative integer/,
                 fn ->
                   DSEx.Optimizer.MIPROv2.new(metric(), max_labeled_demos: -1)
                 end

    assert_raise ArgumentError,
                 ~r/startup_trials must be a non-negative integer/,
                 fn ->
                   DSEx.Optimizer.MIPROv2.new(metric(), startup_trials: -1)
                 end

    for alias <- [:trials, :demos_per_candidate, :cold_start] do
      assert_raise ArgumentError, ~r/unknown MIPROv2 options/, fn ->
        DSEx.Optimizer.MIPROv2.new(metric(), [{alias, 1}])
      end
    end

    assert_raise ArgumentError,
                 ~r/max_steps must be an integer >= 0/,
                 fn ->
                   DSEx.Optimizer.SIMBA.new(metric(), max_steps: -1)
                 end

    assert_raise ArgumentError,
                 ~r/max_demos must be an integer >= 0/,
                 fn ->
                   DSEx.Optimizer.SIMBA.new(metric(), max_demos: -1)
                 end

    assert_raise ArgumentError,
                 ~r/DSEx\.Optimizer\.GEPA\.new\/2: invalid value for :generations option: expected non negative integer/,
                 fn ->
                   DSEx.Optimizer.GEPA.new(metric(), generations: -1)
                 end
  end

  test "advanced optimizer constructors reject invalid callback contracts at the boundary" do
    assert_raise ArgumentError,
                 ~r/DSEx\.Optimizer\.COPRO\.new\/2 expects a metric function with arity 2 or 3/,
                 fn -> DSEx.Optimizer.COPRO.new(fn _example -> true end) end

    assert_raise ArgumentError,
                 ~r/DSEx\.Optimizer\.MIPROv2\.new\/2 expects a metric function with arity 2 or 3/,
                 fn -> DSEx.Optimizer.MIPROv2.new(fn _example -> true end) end

    assert_raise ArgumentError,
                 ~r/DSEx\.Optimizer\.SIMBA\.new\/2 expects a metric function with arity 2 or 3/,
                 fn -> DSEx.Optimizer.SIMBA.new(fn _example -> true end) end

    assert_raise ArgumentError,
                 ~r/DSEx\.Optimizer\.GEPA\.new\/2 expects a metric function with arity 2/,
                 fn -> DSEx.Optimizer.GEPA.new(fn _example, _prediction, _trace -> true end) end

    assert_raise ArgumentError,
                 ~r/DSEx\.Optimizer\.GEPA\.new\/2: invalid value for :feedback_fn option: expected nil or an arity-1 function/,
                 fn -> DSEx.Optimizer.GEPA.new(metric(), feedback_fn: fn -> "feedback" end) end

    assert_raise ArgumentError,
                 ~r/DSEx\.Optimizer\.COPRO\.new\/2: invalid value for :proposer_lm option: expected nil, an LM module/,
                 fn -> DSEx.Optimizer.COPRO.new(metric(), proposer_lm: %{provider: :missing}) end

    assert_raise ArgumentError,
                 ~r/prompt_lm expected/,
                 fn -> DSEx.Optimizer.SIMBA.new(metric(), prompt_lm: %{provider: :missing}) end
  end

  test "SIMBA rejects deprecated option aliases" do
    for alias <- [:steps, :demos_per_step, :judge_lm] do
      assert_raise ArgumentError, ~r/unknown SIMBA options/, fn ->
        DSEx.Optimizer.SIMBA.new(metric(), [{alias, 1}])
      end
    end
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
