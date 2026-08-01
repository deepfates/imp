defmodule Imp.Optimizer.MIPROv2.OptunaStartupSearchTest do
  use ExUnit.Case, async: false

  alias Imp.Optimizer.MIPROv2
  alias Imp.OperationalSafetyError
  alias Imp.Optimizer.MIPROv2.{OptunaStartupPolicy, OptunaTPEPolicy}
  alias Imp.Optimizer.MIPROv2.PythonRandom
  alias Imp.Optimizer.{Report, SearchPolicy}

  @python "tmp/dspy-parity-venv/bin/python"
  @runner "test/support/dspy_3_2_1_optuna_startup_tape.py"
  @schedules %{
    2_026_072_602 => [5, 0, 0, 4, 2, 2, 0, 4, 1],
    2_026_072_603 => [1, 5, 0, 3, 3, 5, 4, 4, 0],
    2_026_072_604 => [3, 4, 1, 4, 2, 0, 2, 1, 0]
  }

  def metric(expected, prediction),
    do: Imp.get(expected, :route) == Imp.get(prediction, :route)

  test "pinned startup policy reproduces all three sealed Optuna schedules" do
    Enum.each(@schedules, fn {seed, expected} ->
      assert startup_schedule(seed) == expected
    end)
  end

  test "Python-compatible sampling reproduces CPython Random.sample" do
    for {seed, count, expected} <- [
          {0, 3, [6, 9, 0]},
          {0, 8, [6, 9, 0, 2, 4, 3, 5, 1]},
          {9, 3, [7, 5, 4]},
          {31, 8, [0, 7, 1, 6, 3, 8, 9, 5]}
        ] do
      assert {^expected, %PythonRandom{}} =
               PythonRandom.sample(PythonRandom.new(seed), Enum.to_list(0..9), count)
    end
  end

  test "Python-compatible RNG checkpoint resumes the exact sample stream" do
    {first, rng} = PythonRandom.sample(PythonRandom.new(9), Enum.to_list(0..19), 7)

    loaded =
      rng |> PythonRandom.dump() |> Jason.encode!() |> Jason.decode!() |> PythonRandom.load!()

    {second, _rng} = PythonRandom.sample(loaded, Enum.to_list(0..19), 7)

    {expected_first, uninterrupted} =
      PythonRandom.sample(PythonRandom.new(9), Enum.to_list(0..19), 7)

    {expected_second, _uninterrupted} =
      PythonRandom.sample(uninterrupted, Enum.to_list(0..19), 7)

    assert {first, second} == {expected_first, expected_second}
  end

  @tag :evidence_infrastructure
  test "three sealed schedules match independently executed Optuna 4.9.0" do
    {output, 0} =
      System.cmd(Path.expand(@python), [Path.expand(@runner)], stderr_to_stdout: false)

    upstream = Jason.decode!(output)
    assert upstream["optuna"] == "4.9.0"

    assert upstream["schedules"] ==
             Map.new(@schedules, fn {seed, schedule} -> {Integer.to_string(seed), schedule} end)

    assert Map.new(@schedules, fn {seed, _schedule} ->
             {Integer.to_string(seed), startup_schedule(seed)}
           end) == upstream["schedules"]
  end

  @tag :evidence_infrastructure
  test "two-predictor categorical space and startup stream match Optuna 4.9.0" do
    {output, 0} =
      System.cmd(Path.expand(@python), [Path.expand(@runner)], stderr_to_stdout: false)

    upstream = Jason.decode!(output)

    predictors = [%{name: :first}, %{name: :second}]
    candidates = %{first: Enum.to_list(0..3), second: Enum.to_list(0..3)}

    assert MIPROv2.categorical_space(predictors, candidates, nil) == %{
             "atom:first:instruction" => [0, 1, 2, 3],
             "atom:second:instruction" => [0, 1, 2, 3]
           }

    Enum.each(@schedules, fn {seed, _one_parameter_schedule} ->
      expected = upstream["two_parameter_schedules"][Integer.to_string(seed)]
      assert two_parameter_startup_schedule(seed) == expected
    end)
  end

  test "policy JSON checkpoint resumes the exact remaining startup stream" do
    policy = new_policy(2_026_072_602)
    {first, policy} = take_suggestions(policy, 4)
    dumped = SearchPolicy.dump(policy)
    loaded = SearchPolicy.load!(dumped, [OptunaStartupPolicy])
    {rest, loaded} = take_suggestions(loaded, 5)

    assert first ++ rest == @schedules[2_026_072_602]
    assert SearchPolicy.dump(loaded)["state"]["completed_trials"] == 10

    assert SearchPolicy.dump(loaded)["state"]["rng"]["algorithm"] ==
             "numpy_random_state_mt19937"
  end

  @tag :evidence_infrastructure
  test "modeled categorical TPE matches Optuna through startup and first Bayesian trial" do
    {output, 0} =
      System.cmd(Path.expand(@python), [Path.expand(@runner)], stderr_to_stdout: false)

    upstream = Jason.decode!(output)

    Enum.each(@schedules, fn {seed, _startup} ->
      for {parameter_count, key} <- [{1, "one_parameter"}, {2, "two_parameter"}] do
        expected = upstream["modeled_schedules"][Integer.to_string(seed)][key]

        assert Enum.take(modeled_schedule(seed, parameter_count, expected), 10) ==
                 Enum.take(expected, 10)
      end
    end)
  end

  test "modeled policy checkpoint resumes without replay or RNG drift" do
    upstream = upstream_modeled_schedule(2_026_072_602, "two_parameter")
    policy = new_modeled_policy(2_026_072_602, 2)
    {first, policy} = drive_modeled(policy, Enum.take(upstream, 11))

    loaded =
      policy
      |> SearchPolicy.dump()
      |> SearchPolicy.load!([OptunaTPEPolicy])

    {rest, loaded} = drive_modeled(loaded, Enum.drop(upstream, 11))

    assert first ++ rest == Enum.map(upstream, & &1["params"])
    assert length(SearchPolicy.dump(loaded)["state"]["observations"]) == 16
  end

  test "public MIPRO checkpoint binds exact policy and resumes without replay" do
    {prompt_lm, prompt_agent} = prompt_lm(6)
    task_lm = Imp.LM.Static.new(handler: fn _messages, _opts -> %{route: "K11"} end)
    source = program(task_lm)
    optimizer = exact_optimizer(prompt_lm, task_lm, num_trials: 9)

    paused = MIPROv2.compile(optimizer, source, trainset(), valset(), max_trials: 4)
    paused_report = Report.fetch(paused)
    checkpoint = paused_report.metadata.resume_state

    assert paused_report.metadata.run_status == :paused

    assert get_in(checkpoint, ["payload", "state", "policy", "policy"]) ==
             "dspy_3_2_1_optuna_4_9_0_startup"

    assert Agent.get(prompt_agent, & &1) == []

    resumed =
      MIPROv2.compile(optimizer, source, trainset(), valset(),
        resume_state: checkpoint,
        max_trials: 5
      )

    report = Report.fetch(resumed)

    assert report.metadata.run_status == :complete

    assert Enum.map(report.candidates, & &1.params["atom:main:instruction"]) ==
             [1, 5, 0, 4, 2, 2, 0, 2, 0]

    assert Agent.get(prompt_agent, & &1) == []

    beam_native =
      MIPROv2.new(&__MODULE__.metric/2,
        auto: nil,
        num_candidates: 6,
        num_trials: 9,
        max_bootstrapped_demos: 0,
        max_labeled_demos: 0,
        minibatch: false,
        prompt_lm: prompt_lm,
        task_lm: task_lm,
        program_aware_proposer: false,
        data_aware_proposer: true,
        tip_aware_proposer: true,
        fewshot_aware_proposer: false,
        proposer_fidelity: :dspy_3_2_1,
        search_fidelity: :beam_native,
        seed: 9
      )

    assert_raise ArgumentError, ~r/resume state does not match/, fn ->
      MIPROv2.compile(beam_native, source, trainset(), valset(),
        resume_state: checkpoint,
        max_trials: 0
      )
    end
  end

  test "startup-only mode rejects modeled TPE entry and runtime drift before setup calls" do
    owner = self()

    prompt_lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          send(owner, :unexpected_prompt_call)
          %{summary: "not reached"}
        end
      )

    task_lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          send(owner, :unexpected_task_call)
          %{route: "K11"}
        end
      )

    assert_raise ArgumentError, ~r/modeled TPE is not implemented/, fn ->
      exact_optimizer(prompt_lm, task_lm, num_trials: 10)
      |> MIPROv2.compile(program(task_lm), trainset(), valset())
    end

    refute_received :unexpected_prompt_call
    refute_received :unexpected_task_call

    assert_raise ArgumentError, ~r/requires startup_trials: 10/, fn ->
      exact_optimizer(prompt_lm, task_lm, startup_trials: 9)
      |> MIPROv2.compile(program(task_lm), trainset(), valset())
    end

    assert_raise ArgumentError, ~r/requires max_concurrency: 1/, fn ->
      exact_optimizer(prompt_lm, task_lm, max_concurrency: 2)
      |> MIPROv2.compile(program(task_lm), trainset(), valset())
    end

    assert_raise ArgumentError, ~r/seed must be at most/, fn ->
      exact_optimizer(prompt_lm, task_lm, seed: 4_294_967_296)
      |> MIPROv2.compile(program(task_lm), trainset(), valset())
    end

    refute_received :unexpected_prompt_call
    refute_received :unexpected_task_call
  end

  test "public MIPRO compile crosses from startup into pinned modeled TPE" do
    {prompt_lm, prompt_agent} = prompt_lm(4)
    task_lm = Imp.LM.Static.new(handler: fn _messages, _opts -> %{route: "K11"} end)

    compiled =
      exact_optimizer(prompt_lm, task_lm,
        num_candidates: 4,
        num_trials: 15,
        search_fidelity: :dspy_3_2_1_optuna_4_9_0
      )
      |> MIPROv2.compile(program(task_lm), trainset(), valset())

    report = Report.fetch(compiled)

    {output, 0} =
      System.cmd(Path.expand(@python), [Path.expand(@runner)], stderr_to_stdout: false)

    expected = Jason.decode!(output)["constant_modeled_schedule"]

    assert Enum.map(report.candidates, & &1.params["atom:main:instruction"]) ==
             Enum.map(expected, & &1["params"]["0_predictor_instruction"])

    assert report.metadata.sampler == :optuna_4_9_0_multivariate_categorical_tpe
    refute report.metadata.exact_sampler_sequence_parity

    assert report.metadata.exact_sampler_sequence_scope ==
             :modeled_categorical_tpe_with_beam_float_tie_breaking

    assert Agent.get(prompt_agent, & &1) == []
  end

  test "matched compile keeps first full-evaluation winner on ties and reports exact scope" do
    {prompt_lm, prompt_agent} = prompt_lm(6)
    task_lm = Imp.LM.Static.new(handler: fn _messages, _opts -> %{route: "K11"} end)
    source = program(task_lm)

    compiled =
      exact_optimizer(prompt_lm, task_lm, num_trials: 1)
      |> MIPROv2.compile(source, trainset(), valset())

    report = Report.fetch(compiled)
    assert report.best_score == 1.0
    assert instruction(compiled) == instruction(source)
    assert report.metadata.sampler == :optuna_4_9_0_startup_random
    assert report.metadata.exact_sampler_sequence_parity
    assert report.metadata.exact_sampler_sequence_scope == :startup_only_before_modeled_tpe
    assert report.metadata.upstream_release == "DSPy 3.2.1"
    assert report.metadata.upstream_commit == "29448ae12756abdd14bd8796c819247ebb83673c"
    assert report.metadata.optuna_release == "4.9.0"
    assert Agent.get(prompt_agent, & &1) == []
  end

  test "ordinary task parse failures score zero and leave later trials eligible" do
    {prompt_lm, prompt_agent} = prompt_lm(6)

    validation_calls =
      start_supervised!({Agent, fn -> 0 end}, id: {:parse_validation_calls, self()})

    task_lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          if inspect(messages) =~ "validation" do
            Agent.update(validation_calls, &(&1 + 1))

            {:error,
             %Imp.AdapterParseError{
               message: "missing route marker",
               reason: :missing_output_field
             }}
          else
            %{route: "K11"}
          end
        end
      )

    compiled =
      exact_optimizer(prompt_lm, task_lm, num_trials: 1, max_errors: 0)
      |> MIPROv2.compile(program(task_lm), trainset(), valset())

    report = Report.fetch(compiled)
    assert report.best_score == 0.0
    assert report.candidate_count == 1
    assert Enum.map(report.metadata.full_evaluations, & &1.score) == [0.0, 0.0]
    assert length(report.errors) == 2
    assert Agent.get(validation_calls, & &1) == 2
    assert Agent.get(prompt_agent, & &1) == []
  end

  test "explicit operational safety failures propagate instead of becoming trial zeroes" do
    {prompt_lm, _prompt_agent} = prompt_lm(6)

    validation_calls =
      start_supervised!({Agent, fn -> 0 end}, id: {:safety_validation_calls, self()})

    task_lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          if inspect(messages) =~ "validation" do
            Agent.update(validation_calls, &(&1 + 1))

            MIPROv2.operational_error(:cost, :nonzero_provider_cost,
              message: "provider cost guard drift"
            )
          else
            %{route: "K11"}
          end
        end
      )

    assert_raise OperationalSafetyError, ~r/provider cost guard drift/, fn ->
      exact_optimizer(prompt_lm, task_lm, num_trials: 1, max_errors: :infinity)
      |> MIPROv2.compile(program(task_lm), trainset(), valset())
    end

    assert Agent.get(validation_calls, & &1) == 1
  end

  test "pinned default contains one bootstrap failure and still enters search" do
    {prompt_lm, prompt_agent} = prompt_lm(4)
    task_calls = start_supervised!({Agent, fn -> 0 end}, id: {:finite_task_calls, self()})

    task_lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          call = Agent.get_and_update(task_calls, &{&1, &1 + 1})

          if call == 0,
            do: {:error, {:adapter_error, %{reason: :first_bootstrap_failure}}},
            else: %{route: "K11"}
        end
      )

    compiled =
      exact_optimizer(prompt_lm, task_lm,
        num_candidates: 4,
        num_trials: 1,
        max_errors: 10
      )
      |> MIPROv2.compile(program(task_lm), trainset(), valset())

    report = Report.fetch(compiled)
    assert report.metadata.completed_trials == 1
    assert report.metadata.bootstrap.trajectory_count == 8
    assert report.metadata.bootstrap.accepted_count == 7
    assert report.metadata.bootstrap.rejected_count == 1

    assert [failure] = report.metadata.bootstrap.errors
    assert failure.stage == :bootstrap

    assert failure.reason ==
             {:invalid_lm_result, {:error, {:adapter_error, %{reason: :first_bootstrap_failure}}}}

    assert report.errors == [failure]
    assert report.metadata.status == :with_errors
    assert Agent.get(prompt_agent, & &1) == []
  end

  test "Experiment completes through MIPRO after one contained bootstrap failure" do
    {prompt_lm, prompt_agent} = prompt_lm(4)
    task_calls = start_supervised!({Agent, fn -> 0 end}, id: {:experiment_task_calls, self()})

    task_lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          if inspect(messages) =~ "request-" do
            call = Agent.get_and_update(task_calls, &{&1, &1 + 1})

            if call == 0,
              do: {:error, {:adapter_error, %{reason: :first_bootstrap_failure}}},
              else: %{route: "K11"}
          else
            %{route: "K11"}
          end
        end
      )

    data =
      Imp.Experiment.Data.new(
        train: trainset(),
        selection:
          Enum.map(0..1, fn index ->
            Imp.example(text: "selection-#{index}", route: "K11") |> Imp.with_inputs(:text)
          end),
        test:
          Enum.map(0..1, fn index ->
            Imp.example(text: "test-#{index}", route: "K11") |> Imp.with_inputs(:text)
          end)
      )

    optimizer =
      exact_optimizer(prompt_lm, task_lm,
        num_candidates: 4,
        num_trials: 1,
        max_errors: 10
      )

    assert {:ok, result} =
             Imp.Experiment.check(program(task_lm), optimizer, data, &__MODULE__.metric/2,
               evaluation_options: [max_errors: :infinity, max_concurrency: 1]
             )

    assert result.selected == :baseline
    assert result.baseline_selection.score == 1.0
    assert result.optimized_selection.score == 1.0
    assert result.test.score == 1.0
    assert Agent.get(prompt_agent, & &1) == []
  end

  test "pinned default stops bootstrap at ten failures with structured diagnostics" do
    {prompt_lm, prompt_agent} = prompt_lm(4)
    task_calls = start_supervised!({Agent, fn -> 0 end}, id: {:exhausted_task_calls, self()})

    task_lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          call = Agent.get_and_update(task_calls, &{&1 + 1, &1 + 1})
          {:error, {:adapter_error, %{call: call, reason: :bootstrap_failure}}}
        end
      )

    error =
      assert_raise Imp.EvaluationCancelledError, fn ->
        exact_optimizer(prompt_lm, task_lm,
          num_candidates: 4,
          num_trials: 1,
          max_errors: 10
        )
        |> MIPROv2.compile(program(task_lm), trainset(), valset())
      end

    assert error.max_errors == 10
    assert length(error.rows) == 10
    assert length(error.errors) == 10
    assert Enum.map(error.errors, & &1.index) == Enum.to_list(0..9)
    assert Enum.all?(error.errors, &(&1.stage == :mipro_bootstrap))
    assert Agent.get(task_calls, & &1) == 10
    assert Agent.get(prompt_agent, & &1) != []
  end

  test "pinned default contains an exhausted candidate evaluation as score zero" do
    {prompt_lm, prompt_agent} = prompt_lm(4)

    task_lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          if inspect(messages) =~ "validation-" do
            {:error, {:adapter_error, %{reason: :validation_failure}}}
          else
            %{route: "K11"}
          end
        end
      )

    validation =
      Enum.map(0..11, fn index ->
        Imp.example(text: "validation-#{index}", route: "K11") |> Imp.with_inputs(:text)
      end)

    compiled =
      exact_optimizer(prompt_lm, task_lm,
        num_candidates: 4,
        num_trials: 1,
        max_errors: 10
      )
      |> MIPROv2.compile(program(task_lm), trainset(), validation)

    report = Report.fetch(compiled)
    assert Enum.map(report.metadata.full_evaluations, & &1.score) == [0.0, 0.0]
    assert length(report.errors) == 20

    assert Enum.all?(report.errors, fn failure ->
             failure.reason ==
               {:invalid_lm_result, {:error, {:adapter_error, %{reason: :validation_failure}}}}
           end)

    assert report.metadata.status == :with_errors
    assert instruction(compiled) == "Route the opaque request."
    assert Agent.get(prompt_agent, & &1) == []
  end

  test "operational safety escapes the finite bootstrap budget on its first call" do
    {prompt_lm, prompt_agent} = prompt_lm(4)
    task_calls = start_supervised!({Agent, fn -> 0 end}, id: {:guard_task_calls, self()})

    safety =
      OperationalSafetyError.exception(
        kind: :route,
        reason: :provider_drift,
        message: "bootstrap route guard drift"
      )

    task_lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          Agent.update(task_calls, &(&1 + 1))
          {:error, safety}
        end
      )

    assert_raise OperationalSafetyError, "bootstrap route guard drift", fn ->
      exact_optimizer(prompt_lm, task_lm,
        num_candidates: 4,
        num_trials: 1,
        max_errors: 10
      )
      |> MIPROv2.compile(program(task_lm), trainset(), valset())
    end

    assert Agent.get(task_calls, & &1) == 1
    assert Agent.get(prompt_agent, & &1) != []
  end

  defp startup_schedule(seed) do
    {schedule, _policy} = seed |> new_policy() |> take_suggestions(9)
    schedule
  end

  defp two_parameter_startup_schedule(seed) do
    names = ["0_predictor_instruction", "1_predictor_instruction"]
    space = Map.new(names, &{&1, Enum.to_list(0..3)})

    policy =
      OptunaStartupPolicy
      |> SearchPolicy.new(
        space: space,
        parameter_order: names,
        seed: seed,
        startup_trials: 10
      )
      |> SearchPolicy.observe(%{params: Map.new(names, &{&1, 0}), score: 0.0})

    Enum.map_reduce(1..8, policy, fn _index, policy ->
      {params, policy} = SearchPolicy.suggest(policy, :candidate)
      {params, SearchPolicy.observe(policy, %{params: params, score: 0.0})}
    end)
    |> elem(0)
  end

  defp new_policy(seed) do
    OptunaStartupPolicy
    |> SearchPolicy.new(
      space: %{"0_predictor_instruction" => Enum.to_list(0..5)},
      parameter_order: ["0_predictor_instruction"],
      seed: seed,
      startup_trials: 10
    )
    |> SearchPolicy.observe(%{params: %{"0_predictor_instruction" => 0}, score: 0.0})
  end

  defp take_suggestions(policy, count) do
    Enum.map_reduce(1..count, policy, fn _index, policy ->
      {params, policy} = SearchPolicy.suggest(policy, :candidate)
      policy = SearchPolicy.observe(policy, %{params: params, score: 0.0})
      {params["0_predictor_instruction"], policy}
    end)
  end

  defp upstream_modeled_schedule(seed, key) do
    {output, 0} =
      System.cmd(Path.expand(@python), [Path.expand(@runner)], stderr_to_stdout: false)

    Jason.decode!(output)["modeled_schedules"][Integer.to_string(seed)][key]
  end

  defp modeled_schedule(seed, parameter_count, upstream) do
    {params, _policy} = drive_modeled(new_modeled_policy(seed, parameter_count), upstream)

    Enum.zip(params, upstream)
    |> Enum.map(fn {params, trial} -> %{"params" => params, "score" => trial["score"]} end)
  end

  defp new_modeled_policy(seed, parameter_count) do
    names = Enum.map(0..(parameter_count - 1), &"#{&1}_predictor_instruction")

    OptunaTPEPolicy
    |> SearchPolicy.new(
      space: Map.new(names, &{&1, Enum.to_list(0..3)}),
      parameter_order: names,
      seed: seed,
      startup_trials: 10
    )
    |> SearchPolicy.observe(%{params: Map.new(names, &{&1, 0}), score: 0.25})
  end

  defp drive_modeled(policy, trials) do
    Enum.map_reduce(trials, policy, fn trial, policy ->
      {params, policy} = SearchPolicy.suggest(policy, :candidate)
      policy = SearchPolicy.observe(policy, %{params: params, score: trial["score"]})
      {params, policy}
    end)
  end

  defp exact_optimizer(prompt_lm, task_lm, overrides) do
    defaults = [
      auto: nil,
      num_candidates: 6,
      num_trials: 0,
      max_bootstrapped_demos: 0,
      max_labeled_demos: 0,
      minibatch: false,
      prompt_lm: prompt_lm,
      task_lm: task_lm,
      startup_trials: 10,
      max_concurrency: 1,
      max_errors: :infinity,
      program_aware_proposer: false,
      data_aware_proposer: true,
      tip_aware_proposer: true,
      fewshot_aware_proposer: false,
      proposer_fidelity: :dspy_3_2_1,
      search_fidelity: :dspy_3_2_1_optuna_4_9_0_startup,
      seed: 9
    ]

    MIPROv2.new(&__MODULE__.metric/2, Keyword.merge(defaults, overrides))
  end

  defp prompt_lm(candidate_count) do
    answers =
      [
        %{observations: "first observations"},
        %{observations: "second observations"},
        %{summary: "frozen dataset summary"}
      ] ++ Enum.map(0..(candidate_count - 1), &%{proposed_instruction: "candidate #{&1}"})

    agent = start_supervised!({Agent, fn -> answers end})

    lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          Agent.get_and_update(agent, fn [answer | rest] -> {answer, rest} end)
        end
      )

    {lm, agent}
  end

  defp program(task_lm) do
    "text -> route"
    |> Imp.signature("Route the opaque request.")
    |> Imp.predict(lm: task_lm, adapter: Imp.Adapter.Chat)
  end

  defp instruction(program) do
    program
    |> Imp.ProgramParameters.predictors()
    |> hd()
    |> Map.fetch!(:predictor)
    |> Map.fetch!(:signature)
    |> Map.fetch!(:instructions)
  end

  defp trainset do
    Enum.map(0..19, fn index ->
      Imp.example(text: "request-#{index}", route: "K11") |> Imp.with_inputs(:text)
    end)
  end

  defp valset,
    do: [Imp.example(text: "validation", route: "K11") |> Imp.with_inputs(:text)]
end
