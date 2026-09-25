defmodule SavingFreshAtomsTest do
  use ExUnit.Case, async: true

  # A saved program loads in a VM that has never seen its field names as
  # atoms: a fresh `mix run` loading a router saved by another process. The
  # names come back as strings, which `Imp.Example` looks up by text.

  defp rename_atom(term, from, to) do
    case term do
      %{"__imp_type__" => "atom", "value" => ^from} = atom -> %{atom | "value" => to}
      %{} = map -> Map.new(map, fn {k, v} -> {k, rename_atom(v, from, to)} end)
      list when is_list(list) -> Enum.map(list, &rename_atom(&1, from, to))
      other -> other
    end
  end

  test "demos keyed by atoms this VM never created still load" do
    fresh = "never_an_atom_" <> Integer.to_string(System.unique_integer([:positive]))

    trainset = [
      Imp.example(ticket: "charged twice", team: "atlas") |> Imp.Example.with_inputs([:ticket])
    ]

    # LabeledFewShot also attaches its report, which repeats the demos.
    assert {:ok, program} =
             Imp.optimize(
               Imp.predict("ticket -> team"),
               Imp.Optimizer.LabeledFewShot.new(k: 1),
               trainset
             )

    state =
      program
      |> Imp.Saving.dump()
      |> Jason.encode!()
      |> Jason.decode!()
      |> rename_atom("ticket", fresh)

    loaded = Imp.Saving.load(state)
    [demo] = Imp.ProgramAccess.demos(loaded)
    assert Imp.get(demo, fresh) == "charged twice"
    assert Imp.get(demo, :team) == "atlas"
  end
end
