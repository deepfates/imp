defmodule Imp.Optimizer.MIPROv2.OptunaStartupSearchTest do
  use ExUnit.Case, async: false

  alias Imp.Optimizer.MIPROv2
  alias Imp.OperationalSafetyError
  alias Imp.Optimizer.MIPROv2.OptunaStartupPolicy
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

  test "matched mode rejects modeled TPE entry and runtime drift before setup calls" do
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

  defp startup_schedule(seed) do
    {schedule, _policy} = seed |> new_policy() |> take_suggestions(9)
    schedule
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
