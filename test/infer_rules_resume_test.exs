defmodule Imp.Optimizer.InferRules.ResumeTest do
  use ExUnit.Case, async: false

  alias Imp.Optimizer.{InferRules, Report}

  defmodule TwoPredictorProgram do
    defstruct [:first, :second]

    def optimizer_predictors(program), do: [first: program.first, second: program.second]
    def update_optimizer_predictor(program, name, update), do: Map.update!(program, name, update)

    def call(program, _inputs) do
      instructions = [program.first.signature.instructions, program.second.signature.instructions]

      answer =
        if Enum.at(instructions, 0) =~ "first-rule" and
             Enum.at(instructions, 1) =~ "second-rule",
           do: "yes",
           else: "no"

      {:ok, Imp.Prediction.new(%{answer: answer})}
    end
  end

  def exact_metric(example, prediction),
    do: Imp.Metrics.exact_match(:answer).(example, prediction)

  test "resume does not repeat a sealed bootstrap or explicit candidates" do
    uninterrupted_counter = start_supervised!({Agent, fn -> 0 end}, id: :infer_full_counter)
    {program, optimizer, trainset, devset} = explicit_fixture(uninterrupted_counter)

    uninterrupted =
      optimizer
      |> InferRules.compile(program, trainset, devset)
      |> Report.fetch()

    uninterrupted_calls = Agent.get(uninterrupted_counter, & &1)

    resumed_counter = start_supervised!({Agent, fn -> 0 end}, id: :infer_resumed_counter)
    {program, optimizer, trainset, devset} = explicit_fixture(resumed_counter)

    paused =
      optimizer
      |> InferRules.compile(program, trainset, devset, max_operations: 4)
      |> Report.fetch()

    assert paused.metadata.run_status == :paused
    assert paused.metadata.completed_operations == 4
    assert paused.candidate_count == 1
    assert is_map(paused.metadata.resume_state)
    calls_after_pause = Agent.get(resumed_counter, & &1)
    assert calls_after_pause == 2

    checkpoint = paused.metadata.resume_state |> Jason.encode!() |> Jason.decode!()

    resumed =
      optimizer
      |> InferRules.compile(program, trainset, devset, resume_state: checkpoint)
      |> Report.fetch()

    assert resumed.metadata.resumed
    assert resumed.metadata.run_status == :complete
    assert resumed.metadata.completed_operations == 7
    assert resumed.candidates == uninterrupted.candidates
    assert resumed.best_score == uninterrupted.best_score
    assert Agent.get(resumed_counter, & &1) == uninterrupted_calls
  end

  test "resume continues a multi-predictor proposal without repeating its sealed first call" do
    calls = start_supervised!({Agent, fn -> [] end})

    rule_lm =
      Imp.LM.Static.new(
        handler: fn _messages, opts ->
          index =
            Agent.get_and_update(calls, fn calls ->
              {length(calls), calls ++ [opts[:rollout_id]]}
            end)

          %{
            reasoning: "deterministic",
            natural_language_rules: if(index == 0, do: "first-rule", else: "second-rule")
          }
        end
      )

    task_lm = Imp.LM.Static.new(handler: fn _messages, _opts -> %{answer: "no"} end)

    program = %TwoPredictorProgram{
      first: Imp.predict("question -> answer", lm: task_lm),
      second: Imp.predict("answer -> explanation", lm: task_lm)
    }

    row =
      Imp.example(question: "q", answer: "yes", explanation: "e") |> Imp.with_inputs(:question)

    optimizer =
      InferRules.new(&__MODULE__.exact_metric/2,
        rule_lm: rule_lm,
        num_candidates: 1,
        num_rules: 1,
        max_bootstrapped_demos: 0,
        max_labeled_demos: 0
      )

    paused =
      optimizer
      |> InferRules.compile(program, [row], [row], max_operations: 2)
      |> Report.fetch()

    assert paused.metadata.run_status == :paused
    assert paused.metadata.proposal_calls == 1
    assert paused.candidate_count == 0
    assert Agent.get(calls, & &1) == [0]

    resumed =
      optimizer
      |> InferRules.compile(program, [row], [row], resume_state: paused.metadata.resume_state)
      |> Report.fetch()

    assert resumed.metadata.run_status == :complete
    assert resumed.metadata.proposal_calls == 2
    assert Agent.get(calls, & &1) == [0, 1]
    assert resumed.best_score == 1.0
  end

  test "metric identity drift is refused before bootstrap, rule, or task work" do
    counter = start_supervised!({Agent, fn -> 0 end})
    {program, optimizer, trainset, devset} = explicit_fixture(counter)

    checkpoint =
      optimizer
      |> InferRules.compile(program, trainset, devset, max_operations: 0)
      |> Report.fetch()
      |> then(& &1.metadata.resume_state)
      |> Jason.encode!()
      |> Jason.decode!()

    drifted =
      new_explicit_optimizer(
        captured_metric(counter),
        metric_identity(%{"field" => "answer", "mode" => "case_insensitive"})
      )

    assert_raise ArgumentError,
                 ~r/does not match the program runtime, datasets, or configuration/,
                 fn ->
                   InferRules.compile(drifted, program, trainset, devset,
                     resume_state: checkpoint,
                     max_operations: 0
                   )
                 end

    changed_program = %{program | config: [temperature: 0.25]}

    assert_raise ArgumentError,
                 ~r/does not match the program runtime, datasets, or configuration/,
                 fn ->
                   InferRules.compile(optimizer, changed_program, trainset, devset,
                     resume_state: checkpoint,
                     max_operations: 0
                   )
                 end

    changed_devset = [
      Imp.example(question: "changed", answer: "yes") |> Imp.with_inputs(:question)
    ]

    assert_raise ArgumentError,
                 ~r/does not match the program runtime, datasets, or configuration/,
                 fn ->
                   InferRules.compile(optimizer, program, trainset, changed_devset,
                     resume_state: checkpoint,
                     max_operations: 0
                   )
                 end

    changed_optimizer = %{optimizer | num_rules: optimizer.num_rules + 1}

    assert_raise ArgumentError,
                 ~r/does not match the program runtime, datasets, or configuration/,
                 fn ->
                   InferRules.compile(changed_optimizer, program, trainset, devset,
                     resume_state: checkpoint,
                     max_operations: 0
                   )
                 end

    assert Agent.get(counter, & &1) == 0
  end

  test "public optimize front door exposes the durable operation boundary" do
    counter = start_supervised!({Agent, fn -> 0 end})
    {program, optimizer, trainset, devset} = explicit_fixture(counter)

    paused = Imp.optimize!(program, optimizer, trainset, devset, max_operations: 0)
    report = Report.fetch(paused)

    assert report.metadata.run_status == :paused
    assert report.metadata.completed_operations == 0
    assert is_map(report.metadata.resume_state)
    assert Agent.get(counter, & &1) == 0
  end

  test "anonymous metrics remain available only for complete non-durable runs" do
    counter = start_supervised!({Agent, fn -> 0 end})
    {program, _optimizer, trainset, devset} = explicit_fixture(counter)
    optimizer = new_explicit_optimizer(Imp.Metrics.exact_match(:answer), nil)

    report = optimizer |> InferRules.compile(program, trainset, devset) |> Report.fetch()

    refute report.metadata.durable
    assert is_nil(report.metadata.metric_identity)
    assert is_nil(report.metadata.resume_state)

    assert_raise ArgumentError, ~r/requires :metric_identity/, fn ->
      InferRules.compile(optimizer, program, trainset, devset, max_operations: 0)
    end
  end

  @tag :tmp_dir
  test "fresh OS resume reconstructs sealed programs without replaying completed work", %{
    tmp_dir: tmp_dir
  } do
    checkpoint = Path.join(tmp_dir, "checkpoint.json")
    created = Path.join(tmp_dir, "created.json")
    resumed = Path.join(tmp_dir, "resumed.json")

    assert {_output, 0} = fresh_os(["create", checkpoint, created])
    assert {_output, 0} = fresh_os(["resume", checkpoint, resumed])

    assert created |> File.read!() |> Jason.decode!() == %{
             "best_score" => 1.0,
             "candidate_count" => 1,
             "completed_operations" => 4,
             "resumed" => false,
             "status" => "paused",
             "task_calls" => 2
           }

    assert resumed |> File.read!() |> Jason.decode!() == %{
             "best_score" => 1.0,
             "candidate_count" => 4,
             "completed_operations" => 7,
             "resumed" => true,
             "status" => "complete",
             "task_calls" => 3
           }
  end

  defp explicit_fixture(counter) do
    task_lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          Agent.update(counter, &(&1 + 1))
          %{answer: "yes"}
        end
      )

    program = Imp.predict("question -> answer", lm: task_lm)
    row = Imp.example(question: "q", answer: "yes") |> Imp.with_inputs(:question)

    optimizer =
      new_explicit_optimizer(captured_metric(counter), metric_identity())

    {program, optimizer, [row], [row]}
  end

  defp new_explicit_optimizer(metric, identity) do
    InferRules.new(metric,
      candidates: ["Return yes.", "Answer exactly."],
      metric_identity: identity,
      max_bootstrapped_demos: 1,
      max_labeled_demos: 0
    )
  end

  defp captured_metric(counter) do
    fn example, prediction ->
      _ = Agent.get(counter, & &1)
      exact_metric(example, prediction)
    end
  end

  defp metric_identity(config \\ %{"field" => "answer", "mode" => "exact"}) do
    %{"id" => "infer-rules-exact-answer", "version" => 1, "config" => config}
  end

  defp fresh_os(args) do
    expression = "Imp.Test.InferRulesResumeOS.run(System.argv())"

    System.cmd("mix", ["run", "--no-compile", "--no-deps-check", "-e", expression, "--" | args],
      env: [{"MIX_ENV", "test"}],
      stderr_to_stdout: true
    )
  end
end
