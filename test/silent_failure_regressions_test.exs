defmodule SilentFailureRegressionsTest do
  @moduledoc """
  Telos-asserting regressions for the six adversarially-confirmed silent
  failures (epic dee-zobd, wave 3). Each test fails on the pre-fix code:
  the old suites were structurally blind to every one of these.

  - P03 (dee-i3s4): save/load silently dropped a pinned non-portable LM
  - P09 (dee-qc0q): Evaluate :timeout never enforced at max_concurrency: 1
  - P07 (dee-pac8): Refine/BestOfN scored a fabricated empty Example
  - P14 (dee-f1ct): Evaluate max_errors halt was silent and off-by-one
  - P05 (dee-ovd3): XML adapter parse returned :ok on tag-free prose
  - P13 (dee-x50b): GSM8K.metric scored correct predictions as failures
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  defmodule Program do
    defstruct [:handler]

    def call(%__MODULE__{handler: handler}, inputs), do: handler.(inputs)
  end

  defp static_lm(reply) do
    %{module: Imp.LM.Static, opts: [handler: fn _messages, _opts -> reply end]}
  end

  defp example(question, answer) do
    Imp.example(question: question, answer: answer) |> Imp.Example.with_inputs(:question)
  end

  # ---------------------------------------------------------------------------
  # P03 (dee-i3s4): dumping a program pinned to a non-portable LM must raise,
  # matching the doctrine RLM already enforces (Imp.Saving.dump_portable_lm).
  # Before the fix, Predict.dump nilled the LM while writing dynamic_lm: false
  # and the loaded program silently answered with the GLOBAL LM.
  # ---------------------------------------------------------------------------

  test "P03: dumping a Predict pinned to a non-portable LM raises loudly" do
    program = Imp.predict("question -> answer", lm: static_lm(%{answer: "PINNED"}))

    assert_raise ArgumentError, ~r/Predict LM is not portable/, fn ->
      Imp.dump(program)
    end
  end

  test "P03: ChainOfThought and nesting programs inherit the pinned-LM raise" do
    cot = Imp.chain_of_thought("question -> answer", lm: static_lm(%{answer: "PINNED"}))

    assert_raise ArgumentError, ~r/Predict LM is not portable/, fn ->
      Imp.dump(cot)
    end

    metric = fn _example, _prediction -> true end
    registry = Imp.Saving.Registry.new(quality_metric: metric)

    refine =
      Imp.predict("question -> answer", lm: static_lm(%{answer: "PINNED"}))
      |> Imp.Predict.Refine.new(metric)

    assert_raise ArgumentError, ~r/Predict LM is not portable/, fn ->
      Imp.Saving.dump(refine, registry: registry)
    end
  end

  # The next three tests guard behavior that is IDENTICAL on pre-#61 code
  # (RLM's raise predates the fix; the portable and dynamic round-trips were
  # never broken), so they cannot fail on pre-fix lib/ by construction. Their
  # teeth are proven by defect injection instead: each fails when its target
  # defect is introduced into current lib/ (transcripts in the de-tp5x PR).
  test "P03: RLM's existing pinned-LM raise is covered directly" do
    rlm = Imp.Predict.RLM.new("question -> answer", lm: static_lm(%{answer: "PINNED"}))

    assert_raise ArgumentError, ~r/RLM controller LM is not portable/, fn ->
      Imp.dump(rlm)
    end
  end

  test "P03: a ReqLLM-pinned Predict round-trips with dynamic_lm?: false and the same LM" do
    lm = %Imp.Clients.ReqLLM{model: "openai:gpt-test", opts: []}
    program = Imp.predict("question -> answer", lm: lm)

    loaded = program |> Imp.dump() |> Imp.load()

    assert loaded.dynamic_lm? == false
    assert loaded.lm == lm
  end

  test "P03: the explicit escape hatch is a dynamic program, which round-trips as dynamic" do
    program = Imp.predict("question -> answer")
    assert program.dynamic_lm?

    dumped = Imp.dump(program)
    assert dumped["dynamic_lm"] == true
    assert dumped["lm"] == nil

    loaded = Imp.load(dumped)
    assert loaded.dynamic_lm?
    assert loaded.lm == nil

    # A dynamic program explicitly answers with whatever LM is configured.
    {:ok, prediction} =
      Imp.context([lm: static_lm(%{answer: "GLOBAL"})], fn ->
        Imp.call(loaded, %{question: "who answers?"})
      end)

    assert Imp.get(prediction, :answer) == "GLOBAL"
  end

  # ---------------------------------------------------------------------------
  # P09 (dee-qc0q): a finite :timeout must be enforced at the DEFAULT
  # max_concurrency: 1 (the sequential path used to skip the timeout machinery
  # entirely: a 300ms program with timeout: 50 completed quietly with score 1.0).
  # ---------------------------------------------------------------------------

  test "P09: Evaluate :timeout kills a slow row loudly at default max_concurrency" do
    program = %Program{
      handler: fn _inputs ->
        Process.sleep(300)
        {:ok, Imp.prediction(answer: "late")}
      end
    }

    metric = fn _example, _prediction -> true end

    # max_concurrency deliberately omitted: the default (1) must enforce it.
    evaluator = Imp.Evaluate.new([example("slow?", "late")], metric, timeout: 50)

    {result, log} =
      with_log(fn -> Imp.Evaluate.run(evaluator, program) end)

    assert [%{prediction: nil, score: score, passed?: false, error: reason}] = result.rows
    assert score == 0.0
    assert reason == {:evaluation_task_exit, :timeout}
    assert [%{index: 0, reason: {:evaluation_task_exit, :timeout}}] = result.errors
    assert log =~ "killed row 0"
    assert log =~ "time budget"
  end

  test "P09: an infinite timeout runs sequentially; an explicit max_concurrency: 1 still kills" do
    program = %Program{handler: fn _inputs -> {:ok, Imp.prediction(answer: "ok")} end}
    metric = fn _example, _prediction -> true end

    result =
      [example("fast?", "ok")]
      |> Imp.Evaluate.new(metric)
      |> Imp.Evaluate.run(program)

    assert result.score == 1.0

    # Teeth (de-tp5x): the kill contract must also hold when the caller PASSES
    # max_concurrency: 1 explicitly, not just via the default. The pre-#61
    # sequential path matched on max_concurrency: 1 regardless of how it was
    # set and skipped the timeout machinery entirely, so this half fails on
    # pre-fix lib/.
    slow = %Program{
      handler: fn _inputs ->
        Process.sleep(300)
        {:ok, Imp.prediction(answer: "late")}
      end
    }

    {result, log} =
      with_log(fn ->
        [example("slow?", "late")]
        |> Imp.Evaluate.new(metric, timeout: 50, max_concurrency: 1)
        |> Imp.Evaluate.run(slow)
      end)

    assert [%{prediction: nil, passed?: false, error: {:evaluation_task_exit, :timeout}}] =
             result.rows

    assert log =~ "killed row 0"
  end

  test "Evaluate never scores an operational program failure in sequential or task execution" do
    safety =
      Imp.OperationalSafetyError.exception(
        kind: :cost,
        reason: :reservation_exhausted,
        message: "evaluation cost guard"
      )

    program = %Program{handler: fn _inputs -> {:error, safety} end}
    rows = [example("guarded?", "yes")]
    metric = fn _example, _prediction -> true end

    for opts <- [[timeout: :infinity], [timeout: 1_000, max_concurrency: 1]] do
      assert_raise Imp.OperationalSafetyError, "evaluation cost guard", fn ->
        rows |> Imp.Evaluate.new(metric, opts) |> Imp.Evaluate.run(program)
      end
    end
  end

  test "Evaluate never converts an operational metric guard into score zero" do
    safety =
      Imp.OperationalSafetyError.exception(
        kind: :budget,
        reason: :metric_budget,
        message: "metric budget guard"
      )

    program = %Program{handler: fn _inputs -> {:ok, Imp.prediction(answer: "yes")} end}
    metric = fn _example, _prediction -> raise safety end

    assert_raise Imp.OperationalSafetyError, "metric budget guard", fn ->
      [example("guarded metric?", "yes")]
      |> Imp.Evaluate.new(metric)
      |> Imp.Evaluate.run(program)
    end
  end

  # ---------------------------------------------------------------------------
  # P07 (dee-pac8): Refine and BestOfN reward functions must receive the
  # call's ACTUAL inputs, matching DSPy's `reward_fn(kwargs, outputs)`
  # (dspy/predict/refine.py, best_of_n.py). Before the fix they received a
  # fabricated empty %Imp.Example{} and input-reading metrics scored 0.0.
  # ---------------------------------------------------------------------------

  test "P07: Refine reward function sees the call inputs" do
    parent = self()

    program = Imp.predict("question -> answer", lm: static_lm(%{answer: "4"}))

    metric = fn example, _prediction ->
      send(parent, {:metric_example, example})
      if Imp.Example.get(example, :question) == "What is 2+2?", do: 1.0, else: 0.0
    end

    refine = Imp.Predict.Refine.new(program, metric, max_attempts: 3)

    assert {:ok, prediction} = Imp.Predict.Refine.call(refine, %{question: "What is 2+2?"})

    # Input-reading metric passed on attempt 1, so the threshold short-circuit
    # fires: exactly one attempt, score 1.0. The blind path scored 0.0 and
    # burned every attempt.
    assert [%{attempt: 1, score: 1.0}] = Imp.Prediction.get(prediction, :refine_history)

    assert_received {:metric_example, example}
    assert Imp.Example.get(example, :question) == "What is 2+2?"
  end

  test "P07: BestOfN reward function sees the call inputs" do
    parent = self()

    program = Imp.predict("question -> answer", lm: static_lm(%{answer: "Brussels"}))

    metric = fn example, _prediction ->
      send(parent, {:metric_example, example})

      if Imp.Example.get(example, :question) == "Capital of Belgium?",
        do: 1.0,
        else: 0.0
    end

    best = Imp.Predict.BestOfN.new(program, metric, n: 3)

    assert {:ok, prediction} = Imp.Predict.BestOfN.call(best, %{question: "Capital of Belgium?"})
    assert Imp.Prediction.get(prediction, :answer) == "Brussels"

    assert_received {:metric_example, example}
    assert Imp.Example.get(example, :question) == "Capital of Belgium?"
  end

  test "P07: Refine keeps the injected hint invisible to the reward function" do
    parent = self()

    program = Imp.predict("question -> answer", lm: static_lm(%{answer: "wrong"}))

    metric = fn example, _prediction ->
      send(parent, {:metric_inputs, example |> Imp.Example.to_map() |> Map.keys()})
      0.0
    end

    refine =
      Imp.Predict.Refine.new(program, metric,
        max_attempts: 2,
        feedback_fn: fn _history -> "try harder" end
      )

    assert {:ok, _prediction} = Imp.Predict.Refine.call(refine, %{question: "Q?"})

    # DSPy passes the caller's kwargs; the hint rides the adapter, never the
    # reward function. Both attempts must see only the original input keys.
    assert_received {:metric_inputs, keys_one}
    assert_received {:metric_inputs, keys_two}
    assert keys_one == [:question]
    assert keys_two == [:question]
  end

  # ---------------------------------------------------------------------------
  # P14 (dee-f1ct): reaching max_errors must halt LOUDLY (DSPy parallelizer:
  # cancel at error_count >= max_errors, raise "Execution cancelled...").
  # Before the fix the halt was silent, off by one, and returned a
  # normal-looking partial Result with a subset-denominator score.
  # ---------------------------------------------------------------------------

  test "P14: Evaluate raises EvaluationCancelledError at exactly max_errors errors" do
    program = %Program{handler: fn _inputs -> {:error, :boom} end}
    metric = fn _example, _prediction -> true end

    devset = for i <- 1..10, do: example("q#{i}", "a#{i}")

    evaluator = Imp.Evaluate.new(devset, metric, max_errors: 2)

    log =
      capture_log(fn ->
        assert_raise Imp.EvaluationCancelledError, ~r/execution cancelled: 2 errors/, fn ->
          Imp.Evaluate.run(evaluator, program)
        end
      end)

    assert log =~ "execution cancelled"
  end

  test "P14: the halt threshold matches DSPy (>=): errors below max_errors complete" do
    devset = [example("ok", "fine"), example("bad", "boom"), example("ok2", "fine")]

    program = %Program{
      handler: fn
        %{question: "bad"} -> {:error, :boom}
        _inputs -> {:ok, Imp.prediction(answer: "fine")}
      end
    }

    metric = fn _example, _prediction -> true end

    # One error < max_errors 2: completes quietly with a failure row.
    result =
      devset
      |> Imp.Evaluate.new(metric, max_errors: 2)
      |> Imp.Evaluate.run(program)

    assert length(result.rows) == 3
    assert [%{reason: :boom}] = result.errors

    # Two errors reach max_errors 2: loud halt (old code needed THREE).
    two_bad = [example("bad", "x"), example("bad", "x"), example("ok", "fine")]

    capture_log(fn ->
      assert_raise Imp.EvaluationCancelledError, fn ->
        two_bad
        |> Imp.Evaluate.new(metric, max_errors: 2)
        |> Imp.Evaluate.run(program)
      end
    end)
  end

  test "P14: the exception carries the partial rows and errors (nothing hidden)" do
    program = %Program{handler: fn _inputs -> {:error, :boom} end}
    metric = fn _example, _prediction -> true end

    devset = for i <- 1..5, do: example("q#{i}", "a#{i}")

    capture_log(fn ->
      error =
        assert_raise Imp.EvaluationCancelledError, fn ->
          devset
          |> Imp.Evaluate.new(metric, max_errors: 3)
          |> Imp.Evaluate.run(program)
        end

      assert length(error.errors) == 3
      assert length(error.rows) == 3
      assert error.max_errors == 3
    end)
  end

  test "P14: an error-free run never cancels at max_errors: 0; the first error halts loudly" do
    program = %Program{handler: fn _inputs -> {:ok, Imp.prediction(answer: "ok")} end}
    metric = fn _example, _prediction -> true end

    result =
      [example("q", "ok")]
      |> Imp.Evaluate.new(metric, max_errors: 0)
      |> Imp.Evaluate.run(program)

    assert result.score == 1.0

    # Teeth (de-tp5x): at max_errors: 0 the very first error must RAISE. The
    # pre-#61 code halted at this budget too (1 > 0) but returned a
    # normal-looking partial Result instead of raising, so this half fails on
    # pre-fix lib/.
    failing = %Program{handler: fn _inputs -> {:error, :boom} end}

    capture_log(fn ->
      assert_raise Imp.EvaluationCancelledError, fn ->
        [example("q", "a"), example("q2", "a2")]
        |> Imp.Evaluate.new(metric, max_errors: 0)
        |> Imp.Evaluate.run(failing)
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # P05 (dee-ovd3): XML adapter parse must reject non-conforming output
  # loudly. DSPy XMLAdapter.parse raises AdapterParseError unless every
  # output field is present in tags; tag-free prose used to fall back to
  # Chat.parse and return {:ok, ...} with the whole completion as the answer.
  # ---------------------------------------------------------------------------

  test "P05: XML parse rejects tag-free prose loudly" do
    signature = Imp.signature("question -> answer")

    assert {:error, {:missing_output_fields, [:answer]}} =
             Imp.Adapter.XML.parse(signature, "no xml tags here, just prose", [])
  end

  # de-tp5x: two decorative P05 tests deleted here. "accepts well-formed
  # tagged output" and "requires every output field in tags" both passed on
  # pre-#61 code (partial-tag rejection already worked via Chat.parse; only
  # the ZERO-tag fallback was the defect, guarded above) and both are exact
  # duplicates of test/upstream_exam/adapters_test.exs ("xml adapter format
  # and parse basic" / "xml adapter parse errors on missing field").

  # ---------------------------------------------------------------------------
  # P13 (dee-x50b): the public GSM8K metric must score the repo's own fetched
  # data correctly. Fetched rows keep the full "#### N" rationale in :answer;
  # DSPy's gsm8k_metric compares extracted integers on both sides, so a model
  # answering exactly "18" is CORRECT. The old text-EM on :answer scored it
  # as a failure on every fetched row.
  # ---------------------------------------------------------------------------

  test "P13: GSM8K.metric scores a correct bare-number prediction as true on real fetched data" do
    [example] =
      Imp.Datasets.GSM8K.load(Path.join([__DIR__, "fixtures", "gsm8k", "gsm8k-test-0-1.jsonl"]))

    assert Imp.Example.get(example, :canonical_answer) == "18"
    assert Imp.Example.get(example, :answer) =~ "#### 18"

    assert Imp.Datasets.GSM8K.metric(example, Imp.prediction(answer: "18")) == true
    assert Imp.Datasets.GSM8K.metric(example, Imp.prediction(answer: "$18")) == true
    assert Imp.Datasets.GSM8K.metric(example, Imp.prediction(answer: "18.0")) == true
    assert Imp.Datasets.GSM8K.metric(example, Imp.prediction(answer: "19")) == false
  end

  test "P13: GSM8K.metric extracts the gold answer when only the raw rationale is present" do
    example =
      Imp.example(question: "total?", answer: "Some work. #### 29")
      |> Imp.Example.with_inputs(:question)

    assert Imp.Datasets.GSM8K.metric(example, Imp.prediction(answer: "29")) == true
    assert Imp.Datasets.GSM8K.metric(example, Imp.prediction(answer: "28")) == false
  end
end
