defmodule Imp.Optimizer.SIMBA.ResumeTest do
  use ExUnit.Case, async: false

  alias Imp.Optimizer.{Report, SIMBA}

  def exact_metric(example, prediction),
    do: Imp.Metrics.exact_match(:answer).(example, prediction)

  test "JSON checkpoint resume matches an uninterrupted run and rebinds runtime callbacks" do
    uninterrupted_state = start_supervised!({Agent, fn -> counters() end}, id: :simba_full)
    {program, optimizer, trainset, final_set} = fixture(uninterrupted_state)

    uninterrupted =
      optimizer
      |> SIMBA.compile(program, trainset, final_set)
      |> Report.fetch()

    pause_state = start_supervised!({Agent, fn -> counters() end}, id: :simba_pause)
    {pause_program, pause_optimizer, pause_trainset, pause_final_set} = fixture(pause_state)

    checkpoint_fn = fn checkpoint ->
      Agent.update(
        pause_state,
        &Map.update!(&1, :checkpoints, fn values -> values ++ [checkpoint] end)
      )
    end

    paused =
      pause_optimizer
      |> SIMBA.compile(pause_program, pause_trainset, pause_final_set,
        max_steps: 1,
        checkpoint_fn: checkpoint_fn
      )
      |> Report.fetch()

    assert paused.metadata.run_status == :paused
    assert paused.metadata.completed_steps == 1
    assert paused.best_score == nil
    assert paused.metadata.final_candidates == []

    after_pause = Agent.get(pause_state, & &1)
    assert length(after_pause.checkpoints) == 2

    assert Enum.map(after_pause.checkpoints, &get_in(&1, ["payload", "state", "completed_steps"])) ==
             [0, 1]

    assert get_in(Enum.at(after_pause.checkpoints, 0), ["payload", "state", "poisson_rng"]) !=
             get_in(Enum.at(after_pause.checkpoints, 1), ["payload", "state", "poisson_rng"])

    checkpoint = paused.metadata.resume_state |> Jason.encode!() |> Jason.decode!()
    checkpoint_state = checkpoint["payload"]["state"]

    assert checkpoint["type"] == "imp_simba_run"
    assert checkpoint["schema_version"] == 1
    assert is_binary(checkpoint["payload_sha256"])
    assert checkpoint_state["population"]["policy"]
    assert checkpoint_state["poisson_rng"]
    assert checkpoint_state["order"]
    assert checkpoint_state["cursor"] >= 0
    assert checkpoint_state["trajectory_calls"] > 0
    assert checkpoint_state["candidate_evaluation_calls"] > 0
    assert checkpoint_state["final_evaluation_calls"] == 0
    assert checkpoint_state["final_evaluations"] == []
    assert is_list(checkpoint_state["errors"])

    resume_state = start_supervised!({Agent, fn -> counters() end}, id: :simba_resume)
    {resume_program, resume_optimizer, resume_trainset, resume_final_set} = fixture(resume_state)

    resumed =
      resume_optimizer
      |> SIMBA.compile(resume_program, resume_trainset, resume_final_set,
        resume_state: checkpoint
      )
      |> Report.fetch()

    assert Agent.get(pause_state, & &1) == after_pause
    assert Agent.get(resume_state, & &1).task_calls > 0

    assert resumed.metadata.resumed
    assert resumed.metadata.run_status == :complete
    assert resumed.metadata.completed_steps == 3
    assert resumed.candidates == uninterrupted.candidates
    assert resumed.best_score == uninterrupted.best_score
    assert resumed.errors == uninterrupted.errors
    assert resumed.metadata.trial_logs == uninterrupted.metadata.trial_logs
    assert resumed.metadata.final_candidates == uninterrupted.metadata.final_candidates
    assert resumed.metadata.search_policy == uninterrupted.metadata.search_policy
    assert resumed.metadata.trajectory_calls == uninterrupted.metadata.trajectory_calls

    assert resumed.metadata.candidate_evaluation_calls ==
             uninterrupted.metadata.candidate_evaluation_calls

    assert resumed.metadata.final_evaluation_calls ==
             uninterrupted.metadata.final_evaluation_calls

    assert resumed.metadata.budgets == uninterrupted.metadata.budgets
    assert Jason.encode!(resumed.metadata.resume_state)
  end

  test "resume rejects mutated payloads and incompatible datasets" do
    state = start_supervised!({Agent, fn -> counters() end})
    {program, optimizer, trainset, final_set} = fixture(state)

    checkpoint =
      optimizer
      |> SIMBA.compile(program, trainset, final_set, max_steps: 1)
      |> Report.fetch()
      |> then(& &1.metadata.resume_state)
      |> Jason.encode!()
      |> Jason.decode!()

    mutated = put_in(checkpoint, ["payload", "state", "trajectory_calls"], 99_999)

    assert_raise ArgumentError, ~r/checksum does not match its payload/, fn ->
      SIMBA.compile(optimizer, program, trainset, final_set, resume_state: mutated)
    end

    changed_trainset =
      List.replace_at(
        trainset,
        0,
        Imp.example(question: "different", answer: "yes") |> Imp.with_inputs(:question)
      )

    assert_raise ArgumentError,
                 ~r/does not match the program runtime, datasets, or search configuration/,
                 fn ->
                   SIMBA.compile(optimizer, program, changed_trainset, final_set,
                     resume_state: checkpoint
                   )
                 end

    changed_optimizer = %{optimizer | max_demos: 1}

    assert_raise ArgumentError,
                 ~r/does not match the program runtime, datasets, or search configuration/,
                 fn ->
                   SIMBA.compile(changed_optimizer, program, trainset, final_set,
                     resume_state: checkpoint
                   )
                 end
  end

  test "resume rejects task call policy drift before more search work" do
    state = start_supervised!({Agent, fn -> counters() end})
    {program, optimizer, trainset, final_set} = fixture(state)

    checkpoint =
      optimizer
      |> SIMBA.compile(program, trainset, final_set, max_steps: 1)
      |> Report.fetch()
      |> then(& &1.metadata.resume_state)
      |> Jason.encode!()
      |> Jason.decode!()

    calls_before = Agent.get(state, & &1)
    changed = %{program | config: [temperature: 0.75], dynamic_adapter?: false}

    assert_raise ArgumentError,
                 ~r/does not match the program runtime, datasets, or search configuration/,
                 fn ->
                   SIMBA.compile(optimizer, changed, trainset, final_set,
                     resume_state: checkpoint,
                     max_steps: 0
                   )
                 end

    assert Agent.get(state, & &1) == calls_before
  end

  test "resume does not replay completed final evaluations" do
    interrupted_state = start_supervised!({Agent, fn -> counters() end}, id: :simba_interrupted)
    {program, optimizer, trainset, final_set} = fixture(interrupted_state)

    checkpoint_fn = fn checkpoint ->
      Agent.update(
        interrupted_state,
        &Map.update!(&1, :checkpoints, fn values -> values ++ [checkpoint] end)
      )

      if length(checkpoint["payload"]["state"]["final_evaluations"]) == 1 do
        raise "simulated checkpoint interruption"
      end
    end

    assert_raise RuntimeError, "simulated checkpoint interruption", fn ->
      SIMBA.compile(optimizer, program, trainset, final_set, checkpoint_fn: checkpoint_fn)
    end

    checkpoint = interrupted_state |> Agent.get(&List.last(&1.checkpoints)) |> json_round_trip()
    assert length(checkpoint["payload"]["state"]["final_evaluations"]) == 1
    completed_final_calls = checkpoint["payload"]["state"]["final_evaluation_calls"]
    assert completed_final_calls == length(final_set)

    resumed_state = start_supervised!({Agent, fn -> counters() end}, id: :simba_final_resume)

    {resumed_program, resumed_optimizer, resumed_trainset, resumed_final_set} =
      fixture(resumed_state)

    report =
      resumed_optimizer
      |> SIMBA.compile(resumed_program, resumed_trainset, resumed_final_set,
        resume_state: checkpoint
      )
      |> Report.fetch()

    assert report.metadata.run_status == :complete

    assert Agent.get(resumed_state, & &1.task_calls) ==
             report.metadata.final_evaluation_calls - completed_final_calls
  end

  test "declared metric identity permits fresh captures and rejects config drift before work" do
    state = start_supervised!({Agent, fn -> counters() end}, id: :simba_metric_source)
    identity = metric_identity(%{"field" => "answer", "mode" => "exact"})

    {program, optimizer, trainset, final_set} =
      fixture(state, captured_metric(state), identity)

    checkpoint =
      optimizer
      |> SIMBA.compile(program, trainset, final_set, max_steps: 1)
      |> Report.fetch()
      |> then(& &1.metadata.resume_state)
      |> json_round_trip()

    replacement =
      start_supervised!(
        Supervisor.child_spec({Agent, fn -> counters() end}, id: :simba_metric_replacement)
      )

    {_program, drifted, _trainset, _final_set} =
      fixture(
        replacement,
        captured_metric(replacement),
        metric_identity(%{"field" => "answer", "mode" => "case_insensitive"})
      )

    assert_raise ArgumentError,
                 ~r/does not match the program runtime, datasets, or search configuration/,
                 fn ->
                   SIMBA.compile(drifted, program, trainset, final_set,
                     resume_state: checkpoint,
                     max_steps: 0
                   )
                 end

    assert Agent.get(replacement, & &1) == counters()

    {_program, rebound, _trainset, _final_set} =
      fixture(replacement, captured_metric(replacement), identity)

    report =
      rebound
      |> SIMBA.compile(program, trainset, final_set,
        resume_state: checkpoint,
        max_steps: 0
      )
      |> Report.fetch()

    assert report.metadata.resumed
    assert report.metadata.durable
    assert report.metadata.completed_steps == 1
    assert report.metadata.metric_identity["kind"] == "declared"
    assert report.metadata.metric_identity["id"] == "exact-answer"
    assert report.metadata.metric_identity["version"] == 1
    assert report.metadata.metric_identity["config_sha256"] =~ "sha256:"
    refute Map.has_key?(report.metadata.metric_identity, "config")
  end

  test "durable anonymous metric without declared identity fails before work" do
    state = start_supervised!({Agent, fn -> counters() end})
    owner = self()

    metric = fn example, prediction ->
      send(owner, :metric_called)
      exact_metric(example, prediction)
    end

    {program, optimizer, trainset, final_set} = fixture(state, metric, nil)

    assert_raise ArgumentError, ~r/requires :metric_identity/, fn ->
      SIMBA.compile(optimizer, program, trainset, final_set, max_steps: 1)
    end

    assert Agent.get(state, & &1) == counters()
    refute_received :metric_called
  end

  test "anonymous metric may complete in process without durable state" do
    state = start_supervised!({Agent, fn -> counters() end})

    {program, optimizer, trainset, final_set} =
      fixture(state, Imp.Metrics.exact_match(:answer), nil)

    report = optimizer |> SIMBA.compile(program, trainset, final_set) |> Report.fetch()

    refute report.metadata.durable
    assert is_nil(report.metadata.metric_identity)
    assert is_nil(report.metadata.resume_state)
    assert report.metadata.run_status == :complete
  end

  test "external named metric derives durable identity" do
    state = start_supervised!({Agent, fn -> counters() end})
    {program, optimizer, trainset, final_set} = fixture(state, &__MODULE__.exact_metric/2, nil)

    report = optimizer |> SIMBA.compile(program, trainset, final_set) |> Report.fetch()

    assert report.metadata.durable

    assert report.metadata.metric_identity == %{
             "arity" => 2,
             "kind" => "external_function",
             "module" => Atom.to_string(__MODULE__),
             "name" => "exact_metric"
           }

    assert is_map(report.metadata.resume_state)
  end

  test "metric identity is strict JSON-safe data" do
    assert_raise ArgumentError, ~r/already JSON-safe config/, fn ->
      SIMBA.new(&__MODULE__.exact_metric/2,
        metric_identity: metric_identity(%{"field" => :answer})
      )
    end

    assert_raise ArgumentError, ~r/use string keys/, fn ->
      SIMBA.new(&__MODULE__.exact_metric/2,
        metric_identity: %{id: "exact-answer", version: 1, config: %{}}
      )
    end

    assert_raise ArgumentError, ~r/contain exactly/, fn ->
      SIMBA.new(&__MODULE__.exact_metric/2,
        metric_identity: %{
          "id" => "exact-answer",
          "version" => 1,
          "config" => %{},
          "extra" => true
        }
      )
    end
  end

  @tag :tmp_dir
  test "fresh OS resumes declared captures and refuses config drift before work", %{
    tmp_dir: tmp_dir
  } do
    checkpoint = Path.join(tmp_dir, "checkpoint.json")
    created = Path.join(tmp_dir, "created.json")
    resumed = Path.join(tmp_dir, "resumed.json")
    refused = Path.join(tmp_dir, "refused.json")

    assert {output, 0} = fresh_os(["create", checkpoint, created])
    assert output == ""
    assert File.exists?(checkpoint)

    assert {output, 0} = fresh_os(["resume", checkpoint, resumed, "same"])
    assert output == ""

    resumed_result = resumed |> File.read!() |> Jason.decode!()
    assert resumed_result["status"] == "resumed"
    assert resumed_result["resumed"]
    assert resumed_result["completed_steps"] == 1
    assert resumed_result["counters"] == %{"task_calls" => 0, "prompt_calls" => 0}

    assert {_output, 2} = fresh_os(["resume", checkpoint, refused, "drift"])
    refused_result = refused |> File.read!() |> Jason.decode!()
    assert refused_result["status"] == "refused"
    assert refused_result["error"] =~ "does not match the program runtime"
    assert refused_result["counters"] == %{"task_calls" => 0, "prompt_calls" => 0}
  end

  defp captured_metric(state) do
    fn example, prediction ->
      _ = Agent.get(state, & &1.task_calls)
      exact_metric(example, prediction)
    end
  end

  defp fixture(state, metric \\ Imp.Metrics.exact_match(:answer), identity \\ metric_identity()) do
    task_lm =
      Imp.LM.Static.new(
        handler: fn messages, opts ->
          Agent.update(state, &Map.update!(&1, :task_calls, fn count -> count + 1 end))
          prompt = Enum.map_join(messages, "\n", & &1.content)
          rollout_id = Keyword.get(opts, :rollout_id, 0)

          if prompt =~ "Answer yes." or rem(rollout_id, 2) == 0,
            do: %{answer: "yes"},
            else: %{answer: "no"}
        end
      )

    prompt_lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          Agent.update(state, &Map.update!(&1, :prompt_calls, fn count -> count + 1 end))

          %{
            discussion: "Prefer the successful trajectory.",
            module_advice: %{main: "Answer yes."}
          }
        end
      )

    initial_demo =
      Imp.example(question: "seed", answer: "yes") |> Imp.with_inputs(:question)

    program = Imp.predict("question -> answer", lm: task_lm, demos: [initial_demo])

    trainset =
      for index <- 1..4 do
        Imp.example(question: "train #{index}", answer: "yes") |> Imp.with_inputs(:question)
      end

    final_set =
      for index <- 1..2 do
        Imp.example(question: "final #{index}", answer: "yes") |> Imp.with_inputs(:question)
      end

    optimizer =
      SIMBA.new(metric,
        bsize: 2,
        num_candidates: 2,
        max_steps: 3,
        max_demos: 0,
        prompt_lm: prompt_lm,
        max_concurrency: 1,
        seed: 41,
        metric_identity: identity
      )

    {program, optimizer, trainset, final_set}
  end

  defp counters, do: %{task_calls: 0, prompt_calls: 0, checkpoints: []}

  defp metric_identity(config \\ %{"field" => "answer"}) do
    %{"id" => "exact-answer", "version" => 1, "config" => config}
  end

  defp fresh_os(args) do
    expression = """
    case Imp.Test.SIMBAMetricResumeOS.run(System.argv()) do
      :ok -> :ok
      {:error, _error} -> System.halt(2)
    end
    """

    System.cmd("mix", ["run", "--no-compile", "--no-deps-check", "-e", expression, "--" | args],
      cd: File.cwd!(),
      env: [{"MIX_ENV", "test"}],
      stderr_to_stdout: true
    )
  end

  defp json_round_trip(value), do: value |> Jason.encode!() |> Jason.decode!()
end
