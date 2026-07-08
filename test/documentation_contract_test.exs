defmodule DocumentationContractTest do
  use ExUnit.Case, async: true

  test "coverage matrix describes current evidence instead of closed planning tickets" do
    body = File.read!("docs/COVERAGE_MATRIX.md")

    refute_closed_ticket_refs(body)
    refute body =~ "integration gate should"
    refute body =~ "integration gate required"
    refute body =~ "integration gate needed"

    assert body =~ "mix integration.check"
    assert body =~ "mix protocol.training.check"
    assert body =~ "mix protocol.check"
  end

  test "release criteria are expressed as current product evidence, not historical tickets" do
    body = File.read!("docs/RELEASE_CRITERIA.md")

    refute_closed_ticket_refs(body)
    refute body =~ "The production release scope is tracked under ticket"

    assert body =~ ~r/Historical planning tickets are not release\s+criteria/
    assert body =~ "mix production.check"
    assert body =~ "mix benchmark.dashboard.full"
  end

  test "API guide ReAct example is executable with a deterministic tool-calling LM" do
    {:ok, actions} =
      Agent.start_link(fn ->
        [
          %{tool_calls: [%{name: :lookup, arguments: %{query: "capital-france"}}]},
          %{tool_calls: [%{name: :submit, arguments: %{answer: "Paris"}}]}
        ]
      end)

    lm = %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn _messages, _opts ->
          Agent.get_and_update(actions, fn
            [action | rest] -> {action, rest}
            [] -> {%{tool_calls: []}, []}
          end)
        end
      ]
    }

    lookup =
      DSEx.tool(
        :lookup,
        "lookup facts",
        fn %{query: "capital-france"} -> "Paris" end,
        schema: %{
          "type" => "object",
          "properties" => %{"query" => %{"type" => "string"}},
          "required" => ["query"]
        }
      )

    program = DSEx.react("question -> answer", [lookup], lm: lm, tool_policy: [:lookup, :submit])

    assert {:ok, prediction} =
             DSEx.call(program, %{question: "What is the capital of France?"})

    assert DSEx.get(prediction, :answer) == "Paris"
  end

  test "API guide Save And Load example uses a portable program" do
    path =
      Path.join(
        System.tmp_dir!(),
        "dsex-doc-save-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(path) end)

    program = DSEx.predict("question -> answer")

    assert :ok = DSEx.Saving.save!(program, path)
    assert %DSEx.Predict.Predict{} = DSEx.Saving.load!(path)
  end

  defp refute_closed_ticket_refs(body) do
    refute body =~ "de-wrnz"
    refute body =~ "de-i8cc"
    refute body =~ "de-qvwf"
    refute body =~ "de-i4o5"
  end
end
