defmodule DSEx.Optimizer.ParameterContractTest do
  use ExUnit.Case, async: true

  alias DSEx.Optimizer.Parameter
  alias DSEx.Optimizer.Parameter.{Change, Set}
  alias DSEx.ProgramParameters

  test "parameter and set persistence is deterministic and rejects tampering" do
    instruction = Parameter.new("predictor/main/instruction", :instruction, "Answer exactly.")
    config = Parameter.new("predictor/main/config", :config, %{"temperature" => 0})
    set = Set.new("program/Elixir.DSEx.Predict.Predict", [config, instruction])

    assert set == set |> Set.dump() |> Set.load!()

    assert Parameter.dump(instruction) ==
             Parameter.dump(Parameter.new(instruction.id, instruction.kind, instruction.value))

    tampered = put_in(Set.dump(set), ["parameters", Access.at(0), "value"], %{"temperature" => 1})

    assert_raise ArgumentError, ~r/parameter digest/, fn -> Set.load!(tampered) end
  end

  test "parameter values are JSON-only and secret-safe" do
    for value <- [:atom, {:tuple}, self(), fn -> :ok end, %{atom_key: "value"}] do
      assert_raise ArgumentError, ~r/JSON data/, fn -> Parameter.new("unsafe", :config, value) end
    end

    assert_raise ArgumentError, ~r/credentials or secret-shaped data/, fn ->
      Parameter.new("unsafe", :config, %{"api_key" => "sk-secret-value"})
    end
  end

  test "set updates are atomic, digest-guarded, and revisioned" do
    first = Parameter.new("first", :instruction, "one")
    second = Parameter.new("second", :instruction, "two")
    set = Set.new("pair", [first, second])

    valid = Change.new("first", :instruction, "ONE", base_digest: first.digest)
    stale = Change.new("second", :instruction, "TWO", base_digest: String.duplicate("0", 64))

    assert {:error, {:stale_parameter_digest, "second", _, _}} =
             Set.apply_changes(set, [valid, stale])

    assert {:ok, unchanged} = Set.fetch(set, "first")
    assert unchanged.value == "one"

    valid_second = Change.new("second", :instruction, "TWO", base_digest: second.digest)
    assert {:ok, committed} = Set.apply_changes(set, [valid, valid_second])
    assert committed.revision == 1
    assert committed.parent_hash == set.hash
    assert committed.hash != set.hash
  end

  test "program instruction, demos, and nested config round-trip through typed changes" do
    demo = DSEx.example(question: "Capital?", answer: "Paris") |> DSEx.with_inputs(:question)

    source =
      DSEx.predict("question -> answer",
        demos: [demo],
        config: [response_format: %{"type" => "json_schema", "schema" => %{"strict" => true}}]
      )

    target =
      source
      |> ProgramParameters.put_instruction(:main, "Return one city.")
      |> ProgramParameters.put_demos(:main, [DSEx.example(question: "2+2?", answer: "4")])
      |> ProgramParameters.put_config(
        :main,
        response_format: %{"type" => "json_object", "nested" => %{"type" => "kept-string"}}
      )

    changes = ProgramParameters.diff(source, target)
    assert Enum.map(changes, & &1.kind) |> Enum.sort() == [:config, :demos, :instruction]

    assert {:ok, applied, snapshot} =
             ProgramParameters.apply_changes_with_snapshot(source, changes)

    predictor = DSEx.ProgramAccess.predict(applied)
    assert predictor.signature.instructions == "Return one city."
    assert [applied_demo] = predictor.demos
    assert DSEx.Example.get(applied_demo, :answer) == "4"

    assert predictor.config[:response_format] == %{
             "type" => "json_object",
             "nested" => %{"type" => "kept-string"}
           }

    assert snapshot.revision == 1
    assert ProgramParameters.snapshot(applied) == snapshot
  end

  test "lineage survives predictor-owning wrappers" do
    metric = fn _example, _prediction -> 1.0 end

    wrappers = [
      DSEx.predict("question -> answer") |> DSEx.Predict.BestOfN.new(metric),
      DSEx.predict("question -> answer") |> DSEx.Predict.Refine.new(metric),
      DSEx.predict("question -> answer")
      |> DSEx.Predict.Assertions.new([{:valid, fn _prediction -> true end}])
    ]

    for wrapper <- wrappers do
      instruction = Enum.find(ProgramParameters.parameters(wrapper), &(&1.kind == :instruction))

      change =
        Change.new(instruction.id, :instruction, "Changed.", base_digest: instruction.digest)

      assert {:ok, updated, committed} =
               ProgramParameters.apply_changes_with_snapshot(wrapper, [change])

      assert committed.revision == 1
      assert ProgramParameters.snapshot(updated) == committed
    end
  end

  test "ReAct tool parameters preserve executable authority and refresh provider config" do
    runner = fn %{query: query} -> query end

    tool =
      DSEx.Tool.new(:lookup, "Old description", runner,
        schema: %{"type" => "object", "properties" => %{"query" => %{"type" => "string"}}}
      )

    programs = [
      DSEx.Predict.ReAct.new("question -> answer", [tool]),
      DSEx.Predict.ReActV2.new("question -> answer", [tool])
    ]

    for program <- programs do
      original_submit = program.tools.submit
      parameters = ProgramParameters.parameters(program)
      description = Enum.find(parameters, &(&1.kind == :tool_description))
      schema = Enum.find(parameters, &(&1.kind == :tool_schema))

      changes = [
        Change.new(description.id, description.kind, "New description",
          base_digest: description.digest
        ),
        Change.new(
          schema.id,
          schema.kind,
          %{"type" => "object", "properties" => %{"term" => %{"type" => "string"}}},
          base_digest: schema.digest
        )
      ]

      assert {:ok, updated} = ProgramParameters.apply_changes(program, changes)
      assert updated.tools.lookup.name == :lookup
      assert updated.tools.lookup.run === runner
      assert updated.tools.lookup.description == "New description"
      assert updated.tools.submit == original_submit

      changed_submit = %{original_submit | description: "Override submit"}

      assert_raise ArgumentError, ~r/submit is reserved/, fn ->
        apply(program.__struct__, :with_tools, [
          program,
          %{program.tools | submit: changed_submit}
        ])
      end

      changed_runner = %{program.tools.lookup | run: fn _input -> :replaced end}

      assert_raise ArgumentError, ~r/preserve tool names and runners/, fn ->
        apply(program.__struct__, :with_tools, [
          program,
          %{program.tools | lookup: changed_runner}
        ])
      end

      provider_lookup =
        updated.react.config[:tools]
        |> Enum.find(&(&1.function.name == "lookup"))

      assert provider_lookup.function.description == "New description"

      assert provider_lookup.function.parameters["properties"] == %{
               "term" => %{"type" => "string"}
             }
    end
  end
end
