defmodule DSEx.SavingCurrentSchemaTest do
  use ExUnit.Case, async: true

  test "RLM state requires every interpreter budget emitted by dump/1" do
    state = DSEx.Predict.RLM.new("question -> answer") |> DSEx.Saving.dump()

    for key <-
          ~w(max_recursion_depth max_interpreter_steps max_interpreter_value_bytes max_interpreter_effects) do
      assert_raise ArgumentError, ~r/missing required keys/, fn ->
        state |> Map.delete(key) |> DSEx.Saving.load()
      end
    end
  end

  test "SemanticF1 state requires its current scoring configuration" do
    state = DSEx.Evaluate.SemanticF1.new() |> DSEx.Saving.dump()

    for key <- ~w(threshold decompositional) do
      assert_raise ArgumentError, ~r/missing required keys/, fn ->
        state |> Map.delete(key) |> DSEx.Saving.load()
      end
    end
  end

  test "pre-canonical CompleteAndGrounded state is rejected" do
    stale = %{
      "type" => "complete_and_grounded",
      "predict" => DSEx.chain_of_thought("question -> answer") |> DSEx.Saving.dump()
    }

    assert_raise ArgumentError, ~r/unsupported saved DSEx program type/, fn ->
      DSEx.Saving.load(stale)
    end
  end
end
