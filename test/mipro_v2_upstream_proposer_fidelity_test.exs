defmodule Imp.Optimizer.MIPROv2.UpstreamProposerFidelityTest do
  use ExUnit.Case, async: false

  alias Imp.Optimizer.MIPROv2.{Config, UpstreamProposer}

  @python "tmp/dspy-parity-venv/bin/python"
  @source "tmp/dspy-3.2.1"
  @runner "test/support/dspy_3_2_1_mipro_proposer_tape.py"
  @commit "29448ae12756abdd14bd8796c819247ebb83673c"

  def metric(expected, prediction),
    do: Imp.get(expected, :route) == Imp.get(prediction, :route)

  test "explicit 3.2.1 mode accepts only its implemented grounded-proposer shape" do
    config =
      Config.new(
        auto: nil,
        num_candidates: 2,
        num_trials: 0,
        program_aware_proposer: false,
        fewshot_aware_proposer: false,
        data_aware_proposer: true,
        tip_aware_proposer: true,
        proposer_fidelity: :dspy_3_2_1
      )

    assert config.proposer_fidelity == :dspy_3_2_1

    assert_raise ArgumentError, ~r/currently requires/, fn ->
      Config.new(proposer_fidelity: :dspy_3_2_1)
    end

    assert_raise ArgumentError, ~r/proposer_fidelity/, fn ->
      Config.new(proposer_fidelity: :unknown)
    end

    assert_raise ArgumentError, ~r/proposal_response_format: :off/, fn ->
      Imp.Optimizer.MIPROv2.new(&__MODULE__.metric/2,
        program_aware_proposer: false,
        fewshot_aware_proposer: false,
        proposer_fidelity: :dspy_3_2_1,
        proposal_response_format: :required
      )
    end
  end

  test "compile overwrites candidate zero with baseline and resume rejects fidelity drift" do
    answers = [
      %{observations: "first observations"},
      %{observations: "second observations"},
      %{summary: "frozen dataset summary"},
      %{proposed_instruction: "candidate zero must be overwritten"},
      %{proposed_instruction: "candidate one survives"}
    ]

    agent = start_supervised!({Agent, fn -> answers end})

    prompt_lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          Agent.get_and_update(agent, fn [answer | rest] -> {answer, rest} end)
        end
      )

    task_lm = Imp.LM.Static.new(handler: fn _messages, _opts -> %{route: "K11"} end)

    program =
      "text -> route"
      |> Imp.signature("Route the opaque request.")
      |> Imp.predict(lm: task_lm, adapter: Imp.Adapter.Chat)

    trainset =
      Enum.map(0..19, fn index ->
        Imp.example(text: "request-#{index}", route: "K11") |> Imp.with_inputs(:text)
      end)

    valset = [Imp.example(text: "validation", route: "K11") |> Imp.with_inputs(:text)]

    optimizer =
      Imp.Optimizer.MIPROv2.new(&__MODULE__.metric/2,
        auto: nil,
        num_candidates: 2,
        num_trials: 1,
        max_bootstrapped_demos: 0,
        max_labeled_demos: 0,
        minibatch: false,
        prompt_lm: prompt_lm,
        program_aware_proposer: false,
        fewshot_aware_proposer: false,
        data_aware_proposer: true,
        tip_aware_proposer: true,
        proposer_fidelity: :dspy_3_2_1,
        seed: 9
      )

    paused =
      Imp.Optimizer.MIPROv2.compile(optimizer, program, trainset, valset, max_trials: 0)

    report = Imp.Optimizer.Report.fetch(paused)

    artifacts =
      report.metadata.resume_state["payload"]["artifacts"]
      |> Imp.Optimizer.Report.decode_term()

    assert artifacts.instruction_candidates.main == [
             "Route the opaque request.",
             "candidate one survives"
           ]

    assert report.metadata.effective_config.proposer_fidelity == :dspy_3_2_1
    assert report.metadata.proposals.main.fidelity == :dspy_3_2_1
    assert report.metadata.proposals.main.dataset_summary_calls == 3
    assert report.metadata.proposals.main.total_setup_calls == 5
    assert Agent.get(agent, & &1) == []

    resumed =
      Imp.Optimizer.MIPROv2.compile(optimizer, program, trainset, valset,
        resume_state: report.metadata.resume_state,
        max_trials: 0
      )

    assert Imp.Optimizer.Report.fetch(resumed).metadata.resumed
    assert Agent.get(agent, & &1) == []

    assert_raise ArgumentError, ~r/does not match/, fn ->
      Imp.Optimizer.MIPROv2.compile(optimizer, program, trainset, valset,
        resume_state: report.metadata.resume_state,
        max_trials: 0,
        seed: 10
      )
    end
  end

  test "dataset summary skips COMPLETE batches and continues like pinned DSPy" do
    owner = self()

    answers = [
      %{observations: "first"},
      %{observations: "COMPLETE"},
      %{observations: "later"},
      %{summary: "firstlater"}
    ]

    agent = start_supervised!({Agent, fn -> answers end})

    lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          send(owner, {:summary_call, messages})
          Agent.get_and_update(agent, fn [answer | rest] -> {answer, rest} end)
        end
      )

    signature = Imp.signature("text -> route")

    trainset =
      Enum.map(0..29, fn index ->
        Imp.example(text: "request-#{index}", route: "K11") |> Imp.with_inputs(:text)
      end)

    assert UpstreamProposer.summarize!(lm, trainset, signature, 10) == "firstlater"
    assert Agent.get(agent, & &1) == []

    calls =
      Enum.map(1..4, fn _ ->
        receive do
          {:summary_call, messages} -> messages
        end
      end)

    final_user = calls |> List.last() |> List.last() |> Map.fetch!(:content)
    assert final_user =~ "[[ ## observations ## ]]\nfirstlater"
  end

  @tag :evidence_infrastructure
  test "five-call transcript is byte-identical to pinned DSPy 3.2.1" do
    unless File.exists?(@python) and File.dir?(@source) do
      flunk("run scripts/setup_dspy_stable_source.sh and scripts/setup_dspy_parity_env.sh")
    end

    {output, 0} =
      System.cmd(Path.expand(@python), [Path.expand(@runner)],
        env: [{"PYTHONPATH", Path.expand(@source)}],
        stderr_to_stdout: false
      )

    upstream = Jason.decode!(output)
    assert upstream["commit"] == @commit
    assert length(upstream["messages"]) == 5
    assert upstream["rollout_ids"] == [658_434_843, 286_833_407]

    owner = self()

    answers = [
      %{observations: "first observations"},
      %{observations: "second observations"},
      %{summary: "frozen dataset summary"},
      %{proposed_instruction: "candidate zero"},
      %{proposed_instruction: "candidate one"}
    ]

    agent = start_supervised!({Agent, fn -> answers end})

    lm =
      Imp.LM.Static.new(
        handler: fn messages, opts ->
          send(owner, {:call, messages, opts})
          Agent.get_and_update(agent, fn [answer | rest] -> {answer, rest} end)
        end
      )

    signature = Imp.signature("text -> route", "Route the opaque request.")

    trainset =
      Enum.map(0..19, fn index ->
        Imp.example(
          text: "request-#{index |> Integer.to_string() |> String.pad_leading(2, "0")}",
          route: if(rem(index, 2) == 0, do: "K11", else: "K47")
        )
        |> Imp.with_inputs(:text)
      end)

    summary = UpstreamProposer.summarize!(lm, trainset, signature, 10)
    predictor = Imp.predict(signature)

    {proposed, report} =
      UpstreamProposer.propose_with_report!(lm, predictor, summary,
        count: 2,
        seed: 9,
        temperature: 1.0
      )

    calls = collect_calls(5, [])
    actual_messages = Enum.map(calls, fn {messages, _opts} -> stringify(messages) end)

    assert actual_messages == upstream["messages"]

    assert Enum.map(Enum.drop(calls, 3), fn {_messages, opts} -> opts[:rollout_id] end) ==
             upstream["rollout_ids"]

    assert proposed == ["candidate zero", "candidate one"]
    assert report.calls == 2

    assert Enum.map(report.slots, & &1.tip) == [
             "Make sure your instruction is very informative and descriptive.",
             "Keep the instruction clear and concise."
           ]

    assert Agent.get(agent, & &1) == []
  end

  defp collect_calls(0, calls), do: Enum.reverse(calls)

  defp collect_calls(count, calls) do
    receive do
      {:call, messages, opts} -> collect_calls(count - 1, [{messages, opts} | calls])
    after
      1_000 -> flunk("missing #{count} proposer calls")
    end
  end

  defp stringify(value) when is_list(value), do: Enum.map(value, &stringify/1)

  defp stringify(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {to_string(key), stringify(item)} end)

  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value), do: value
end
