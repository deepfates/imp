defmodule Imp.SettingsIsolationRegressionTest do
  # Regression for dee-fqsr: an order-dependent digest flake in the instruction
  # optimizer contract suite (InstructionOptimizerContractArtifactTest), root-caused
  # to other tests leaking a NON-DEFAULT global :lm into the shared Imp.Settings
  # Agent (Imp.configure without an on_exit reset). BootstrapFewShot reads global
  # settings during teacher rollouts, so a leaked :lm can alter the trace-captured
  # demos and shift the {trajectory_index, predictor_name, demos} sha256 selection.
  #
  # These pins assert that BootstrapFewShot demo capture with an explicit predictor
  # LM is invariant to a poisoned global :lm, and that the sha256 selection is a
  # pure function of its inputs. async: false because it mutates the global Agent.
  use ExUnit.Case, async: false

  setup do
    Imp.Settings.reset()
    on_exit(&Imp.Settings.reset/0)
    :ok
  end

  defp compile_demos do
    program =
      Imp.predict("question -> answer",
        lm: %{
          module: Imp.LM.Static,
          opts: [handler: fn _messages, _opts -> %{answer: "generated"} end]
        }
      )

    example = Imp.example(question: "q", answer: "gold") |> Imp.with_inputs(:question)

    Imp.Optimizer.BootstrapFewShot.new(nil, max_bootstrapped_demos: 1, max_labeled_demos: 0)
    |> Imp.Optimizer.BootstrapFewShot.compile(program, [example])
    |> Map.fetch!(:demos)
    |> Enum.map(&Imp.Example.to_map/1)
  end

  defp poison_global_lm do
    Imp.configure(
      lm: %{
        module: Imp.LM.Static,
        opts: [handler: fn _messages, _opts -> %{answer: "POISON"} end]
      }
    )
  end

  test "BootstrapFewShot demo capture is invariant to a leaked global :lm" do
    clean = compile_demos()

    # Simulate the exact leak class: a prior test left a non-default global :lm.
    poison_global_lm()
    refute Imp.Settings.get().lm == nil, "guard: the poison :lm must actually be set globally"

    poisoned = compile_demos()

    assert poisoned == clean
    assert clean == [%{question: "q", answer: "generated", augmented: true}]
  end

  test "repeated_call sha256 selection is a pure function of {index, name, demos}" do
    demos = [
      Imp.example(question: "q0", answer: "a0"),
      Imp.example(question: "q1", answer: "a1"),
      Imp.example(question: "q2", answer: "a2")
    ]

    baseline = Imp.Optimizer.BootstrapFewShot.repeated_call_selection(demos, 0, :main)

    poison_global_lm()
    Imp.configure(async_max_workers: 1, track_usage: true)

    assert Imp.Optimizer.BootstrapFewShot.repeated_call_selection(demos, 0, :main) == baseline
  end
end
