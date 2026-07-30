defmodule Imp.Optimizer.MIPROv2.UpstreamFewshotTest do
  use ExUnit.Case, async: false

  alias Imp.Optimizer.MIPROv2
  alias Imp.Optimizer.Report

  @python "tmp/dspy-parity-venv/bin/python"
  @source "tmp/dspy-3.2.1"
  @runner "test/support/dspy_3_2_1_mipro_fewshot_tape.py"
  @proposer_runner "test/support/dspy_3_2_1_mipro_fewshot_proposer_tape.py"
  @optuna_runner "test/support/dspy_3_2_1_optuna_startup_tape.py"
  @commit "29448ae12756abdd14bd8796c819247ebb83673c"

  def metric(_expected, _prediction), do: true

  @tag :evidence_infrastructure
  test "public pinned path retains the same ordered few-shot arm contents as DSPy 3.2.1" do
    {output, 0} =
      System.cmd(Path.expand(@python), [Path.expand(@runner)],
        env: [{"PYTHONPATH", Path.expand(@source)}],
        stderr_to_stdout: false
      )

    upstream = Jason.decode!(output)
    assert upstream["commit"] == @commit

    task_lm = Imp.LM.Static.new(handler: fn _messages, _opts -> %{route: "K11"} end)

    prompt_answers =
      start_supervised!(
        {Agent,
         fn ->
           [
             %{observations: "dataset observations"},
             %{summary: "dataset summary"},
             %{proposed_instruction: "candidate 0"},
             %{proposed_instruction: "candidate 1"},
             %{proposed_instruction: "candidate 2"},
             %{proposed_instruction: "candidate 3"}
           ]
         end}
      )

    prompt_lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          Agent.get_and_update(prompt_answers, fn [answer | rest] -> {answer, rest} end)
        end
      )

    program =
      "text -> route"
      |> Imp.signature("Route the request.")
      |> Imp.predict(lm: task_lm, adapter: Imp.Adapter.Chat)

    trainset =
      Enum.map(0..3, fn index ->
        Imp.example(text: "request-#{index}", route: "K11") |> Imp.with_inputs(:text)
      end)

    valset = [Imp.example(text: "validation", route: "K11") |> Imp.with_inputs(:text)]

    paused =
      MIPROv2.new(&__MODULE__.metric/2,
        auto: nil,
        num_candidates: 4,
        num_trials: 0,
        max_bootstrapped_demos: 2,
        max_labeled_demos: 1,
        minibatch: false,
        prompt_lm: prompt_lm,
        program_aware_proposer: false,
        fewshot_aware_proposer: false,
        data_aware_proposer: true,
        tip_aware_proposer: true,
        proposer_fidelity: :dspy_3_2_1,
        seed: 9
      )
      |> MIPROv2.compile(program, trainset, valset, max_trials: 0)

    report = Report.fetch(paused)

    artifacts =
      report.metadata.resume_state["payload"]["artifacts"]
      |> Report.decode_term()

    actual = Enum.map(artifacts.search_demos.main, &Enum.map(&1, fn demo -> demo_json(demo) end))

    assert actual == upstream["demos"]
    assert report.metadata.bootstrap.demos_retained
    assert report.metadata.search_space["atom:main:demos"] == 4
  end

  test "pinned Optuna startup orders instruction then demos for each predictor" do
    predictors = [%{name: :first}, %{name: :second}]
    instructions = %{first: ["a", "b"], second: ["c", "d"]}
    demos = %{first: [[], [:one]], second: [[], [:two]]}

    assert MIPROv2.categorical_space(predictors, instructions, demos) == %{
             "atom:first:instruction" => [0, 1],
             "atom:first:demos" => [0, 1],
             "atom:second:instruction" => [0, 1],
             "atom:second:demos" => [0, 1]
           }
  end

  @tag :evidence_infrastructure
  test "few-shot-aware proposal messages match DSPy 3.2.1 through public compile" do
    {output, 0} =
      System.cmd(Path.expand(@python), [Path.expand(@proposer_runner)],
        env: [{"PYTHONPATH", Path.expand(@source)}],
        stderr_to_stdout: false
      )

    upstream = Jason.decode!(output)
    assert upstream["commit"] == @commit
    owner = self()

    task_lm = Imp.LM.Static.new(handler: fn _messages, _opts -> %{route: "K11"} end)

    prompt_answers =
      start_supervised!(
        {Agent,
         fn ->
           [
             %{observations: "dataset observations"},
             %{summary: "dataset summary"},
             %{proposed_instruction: "candidate 0"},
             %{proposed_instruction: "candidate 1"},
             %{proposed_instruction: "candidate 2"},
             %{proposed_instruction: "candidate 3"}
           ]
         end}
      )

    prompt_lm =
      Imp.LM.Static.new(
        handler: fn messages, opts ->
          send(owner, {:fewshot_proposal_call, messages, opts})
          Agent.get_and_update(prompt_answers, fn [answer | rest] -> {answer, rest} end)
        end
      )

    program =
      "text -> route"
      |> Imp.signature("Route the request.")
      |> Imp.predict(lm: task_lm, adapter: Imp.Adapter.Chat)

    trainset =
      Enum.map(0..3, fn index ->
        Imp.example(text: "request-#{index}", route: "K11") |> Imp.with_inputs(:text)
      end)

    valset = [Imp.example(text: "validation", route: "K11") |> Imp.with_inputs(:text)]

    paused =
      MIPROv2.new(&__MODULE__.metric/2,
        auto: nil,
        num_candidates: 4,
        num_trials: 0,
        max_bootstrapped_demos: 2,
        max_labeled_demos: 1,
        minibatch: false,
        prompt_lm: prompt_lm,
        program_aware_proposer: false,
        fewshot_aware_proposer: true,
        data_aware_proposer: true,
        tip_aware_proposer: true,
        proposer_fidelity: :dspy_3_2_1,
        seed: 9
      )
      |> MIPROv2.compile(program, trainset, valset, max_trials: 0)

    calls = collect_calls(6, [])

    assert Enum.map(calls, fn {messages, _opts} -> stringify(messages) end) ==
             upstream["prompt_messages"]

    assert Enum.map(Enum.drop(calls, 2), fn {_messages, opts} -> opts[:rollout_id] end) ==
             upstream["rollout_ids"]

    slots = Report.fetch(paused).metadata.proposals.main.slots
    assert Enum.map(slots, & &1.grounded_demo_count) == [0, 3, 3, 3]
    assert Agent.get(prompt_answers, & &1) == []
  end

  test "pinned few-shot path rejects an incompatible teacher before task or proposal calls" do
    owner = self()

    lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          send(owner, :unexpected_call)
          %{route: "K11"}
        end
      )

    student = Imp.predict("text -> route", lm: lm)
    teacher = Imp.predict("question -> answer", lm: lm)
    row = Imp.example(text: "request", route: "K11") |> Imp.with_inputs(:text)

    optimizer =
      MIPROv2.new(&__MODULE__.metric/2,
        auto: nil,
        num_candidates: 4,
        num_trials: 0,
        max_bootstrapped_demos: 2,
        max_labeled_demos: 1,
        minibatch: false,
        prompt_lm: lm,
        teacher: teacher,
        program_aware_proposer: false,
        fewshot_aware_proposer: false,
        data_aware_proposer: true,
        tip_aware_proposer: true,
        proposer_fidelity: :dspy_3_2_1
      )

    assert_raise ArgumentError, ~r/same ordered predictor names and signatures/, fn ->
      MIPROv2.compile(optimizer, student, [row], [row], max_trials: 0)
    end

    refute_received :unexpected_call
  end

  test "public pinned compile jointly searches instructions and demos and resumes durably" do
    task_lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          current = messages |> List.last() |> Map.fetch!(:content)
          rendered = Enum.map_join(messages, "\n", & &1.content)

          if current =~ "validation" do
            %{route: if(rendered =~ "request-", do: "K11", else: "K00")}
          else
            %{route: "K11"}
          end
        end
      )

    prompt_answers =
      start_supervised!(
        {Agent,
         fn ->
           [
             %{observations: "dataset observations"},
             %{summary: "dataset summary"},
             %{proposed_instruction: "candidate 0"},
             %{proposed_instruction: "candidate 1"},
             %{proposed_instruction: "candidate 2"},
             %{proposed_instruction: "candidate 3"}
           ]
         end}
      )

    prompt_lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          Agent.get_and_update(prompt_answers, fn [answer | rest] -> {answer, rest} end)
        end
      )

    program =
      "text -> route"
      |> Imp.signature("Route the request.")
      |> Imp.predict(lm: task_lm, adapter: Imp.Adapter.Chat)

    trainset =
      Enum.map(0..3, fn index ->
        Imp.example(text: "request-#{index}", route: "K11") |> Imp.with_inputs(:text)
      end)

    valset = [Imp.example(text: "validation", route: "K11") |> Imp.with_inputs(:text)]

    optimizer =
      MIPROv2.new(&__MODULE__.route_metric/2,
        auto: nil,
        num_candidates: 4,
        num_trials: 4,
        max_bootstrapped_demos: 2,
        max_labeled_demos: 1,
        minibatch: false,
        prompt_lm: prompt_lm,
        program_aware_proposer: false,
        fewshot_aware_proposer: false,
        data_aware_proposer: true,
        tip_aware_proposer: true,
        proposer_fidelity: :dspy_3_2_1,
        search_fidelity: :dspy_3_2_1_optuna_4_9_0_startup,
        startup_trials: 10,
        seed: 9
      )

    paused = MIPROv2.compile(optimizer, program, trainset, valset, max_trials: 2)
    paused_report = Report.fetch(paused)

    assert paused_report.metadata.run_status == :paused
    assert Enum.all?(paused_report.candidates, &Map.has_key?(&1.params, "atom:main:demos"))

    selected =
      MIPROv2.compile(optimizer, program, trainset, valset,
        resume_state: paused_report.metadata.resume_state,
        max_trials: 2
      )

    report = Report.fetch(selected)

    {optuna_output, 0} =
      System.cmd(Path.expand(@python), [Path.expand(@optuna_runner)], stderr_to_stdout: false)

    expected_params = Jason.decode!(optuna_output)["instruction_demo_schedule"]

    assert report.metadata.run_status == :complete
    assert report.best_score == 1.0
    assert report.metadata.resumed
    assert hd(Imp.ProgramParameters.predictors(selected)).predictor.demos != []

    assert Enum.map(report.candidates, fn candidate ->
             %{
               "0_predictor_instruction" => candidate.params["atom:main:instruction"],
               "0_predictor_demos" => candidate.params["atom:main:demos"]
             }
           end) == expected_params

    assert Agent.get(prompt_answers, & &1) == []
  end

  def route_metric(expected, prediction),
    do: Imp.get(expected, :route) == Imp.get(prediction, :route)

  defp demo_json(demo) do
    values =
      demo |> Imp.Example.to_map() |> Map.new(fn {key, value} -> {to_string(key), value} end)

    %{
      "values" => Map.delete(values, "imp_augmented"),
      "augmented" => values["imp_augmented"] == true
    }
  end

  defp collect_calls(0, calls), do: Enum.reverse(calls)

  defp collect_calls(count, calls) do
    receive do
      {:fewshot_proposal_call, messages, opts} ->
        collect_calls(count - 1, [{messages, opts} | calls])
    after
      1_000 -> flunk("missing #{count} few-shot proposal calls")
    end
  end

  defp stringify(value) when is_map(value),
    do: Map.new(value, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(value) when is_list(value), do: Enum.map(value, &stringify/1)
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value), do: value
end
