defmodule Mix.Tasks.Imp.Benchmark.RagToolAgent do
  @moduledoc """
  Run RAG, tool, and agent parity plus production-semantics checks.

      mix imp.benchmark.rag_tool_agent

      mix imp.benchmark.rag_tool_agent \
        --live \
        --model gpt-5.4-mini-2026-03-17 \
        --dspy-model responses/gpt-5.4-mini-2026-03-17 \
        --env-file .env

  The task compares directly equivalent DSPy slices where practical and records
  Imp-only production semantics for surfaces DSPy does not model the same way.
  Live mode adds matched retrieval and tool-use rows and fails closed unless
  model identity, provider-equivalent transport, effective generation controls,
  exact outputs/traces, and provider-reported usage are complete on both sides.
  """

  use Mix.Task

  @shortdoc "Run RAG/tool/agent parity and production-semantics checks"

  @default_out_dir Imp.BenchmarkTruth.Paths.runs("rag-tool-agent")
  @fixture_path "test/fixtures/benchmarks/rag-tool-agent-provider-free.json"
  @script_path "scripts/dspy_rag_tool_agent.py"
  @task_path "lib/mix/tasks/imp.benchmark.rag_tool_agent.ex"
  @authority_path "benchmarks/authority_sources/dspy-3.2.1-29448ae.json"
  @provider_free_dspy_row_ids ["rag_memory_retrieval", "react_lookup_tool"]
  @live_row_ids ["live_rag_memory_retrieval", "live_mcp_lookup_tool"]
  @live_settings %{
    "temperature" => 0.0,
    "max_tokens" => 400,
    "reasoning_effort" => nil,
    "effective_generation" => %{
      "max_completion_tokens" => 400,
      "reasoning_effort" => nil,
      "temperature" => "provider_default"
    },
    "cache" => false,
    "max_iters" => 4,
    "retrieval_k" => 1
  }

  @live_rag_instruction "Answer using the supplied context. Return only the exact answer span."

  @live_tool_instruction """
  First call lookup_capital with country "france". After its result is in history,
  call submit with answer exactly equal to that result. Never answer from memory
  and never call lookup_capital more than once.
  """

  @impl true
  def run(args) do
    run_with_runners(args, %{})
  end

  @doc false
  def validate_artifact!(artifact, opts \\ []) when is_map(artifact) and is_list(opts) do
    artifact = Imp.BenchmarkTruth.RunContext.verify!(artifact)

    if Keyword.get(opts, :require_clean, true) and
         get_in(artifact, ["run_context", "workspace", "state"]) != "clean" do
      raise ArgumentError, "RAG/tool/agent evidence requires a clean source checkout"
    end

    unless get_in(artifact, ["run_context", "inputs"]) == source_bindings() do
      raise ArgumentError, "RAG/tool/agent artifact source bindings are stale"
    end

    validate_dspy_source!(artifact["dspy"] || %{})

    unless get_in(artifact, ["summary", "provider_free_contract_complete"]) == true do
      raise ArgumentError, "RAG/tool/agent artifact lacks complete provider-free contracts"
    end

    artifact
  end

  @doc false
  def run_with_runners(args, runners) when is_list(args) and is_map(runners) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          out: :string,
          python: :string,
          live: :boolean,
          model: :string,
          dspy_model: :string,
          api_key_env: :string,
          env_file: :string,
          temperature: :float,
          max_tokens: :integer,
          reasoning_effort: :string,
          require_clean: :boolean
        ]
      )

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")
    Imp.BenchmarkEnv.load_files!(Keyword.get_values(opts, :env_file))
    Mix.Task.run("app.start")

    out_dir = Keyword.get(opts, :out, @default_out_dir)
    File.mkdir_p!(out_dir)
    live = Keyword.get(opts, :live, false)
    live_config = if live, do: live_config!(opts), else: nil

    run_context =
      Imp.BenchmarkTruth.RunContext.capture_git!(
        require_clean: Keyword.get(opts, :require_clean, false),
        source_commits: %{
          "dspy" => "stanfordnlp/dspy@29448ae12756abdd14bd8796c819247ebb83673c"
        },
        inputs: source_bindings()
      )

    imp = imp_report()
    imp = maybe_add_live_rows(imp, live_config, runners[:imp])
    dspy = dspy_report(python(opts), out_dir, live_config, runners[:dspy])
    report = comparison_report(imp, dspy)
    out_path = Path.join(out_dir, "rag-tool-agent-parity-#{timestamp_slug()}.json")

    %{artifact: report, path: out_path} =
      Imp.BenchmarkTruth.ArtifactFile.write_run_json!(out_path, report, run_context)

    Mix.shell().info("RAG/tool/agent parity report: #{out_path}")

    Mix.shell().info(
      "RAG/tool/agent passing rows: #{report["summary"]["passing"]}/#{report["summary"]["total"]}"
    )

    unless report["summary"]["all_passing"] do
      Mix.raise("RAG/tool/agent parity failed; inspect #{out_path}")
    end
  end

  defp live_config!(opts) do
    model = Keyword.get(opts, :model) || Mix.raise("--model is required with --live")

    dspy_model =
      Keyword.get(opts, :dspy_model) || Mix.raise("--dspy-model is required with --live")

    provider = model_provider(model)
    api_key_env = Keyword.get(opts, :api_key_env, default_api_key_env(provider))
    api_key = System.get_env(api_key_env)

    unless is_binary(api_key) and byte_size(api_key) > 0 do
      Mix.raise("#{api_key_env} is required with --live")
    end

    temperature = Keyword.get(opts, :temperature, @live_settings["temperature"])
    max_tokens = Keyword.get(opts, :max_tokens, @live_settings["max_tokens"])

    reasoning_effort =
      Keyword.get(opts, :reasoning_effort, default_reasoning_effort(provider, model))

    settings = %{
      @live_settings
      | "temperature" => temperature,
        "max_tokens" => max_tokens,
        "reasoning_effort" => reasoning_effort,
        "effective_generation" =>
          effective_generation(provider, model, temperature, max_tokens, reasoning_effort)
    }

    %{
      model: model,
      dspy_model: dspy_model,
      provider: provider,
      model_identity: model_identity(model),
      wire_api: imp_wire_api(provider, model),
      api_key_env: api_key_env,
      api_key: api_key,
      settings: settings
    }
  end

  defp model_identity(model) do
    model
    |> String.trim()
    |> String.trim_leading("openai:")
    |> String.trim_leading("openai/")
    |> String.trim_leading("responses/")
    |> String.trim_leading("anthropic:")
    |> String.trim_leading("anthropic/")
    |> String.trim_leading("gemini:")
    |> String.trim_leading("gemini/")
    |> String.trim_leading("google:")
    |> String.trim_leading("google/")
  end

  defp model_provider(model) do
    normalized = model |> String.trim() |> String.downcase()

    cond do
      String.starts_with?(normalized, ["anthropic:", "anthropic/"]) -> "anthropic"
      String.starts_with?(normalized, ["gemini:", "gemini/", "google:", "google/"]) -> "google"
      true -> "openai"
    end
  end

  defp default_api_key_env("anthropic"), do: "ANTHROPIC_API_KEY"
  defp default_api_key_env("google"), do: "GEMINI_API_KEY"
  defp default_api_key_env("openai"), do: "OPENAI_API_KEY"

  defp default_reasoning_effort("openai", model) do
    if String.match?(String.downcase(model), ~r/(gpt-5|o[134])/) do
      "low"
    end
  end

  defp default_reasoning_effort(_provider, _model), do: nil

  defp effective_generation("openai", model, temperature, max_tokens, reasoning_effort) do
    if String.match?(String.downcase(model), ~r/(gpt-5|o[134])/) do
      %{
        "max_completion_tokens" => max_tokens,
        "reasoning_effort" => reasoning_effort,
        "temperature" => "provider_default"
      }
    else
      %{"max_tokens" => max_tokens, "temperature" => temperature}
    end
  end

  defp effective_generation(_provider, _model, temperature, max_tokens, reasoning_effort) do
    %{"max_tokens" => max_tokens, "temperature" => temperature}
    |> maybe_put("reasoning_effort", reasoning_effort)
  end

  defp imp_wire_api("anthropic", _model), do: "anthropic_messages"
  defp imp_wire_api("google", _model), do: "google_generate_content"

  defp imp_wire_api("openai", model) do
    if String.contains?(String.downcase(model), "responses/"),
      do: "openai_responses",
      else: "openai_responses"
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp imp_report do
    rows = [
      rag_memory_retrieval_row(),
      rag_multi_hop_retrieval_row(),
      http_retriever_protocol_row(),
      react_lookup_tool_row(),
      react_unknown_tool_error_row(),
      mcp_import_agent_row(),
      agent_policy_denial_row(),
      react_v2_recovery_row(),
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

    lm = fn messages, _opts ->
      prompt = Enum.map_join(messages, "\n", & &1.content)
      {:ok, %{answer: if(String.contains?(prompt, "Paris"), do: "Paris", else: "unknown")}}
    end

    program =
      Imp.predict("question, context -> answer", lm: lm)
      |> Imp.rag(retriever, k: 1)

    {:ok, prediction} = Imp.call(program, %{question: "What is France's capital?"})
    [retrieved_doc] = prediction.metadata.retrieval.docs

    answer = Imp.Prediction.get(prediction, :answer)

    %{
      "id" => "rag_memory_retrieval",
      "category" => "rag",
      "comparison_status" => "direct",
      "passing" =>
        answer == "Paris" and retrieved_doc.text == "France capital: Paris." and
          prediction.metadata.retrieval.count == 1,
      "answer" => answer,
      "retrieved" => [normalize(retrieved_doc)],
      "trace" => %{
        "program" => "Imp.Predict.RAG",
        "retriever" => "Imp.Retrieve.Memory",
        "documents" => prediction.metadata.retrieval.count
      }
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

  defp react_v2_recovery_row do
    broken = Imp.tool(:broken, "always fails", fn _args -> raise "scripted failure" end)

    {:ok, queue} =
      Agent.start_link(fn ->
        [
          %{
            tool_calls: [
              %{id: "broken-1", name: "broken", arguments: %{}},
              %{id: "unknown-1", name: "unknown", arguments: %{}}
            ]
          },
          %{tool_calls: [%{id: "malformed-1", name: "submit", arguments: %{}}]},
          %{tool_calls: [%{id: "submit-1", name: "submit", arguments: %{answer: "recovered"}}]}
        ]
      end)

    lm = fn _messages, _opts ->
      Agent.get_and_update(queue, fn [response | rest] -> {{:ok, response}, rest} end)
    end

    {:ok, prediction} =
      Imp.react_v2("question -> answer", [broken], lm: lm, max_iters: 3)
      |> Imp.call(%{question: "recover"})

    Agent.stop(queue)

    events = prediction |> Imp.get(:history) |> Map.fetch!(:messages)

    trace =
      Enum.map(events, fn event ->
        %{
          "call_ids" => Enum.map(event.tool_calls.tool_calls, & &1.id),
          "results" =>
            Enum.map(event.tool_call_results, fn result ->
              %{"error" => result.error, "result" => normalize(result.result)}
            end)
        }
      end)

    expected = [
      %{
        "call_ids" => ["broken-1", "unknown-1"],
        "results" => [
          %{"error" => true, "result" => ["error", ["tool_error", "broken", "scripted failure"]]},
          %{"error" => true, "result" => ["error", ["unknown_tool", "unknown"]]}
        ]
      },
      %{
        "call_ids" => ["malformed-1"],
        "results" => [
          %{"error" => true, "result" => ["error", ["missing_output_fields", ["answer"]]]}
        ]
      },
      %{
        "call_ids" => ["submit-1"],
        "results" => [%{"error" => false, "result" => %{"answer" => "recovered"}}]
      }
    ]

    %{
      "id" => "react_v2_recovers_from_tool_and_submit_errors",
      "category" => "agent_recovery",
      "comparison_status" => "imp_only",
      "passing" =>
        Imp.get(prediction, :answer) == "recovered" and
          Imp.get(prediction, :termination_reason) == :submit and trace == expected,
      "answer" => Imp.get(prediction, :answer),
      "trace" => trace,
      "termination_reason" => to_string(Imp.get(prediction, :termination_reason)),
      "deviation" =>
        "BEAM-native ReActV2 recovery records failing, unknown, and malformed calls as observations before bounded successful submission."
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

  defp maybe_add_live_rows(report, nil, _runner), do: report

  defp maybe_add_live_rows(report, config, runner) do
    rows =
      case runner do
        fun when is_function(fun, 1) -> fun.(public_live_config(config))
        nil -> live_imp_rows(config)
        other -> Mix.raise("invalid injected Imp live runner: #{inspect(other)}")
      end

    validate_live_rows!(rows, "Imp")
    Map.update!(report, "rows", &(&1 ++ rows))
  end

  defp live_imp_rows(config) do
    [live_imp_rag_row(config), live_imp_mcp_tool_row(config)]
  end

  defp live_imp_rag_row(config) do
    live_imp_row("live_rag_memory_retrieval", "rag", config, fn lm ->
      retriever =
        Imp.Retrieve.Memory.new([
          %{id: "fr", text: "France capital: Paris."},
          %{id: "beam", text: "BEAM runs lightweight Elixir processes."}
        ])

      program =
        Imp.signature("question, context -> answer", @live_rag_instruction)
        |> Imp.predict(lm: lm, adapter: Imp.Adapter.JSON, config: [json_retries: 1])
        |> Imp.rag(retriever, k: config.settings["retrieval_k"])

      with {:ok, prediction} <- Imp.call(program, %{question: "What is France's capital?"}) do
        answer = prediction |> Imp.get(:answer, "") |> to_string()
        retrieval = prediction.metadata.retrieval

        {:ok,
         %{
           "answer" => answer,
           "retrieved" => Enum.map(retrieval.docs, &normalize/1),
           "passing" => answer == "Paris" and retrieval.count == 1
         }}
      end
    end)
  end

  defp live_imp_mcp_tool_row(config) do
    live_imp_row("live_mcp_lookup_tool", "tools", config, fn lm ->
      catalog =
        Imp.MCP.Catalog.new([
          %{
            name: :lookup_capital,
            description: "Look up the capital for one supported country key.",
            input_schema: %{
              "type" => "object",
              "properties" => %{
                "country" => %{"type" => "string", "enum" => ["france"]}
              },
              "required" => ["country"]
            },
            run: fn
              %{country: "france"} -> "Paris"
              %{"country" => "france"} -> "Paris"
              other -> {:error, {:unexpected_country, other}}
            end
          }
        ])

      [tool] = Imp.MCP.import_tools(catalog)

      agent =
        Imp.react(
          Imp.Signature.new("question -> answer", @live_tool_instruction),
          [tool],
          lm: lm,
          tool_policy: [:lookup_capital, :submit],
          max_iters: config.settings["max_iters"]
        )

      with {:ok, prediction} <- Imp.call(agent, %{question: "What is France's capital?"}) do
        answer = prediction |> Imp.get(:answer, "") |> to_string()

        trace =
          prediction
          |> Imp.get(:history, [])
          |> Enum.reject(&(&1.tool == :submit))
          |> Enum.map(
            &%{
              "tool" => to_string(&1.tool),
              "arguments" => normalize(&1.arguments),
              "result" => &1.result
            }
          )

        {:ok,
         %{
           "answer" => answer,
           "tool_trace" => trace,
           "passing" => answer == "Paris" and trace == expected_live_tool_trace()
         }}
      end
    end)
  end

  defp live_imp_row(id, category, config, fun) do
    lm_opts =
      [
        api_key: config.api_key,
        temperature: config.settings["temperature"],
        max_tokens: config.settings["max_tokens"],
        cache: config.settings["cache"]
      ]
      |> maybe_keyword(:reasoning_effort, config.settings["reasoning_effort"])

    lm =
      Imp.req_llm(imp_model(config.model), lm_opts)

    {result, usage} = collect_req_llm_usage(fn -> fun.(lm) end)

    case result do
      {:ok, values} ->
        values
        |> Map.merge(%{
          "id" => id,
          "category" => category,
          "comparison_status" => "direct",
          "passing" => values["passing"] == true and usage_complete?(usage),
          "evidence" => live_evidence(config, config.model, usage, nil, id, "submit")
        })

      {:error, reason} ->
        %{
          "id" => id,
          "category" => category,
          "comparison_status" => "direct",
          "passing" => false,
          "answer" => nil,
          "error" => diagnostic(reason),
          "evidence" =>
            live_evidence(config, config.model, usage, diagnostic(reason), id, "submit")
        }
    end
  rescue
    exception ->
      %{
        "id" => id,
        "category" => category,
        "comparison_status" => "direct",
        "passing" => false,
        "answer" => nil,
        "error" => diagnostic(exception),
        "evidence" =>
          live_evidence(
            config,
            config.model,
            empty_usage(),
            diagnostic(exception),
            id,
            "submit"
          )
      }
  end

  defp collect_req_llm_usage(fun) do
    {:ok, usage_agent} = Agent.start_link(fn -> empty_usage() end)
    handler_id = {__MODULE__, :live_usage, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:req_llm, :token_usage],
        &__MODULE__.handle_live_usage/4,
        usage_agent
      )

    try do
      result = fun.()
      {result, Agent.get(usage_agent, & &1)}
    after
      :telemetry.detach(handler_id)
      Agent.stop(usage_agent)
    end
  end

  defp empty_usage,
    do: %{"requests" => 0, "input_tokens" => 0, "output_tokens" => 0, "usd" => 0.0}

  @doc false
  def handle_live_usage(_event, measurements, _metadata, usage_agent) do
    Agent.update(usage_agent, &add_usage(&1, measurements))
  end

  defp add_usage(usage, measurements) do
    tokens = Map.get(measurements, :tokens, %{})

    usage
    |> Map.update!("requests", &(&1 + 1))
    |> Map.update!("input_tokens", &(&1 + usage_number(tokens, :input_tokens)))
    |> Map.update!("output_tokens", &(&1 + usage_number(tokens, :output_tokens)))
    |> Map.update!("usd", &(&1 + usage_number(measurements, :total_cost)))
  end

  defp usage_number(map, key) do
    case Map.get(map, key, Map.get(map, to_string(key), 0)) do
      value when is_number(value) -> value
      _other -> 0
    end
  end

  defp usage_complete?(usage) do
    usage["requests"] > 0 and usage["input_tokens"] > 0 and usage["output_tokens"] > 0 and
      is_number(usage["usd"]) and usage["usd"] > 0
  end

  defp live_evidence(config, runtime_model, usage, error, row_id, termination_tool) do
    %{
      "mode" => "live",
      "provider" => config.provider,
      "model_identity" => config.model_identity,
      "runtime_model" => runtime_model,
      "wire_api" => config.wire_api,
      "generation" => config.settings,
      "prompt_contract" => live_prompt_contract(row_id),
      "termination_tool" => if(row_id == "live_mcp_lookup_tool", do: termination_tool),
      "usage" => usage,
      "usage_complete" => usage_complete?(usage),
      "error" => error
    }
  end

  defp imp_model(model) do
    cond do
      String.contains?(model, ":") -> model
      String.starts_with?(model, "anthropic/") -> "anthropic:#{model_identity(model)}"
      String.starts_with?(model, ["gemini/", "google/"]) -> "google:#{model_identity(model)}"
      true -> "openai:#{model_identity(model)}"
    end
  end

  defp public_live_config(config) do
    %{
      "model" => config.model,
      "dspy_model" => config.dspy_model,
      "provider" => config.provider,
      "model_identity" => config.model_identity,
      "wire_api" => config.wire_api,
      "api_key_env" => config.api_key_env,
      "settings" => config.settings
    }
  end

  defp live_prompt_contract("live_rag_memory_retrieval"), do: "rag-exact-context-v1"
  defp live_prompt_contract("live_mcp_lookup_tool"), do: "lookup-capital-then-terminate-v1"

  defp validate_live_rows!(rows, runner) when is_list(rows) do
    ids = MapSet.new(rows, & &1["id"])
    expected = MapSet.new(@live_row_ids)

    unless ids == expected do
      Mix.raise(
        "#{runner} live rows must be exactly #{inspect(@live_row_ids)}, got: #{inspect(MapSet.to_list(ids))}"
      )
    end
  end

  defp validate_live_rows!(rows, runner),
    do: Mix.raise("#{runner} live runner returned invalid rows: #{inspect(rows)}")

  defp dspy_report(python, out_dir, live_config, runner) do
    cond do
      is_function(runner, 1) ->
        report = runner.(if(live_config, do: public_live_config(live_config), else: nil))
        validate_dspy_report!(report, live_config)
        report

      is_nil(runner) ->
        run_dspy_report!(python, out_dir, live_config)

      true ->
        Mix.raise("invalid injected DSPy runner: #{inspect(runner)}")
    end
  end

  defp run_dspy_report!(python, out_dir, live_config) do
    out_path = Path.join(out_dir, "dspy-rag-tool-agent-#{timestamp_slug()}.json")

    args =
      ["scripts/dspy_rag_tool_agent.py", "--out", out_path] ++
        dspy_live_args(live_config)

    case System.cmd(python, args, stderr_to_stdout: true) do
      {_output, 0} ->
        report = out_path |> File.read!() |> Jason.decode!()
        validate_dspy_report!(report, live_config)
        report

      {output, status} ->
        Mix.raise("DSPy RAG/tool sidecar failed with status #{status}:\n#{output}")
    end
  end

  defp dspy_live_args(nil), do: []

  defp dspy_live_args(config) do
    [
      "--live",
      "--model",
      config.dspy_model,
      "--api-key-env",
      config.api_key_env,
      "--temperature",
      to_string(config.settings["temperature"]),
      "--max-tokens",
      to_string(config.settings["max_tokens"])
    ]
    |> maybe_args("--reasoning-effort", config.settings["reasoning_effort"])
  end

  defp maybe_args(args, _flag, nil), do: args
  defp maybe_args(args, flag, value), do: args ++ [flag, value]

  defp maybe_keyword(opts, _key, nil), do: opts
  defp maybe_keyword(opts, key, value), do: Keyword.put(opts, key, value)

  defp validate_dspy_report!(%{"rows" => rows} = report, nil) when is_list(rows) do
    validate_exact_rows!(rows, @provider_free_dspy_row_ids, "DSPy provider-free")
    validate_dspy_source!(report)
  end

  defp validate_dspy_report!(%{"rows" => rows}, _config) do
    validate_exact_rows!(
      rows,
      @provider_free_dspy_row_ids ++ @live_row_ids,
      "DSPy live"
    )
  end

  defp validate_dspy_report!(report, _config),
    do: Mix.raise("DSPy runner returned invalid report: #{inspect(report)}")

  defp validate_exact_rows!(rows, expected_ids, runner) do
    ids = Enum.map(rows, & &1["id"])

    unless Enum.sort(ids) == Enum.sort(expected_ids) and length(ids) == length(Enum.uniq(ids)) do
      Mix.raise(
        "#{runner} rows must be exactly #{inspect(expected_ids)} with no duplicates, got: #{inspect(ids)}"
      )
    end

    :ok
  end

  defp validate_dspy_source!(report) do
    expected = provider_free_fixture()["dspy_authority"]
    source = report["source"] || %{}

    unless source["repository"] == expected["repository"] and
             source["version"] == expected["version"] and
             source["commit"] == expected["commit"] and
             source["script_sha256"] == file_sha256!(@script_path) and
             source["authority_sha256"] == file_sha256!(@authority_path) and
             source["fixture_sha256"] == file_sha256!(@fixture_path) do
      Mix.raise("DSPy provider-free report has stale or wrong source bindings")
    end
  end

  defp comparison_report(imp, dspy) do
    dspy_rows = Map.new(dspy["rows"], &{&1["id"], &1})

    rows =
      Enum.map(imp["rows"], fn row ->
        compare_row(row, dspy_rows[row["id"]])
      end)

    passing = Enum.count(rows, & &1["passing"])
    provider_free_rows = Enum.reject(rows, &(&1["id"] in @live_row_ids))
    live_rows = Enum.filter(rows, &(&1["id"] in @live_row_ids))
    provider_free_complete = Enum.all?(provider_free_rows, & &1["passing"])

    live_complete =
      MapSet.new(live_rows, & &1["id"]) == MapSet.new(@live_row_ids) and
        Enum.all?(live_rows, & &1["passing"])

    full = provider_free_complete and live_complete

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
        "provider_free_contract_complete" => provider_free_complete,
        "bounded_provider_free_operational_contracts_complete" => provider_free_complete,
        "live_matched_behavior_complete" => live_complete,
        "full_rag_tool_agent_parity" => full,
        "comparative_effectiveness_complete" => false,
        "note" => summary_note(live_complete)
      },
      "imp" => Map.take(imp, ["runner", "elixir", "otp", "git_sha"]),
      "dspy" => Map.take(dspy, ["runner", "python", "dspy_version", "git_sha", "source"]),
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
        Map.take(dspy, Map.keys(expected)) == expected and
        live_evidence_compatible?(imp, dspy)

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

  defp direct_expected("live_rag_memory_retrieval"), do: %{"answer" => "Paris"}

  defp direct_expected("live_mcp_lookup_tool"),
    do: %{"answer" => "Paris", "tool_trace" => expected_live_tool_trace()}

  defp expected_tool_trace,
    do: [
      %{"tool" => "lookup", "arguments" => %{"query" => "capital-france"}, "result" => "Paris"}
    ]

  defp expected_live_tool_trace,
    do: [
      %{
        "tool" => "lookup_capital",
        "arguments" => %{"country" => "france"},
        "result" => "Paris"
      }
    ]

  defp live_evidence_compatible?(%{"id" => id}, _dspy) when id not in @live_row_ids, do: true

  defp live_evidence_compatible?(imp, dspy) do
    imp_evidence = imp["evidence"] || %{}
    dspy_evidence = dspy["evidence"] || %{}

    imp_evidence["mode"] == "live" and dspy_evidence["mode"] == "live" and
      imp_evidence["provider"] == dspy_evidence["provider"] and
      imp_evidence["model_identity"] == dspy_evidence["model_identity"] and
      wire_api_family(imp_evidence["wire_api"]) == wire_api_family(dspy_evidence["wire_api"]) and
      imp_evidence["generation"] == dspy_evidence["generation"] and
      imp_evidence["prompt_contract"] == dspy_evidence["prompt_contract"] and
      termination_tools_compatible?(imp["id"], imp_evidence, dspy_evidence) and
      imp_evidence["usage_complete"] == true and dspy_evidence["usage_complete"] == true and
      is_nil(imp_evidence["error"]) and is_nil(dspy_evidence["error"])
  end

  defp wire_api_family("anthropic_messages"), do: "anthropic_messages"
  defp wire_api_family("litellm_anthropic_messages"), do: "anthropic_messages"
  defp wire_api_family("google_generate_content"), do: "google_generate_content"
  defp wire_api_family("litellm_google_generate_content"), do: "google_generate_content"
  defp wire_api_family(value), do: value

  defp termination_tools_compatible?("live_mcp_lookup_tool", imp, dspy),
    do: imp["termination_tool"] == "submit" and dspy["termination_tool"] == "finish"

  defp termination_tools_compatible?(_id, imp, dspy),
    do: is_nil(imp["termination_tool"]) and is_nil(dspy["termination_tool"])

  defp summary_note(false) do
    "Provider-free RAG/tool/agent artifact. Direct DSPy comparisons cover deterministic one-shot RAG retrieval and ReAct lookup. Imp production rows cover multi-hop RAG, HTTP retriever protocol shape, MCP import, agent policy denial, ReAct error traces, CodeAct, ProgramOfThought success/error policy, streaming, async, and save/load redaction. Live matched behavior is not present or did not pass complete evidence controls."
  end

  defp summary_note(true) do
    "Provider-free production contracts and matched live retrieval/tool behavior pass. Live rows use one model identity, provider-equivalent wire APIs, matched generation controls, complete provider usage, exact answers, and canonical tool traces. Imp's tool row imports an MCP catalog tool; the credential-gated live provider suite separately proves the same ReAct composition through HTTP MCP JSON-RPC transport."
  end

  defp diagnostic(reason) do
    reason
    |> inspect(limit: 20, printable_limit: 2_048)
    |> Imp.Redaction.redact()
    |> String.slice(0, 2_048)
  end

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

  @doc false
  def source_bindings do
    %{
      "protocol_id" => "rag_tool_agent_provider_free_v2",
      "task_sha256" => file_sha256!(@task_path),
      "script_sha256" => file_sha256!(@script_path),
      "authority_path" => @authority_path,
      "authority_sha256" => file_sha256!(@authority_path),
      "fixture_path" => @fixture_path,
      "fixture_sha256" => file_sha256!(@fixture_path),
      "required_dspy_rows" => @provider_free_dspy_row_ids
    }
  end

  defp provider_free_fixture, do: @fixture_path |> File.read!() |> Jason.decode!()

  defp file_sha256!(path) do
    "sha256:" <>
      (path |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower))
  end

  defp timestamp_slug do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
    |> String.replace(~r/[^0-9A-Za-z]/, "")
  end
end
