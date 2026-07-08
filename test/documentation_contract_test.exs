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
    assert body =~ "mix livebook.execute.check"
  end

  test "user-facing docs name the executable Livebook proof" do
    assert File.read!("README.md") =~ "mix livebook.execute.check"
    assert File.read!("docs/README.md") =~ "mix livebook.execute.check"
    assert File.read!("docs/PRODUCTION_OPERATIONS.md") =~ "mix livebook.execute.check"
  end

  test "README teaches the new-app onboarding path" do
    body = File.read!("README.md")

    assert body =~ "mix new qa_bot --sup"
    assert body =~ "DSEx.LM.Static"
    assert body =~ "DSEx.context([lm: lm, adapter: DSEx.Adapter.Chat]"
    assert body =~ "OPENAI_MODEL"
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

  test "API guide RAG example retrieves context, records metadata, and stays portable" do
    docs = [
      %{text: "France has capital Paris."},
      %{text: "Germany has capital Berlin."}
    ]

    lm = %{
      module: DSEx.LM.Static,
      opts: [
        handler: fn messages, _opts ->
          prompt = Enum.map_join(messages, "\n", & &1.content)

          if prompt =~ "France has capital Paris.",
            do: %{answer: "Paris"},
            else: %{answer: "unknown"}
        end
      ]
    }

    retriever = DSEx.Retrieve.Memory.new(docs, k: 1)

    program =
      "question, context -> answer"
      |> DSEx.predict(lm: lm)
      |> DSEx.rag(retriever, k: 1)

    assert {:ok, prediction} = DSEx.call(program, %{question: "capital France"})
    assert DSEx.get(prediction, :answer) == "Paris"
    assert prediction.metadata.retrieval.count == 1

    path =
      Path.join(
        System.tmp_dir!(),
        "dsex-doc-rag-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(path) end)

    assert :ok = DSEx.Saving.save!(program, path)
    assert %DSEx.Predict.RAG{retriever: %DSEx.Retrieve.Memory{}} = DSEx.Saving.load!(path)
  end

  test "API guide Optimize.Anything and GEPA examples produce improving reports" do
    artifact = DSEx.Optimize.Anything.new_artifact(:config, "mode=slow")

    report =
      DSEx.Optimize.Anything.optimize(
        artifact,
        fn artifact, _examples ->
          if artifact.text =~ "mode=fast", do: 1.0, else: 0.0
        end,
        trials: 1,
        mutation_fn: fn _artifact, _trial, _seed -> "mode=fast" end
      )

    assert report.baseline.score == 0.0
    assert report.best.score == 1.0
    assert report.best.artifact.text =~ "mode=fast"

    prompt = DSEx.Optimize.Anything.new_artifact(:prompt, "Base")

    gepa_report =
      DSEx.Optimize.GEPA.optimize(
        prompt,
        fn artifact, examples ->
          %{
            per_example_scores:
              Enum.map(examples, &if(String.contains?(artifact.text, &1), do: 1.0, else: 0.0)),
            asi: Enum.reject(examples, &String.contains?(artifact.text, &1))
          }
        end,
        examples: ["Paris", "concise"],
        dev_examples: ["Paris"],
        generations: 2,
        mutation_fn: fn _artifact, asi, _generation -> {:replace, Enum.join(asi, " ")} end
      )

    assert gepa_report.best.aggregate_score >= gepa_report.baseline.aggregate_score
    assert gepa_report.metadata.frontier_size >= 1
  end

  test "API guide MCP import example returns ordinary DSEx tools" do
    catalog =
      DSEx.MCP.Catalog.new([
        %{
          name: :lookup,
          description: "lookup",
          input_schema: %{required: [:key]},
          run: & &1
        }
      ])

    [tool] = DSEx.MCP.import_tools(catalog)

    assert tool.name == :lookup
    assert DSEx.Tool.call(tool, %{key: "value"}) == %{key: "value"}
  end

  test "API guide streaming example collects predictions and parses incremental fields" do
    lm = %{
      module: DSEx.LM.Static,
      opts: [handler: fn _messages, _opts -> %{answer: "Paris"} end]
    }

    program = DSEx.predict("question -> answer", lm: lm)

    assert DSEx.Streaming.stream(program, %{question: "q"}) |> Enum.to_list() == [
             "P",
             "a",
             "r",
             "i",
             "s"
           ]

    assert DSEx.Streaming.incremental_fields(
             ["[[ ## answer ## ]]Paris", "[[ ## rationale ## ]]lookup"],
             "question -> answer, rationale"
           ) == [
             %{field: :answer, value: "Paris"},
             %{field: :rationale, value: "lookup"}
           ]
  end

  defp refute_closed_ticket_refs(body) do
    refute body =~ "de-wrnz"
    refute body =~ "de-i8cc"
    refute body =~ "de-qvwf"
    refute body =~ "de-i4o5"
  end
end
