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

    loaded = Imp.Saving.load!(state)
    [demo] = Imp.ProgramAccess.demos(loaded)
    assert Imp.get(demo, fresh) == "charged twice"
    assert Imp.get(demo, :team) == "atlas"
  end

  test "a saved RAG program with a memory retriever loads with field names this VM never created" do
    query = "never_q_" <> Integer.to_string(System.unique_integer([:positive]))
    context = "never_c_" <> Integer.to_string(System.unique_integer([:positive]))
    tag = "never_t_" <> Integer.to_string(System.unique_integer([:positive]))

    program =
      Imp.rag(
        Imp.predict("context, question -> answer"),
        Imp.memory([%{text: "Refunds take five days", tag: "billing"}], k: 1)
      )

    state =
      program
      |> Imp.Saving.dump()
      |> Jason.encode!()
      |> Jason.decode!()
      |> rename_atom("question", query)
      |> rename_atom("context", context)
      |> rename_atom("tag", tag)

    loaded = Imp.Saving.load!(state)
    assert to_string(loaded.query_field) == query
    assert to_string(loaded.context_field) == context
    assert [%{^tag => "billing"}] = loaded.retriever.docs
    assert_raise ArgumentError, fn -> String.to_existing_atom(query) end
  end

  test "a saved tool name and tool policy load with names this VM never created" do
    fresh = "never_tool_" <> Integer.to_string(System.unique_integer([:positive]))
    lookup = fn %{"query" => query} -> "found #{query}" end
    registry = Imp.Saving.Registry.new(lookup_runner: lookup)
    tool = Imp.tool(:lookup, "lookup facts", lookup, schema: %{query: :string})

    program =
      Imp.Predict.ReAct.new("question -> answer", [tool], max_iters: 0, tool_policy: [:lookup])

    state =
      program
      |> Imp.dump(registry: registry)
      |> Jason.encode!()
      |> Jason.decode!()
      |> rename_atom("lookup", fresh)

    loaded = Imp.load!(state, registry: registry)
    assert Imp.Tool.call(Map.fetch!(loaded.tools, fresh), %{query: "beam"}) == "found beam"
    assert Imp.ToolPolicy.authorize(loaded.tool_policy, fresh, %{}) == :ok
    assert_raise ArgumentError, fn -> String.to_existing_atom(fresh) end
  end
end
