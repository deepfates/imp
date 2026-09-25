defmodule Imp.Optimizer.ParameterContractTest do
  use ExUnit.Case, async: true

  alias Imp.Optimizer.Component
  alias Imp.Optimizer.Parameter
  alias Imp.Optimizer.Parameter.{Change, Set}
  alias Imp.Predict.{Assertions, BestOfN, ReAct, ReActV2, Refine}
  alias Imp.ProgramParameters

  defmodule ComponentProgram do
    @behaviour Imp.Module
    defstruct [:mode, :threshold, :runtime, :dependency_mode]

    @impl true
    def call(program, _inputs),
      do: {:ok, Imp.Prediction.new(%{mode: program.mode, threshold: program.threshold})}

    @impl true
    def optimizer_components(program) do
      mode =
        Parameter.new("routing/mode", :artifact, program.mode)
        |> Component.new(
          description: "Routing strategy",
          constraints: %{"type" => "string", "enum" => ["fast", "careful"]}
        )

      threshold_dependencies =
        if program.dependency_mode == :unknown,
          do: ["routing/missing"],
          else: ["routing/mode"]

      threshold =
        Parameter.new("routing/threshold", :artifact, program.threshold)
        |> Component.new(
          description: "Minimum confidence",
          constraints: %{"type" => "number", "minimum" => 0.0, "maximum" => 1.0},
          dependencies: threshold_dependencies
        )

      if program.dependency_mode == :cycle do
        [%{mode | dependencies: ["routing/threshold"]}, threshold]
      else
        [mode, threshold]
      end
    end

    @impl true
    def update_optimizer_components(program, replacements) do
      send(self(), {:component_update, replacements})

      Enum.reduce(replacements, program, fn
        {"routing/mode", value}, current -> %{current | mode: value}
        {"routing/threshold", value}, current -> %{current | threshold: value}
      end)
    end
  end

  test "parameter and set persistence is deterministic and rejects tampering" do
    instruction = Parameter.new("predictor/main/instruction", :instruction, "Answer exactly.")
    config = Parameter.new("predictor/main/config", :config, %{"temperature" => 0})
    set = Set.new("program/Elixir.Imp.Predict.Predict", [config, instruction])

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

  test "component patterns are compiled when the public constraint is built" do
    parameter = Parameter.new("routing/code", :artifact, "R17")

    assert %Component{constraints: %{"pattern" => "^R[0-9]+$"}} =
             Component.new(parameter, constraints: %{"pattern" => "^R[0-9]+$"})

    assert_raise Regex.CompileError, fn ->
      Component.new(parameter, constraints: %{"pattern" => "["})
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
    demo = Imp.example(question: "Capital?", answer: "Paris") |> Imp.with_inputs(:question)

    source =
      Imp.predict("question -> answer",
        demos: [demo],
        config: [response_format: %{"type" => "json_schema", "schema" => %{"strict" => true}}]
      )

    target =
      source
      |> ProgramParameters.put_instruction(:main, "Return one city.")
      |> ProgramParameters.put_demos(:main, [Imp.example(question: "2+2?", answer: "4")])
      |> ProgramParameters.put_config(
        :main,
        response_format: %{"type" => "json_object", "nested" => %{"type" => "kept-string"}}
      )

    changes = ProgramParameters.diff(source, target)
    assert Enum.map(changes, & &1.kind) |> Enum.sort() == [:config, :demos, :instruction]

    assert {:ok, applied, snapshot} =
             ProgramParameters.apply_changes_with_snapshot(source, changes)

    predictor = Imp.ProgramAccess.predict(applied)
    assert predictor.signature.instructions == "Return one city."
    assert [applied_demo] = predictor.demos
    assert Imp.Example.get(applied_demo, :answer) == "4"

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
      Imp.predict("question -> answer") |> BestOfN.new(metric),
      Imp.predict("question -> answer") |> Refine.new(metric),
      Imp.predict("question -> answer")
      |> Assertions.new([{:valid, fn _prediction -> true end}])
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
    runner = fn %{"query" => query} -> query end

    tool =
      Imp.Tool.new(:lookup, "Old description", runner,
        schema: %{"type" => "object", "properties" => %{"query" => %{"type" => "string"}}}
      )

    # ReActV2 has `submit` only for a signature that is not one text output.
    programs = [
      ReAct.new("question -> answer", [tool]),
      ReActV2.new("question -> answer, confidence: float", [tool])
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
        with_tools(program, %{program.tools | submit: changed_submit})
      end

      changed_runner = %{program.tools.lookup | run: fn _input -> :replaced end}

      assert_raise ArgumentError, ~r/preserve tool names and runners/, fn ->
        with_tools(program, %{program.tools | lookup: changed_runner})
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

  test "custom components are described, constrained, dependency-checked, and atomically applied" do
    runtime = fn value -> {:trusted_runtime, value} end

    program = %ComponentProgram{
      mode: "fast",
      threshold: 0.5,
      runtime: runtime,
      dependency_mode: :valid
    }

    [mode, threshold] = ProgramParameters.components(program)
    assert mode.parameter.id == "routing/mode"
    assert mode.description == "Routing strategy"
    assert mode.constraints["enum"] == ["fast", "careful"]
    assert threshold.dependencies == ["routing/mode"]

    parameters = Map.new([mode, threshold], &{&1.parameter.id, &1.parameter})

    changes = [
      Change.new("routing/mode", :artifact, "careful",
        base_digest: parameters["routing/mode"].digest
      ),
      Change.new("routing/threshold", :artifact, 0.9,
        base_digest: parameters["routing/threshold"].digest
      )
    ]

    assert {:ok, updated} = ProgramParameters.apply_changes(program, changes)
    assert updated.mode == "careful"
    assert updated.threshold == 0.9
    assert updated.runtime === runtime

    assert_received {:component_update,
                     %{"routing/mode" => "careful", "routing/threshold" => 0.9}}

    invalid = [
      hd(changes),
      Change.new("routing/threshold", :artifact, 2.0,
        base_digest: parameters["routing/threshold"].digest
      )
    ]

    assert {:error, {:invalid_parameter_value, "routing/threshold", message}} =
             ProgramParameters.apply_changes(program, invalid)

    assert message =~ "above maximum"
    refute_received {:component_update, _replacements}
    assert program.mode == "fast"
    assert program.threshold == 0.5
  end

  test "component graphs reject unknown dependencies and cycles" do
    base = %ComponentProgram{mode: "fast", threshold: 0.5, runtime: nil}

    assert_raise ArgumentError, ~r/unknown dependencies/, fn ->
      ProgramParameters.components(%{base | dependency_mode: :unknown})
    end

    assert_raise ArgumentError, ~r/contain a cycle/, fn ->
      ProgramParameters.components(%{base | dependency_mode: :cycle})
    end
  end

  test "complete value maps reject omissions before invoking a component callback" do
    program = %ComponentProgram{
      mode: "fast",
      threshold: 0.5,
      runtime: nil,
      dependency_mode: :valid
    }

    assert ProgramParameters.values(program) == %{
             "routing/mode" => "fast",
             "routing/threshold" => 0.5
           }

    assert {:error, {:parameter_value_ids_mismatch, mismatch}} =
             ProgramParameters.apply_values(program, %{"routing/mode" => "careful"})

    assert mismatch.missing == MapSet.new(["routing/threshold"])
    assert mismatch.unknown == MapSet.new()
    refute_received {:component_update, _replacements}
  end

  test "custom components round-trip through an Artifact into fresh trusted code" do
    selected_runtime = fn _ -> :selected_runtime_must_not_persist end

    selected = %ComponentProgram{
      mode: "careful",
      threshold: 0.8,
      runtime: selected_runtime,
      dependency_mode: :valid
    }

    artifact =
      "selected-components"
      |> Imp.Optimizer.Artifact.parameter_candidate(selected, score: 1.0)
      |> Imp.Optimizer.Artifact.new()

    encoded = Jason.encode!(artifact)
    refute encoded =~ "selected_runtime_must_not_persist"

    assert get_in(artifact, ["payload", "candidates", "selected-components", "kind"]) ==
             "parameter_set"

    fresh_runtime = fn value -> {:fresh_runtime, value} end

    fresh = %ComponentProgram{
      mode: "fast",
      threshold: 0.2,
      runtime: fresh_runtime,
      dependency_mode: :valid
    }

    applied = Imp.Optimizer.Artifact.apply(artifact, fresh)
    assert applied.mode == "careful"
    assert applied.threshold == 0.8
    assert applied.runtime === fresh_runtime
    assert applied.runtime.(applied.mode) == {:fresh_runtime, "careful"}

    baseline_artifact =
      "baseline-components"
      |> Imp.Optimizer.Artifact.parameter_candidate(fresh, score: 0.0)

    combined =
      Imp.Optimizer.Artifact.new(baseline_artifact, [
        get_in(artifact, ["payload", "candidates", "selected-components"])
      ])

    assert %{
             changed_components: ["routing/mode", "routing/threshold"],
             changed_predictors: []
           } =
             Imp.Optimizer.Artifact.compare(
               combined,
               "baseline-components",
               "selected-components"
             )
  end

  defp with_tools(%ReAct{} = program, tools), do: ReAct.with_tools(program, tools)

  defp with_tools(%ReActV2{} = program, tools), do: ReActV2.with_tools(program, tools)
end
