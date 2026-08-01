defmodule Imp.Optimizer.MIPROv2.OptunaMinibatchSearchTest do
  use ExUnit.Case, async: false

  alias Imp.OperationalSafetyError
  alias Imp.Optimizer.MIPROv2
  alias Imp.Optimizer.{Report, Sampling}

  @python "tmp/dspy-parity-venv/bin/python"
  @runner "test/support/dspy_3_2_1_mipro_minibatch_tape.py"
  @source "tmp/dspy-3.2.1"
  @commit "29448ae12756abdd14bd8796c819247ebb83673c"

  def metric(expected, prediction),
    do: Imp.get(expected, :route) == Imp.get(prediction, :route)

  @tag :evidence_infrastructure
  test "public pinned minibatch trace matches DSPy through modeled TPE" do
    upstream = upstream_trace()
    compiled = compile_result(12)
    report = Report.fetch(compiled)

    assert upstream["commit"] == @commit
    assert upstream["optuna"] == "4.9.0"
    assert Enum.map(report.candidates, & &1.sampled_indices) == upstream["sampled_indices"]

    assert Enum.map(report.candidates, fn candidate ->
             %{
               "upstream_trial_num" => candidate.upstream_trial_num,
               "instruction" => candidate.params["atom:main:instruction"],
               "score" => Float.round(candidate.score * 100, 2)
             }
           end) == upstream["trials"]

    assert Enum.map(report.metadata.full_evaluations, fn evaluation ->
             %{
               "trial" => if(evaluation.kind == :baseline, do: 1, else: evaluation.trial),
               "instruction" => evaluation.params["atom:main:instruction"],
               "score" => Float.round(evaluation.score * 100, 2)
             }
           end) == upstream["full_evaluations"]

    assert report.best_score == upstream["best_score"] / 100
    assert compiled.signature.instructions == upstream["best_instruction"]
    positive_half = MIPROv2.upstream_evaluation_score([1.0 | List.duplicate(0.0, 31)])
    negative_half = MIPROv2.upstream_evaluation_score([-1.0 | List.duplicate(0.0, 31)])
    assert positive_half == upstream["half_even_scores"]["positive"]
    assert negative_half == upstream["half_even_scores"]["negative"]
    assert Float.round(positive_half, 4) == 0.0312
    assert Float.round(negative_half, 4) == -0.0312

    assert report.metadata.evaluation_call_accounting == %{
             unit: :requested_example_evaluations,
             baseline: 8,
             objectives: 36,
             promoted_full: 24,
             total: 68,
             provider_calls?: false,
             interrupted_attempts_included?: false
           }
  end

  test "JSON resume immediately before and after promotion is trace-identical" do
    uninterrupted = compile_report(12)

    for cut <- [4, 5] do
      paused = compile_report(cut)
      checkpoint = paused.metadata.resume_state |> Jason.encode!() |> Jason.decode!()

      resumed =
        compile_report(12 - cut,
          resume_state: checkpoint,
          max_trials: 12 - cut
        )

      assert resumed.candidates == uninterrupted.candidates
      assert resumed.metadata.full_evaluations == uninterrupted.metadata.full_evaluations
      assert resumed.metadata.search_policy == uninterrupted.metadata.search_policy
      assert resumed.metadata.evaluation_calls == uninterrupted.metadata.evaluation_calls
    end
  end

  test "pinned minibatch resume rejects a tampered BEAM RNG and schema-one state" do
    checkpoint = compile_report(4).metadata.resume_state
    beam_rng = Sampling.new(9) |> Sampling.dump()

    tampered_payload =
      put_in(checkpoint["payload"], ["state", "rng"], %{
        "kind" => "beam_sampling",
        "state" => beam_rng
      })

    tampered = %{
      checkpoint
      | "payload" => tampered_payload,
        "payload_sha256" => checkpoint_checksum(tampered_payload)
    }

    assert_raise ArgumentError, ~r/checkpoint RNG kind does not match/, fn ->
      compile_report(8, resume_state: tampered)
    end

    legacy_payload =
      tampered_payload
      |> put_in(["compatibility"], Map.take(tampered_payload["compatibility"], ["sha256"]))
      |> put_in(["state", "rng"], beam_rng)

    legacy = %{
      checkpoint
      | "schema_version" => 1,
        "payload" => legacy_payload,
        "payload_sha256" => checkpoint_checksum(legacy_payload)
    }

    assert_raise ArgumentError, ~r/schema-one.*cannot contain pinned minibatch RNG/s, fn ->
      compile_report(8, resume_state: legacy)
    end
  end

  test "full-size minibatch preserves valset order and does not consume Python RNG" do
    baseline = compile_report(0, minibatch_size: 8, num_trials: 1)
    first = compile_report(1, minibatch_size: 8, num_trials: 1)

    assert hd(first.candidates).sampled_indices == Enum.to_list(0..7)
    assert hd(first.candidates).evaluation_scope == :full_validation

    assert get_in(first.metadata.resume_state, ["payload", "state", "rng"]) ==
             get_in(baseline.metadata.resume_state, ["payload", "state", "rng"])
  end

  test "equal minibatch means promote combinations in first-seen order" do
    report = compile_report(12, metric: fn _expected, _prediction -> true end)

    assert Enum.map(tl(report.metadata.full_evaluations), fn evaluation ->
             evaluation.params["atom:main:instruction"]
           end) == [1, 2, 3]
  end

  test "ordinary minibatch errors score zero while operational safety remains fatal" do
    failing_task =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          if inspect(messages) =~ "validation-",
            do: {:error, :ordinary_failure},
            else: %{route: "K11"}
        end
      )

    ordinary = compile_report(1, task_lm: failing_task, max_errors: 0, num_trials: 1)
    assert Enum.map(ordinary.metadata.full_evaluations, & &1.score) == [0.0, 0.0]
    assert Enum.map(ordinary.candidates, & &1.score) == [0.0]

    safety_task =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          if inspect(messages) =~ "validation-" do
            MIPROv2.operational_error(:cost, :budget_drift, message: "minibatch budget drift")
          else
            %{route: "K11"}
          end
        end
      )

    assert_raise OperationalSafetyError, "minibatch budget drift", fn ->
      compile_report(1, task_lm: safety_task, max_errors: :infinity, num_trials: 1)
    end
  end

  defp upstream_trace do
    {output, 0} =
      System.cmd(Path.expand(@python), [Path.expand(@runner)],
        env: [{"PYTHONPATH", Path.expand(@source)}],
        stderr_to_stdout: false
      )

    output |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()
  end

  defp compile_report(max_trials, overrides \\ []) do
    max_trials
    |> compile_result(overrides)
    |> Report.fetch()
  end

  defp compile_result(max_trials, overrides \\ []) do
    metric = Keyword.get(overrides, :metric, &__MODULE__.metric/2)

    task_lm =
      Keyword.get_lazy(overrides, :task_lm, fn ->
        Imp.LM.Static.new(handler: fn _messages, _opts -> %{route: "K11"} end)
      end)

    prompt_answers =
      start_supervised!(
        {Agent,
         fn ->
           [
             %{observations: "first observations"},
             %{observations: "second observations"},
             %{summary: "frozen dataset summary"}
           ] ++ Enum.map(0..3, &%{proposed_instruction: "candidate #{&1}"})
         end},
        id: {:prompt_answers, System.unique_integer([:positive])}
      )

    prompt_lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          Agent.get_and_update(prompt_answers, fn [answer | rest] -> {answer, rest} end)
        end
      )

    program =
      "text -> route"
      |> Imp.signature("Route the opaque request.")
      |> Imp.predict(lm: task_lm, adapter: Imp.Adapter.Chat)

    trainset =
      Enum.map(0..19, fn index ->
        Imp.example(
          text: "train-#{index |> Integer.to_string() |> String.pad_leading(2, "0")}",
          route: "K11"
        )
        |> Imp.with_inputs(:text)
      end)

    valset =
      Enum.map(0..7, fn index ->
        route = if index in [0, 3, 4, 7], do: "K11", else: "OTHER"

        Imp.example(
          text: "validation-#{index |> Integer.to_string() |> String.pad_leading(2, "0")}",
          route: route
        )
        |> Imp.with_inputs(:text)
      end)

    defaults = [
      auto: nil,
      num_candidates: 4,
      num_trials: 12,
      max_bootstrapped_demos: 0,
      max_labeled_demos: 0,
      minibatch: true,
      minibatch_size: 3,
      minibatch_full_eval_steps: 5,
      prompt_lm: prompt_lm,
      task_lm: task_lm,
      metric_identity: %{"id" => "route-equality", "version" => 1, "config" => %{}},
      startup_trials: 10,
      max_concurrency: 1,
      max_errors: :infinity,
      program_aware_proposer: false,
      data_aware_proposer: true,
      tip_aware_proposer: true,
      fewshot_aware_proposer: false,
      proposer_fidelity: :dspy_3_2_1,
      search_fidelity: :dspy_3_2_1_optuna_4_9_0,
      seed: 9
    ]

    optimizer_options =
      defaults
      |> Keyword.merge(Keyword.take(overrides, Keyword.keys(defaults)))

    compile_options =
      overrides
      |> Keyword.take([:resume_state])
      |> Keyword.put(:max_trials, max_trials)

    MIPROv2.new(metric, optimizer_options)
    |> MIPROv2.compile(program, trainset, valset, compile_options)
  end

  defp checkpoint_checksum(payload) do
    payload
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
