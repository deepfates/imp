defmodule Mix.Tasks.Imp.Benchmark.RagToolAgent do
  @moduledoc """
  Run provider-free RAG, tool, and agent production-semantics parity checks.

      mix imp.benchmark.rag_tool_agent

  The task compares directly equivalent DSPy slices where practical and records
  Imp-only production semantics for surfaces DSPy does not model the same way.
  """

  use Mix.Task

  @shortdoc "Run RAG/tool/agent parity and production-semantics checks"

  @default_out_dir "benchmarks/results"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          out: :string,
          python: :string
        ]
      )

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    out_dir = Keyword.get(opts, :out, @default_out_dir)
    File.mkdir_p!(out_dir)

    imp = imp_report()
    dspy = dspy_report(python(opts), out_dir)
    report = comparison_report(imp, dspy)
    out_path = Path.join(out_dir, "rag-tool-agent-parity-#{timestamp_slug()}.json")
    File.write!(out_path, Jason.encode!(report, pretty: true) <> "\n")

    Mix.shell().info("RAG/tool/agent parity report: #{out_path}")

    Mix.shell().info(
      "RAG/tool/agent passing rows: #{report["summary"]["passing"]}/#{report["summary"]["total"]}"
    )

    unless report["summary"]["all_passing"] do
      Mix.raise("RAG/tool/agent parity failed; inspect #{out_path}")
    end
  end

  defp imp_report do
    rows = [
      rag_memory_retrieval_row(),
      rag_multi_hop_retrieval_row(),
      http_retriever_protocol_row(),
      react_lookup_tool_row(),
      react_unknown_tool_error_row(),
      mcp_import_agent_row(),
      agent_policy_denial_row(),
      code_act_row(),
      program_of_thought_row(),
      program_of_thought_sandbox_error_row(),
      streaming_incremental_row(),
      async_concurrency_row(),
      save_load_redaction_row()
    ]

    %{
      "schema_version" => 1,
      "runner" => "imp-rag-tool-agent",
      "generated_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "git_sha" => git_sha(),
      "elixir" => System.version(),
      "otp" => System.otp_release(),
      "rows" => rows
    }
  end

  defp rag_memory_retrieval_row do
    retriever =
      Imp.Retrieve.Memory.new([
        %{id: "fr", text: "France capital: Paris."},
        %{id: "beam", text: "BEAM runs lightweight Elixir processes."}
      ])

    {:ok, [doc]} = Imp.Retrieve.retrieve(retriever, "What is France's capital?", k: 1)

    lm = fn _messages, _opts ->
      {:ok, %{answer: if(String.contains?(doc.text, "Paris"), do: "Paris", else: "unknown")}}
    end

    program = Imp.predict("question, context -> answer", lm: lm)

    {:ok, prediction} =
      Imp.call(program, %{question: "What is France's capital?", context: doc.text})

    answer = Imp.Prediction.get(prediction, :answer)

    %{
      "id" => "rag_memory_retrieval",
      "category" => "rag",
      "comparison_status" => "direct",
      "passing" => answer == "Paris" and doc.text == "France capital: Paris.",
      "answer" => answer,
      "retrieved" => [normalize(doc)],
      "trace" => %{"retriever" => "Imp.Retrieve.Memory", "documents" => 1}
    }
  end

  defp rag_multi_hop_retrieval_row do
    retriever = fn query, _opts ->
      cond do
        String.contains?(query, "Paris") ->
          {:ok, [%{id: "answer", text: "Paris is the capital of France."}]}

        String.contains?(query, "Eiffel") ->
          {:ok, [%{id: "bridge", text: "The Eiffel Tower is in Paris."}]}

        true ->
          {:ok, []}
      end
    end

    lm = fn messages, _opts ->
      prompt = Enum.map_join(messages, "\n", & &1.content)

      answer =
        if String.contains?(prompt, "The Eiffel Tower is in Paris.") and
             String.contains?(prompt, "Paris is the capital of France."),
           do: "France",
           else: "unknown"

      {:ok, %{answer: answer}}
    end

    program =
      "question, context -> answer"
      |> Imp.predict(lm: lm)
      |> Imp.rag(retriever, k: 1, hops: 2)

    {:ok, prediction} =
      Imp.call(program, %{question: "Which country has the capital of Eiffel's city?"})

    retrieval = prediction.metadata.retrieval

    %{
      "id" => "rag_multi_hop_retrieval",
      "category" => "rag",
      "comparison_status" => "imp_only",
      "passing" =>
        Imp.Prediction.get(prediction, :answer) == "France" and retrieval.count == 2 and
          Enum.map(retrieval.docs, & &1.id) == ["bridge", "answer"] and
          Enum.map(retrieval.hops, & &1.count) == [1, 1],
      "answer" => Imp.Prediction.get(prediction, :answer),
      "retrieved" => Enum.map(retrieval.docs, &normalize/1),
      "trace" => %{
        "hops" => Enum.map(retrieval.hops, &normalize/1)
      },
      "deviation" =>
        "Imp multi-hop RAG is a native iterative retrieval option on Imp.rag/3; DSPy rows cover one-shot RAG directly while this row proves Imp-owned hop semantics."
    }
  end

  defp react_lookup_tool_row do
    {:ok, queue} =
      Agent.start_link(fn ->
        [
          %{tool_calls: [%{name: :lookup, arguments: %{query: "capital-france"}}]},
          %{tool_calls: [%{name: :submit, arguments: %{answer: "Paris"}}]}
        ]
      end)

    lm = fn _messages, _opts ->
      Agent.get_and_update(queue, fn
        [response | rest] -> {{:ok, response}, rest}
        [] -> {{:error, :empty}, []}
      end)
    end

    lookup =
      Imp.Tool.new(:lookup, "Lookup a fact by query.", fn %{query: "capital-france"} ->
        "Paris"
      end)

    agent = Imp.react("question -> answer", [lookup], lm: lm, max_iters: 3)
    {:ok, prediction} = Imp.Predict.ReAct.call(agent, %{question: "What is France's capital?"})
    Agent.stop(queue)

    trace =
      prediction
      |> Imp.Prediction.get(:history)
      |> Enum.reject(&(&1.tool == :submit))
      |> Enum.map(
        &%{
          "tool" => to_string(&1.tool),
          "arguments" => normalize(&1.arguments),
          "result" => &1.result
        }
      )

    %{
      "id" => "react_lookup_tool",
      "category" => "tools",
      "comparison_status" => "direct",
      "passing" =>
        Imp.Prediction.get(prediction, :answer) == "Paris" and trace == expected_tool_trace(),
      "answer" => Imp.Prediction.get(prediction, :answer),
      "tool_trace" => trace,
      "trace" => %{
        "termination_reason" => to_string(Imp.Prediction.get(prediction, :termination_reason))
      }
    }
  end

  defp http_retriever_protocol_row do
    {:ok, requests} = Agent.start_link(fn -> [] end)

    transport = fn url, headers, body, opts ->
      decoded = Jason.decode!(IO.iodata_to_binary(body))

      Agent.update(requests, fn entries ->
        entries ++
          [
            %{
              "url" => url,
              "headers" => normalize(headers),
              "body" => decoded,
              "opts" => normalize(opts)
            }
          ]
      end)

      {:ok,
       %{
         status: 200,
         headers: [{"content-type", "application/json"}],
         body:
           Jason.encode!(%{
             documents: [
               %{text: "Paris is the capital of France.", score: 0.99, id: "http-doc"}
             ]
           })
       }}
    end

    retriever = Imp.Retrievers.HTTP.new("https://retriever.example/search", transport: transport)
    result = Imp.Retrieve.retrieve(retriever, "capital France", k: 1)
    request_log = Agent.get(requests, & &1)
    Agent.stop(requests)

    {:ok, [doc]} = result
    [request] = request_log

    %{
      "id" => "http_retriever_protocol_shape",
      "category" => "retriever_protocol",
      "comparison_status" => "imp_only",
      "passing" =>
        request["url"] == "https://retriever.example/search" and
          request["body"] == %{"query" => "capital France", "k" => 1} and
          doc.text == "Paris is the capital of France." and doc.metadata["id"] == "http-doc",
      "retrieved" => [normalize(doc)],
      "trace" => %{"request" => request},
      "deviation" =>
        "Provider-facing HTTP retriever protocol shape is an Imp production boundary; this row proves request construction, response mapping, and metadata preservation without live service state."
    }
  end

  defp react_unknown_tool_error_row do
    lm = fn _messages, _opts ->
      {:ok, %{tool_calls: [%{name: :missing_tool, arguments: %{query: "capital-france"}}]}}
    end

    agent = Imp.react("question -> answer", [], lm: lm, max_iters: 1)
    result = Imp.Predict.ReAct.call(agent, %{question: "What is France's capital?"})

    passing =
      match?({:error, {:unknown_tool, :missing_tool}}, result)

    %{
      "id" => "react_unknown_tool_error_trace",
      "category" => "tools",
      "comparison_status" => "imp_only",
      "passing" => passing,
      "trace" => normalize(result),
      "deviation" =>
        "Unknown provider tool-call handling is Imp production error semantics; direct DSPy rows cover successful ReAct tool use."
    }
  end

  defp mcp_import_agent_row do
    catalog =
      Imp.MCP.Catalog.new([
        %{
          name: :lookup,
          description: "lookup a value",
          input_schema: %{required: [:key]},
          run: fn %{key: key} -> %{value: "value:#{key}"} end
        }
      ])

    [tool] = Imp.MCP.import_tools(catalog)

    agent =
      Imp.Agent.new(
        :lookup_agent,
        fn agent, %{key: key}, runtime ->
          Imp.Agent.call_tool(agent, :lookup, %{key: key}, runtime)
        end,
        tools: [tool]
      )

    {:ok, output, runtime} = Imp.Agent.run(agent, %{key: "abc"})

    %{
      "id" => "mcp_import_agent_trace",
      "category" => "mcp_agent",
      "comparison_status" => "imp_only",
      "passing" =>
        output == %{value: "value:abc"} and Enum.map(runtime.traces, & &1.type) == [:tool, :agent],
      "trace" => normalize(runtime.traces),
      "deviation" =>
        "DSPy does not expose Imp's MCP import and typed Agent runtime; this row proves Imp production semantics."
    }
  end

  defp agent_policy_denial_row do
    tool = Imp.Tool.new(:blocked, "blocked", fn _ -> "nope" end)

    agent =
      Imp.Agent.new(
        :locked,
        fn agent, _input, runtime ->
          Imp.Agent.call_tool(agent, :blocked, %{}, runtime)
        end,
        tools: [tool],
        tool_policy: []
      )

    {:error, {:tool_denied, :blocked}, runtime} = Imp.Agent.run(agent, %{})

    %{
      "id" => "agent_tool_policy_denial",
      "category" => "agent",
      "comparison_status" => "imp_only",
      "passing" => Enum.map(runtime.traces, & &1.type) == [:tool_denied, :agent_error],
      "trace" => normalize(runtime.traces),
      "deviation" =>
        "Imp Agent tool policies are an Elixir production-runtime surface, not a direct DSPy primitive."
    }
  end

  defp code_act_row do
    actions = [%{tool: "lookup", arguments: %{"key" => "n"}}, %{program: "observation + 1"}]
    Process.put(:rag_tool_agent_code_act_actions, actions)

    lm = %{
      module: Imp.LM.Static,
      opts: [
        handler: fn _messages, _opts ->
          [action | rest] = Process.get(:rag_tool_agent_code_act_actions)
          Process.put(:rag_tool_agent_code_act_actions, rest)
          action
        end
      ]
    }

    lookup = Imp.Tool.new(:lookup, "lookup a number", fn %{key: "n"} -> 41 end)
    code_act = Imp.Predict.CodeAct.new("question -> answer", [lookup], lm: lm, max_iters: 3)
    {:ok, prediction} = Imp.Predict.CodeAct.call(code_act, %{question: "life?"})
    Process.delete(:rag_tool_agent_code_act_actions)

    trace = prediction.metadata.code_act_trace

    %{
      "id" => "code_act_tool_program",
      "category" => "code_act",
      "comparison_status" => "imp_only",
      "passing" =>
        Imp.Prediction.get(prediction, :answer) == 42 and
          Enum.map(trace, & &1.action) == [:tool, :program],
      "trace" => normalize(trace),
      "deviation" =>
        "CodeAct execution policy is tested as Imp production semantics; no direct DSPy row is asserted in this initial artifact."
    }
  after
    Process.delete(:rag_tool_agent_code_act_actions)
  end

  defp program_of_thought_row do
    lm = %{
      module: Imp.LM.Static,
      opts: [handler: fn _messages, _opts -> %{program: "x * 2"} end]
    }

    pot = Imp.Predict.ProgramOfThought.new("x: int -> answer: int", lm: lm)
    {:ok, prediction} = Imp.Predict.ProgramOfThought.call(pot, %{x: 21})

    %{
      "id" => "program_of_thought_safe_eval",
      "category" => "program_of_thought",
      "comparison_status" => "imp_only",
      "passing" => Imp.Prediction.get(prediction, :answer) == 42,
      "trace" => %{"program" => Imp.Prediction.get(prediction, :program)},
      "deviation" =>
        "ProgramOfThought safe evaluation is an Imp execution-policy proof in this artifact."
    }
  end

  defp program_of_thought_sandbox_error_row do
    lm = %{
      module: Imp.LM.Static,
      opts: [handler: fn _messages, _opts -> %{program: "System.cmd(\"echo\", [])"} end]
    }

    pot = Imp.Predict.ProgramOfThought.new("x: int -> answer: int", lm: lm)
    result = Imp.Predict.ProgramOfThought.call(pot, %{x: 21})

    %{
      "id" => "program_of_thought_rejects_unsafe_remote_call",
      "category" => "program_of_thought",
      "comparison_status" => "imp_only",
      "passing" => match?({:error, {:unsafe_ast, _}}, result),
      "trace" => normalize(result),
      "deviation" => "ProgramOfThought sandbox rejection is an Imp execution-policy guarantee."
    }
  end

  defp streaming_incremental_row do
    events =
      Imp.Streaming.incremental_fields(
        ["[[ ## ans", "wer ## ]]Paris", "[[ ## rationale ## ]]retrieved"],
        "question -> answer, rationale"
      )

    %{
      "id" => "streaming_incremental_fields",
      "category" => "streaming",
      "comparison_status" => "imp_only",
      "passing" =>
        events == [%{field: :answer, value: "Paris"}, %{field: :rationale, value: "retrieved"}],
      "trace" => normalize(events),
      "deviation" =>
        "Streaming incremental field parsing is Imp production semantics in this artifact."
    }
  end

  defp async_concurrency_row do
    outputs =
      [1, 2, 3]
      |> Imp.Tasks.async_stream(fn value -> value * 2 end, ordered: true)
      |> Enum.to_list()

    %{
      "id" => "tasks_async_stream_ordered_results",
      "category" => "async",
      "comparison_status" => "imp_only",
      "passing" => outputs == [{:ok, 2}, {:ok, 4}, {:ok, 6}],
      "trace" => normalize(outputs),
      "deviation" =>
        "BEAM-native async stream semantics are an Imp production runtime feature rather than a direct DSPy primitive."
    }
  end

  defp save_load_redaction_row do
    secret = "sk-test-rag-tool-agent-secret"

    program =
      Imp.predict("question -> answer", lm: Imp.req_llm("openai:gpt-test", api_key: secret))

    dump = Imp.Saving.dump(program)
    encoded = inspect(dump)
    loaded = Imp.Saving.load(dump)

    %{
      "id" => "save_load_redacts_provider_secret",
      "category" => "persistence",
      "comparison_status" => "imp_only",
      "passing" =>
        not String.contains?(encoded, secret) and match?(%Imp.Clients.ReqLLM{}, loaded.lm),
      "trace" => %{"secret_persisted" => String.contains?(encoded, secret)},
      "deviation" => "Save/load credential redaction is an Imp production safety invariant."
    }
  end

  defp dspy_report(python, out_dir) do
    out_path = Path.join(out_dir, "dspy-rag-tool-agent-#{timestamp_slug()}.json")

    case System.cmd(python, ["scripts/dspy_rag_tool_agent.py", "--out", out_path],
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        out_path |> File.read!() |> Jason.decode!()

      {output, status} ->
        Mix.raise("DSPy RAG/tool sidecar failed with status #{status}:\n#{output}")
    end
  end

  defp comparison_report(imp, dspy) do
    dspy_rows = Map.new(dspy["rows"], &{&1["id"], &1})

    rows =
      Enum.map(imp["rows"], fn row ->
        compare_row(row, dspy_rows[row["id"]])
      end)

    passing = Enum.count(rows, & &1["passing"])

    %{
      "schema_version" => 1,
      "generated_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "git_sha" => git_sha(),
      "summary" => %{
        "total" => length(rows),
        "passing" => passing,
        "all_passing" => passing == length(rows),
        "direct_comparisons" => Enum.count(rows, &(&1["comparison_status"] == "direct")),
        "imp_only_or_deviation" => Enum.count(rows, &(&1["comparison_status"] != "direct")),
        "provider_free_contract_complete" => true,
        "live_matched_behavior_complete" => false,
        "full_rag_tool_agent_parity" => false,
        "note" =>
          "Provider-free RAG/tool/agent artifact. Direct DSPy comparisons cover deterministic one-shot RAG retrieval and ReAct lookup. Imp production rows cover multi-hop RAG, HTTP retriever protocol shape, MCP import, agent policy denial, ReAct error traces, CodeAct, ProgramOfThought success/error policy, streaming, async, and save/load redaction."
      },
      "imp" => Map.take(imp, ["runner", "elixir", "otp", "git_sha"]),
      "dspy" => Map.take(dspy, ["runner", "python", "dspy_version", "git_sha"]),
      "rows" => rows
    }
  end

  defp compare_row(imp, nil) do
    %{
      "id" => imp["id"],
      "category" => imp["category"],
      "comparison_status" => imp["comparison_status"],
      "passing" => imp["passing"] == true,
      "imp" => imp,
      "dspy" => nil,
      "deviation" =>
        imp["deviation"] || "No direct DSPy comparison for this Imp production-semantics row."
    }
  end

  defp compare_row(imp, dspy) do
    expected = direct_expected(imp["id"])

    parity =
      Map.take(imp, Map.keys(expected)) == expected and
        Map.take(dspy, Map.keys(expected)) == expected

    %{
      "id" => imp["id"],
      "category" => imp["category"],
      "comparison_status" => "direct",
      "passing" => imp["passing"] == true and dspy["passing"] == true and parity,
      "imp" => imp,
      "dspy" => dspy,
      "expected" => expected,
      "deviation" => nil
    }
  end

  defp direct_expected("rag_memory_retrieval"), do: %{"answer" => "Paris"}

  defp direct_expected("react_lookup_tool"),
    do: %{"answer" => "Paris", "tool_trace" => expected_tool_trace()}

  defp expected_tool_trace,
    do: [
      %{"tool" => "lookup", "arguments" => %{"query" => "capital-france"}, "result" => "Paris"}
    ]

  defp python(opts) do
    path =
      Keyword.get(opts, :python) ||
        if File.exists?("tmp/dspy-parity-venv/bin/python"),
          do: "tmp/dspy-parity-venv/bin/python",
          else: "python3"

    if String.contains?(path, "/"), do: Path.expand(path), else: path
  end

  defp normalize(%_struct{} = struct), do: struct |> Map.from_struct() |> normalize()

  defp normalize(%{} = map),
    do: Map.new(map, fn {key, value} -> {to_string(key), normalize(value)} end)

  defp normalize(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> normalize()
  defp normalize(values) when is_list(values), do: Enum.map(values, &normalize/1)
  defp normalize(value) when is_atom(value), do: to_string(value)
  defp normalize(value), do: value

  defp git_sha do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _other -> nil
    end
  end

  defp timestamp_slug do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
    |> String.replace(~r/[^0-9A-Za-z]/, "")
  end
end
