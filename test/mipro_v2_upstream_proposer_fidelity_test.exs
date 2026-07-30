defmodule Imp.Optimizer.MIPROv2.UpstreamProposerFidelityTest do
  use ExUnit.Case, async: false

  alias Imp.Optimizer.MIPROv2.{Config, UpstreamProposer}

  @python "tmp/dspy-parity-venv/bin/python"
  @source "tmp/dspy-3.2.1"
  @runner "test/support/dspy_3_2_1_mipro_proposer_tape.py"
  @public_runner "test/support/dspy_3_2_1_mipro_public_compile_tape.py"
  @two_predictor_runner "test/support/dspy_3_2_1_mipro_two_predictor_tape.py"
  @commit "29448ae12756abdd14bd8796c819247ebb83673c"

  defmodule SequenceLM do
    defstruct [:agent]

    def generate(%__MODULE__{agent: agent}, _messages, _opts) do
      Agent.get_and_update(agent, fn
        [{:ok, value} | rest] -> {{:ok, value}, rest}
        [{:error, reason} | rest] -> {{:error, reason}, rest}
      end)
    end
  end

  def metric(expected, prediction),
    do: Imp.get(expected, :route) == Imp.get(prediction, :route)

  test "explicit 3.2.1 mode accepts implemented grounded-proposer shapes" do
    config =
      Config.new(
        auto: nil,
        num_candidates: 2,
        num_trials: 0,
        program_aware_proposer: false,
        fewshot_aware_proposer: false,
        data_aware_proposer: true,
        tip_aware_proposer: true,
        max_bootstrapped_demos: 0,
        max_labeled_demos: 0,
        proposer_fidelity: :dspy_3_2_1
      )

    assert config.proposer_fidelity == :dspy_3_2_1

    assert_raise ArgumentError, ~r/currently requires/, fn ->
      Config.new(proposer_fidelity: :dspy_3_2_1)
    end

    fewshot =
      Config.new(
        proposer_fidelity: :dspy_3_2_1,
        program_aware_proposer: false,
        fewshot_aware_proposer: false,
        max_bootstrapped_demos: 2,
        max_labeled_demos: 1
      )

    assert fewshot.max_bootstrapped_demos == 2
    assert fewshot.max_labeled_demos == 1

    grounded_fewshot =
      Config.new(
        proposer_fidelity: :dspy_3_2_1,
        program_aware_proposer: false,
        fewshot_aware_proposer: true,
        max_bootstrapped_demos: 2,
        max_labeled_demos: 1
      )

    assert grounded_fewshot.fewshot_aware_proposer

    assert_raise ArgumentError, ~r/requires max_bootstrapped_demos > 0/, fn ->
      Config.new(
        proposer_fidelity: :dspy_3_2_1,
        program_aware_proposer: false,
        fewshot_aware_proposer: false,
        max_bootstrapped_demos: 0,
        max_labeled_demos: 1
      )
    end

    assert_raise ArgumentError, ~r/proposer_fidelity/, fn ->
      Config.new(proposer_fidelity: :unknown)
    end

    assert_raise ArgumentError, ~r/proposal_response_format: :off/, fn ->
      Imp.Optimizer.MIPROv2.new(&__MODULE__.metric/2,
        program_aware_proposer: false,
        fewshot_aware_proposer: false,
        max_bootstrapped_demos: 0,
        max_labeled_demos: 0,
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

  test "public DSPy-fidelity compile summarizes a custom multi-predictor program without internal metadata" do
    owner = self()

    agent =
      start_supervised!(
        {Agent,
         fn ->
           [
             %{observations: "prompt-only observations"},
             %{summary: "prompt-only summary"},
             %{proposed_instruction: "draft proposal"},
             %{proposed_instruction: "review proposal"}
           ]
         end}
      )

    prompt_lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          send(owner, {:custom_program_prompt_call, messages})
          Agent.get_and_update(agent, fn [answer | rest] -> {answer, rest} end)
        end
      )

    task_lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          flunk("zero-trial custom-program setup must not evaluate the task model")
        end
      )

    program =
      Imp.BenchmarkTruth.IFBenchTwoStage.new(task_lm,
        adapter: Imp.Adapter.Chat,
        config: [json_fallback: false]
      )

    trainset = [
      Imp.Example.new(%{
        prompt: "Write exactly BLUE.",
        imp_metric_row: %{"instruction_id_list" => ["keywords:existence"]}
      })
      |> Imp.Example.with_inputs(:prompt)
    ]

    optimizer =
      Imp.Optimizer.MIPROv2.new(&__MODULE__.metric/2,
        auto: nil,
        num_candidates: 1,
        num_trials: 0,
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
      Imp.Optimizer.MIPROv2.compile(optimizer, program, trainset, trainset, max_trials: 0)

    assert Imp.Optimizer.Report.fetch(paused).metadata.predictor_names == [
             :generate_response_module,
             :ensure_correct_response_module
           ]

    calls = collect_tagged_calls(:custom_program_prompt_call, 4, [])
    summary_prompt = calls |> hd() |> List.last() |> Map.fetch!(:content)
    assert summary_prompt =~ "Write exactly BLUE."
    refute summary_prompt =~ "imp_metric_row"
    refute summary_prompt =~ "instruction_id_list"
    assert Agent.get(agent, & &1) == []
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

    trainset =
      Enum.map(0..29, fn index ->
        Imp.example(text: "request-#{index}", route: "K11") |> Imp.with_inputs(:text)
      end)

    assert UpstreamProposer.summarize!(lm, trainset, 10) == "firstlater"
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

  test "dataset summary contains an ordinary continuation failure but not an operational guard" do
    trainset =
      Enum.map(0..19, fn index ->
        Imp.example(text: "request-#{index}", route: "K11") |> Imp.with_inputs(:text)
      end)

    ordinary_agent =
      start_supervised!(
        {Agent,
         fn ->
           [
             {:ok, %{observations: "retained observations"}},
             {:error, :malformed_continuation},
             {:ok, %{summary: "retained summary"}}
           ]
         end},
        id: :ordinary_continuation_agent
      )

    assert UpstreamProposer.summarize!(
             %SequenceLM{agent: ordinary_agent},
             trainset,
             10
           ) == "retained summary"

    safety =
      Imp.OperationalSafetyError.exception(
        kind: :route,
        reason: :provider_drift,
        message: "provider route drift"
      )

    safety_agent =
      start_supervised!(
        {Agent,
         fn ->
           [
             {:ok, %{observations: "retained observations"}},
             {:error, safety}
           ]
         end},
        id: :safety_continuation_agent
      )

    assert_raise Imp.OperationalSafetyError, "provider route drift", fn ->
      UpstreamProposer.summarize!(%SequenceLM{agent: safety_agent}, trainset, 10)
    end
  end

  @tag :evidence_infrastructure
  test "public zero-shot compile matches bootstrap call graph and RNG-advanced proposals" do
    {output, 0} =
      System.cmd(Path.expand(@python), [Path.expand(@public_runner)],
        env: [{"PYTHONPATH", Path.expand(@source)}],
        stderr_to_stdout: false
      )

    upstream = Jason.decode!(output)
    assert upstream["commit"] == @commit
    assert length(upstream["task_messages"]) == 9
    assert length(upstream["prompt_messages"]) == 9
    assert upstream["demos_discarded"]

    owner = self()

    prompt_answers =
      [
        %{observations: "first observations"},
        %{observations: "second observations"},
        %{summary: "frozen dataset summary"}
      ] ++ Enum.map(0..5, &%{proposed_instruction: "candidate #{&1}"})

    prompt_agent = start_supervised!({Agent, fn -> prompt_answers end})

    prompt_lm =
      Imp.LM.Static.new(
        handler: fn messages, opts ->
          send(owner, {:public_prompt_call, messages, opts})
          Agent.get_and_update(prompt_agent, fn [answer | rest] -> {answer, rest} end)
        end
      )

    task_lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          send(owner, {:public_task_call, messages})
          %{route: "K11"}
        end
      )

    program =
      "text -> route"
      |> Imp.signature("Route the opaque request.")
      |> Imp.predict(lm: task_lm, adapter: Imp.Adapter.Chat)

    trainset =
      Enum.map(0..19, fn index ->
        text = index |> Integer.to_string() |> String.pad_leading(2, "0")
        Imp.example(text: "request-#{text}", route: "K11") |> Imp.with_inputs(:text)
      end)

    valset = [Imp.example(text: "validation", route: "K11") |> Imp.with_inputs(:text)]

    optimizer =
      Imp.Optimizer.MIPROv2.new(&__MODULE__.metric/2,
        auto: nil,
        num_candidates: 6,
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

    paused = Imp.Optimizer.MIPROv2.compile(optimizer, program, trainset, valset, max_trials: 0)
    report = Imp.Optimizer.Report.fetch(paused)

    prompt_calls = collect_tagged_calls(:public_prompt_call, 9, [])
    task_calls = collect_tagged_calls(:public_task_call, 10, [])

    prompt_messages = Enum.map(prompt_calls, fn {messages, _opts} -> stringify(messages) end)

    Enum.zip(prompt_messages, upstream["prompt_messages"])
    |> Enum.with_index()
    |> Enum.each(fn {{actual, expected}, index} ->
      assert actual == expected, "prompt message mismatch at call #{index}"
    end)

    assert task_calls |> Enum.take(9) |> Enum.map(&stringify/1) == upstream["task_messages"]

    assert Enum.map(Enum.drop(prompt_calls, 3), fn {_messages, opts} -> opts[:rollout_id] end) ==
             upstream["rollout_ids"]

    assert report.metadata.bootstrap.trajectory_count == 9
    assert report.metadata.bootstrap.maximum_task_calls == 100
    assert Enum.map(report.metadata.bootstrap.rounds, & &1.calls) == [0, 3, 3, 1, 1, 1]
    assert report.metadata.proposals.main.total_setup_calls == 9

    assert report.metadata.proposals.main.slots |> Enum.map(& &1.rollout_id) ==
             upstream["rollout_ids"]

    artifacts =
      report.metadata.resume_state["payload"]["artifacts"]
      |> Imp.Optimizer.Report.decode_term()

    assert artifacts.search_demos == nil
    assert artifacts.instruction_candidates.main == upstream["instructions"]
    assert Agent.get(prompt_agent, & &1) == []
  end

  @tag :evidence_infrastructure
  test "two-predictor public setup matches bootstrap, proposal messages, and rollout ids" do
    {output, 0} =
      System.cmd(Path.expand(@python), [Path.expand(@two_predictor_runner)],
        env: [{"PYTHONPATH", Path.expand(@source)}],
        stderr_to_stdout: false
      )

    upstream = Jason.decode!(output)
    assert upstream["commit"] == @commit
    assert length(upstream["task_messages"]) == 12
    assert length(upstream["prompt_messages"]) == 11
    assert length(upstream["rollout_ids"]) == 8
    assert upstream["demos_discarded"]

    owner = self()

    prompt_answers =
      [
        %{observations: "first observations"},
        %{observations: "second observations"},
        %{summary: "frozen dataset summary"}
      ] ++ Enum.map(0..7, &%{proposed_instruction: "predictor candidate #{&1}"})

    prompt_agent = start_supervised!({Agent, fn -> prompt_answers end})

    prompt_lm =
      Imp.LM.Static.new(
        handler: fn messages, opts ->
          send(owner, {:two_predictor_prompt_call, messages, opts})
          Agent.get_and_update(prompt_agent, fn [answer | rest] -> {answer, rest} end)
        end
      )

    task_lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          send(owner, {:two_predictor_task_call, messages})
          prompt = Enum.map_join(messages, "\n", & &1.content)

          if prompt =~ "final_response",
            do: %{reasoning: "review reasoning", final_response: "FINAL"},
            else: %{reasoning: "draft reasoning", response: "DRAFT"}
        end
      )

    program =
      Imp.BenchmarkTruth.IFBenchTwoStage.new(task_lm,
        adapter: Imp.Adapter.Chat,
        config: [json_fallback: false]
      )

    trainset =
      Enum.map(0..15, fn index ->
        Imp.Example.new(
          prompt: "request-#{index |> Integer.to_string() |> String.pad_leading(2, "0")}"
        )
        |> Imp.Example.with_inputs(:prompt)
      end)

    valset = [Imp.Example.new(prompt: "validation") |> Imp.Example.with_inputs(:prompt)]

    optimizer =
      Imp.Optimizer.MIPROv2.new(&__MODULE__.metric/2,
        auto: nil,
        num_candidates: 4,
        num_trials: 8,
        max_bootstrapped_demos: 0,
        max_labeled_demos: 0,
        minibatch: false,
        prompt_lm: prompt_lm,
        task_lm: task_lm,
        startup_trials: 10,
        search_fidelity: :dspy_3_2_1_optuna_4_9_0_startup,
        proposer_fidelity: :dspy_3_2_1,
        program_aware_proposer: false,
        data_aware_proposer: true,
        tip_aware_proposer: true,
        fewshot_aware_proposer: false,
        max_concurrency: 1,
        seed: 9
      )

    paused = Imp.Optimizer.MIPROv2.compile(optimizer, program, trainset, valset, max_trials: 0)
    report = Imp.Optimizer.Report.fetch(paused)

    prompt_calls = collect_tagged_calls(:two_predictor_prompt_call, 11, [])
    task_calls = collect_tagged_calls(:two_predictor_task_call, 12, [])

    prompt_messages = Enum.map(prompt_calls, fn {messages, _opts} -> stringify(messages) end)

    Enum.zip(prompt_messages, upstream["prompt_messages"])
    |> Enum.with_index()
    |> Enum.each(fn {{actual, expected}, index} ->
      assert actual == expected, "two-predictor prompt message mismatch at call #{index}"
    end)

    assert Enum.map(task_calls, &stringify/1) == upstream["task_messages"]

    assert Enum.map(Enum.drop(prompt_calls, 3), fn {_messages, opts} -> opts[:rollout_id] end) ==
             upstream["rollout_ids"]

    # DSPy's four zero-shot bootstrap arms are zero-shot, shuffled seed -2,
    # unshuffled seed -1, and shuffled seed 0. The exact task transcript above
    # independently fixes both ordering and the six accepted rollouts.
    assert Enum.map(report.metadata.bootstrap.rounds, & &1.calls) == [0, 1, 3, 2]
    assert report.metadata.bootstrap.trajectory_count == 6

    artifacts =
      report.metadata.resume_state["payload"]["artifacts"]
      |> Imp.Optimizer.Report.decode_term()

    assert artifacts.search_demos == nil

    assert Map.new(artifacts.instruction_candidates, fn {name, instructions} ->
             {to_string(name), instructions}
           end) == %{
             "generate_response_module" => upstream["instructions"]["0"],
             "ensure_correct_response_module" => upstream["instructions"]["1"]
           }

    assert Agent.get(prompt_agent, & &1) == []
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

    summary = UpstreamProposer.summarize!(lm, trainset, 10)
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

  defp collect_tagged_calls(_tag, 0, calls), do: Enum.reverse(calls)

  defp collect_tagged_calls(tag, count, calls) do
    receive do
      {^tag, messages, opts} -> collect_tagged_calls(tag, count - 1, [{messages, opts} | calls])
      {^tag, messages} -> collect_tagged_calls(tag, count - 1, [messages | calls])
    after
      1_000 -> flunk("missing #{count} #{tag} calls")
    end
  end

  defp stringify(value) when is_list(value), do: Enum.map(value, &stringify/1)

  defp stringify(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {to_string(key), stringify(item)} end)

  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value), do: value
end
