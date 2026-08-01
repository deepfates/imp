defmodule Imp.Optimizer.MIPROv2.ResumeTest do
  use ExUnit.Case, async: false

  alias Imp.Optimizer.{MIPROv2, Report}

  def exact_metric(example, prediction),
    do: Imp.Metrics.exact_match(:answer).(example, prediction)

  setup do
    state =
      start_supervised!({Agent, fn -> %{proposal_calls: 0, task_calls: 0, checkpoints: []} end})

    %{state: state}
  end

  test "JSON checkpoint resume matches an uninterrupted run without replaying setup", %{
    state: state
  } do
    {program, optimizer, trainset, valset} = fixture(state)

    uninterrupted =
      optimizer
      |> MIPROv2.compile(program, trainset, valset)
      |> Report.fetch()

    Agent.update(state, fn _ -> %{proposal_calls: 0, task_calls: 0, checkpoints: []} end)

    checkpoint_fn = fn checkpoint ->
      Agent.update(state, fn snapshot ->
        %{snapshot | checkpoints: snapshot.checkpoints ++ [checkpoint]}
      end)
    end

    paused =
      optimizer
      |> MIPROv2.compile(program, trainset, valset,
        max_trials: 2,
        checkpoint_fn: checkpoint_fn
      )
      |> Report.fetch()

    assert paused.metadata.run_status == :paused
    assert paused.metadata.completed_trials == 2
    assert paused.candidate_count == 2

    state_after_pause = Agent.get(state, & &1)
    assert length(state_after_pause.checkpoints) == 3

    assert Enum.map(state_after_pause.checkpoints, fn checkpoint ->
             length(checkpoint["payload"]["state"]["trials"])
           end) == [0, 1, 2]

    resume_state = paused.metadata.resume_state |> Jason.encode!() |> Jason.decode!()

    resumed =
      optimizer
      |> MIPROv2.compile(program, trainset, valset,
        resume_state: resume_state,
        checkpoint_fn: checkpoint_fn
      )
      |> Report.fetch()

    state_after_resume = Agent.get(state, & &1)

    assert state_after_resume.proposal_calls == state_after_pause.proposal_calls
    assert length(state_after_resume.checkpoints) == 7
    assert resumed.metadata.resumed
    assert resumed.metadata.run_status == :complete
    assert resumed.metadata.completed_trials == 6
    assert resumed.candidates == uninterrupted.candidates
    assert resumed.best_score == uninterrupted.best_score
    assert resumed.metadata.full_evaluations == uninterrupted.metadata.full_evaluations
    assert resumed.metadata.search_policy == uninterrupted.metadata.search_policy
    assert resumed.metadata.evaluation_calls == uninterrupted.metadata.evaluation_calls
    assert Jason.encode!(resumed.metadata.resume_state)
  end

  test "schema-one BEAM RNG checkpoints remain resumable", %{state: state} do
    {program, optimizer, trainset, valset} = fixture(state)

    checkpoint =
      optimizer
      |> MIPROv2.compile(program, trainset, valset, max_trials: 2)
      |> Report.fetch()
      |> then(& &1.metadata.resume_state)

    legacy_payload =
      put_in(
        checkpoint["payload"],
        ["state", "rng"],
        get_in(checkpoint, ["payload", "state", "rng", "state"])
      )

    legacy = %{
      checkpoint
      | "schema_version" => 1,
        "payload" => legacy_payload,
        "payload_sha256" => checkpoint_checksum(legacy_payload)
    }

    resumed =
      MIPROv2.compile(optimizer, program, trainset, valset,
        resume_state: Jason.decode!(Jason.encode!(legacy))
      )
      |> Report.fetch()

    assert resumed.metadata.resumed
    assert resumed.metadata.run_status == :complete
    assert resumed.metadata.completed_trials == 6
  end

  test "resume rejects a different resolved dataset", %{state: state} do
    {program, optimizer, trainset, valset} = fixture(state)

    checkpoint =
      optimizer
      |> MIPROv2.compile(program, trainset, valset, max_trials: 1)
      |> Report.fetch()
      |> then(& &1.metadata.resume_state)
      |> Jason.encode!()
      |> Jason.decode!()

    changed_valset = [
      Imp.example(question: "different", answer: "yes") |> Imp.with_inputs(:question)
    ]

    assert_raise ArgumentError,
                 ~r/does not match the program runtime, datasets, or search configuration/,
                 fn ->
                   MIPROv2.compile(optimizer, program, trainset, changed_valset,
                     resume_state: checkpoint
                   )
                 end
  end

  test "resume rejects task runtime and predictor parameter drift", %{state: state} do
    {program, optimizer, trainset, valset} = fixture(state)

    checkpoint =
      optimizer
      |> MIPROv2.compile(program, trainset, valset, max_trials: 1)
      |> Report.fetch()
      |> then(& &1.metadata.resume_state)
      |> Jason.encode!()
      |> Jason.decode!()

    changed_lm = %{
      program.lm
      | opts: Keyword.put(program.lm.opts, :endpoint, "https://changed.invalid")
    }

    changed_runtime = %{program | lm: changed_lm}

    assert_raise ArgumentError,
                 ~r/does not match the program runtime, datasets, or search configuration/,
                 fn ->
                   MIPROv2.compile(optimizer, changed_runtime, trainset, valset,
                     resume_state: checkpoint,
                     max_trials: 0
                   )
                 end

    changed_parameters = %{program | config: [temperature: 0.25]}

    assert_raise ArgumentError,
                 ~r/does not match the program runtime, datasets, or search configuration/,
                 fn ->
                   MIPROv2.compile(optimizer, changed_parameters, trainset, valset,
                     resume_state: checkpoint,
                     max_trials: 0
                   )
                 end
  end

  test "resume permits credential rotation while retaining task runtime identity", %{state: state} do
    {program, optimizer, trainset, valset} = fixture(state)

    program = %{
      program
      | lm:
          program.lm
          |> put_lm_option(:api_key, "credential-before")
          |> put_lm_option(:headers, [
            {"authorization", "Bearer credential-before"},
            {"x-runtime-profile", "stable"}
          ])
    }

    checkpoint =
      optimizer
      |> MIPROv2.compile(program, trainset, valset, max_trials: 1)
      |> Report.fetch()
      |> then(& &1.metadata.resume_state)
      |> Jason.encode!()
      |> Jason.decode!()

    refute Jason.encode!(checkpoint) =~ "credential-before"

    rebound = %{
      program
      | lm:
          program.lm
          |> put_lm_option(:api_key, "credential-after")
          |> put_lm_option(:headers, [
            {"authorization", "Bearer credential-after"},
            {"x-runtime-profile", "stable"}
          ])
    }

    report =
      optimizer
      |> MIPROv2.compile(rebound, trainset, valset,
        resume_state: checkpoint,
        max_trials: 0
      )
      |> Report.fetch()

    assert report.metadata.resumed
    assert report.metadata.completed_trials == 1
  end

  test "resume rejects a mutated checkpoint payload", %{state: state} do
    {program, optimizer, trainset, valset} = fixture(state)

    checkpoint =
      optimizer
      |> MIPROv2.compile(program, trainset, valset, max_trials: 1)
      |> Report.fetch()
      |> then(& &1.metadata.resume_state)
      |> put_in(["payload", "state", "evaluation_calls"], 99_999)

    assert_raise ArgumentError, ~r/checksum does not match its payload/, fn ->
      MIPROv2.compile(optimizer, program, trainset, valset, resume_state: checkpoint)
    end
  end

  test "declared metric identity permits a fresh capture but refuses config drift", %{
    state: state
  } do
    identity = metric_identity(%{"field" => "answer", "mode" => "exact"})
    {program, optimizer, trainset, valset} = fixture(state, captured_metric(state), identity)

    checkpoint =
      optimizer
      |> MIPROv2.compile(program, trainset, valset, max_trials: 1)
      |> Report.fetch()
      |> then(& &1.metadata.resume_state)
      |> Jason.encode!()
      |> Jason.decode!()

    replacement_state =
      start_supervised!(
        Supervisor.child_spec(
          {Agent, fn -> %{proposal_calls: 0, task_calls: 0, checkpoints: []} end},
          id: :replacement_callback_state
        )
      )

    {_program, drifted_optimizer, _trainset, _valset} =
      fixture(
        replacement_state,
        captured_metric(replacement_state),
        metric_identity(%{"field" => "answer", "mode" => "case_insensitive"})
      )

    assert_raise ArgumentError,
                 ~r/does not match the program runtime, datasets, or search configuration/,
                 fn ->
                   MIPROv2.compile(drifted_optimizer, program, trainset, valset,
                     resume_state: checkpoint,
                     max_trials: 0
                   )
                 end

    assert Agent.get(replacement_state, & &1.proposal_calls) == 0
    assert Agent.get(replacement_state, & &1.task_calls) == 0

    {_program, rebound_optimizer, _trainset, _valset} =
      fixture(replacement_state, captured_metric(replacement_state), identity)

    report =
      rebound_optimizer
      |> MIPROv2.compile(program, trainset, valset, resume_state: checkpoint, max_trials: 0)
      |> Report.fetch()

    assert report.metadata.resumed
    assert report.metadata.completed_trials == 1
    assert report.metadata.metric_identity["kind"] == "declared"
    assert report.metadata.metric_identity["id"] == "exact-answer"
    assert report.metadata.metric_identity["version"] == 1
    assert report.metadata.metric_identity["config_sha256"] =~ "sha256:"
    refute Map.has_key?(report.metadata.metric_identity, "config")
  end

  test "durable anonymous metric without declared identity fails before setup", %{state: state} do
    owner = self()

    metric = fn example, prediction ->
      send(owner, :metric_called)
      exact_metric(example, prediction)
    end

    {program, optimizer, trainset, valset} = fixture(state, metric, nil)

    assert_raise ArgumentError, ~r/requires :metric_identity/, fn ->
      MIPROv2.compile(optimizer, program, trainset, valset, max_trials: 1)
    end

    assert Agent.get(state, & &1.proposal_calls) == 0
    assert Agent.get(state, & &1.task_calls) == 0
    refute_received :metric_called
  end

  test "anonymous metric may run explicitly without durable controls", %{state: state} do
    {program, optimizer, trainset, valset} =
      fixture(state, Imp.Metrics.exact_match(:answer), nil)

    report = optimizer |> MIPROv2.compile(program, trainset, valset) |> Report.fetch()

    refute report.metadata.durable
    assert is_nil(report.metadata.metric_identity)
    assert is_nil(report.metadata.resume_state)
    assert report.metadata.run_status == :complete
  end

  test "external named metric derives a durable identity", %{state: state} do
    {program, optimizer, trainset, valset} = fixture(state, &__MODULE__.exact_metric/2, nil)

    report = optimizer |> MIPROv2.compile(program, trainset, valset) |> Report.fetch()

    assert report.metadata.durable

    assert report.metadata.metric_identity == %{
             "arity" => 2,
             "kind" => "external_function",
             "module" => Atom.to_string(__MODULE__),
             "name" => "exact_metric"
           }

    assert is_map(report.metadata.resume_state)
  end

  test "metric identity must be explicit JSON-safe data" do
    assert_raise ArgumentError, ~r/already JSON-safe config/, fn ->
      MIPROv2.new(&__MODULE__.exact_metric/2,
        metric_identity: metric_identity(%{"field" => :answer})
      )
    end

    assert_raise ArgumentError, ~r/use string keys/, fn ->
      MIPROv2.new(&__MODULE__.exact_metric/2,
        metric_identity: %{id: "exact-answer", version: 1, config: %{}}
      )
    end

    assert_raise ArgumentError, ~r/contain exactly/, fn ->
      MIPROv2.new(&__MODULE__.exact_metric/2,
        metric_identity: %{
          "id" => "exact-answer",
          "version" => 1,
          "config" => %{},
          "extra" => true
        }
      )
    end
  end

  defp captured_metric(state) do
    fn example, prediction ->
      _ = Agent.get(state, & &1.proposal_calls)
      Imp.Metrics.exact_match(:answer).(example, prediction)
    end
  end

  defp fixture(
         state,
         metric \\ Imp.Metrics.exact_match(:answer),
         identity \\ metric_identity()
       ) do
    task_lm = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn _messages, _opts ->
          Agent.update(state, &Map.update!(&1, :task_calls, fn count -> count + 1 end))
          %{answer: "yes"}
        end
      ]
    }

    prompt_lm = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn _messages, _opts ->
          Agent.update(
            state,
            &Map.update!(&1, :proposal_calls, fn count -> count + 1 end)
          )

          ["Answer consistently.", "Return yes.", "Use the demonstrations."]
        end
      ]
    }

    program = Imp.predict("question -> answer", lm: task_lm)

    trainset =
      for index <- 1..3 do
        Imp.example(question: "train #{index}", answer: "yes") |> Imp.with_inputs(:question)
      end

    valset =
      for index <- 1..2 do
        Imp.example(question: "val #{index}", answer: "yes") |> Imp.with_inputs(:question)
      end

    optimizer =
      MIPROv2.new(metric,
        auto: nil,
        num_candidates: 3,
        num_trials: 6,
        max_bootstrapped_demos: 0,
        max_labeled_demos: 1,
        minibatch: true,
        minibatch_size: 1,
        minibatch_full_eval_steps: 2,
        prompt_lm: prompt_lm,
        metric_identity: identity,
        startup_trials: 1,
        seed: 31
      )

    {program, optimizer, trainset, valset}
  end

  defp metric_identity(config \\ %{"field" => "answer"}) do
    %{"id" => "exact-answer", "version" => 1, "config" => config}
  end

  defp checkpoint_checksum(payload) do
    payload
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp put_lm_option(%{opts: opts} = lm, key, value),
    do: %{lm | opts: Keyword.put(opts, key, value)}
end
