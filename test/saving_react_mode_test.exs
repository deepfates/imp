defmodule DSEx.SavingReActModeTest do
  use ExUnit.Case, async: true

  test "round-trips provider-native ReAct mode" do
    loaded = round_trip(DSEx.react("question -> answer", [], mode: :provider_native))

    assert loaded.mode == :provider_native
    assert loaded.tools.submit.description == "Submit final outputs"
    assert DSEx.Tool.call(loaded.tools.submit, %{answer: "Paris"}) == %{answer: "Paris"}
  end

  test "round-trips DSPy 3.2.1 ReAct mode" do
    loaded = round_trip(DSEx.react("question -> answer", [], mode: :dspy_3_2_1))

    assert loaded.mode == :dspy_3_2_1

    assert loaded.tools.submit.description ==
             "Mark the task complete so the collected information can be extracted"

    assert DSEx.Tool.call(loaded.tools.submit, %{answer: "ignored"}) == "Completed."
  end

  test "loads legacy ReAct state as provider-native mode" do
    legacy_state =
      DSEx.react("question -> answer", [])
      |> DSEx.Saving.dump()
      |> Map.delete("mode")

    loaded = DSEx.Saving.load(legacy_state)

    assert loaded.mode == :provider_native
    assert DSEx.Tool.call(loaded.tools.submit, %{answer: "Paris"}) == %{answer: "Paris"}
  end

  test "rejects unknown persisted mode strings without creating atoms" do
    unknown_mode = "tampered_mode_#{System.unique_integer([:positive])}"
    state = react_state() |> Map.put("mode", unknown_mode)

    assert_raise ArgumentError, ~r/invalid saved ReAct mode/, fn ->
      DSEx.Saving.load(state)
    end

    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown_mode) end
  end

  test "rejects non-string tampered mode values" do
    state = react_state() |> Map.put("mode", :dspy_3_2_1)

    assert_raise ArgumentError, ~r/invalid saved ReAct mode/, fn ->
      DSEx.Saving.load(state)
    end
  end

  defp react_state do
    DSEx.react("question -> answer", [])
    |> DSEx.Saving.dump()
  end

  defp round_trip(program) do
    program
    |> DSEx.Saving.dump()
    |> Jason.encode!()
    |> Jason.decode!()
    |> DSEx.Saving.load()
  end
end
