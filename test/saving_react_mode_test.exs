defmodule Imp.SavingReActModeTest do
  use ExUnit.Case, async: true

  test "round-trips provider-native ReAct mode" do
    loaded = round_trip(Imp.Predict.ReAct.new("question -> answer", [], mode: :provider_native))

    assert loaded.mode == :provider_native
    assert loaded.tools.submit.description == "Submit final outputs"
    assert Imp.Tool.call(loaded.tools.submit, %{answer: "Paris"}) == %{"answer" => "Paris"}
  end

  test "round-trips the DSPy ReAct mode" do
    program = Imp.Predict.ReAct.new("question -> answer", [], mode: :dspy)
    assert Imp.Saving.dump(program)["mode"] == "dspy"

    loaded = round_trip(program)

    assert loaded.mode == :dspy

    # The faithful mode's reserved control tool is `finish` (dspy.ReAct), not
    # `submit`, and its description references the signature's output fields.
    refute Map.has_key?(loaded.tools, :submit)

    assert loaded.tools.finish.description ==
             "Marks the task as complete. That is, signals that all information for producing the outputs, i.e. `answer`, are now available to be extracted."

    assert Imp.Tool.call(loaded.tools.finish, %{answer: "ignored"}) == "Completed."
  end

  test "loads a program saved under the mode's name before 0.5.0" do
    state =
      Imp.Predict.ReAct.new("question -> answer", [], mode: :dspy)
      |> Imp.Saving.dump()
      |> Map.put("mode", "dspy_3_2_1")

    assert %Imp.Predict.ReAct{mode: :dspy} = loaded = Imp.Saving.load!(state)
    assert Map.has_key?(loaded.tools, :finish)
  end

  test "rejects ReAct state missing the current mode field" do
    stale_state =
      Imp.Predict.ReAct.new("question -> answer", [])
      |> Imp.Saving.dump()
      |> Map.delete("mode")

    assert_raise ArgumentError, ~r/missing required keys: \["mode"\]/, fn ->
      Imp.Saving.load!(stale_state)
    end
  end

  test "rejects unknown persisted mode strings without creating atoms" do
    unknown_mode = "tampered_mode_#{System.unique_integer([:positive])}"
    state = react_state() |> Map.put("mode", unknown_mode)

    assert_raise ArgumentError, ~r/invalid saved ReAct mode/, fn ->
      Imp.Saving.load!(state)
    end

    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown_mode) end
  end

  test "rejects non-string tampered mode values" do
    state = react_state() |> Map.put("mode", :dspy)

    assert_raise ArgumentError, ~r/invalid saved ReAct mode/, fn ->
      Imp.Saving.load!(state)
    end
  end

  defp react_state do
    Imp.Predict.ReAct.new("question -> answer", [])
    |> Imp.Saving.dump()
  end

  defp round_trip(program) do
    program
    |> Imp.Saving.dump()
    |> Jason.encode!()
    |> Jason.decode!()
    |> Imp.Saving.load!()
  end
end
