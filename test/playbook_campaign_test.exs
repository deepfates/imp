defmodule Imp.Optimizer.Playbook.CampaignTest do
  use ExUnit.Case, async: true

  alias Imp.Optimizer.Playbook.Campaign
  alias Imp.Optimizer.Playbook.EquationSearch

  test "accepts all 250 pinned references with exact rational precedence" do
    rows =
      "benchmarks/data/playbook/math-equation-balancer.jsonl"
      |> File.stream!()
      |> Enum.map(&Jason.decode!/1)

    assert length(rows) == 250

    assert Enum.all?(rows, fn row ->
             Campaign.validate_equation(row["input"], row["expected"], row["target_value"]) == :ok
           end)
  end

  test "accepts alternate valid assignments and rejects malformed or reordered answers" do
    assert :ok = Campaign.validate_equation("2 ? 3 ? 4 = 14", "2 + 3 * 4 = 14", 14)
    assert :ok = Campaign.validate_equation("8 ? 4 ? 2 = 1", "8 / 4 / 2 = 1", 1)
    assert {:error, _} = Campaign.validate_equation("2 ? 3 ? 4 = 14", "4 * 3 + 2 = 14", 14)
    assert {:error, _} = Campaign.validate_equation("2 ? 3 ? 4 = 14", "2 + (3 * 4) = 14", 14)
    assert {:error, _} = Campaign.validate_equation("2 ? 3 = 5", "2 / 0 = 5", 5)
  end

  test "BEAM-native bounded search solves every pinned reference exactly" do
    rows =
      "benchmarks/data/playbook/math-equation-balancer.jsonl"
      |> File.stream!()
      |> Enum.map(&Jason.decode!/1)

    Enum.each(rows, fn row ->
      assert {:ok, answer} = EquationSearch.solve(row["input"])
      assert :ok = Campaign.validate_equation(row["input"], answer, row["target_value"])
    end)

    assert {:error, :no_solution} = EquationSearch.solve("1 ? 1 = 3")
    assert {:error, :missing_equation} = EquationSearch.solve_tool(%{})
    assert {:error, :invalid_tool_arguments} = EquationSearch.solve_tool("not a map")
    assert "2 + 3 * 4 = 14" = EquationSearch.solve_tool(%{"numbers" => [2, 3, 4], "target" => 14})
    assert {:error, :invalid_search_terms} = EquationSearch.solve_parts("2,3,4", 14)

    assert {:error, :search_bound_exceeded} =
             EquationSearch.solve("1 ? 1 ? 1 ? 1 ? 1 ? 1 ? 1 ? 1 ? 1 = 9")

    assert :ok = Campaign.validate_equation("2 ? -3 = 5", "2 - -3 = 5", 5)
  end

  test "portable audit reload preserves native JSON configuration" do
    playbook = Imp.Playbook.new(id: "campaign-persistence")

    program =
      "equation -> answer"
      |> Imp.predict(config: [native_json_schema: true])
      |> Imp.with_playbook(playbook)

    restored =
      program |> Imp.Saving.dump() |> Jason.encode!() |> Jason.decode!() |> Imp.Saving.load()

    assert restored.program.config == [native_json_schema: true]
    assert restored.playbook == playbook
  end

  test "portable audit reload rebinds the named BEAM solver tool" do
    runner = &EquationSearch.solve_tool/1
    registry = Imp.Saving.Registry.new(solve_equation: runner)

    tool =
      Imp.tool(:solve_equation, "solve exactly", runner,
        schema: %{"type" => "object", "properties" => %{}}
      )

    playbook = Imp.Playbook.new(id: "campaign-code-act-persistence")

    restored =
      "equation -> answer"
      |> Imp.code_act([tool], max_iters: 2, tool_policy: [:solve_equation])
      |> Imp.with_playbook(playbook)
      |> Imp.Saving.dump(registry: registry)
      |> Jason.encode!()
      |> Jason.decode!()
      |> Imp.Saving.load(registry: registry)

    restored_tool = restored.program.tools[:solve_equation]
    assert Imp.Tool.call(restored_tool, %{equation: "2 ? 3 ? 4 = 14"}) == "2 + 3 * 4 = 14"
    assert restored.playbook == playbook
  end

  test "CodeAct traces project into canonical aligned tool events" do
    prediction = %Imp.Prediction{
      fields: %{answer: "2 + 3 * 4 = 14"},
      metadata: %{
        code_act_trace: [
          %{
            action: :tool,
            input: %{name: :solve_equation, arguments: %{equation: "2 ? 3 ? 4 = 14"}},
            output: "2 + 3 * 4 = 14"
          },
          %{action: :program, input: "observation", output: "2 + 3 * 4 = 14"}
        ]
      }
    }

    trace = Campaign.normalize_code_act_trace(prediction)

    trajectory =
      Imp.Optimizer.Trajectory.project(:evaluation, %{
        index: 0,
        example: %{"id" => "row"},
        prediction: %{"answer" => "2 + 3 * 4 = 14"},
        trace: trace,
        score: 1.0
      })

    assert Enum.map(trajectory.events, & &1.kind) == [:tool_call, :tool_result, :program]
    assert [%{tool: :solve_equation}, %{action: :program}] = trace
  end

  test "accounted model failures score zero while transport failures remain terminal" do
    assert {:ok, "code_act_sandbox_error", %{}} =
             Campaign.classify_model_failure({:code_act_sandbox_error, :unsafe, []})

    assert {:ok, "code_act_tool_error", %{}} =
             Campaign.classify_model_failure({:code_act_tool_error, :bad_arguments, []})

    decode = %Jason.DecodeError{position: 0, token: nil, data: "{"}

    assert {:ok, "adapter_decode_failure", %{"raw_sha256" => digest}} =
             Campaign.classify_model_failure(%Imp.AdapterParseError{
               kind: :other,
               reason: decode,
               trace: %{raw: "{"}
             })

    assert byte_size(digest) == 64
    assert :unknown = Campaign.classify_model_failure({:http_error, 503})
  end
end
