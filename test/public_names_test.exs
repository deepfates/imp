defmodule Imp.PublicNamesTest do
  # One name per idea, and DSPy's where DSPy has one.
  use ExUnit.Case, async: true

  test "a forced submit's reasoning event says forced, a JSON-plain key" do
    owner = self()

    lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          %{
            next_thought: "enough",
            tool_calls: [%{name: "submit", arguments: %{answer: "a", score: 1}}]
          }
        end
      )

    program = Imp.Predict.ReActV2.new("question -> answer, score: int", [], lm: lm, max_iters: 0)

    assert {:ok, run} =
             Imp.start_run(program, %{question: "q"},
               event_sink: fn event -> send(owner, {:run_event, event}) end
             )

    assert {:ok, _prediction} = Task.await(run.task)
    :ok = Imp.Run.stop(run)

    assert_received {:run_event, %Imp.Run.Event{kind: :reasoning, metadata: metadata}}
    assert metadata[:forced] == true
    refute Map.has_key?(metadata, :forced?)

    # A turn is one call of the program; the reasoning belongs to one step of it.
    assert metadata[:step] == 0
    refute Map.has_key?(metadata, :turn)
  end

  test "RLM counts its turns in max_iterations only, DSPy RLM's name" do
    assert %Imp.Predict.RLM{max_iterations: 3} = Imp.rlm("question -> answer", max_iterations: 3)

    assert_raise ArgumentError, ~r/unknown options \[:max_iters\]/, fn ->
      Imp.rlm("question -> answer", max_iters: 3)
    end
  end

  test "Refine counts its attempts in n, as BestOfN and DSPy's Refine do" do
    metric = fn _example, _prediction -> 1.0 end

    assert %Imp.Predict.Refine{n: 2} =
             Imp.refine(Imp.predict("question -> answer"), metric, n: 2)

    assert_raise ArgumentError, ~r/unknown options \[:max_attempts\]/, fn ->
      Imp.refine(Imp.predict("question -> answer"), metric, max_attempts: 2)
    end
  end

  test "a load that raises is load!, and reading a file is read!" do
    for module <- [Imp.Signature, Imp.History, Imp.Optimizer.Report] do
      Code.ensure_loaded!(module)
      assert function_exported?(module, :load!, 1)
      refute function_exported?(module, :load, 1)
    end

    Code.ensure_loaded!(Imp.Clients.TrainingJob)
    assert function_exported?(Imp.Clients.TrainingJob, :load!, 2)
    assert function_exported?(Imp.Clients.TrainingJob, :read!, 2)
    refute function_exported?(Imp.Clients.TrainingJob, :load, 2)

    for module <- [Imp.Datasets.GSM8K, Imp.Datasets.HotPotQA, Imp.Datasets.MATH] do
      Code.ensure_loaded!(module)
      assert function_exported?(module, :read!, 1)
      refute function_exported?(module, :load, 1)
    end

    Code.ensure_loaded!(Imp.Datasets.DataLoader)
    Code.ensure_loaded!(Imp.Datasets.Colors)
    assert function_exported?(Imp.Datasets.DataLoader, :read!, 3)
    refute function_exported?(Imp.Datasets.DataLoader, :load, 3)
    assert function_exported?(Imp.Datasets.Colors, :load!, 1)
  end
end
