defmodule Mix.Tasks.Imp.Benchmark.Trace do
  @moduledoc """
  Run provider-free golden trace parity fixtures through Imp and Python DSPy.

      mix imp.benchmark.trace

  The task is intentionally deterministic: fixture responses are replayed by
  static local LMs on both sides. It proves library semantics without provider latency
  or model nondeterminism.
  """

  use Mix.Task

  @shortdoc "Run Imp-vs-DSPy golden trace parity fixtures"

  @default_fixtures "test/fixtures/golden_trace/cases.json"
  @default_out_dir Imp.BenchmarkTruth.Paths.runs("golden-trace")

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          fixtures: :string,
          out: :string,
          python: :string
        ]
      )

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    fixtures_path = Keyword.get(opts, :fixtures, @default_fixtures)
    out_dir = Keyword.get(opts, :out, @default_out_dir)
    File.mkdir_p!(out_dir)

    cases = fixtures_path |> File.read!() |> Jason.decode!()
    imp = imp_report(cases)
    dspy = dspy_report(fixtures_path, python(opts), out_dir)
    report = comparison_report(fixtures_path, cases, imp, dspy, imp_semantic_checks())

    out_path = Path.join(out_dir, "golden-trace-parity-#{timestamp_slug()}.json")
    File.write!(out_path, Jason.encode!(report, pretty: true) <> "\n")

    Mix.shell().info("golden trace parity report: #{out_path}")
    Mix.shell().info("golden trace passing: #{report["summary"]["all_cases_passing"]}")

    Mix.shell().info(
      "passing cases: #{report["summary"]["passing"]}/#{report["summary"]["total"]}"
    )

    unless report["summary"]["all_cases_passing"] and
             report["summary"]["imp_semantic_checks"]["all_passing"] do
      Mix.raise("golden trace parity failed; inspect #{out_path}")
    end
  end

  defp imp_report(cases) do
    %{
      "schema_version" => 1,
      "runner" => "imp-golden-trace",
      "elixir" => System.version(),
      "otp" => System.otp_release(),
      "git_sha" => git_sha(),
      "cases" => Enum.map(cases, &run_imp_case/1)
    }
  end

  defp run_imp_case(case) do
    {:ok, queue} =
      Agent.start_link(fn ->
        case["imp_responses"] || case["responses"]
      end)

    {:ok, calls} = Agent.start_link(fn -> [] end)

    # A capability-carrying fixture LM (not a bare closure) so the JSON adapter
    # gates response_format on the SAME tier the DSPy FixtureLM declares
    # (dee-ps19). `lm_capability` is optional; absent => DSPy BaseLM default
    # (none), matching the historical fixtures.
    lm = %Imp.BenchmarkTruth.GoldenTraceFixtureLM{
      queue: queue,
      calls: calls,
      capability: Imp.LM.Capability.from_tier(case["lm_capability"])
    }

    try do
      signature = Imp.signature(case["signature"], case["instructions"] || "")
      Process.put(:imp_golden_trace_tools, build_imp_tools(case))
      Process.put(:imp_golden_trace_max_iters, case["max_iters"] || 20)
      program = build_imp_program(case["module"], signature, case["adapter"], lm, case["demos"])

      case safe_call(program, atomize_keys(case["inputs"])) do
        {:ok, prediction} -> imp_success(case, prediction, calls, queue)
        {:error, reason} -> imp_error(case, reason, calls, queue)
      end
    after
      Process.delete(:imp_golden_trace_tools)
      Process.delete(:imp_golden_trace_max_iters)
      Agent.stop(queue)
      Agent.stop(calls)
    end
  end

  defp build_imp_program("predict", signature, adapter, lm, demos),
    do: Imp.predict(signature, lm: lm, adapter: adapter_module(adapter), demos: demos || [])

  defp build_imp_program("chain_of_thought", signature, adapter, lm, demos),
    do:
      Imp.chain_of_thought(signature,
        lm: lm,
        adapter: adapter_module(adapter),
        demos: demos || []
      )

  defp build_imp_program("react", signature, _adapter, lm, _demos),
    do:
      Imp.react(signature, Process.get(:imp_golden_trace_tools, []),
        lm: lm,
        max_iters: Process.get(:imp_golden_trace_max_iters, 20)
      )

  defp build_imp_program("react_dspy", signature, adapter, lm, _demos),
    do:
      Imp.react(signature, Process.get(:imp_golden_trace_tools, []),
        lm: lm,
        adapter: adapter_module(adapter),
        mode: :dspy_3_2_1,
        max_iters: Process.get(:imp_golden_trace_max_iters, 20)
      )

  defp build_imp_program(module, _signature, _adapter, _lm, _demos),
    do: Mix.raise("unsupported fixture module: #{module}")

  defp build_imp_tools(case) do
    Enum.map(case["tools"] || [], fn spec ->
      outputs = spec["outputs"] || %{}

      Imp.Tool.new(
        spec["name"],
        spec["description"] || "",
        fn args ->
          key = args |> normalize() |> Jason.encode!()

          case Map.fetch(outputs, key) do
            {:ok, output} ->
              output

            :error ->
              raise ArgumentError,
                    "unexpected tool arguments for #{spec["name"]}: #{inspect(normalize(args))}"
          end
        end,
        schema: spec["schema"] || %{}
      )
    end)
  end

  defp safe_call(program, inputs) do
    Imp.Module.call(program, inputs)
  rescue
    exception -> {:error, exception}
  end

  defp imp_success(case, prediction, calls, queue) do
    prediction_map = prediction |> Imp.Prediction.to_map() |> normalize()

    %{
      "id" => case["id"],
      "status" => "ok",
      "prediction" => prediction_map,
      "tool_trace" => tool_trace(prediction_map),
      "error" => nil,
      "history" => fixture_history(calls),
      "remaining_responses" => Agent.get(queue, &length/1)
    }
  end

  defp imp_error(case, reason, calls, queue) do
    %{
      "id" => case["id"],
      "status" => "error",
      "prediction" => nil,
      "tool_trace" => [],
      "error" => Exception.format(:error, reason),
      "history" => fixture_history(calls),
      "remaining_responses" => Agent.get(queue, &length/1)
    }
  end

  # The FixtureLM records raw per-call {messages, opts}; normalize at read time
  # into the {"messages", "opts"} string-keyed shape the comparator consumes.
  defp fixture_history(calls), do: calls |> Agent.get(& &1) |> normalize()

  defp adapter_module("chat"), do: Imp.Adapter.Chat
  defp adapter_module("json"), do: Imp.Adapter.JSON
  defp adapter_module(adapter), do: Mix.raise("unsupported fixture adapter: #{adapter}")

  defp dspy_report(fixtures_path, python, out_dir) do
    out_path = Path.join(out_dir, "dspy-golden-trace-#{timestamp_slug()}.json")

    args = [
      "scripts/dspy_golden_trace_runner.py",
      "--fixtures",
      fixtures_path,
      "--out",
      out_path
    ]

    case System.cmd(python, args, stderr_to_stdout: true) do
      {_output, 0} ->
        out_path |> File.read!() |> Jason.decode!()

      {output, status} ->
        Mix.raise("DSPy golden trace runner failed with status #{status}:\n#{output}")
    end
  end

  defp comparison_report(fixtures_path, cases, imp, dspy, semantic_checks) do
    imp_cases = Map.new(imp["cases"], &{&1["id"], &1})
    dspy_cases = Map.new(dspy["cases"], &{&1["id"], &1})

    comparisons =
      Enum.map(cases, fn case ->
        compare_case(case, imp_cases[case["id"]], dspy_cases[case["id"]])
      end)

    passing = Enum.count(comparisons, & &1["passing"])
    prediction_cases = Enum.reject(comparisons, &(&1["expected_status"] == "error"))
    error_cases = Enum.filter(comparisons, &(&1["expected_status"] == "error"))
    tool_trace_cases = Enum.reject(comparisons, &is_nil(&1["tool_trace_parity"]))

    %{
      "schema_version" => 1,
      "generated_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "git_sha" => git_sha(),
      "fixtures" => %{
        "path" => fixtures_path,
        "sha256" => file_sha256(fixtures_path),
        "cases" => length(cases)
      },
      "imp" => Map.take(imp, ["runner", "elixir", "otp", "git_sha"]),
      "dspy" => Map.take(dspy, ["runner", "python", "dspy_version", "git_sha"]),
      "summary" => %{
        "total" => length(comparisons),
        "passing" => passing,
        "all_cases_passing" => passing == length(comparisons),
        "prediction_cases" => length(prediction_cases),
        "prediction_parity" => Enum.all?(prediction_cases, & &1["prediction_parity"]),
        "error_cases" => length(error_cases),
        "error_status_parity" => Enum.all?(error_cases, & &1["status_parity"]),
        "tool_trace_cases" => length(tool_trace_cases),
        "tool_trace_parity" => Enum.all?(tool_trace_cases, & &1["tool_trace_parity"]),
        "imp_semantic_checks" => semantic_summary(semantic_checks),
        # Computed, not hardcoded: how many cases render byte-identical
        # prompts to DSPy. This is the real faithful-port measurement (epic
        # dee-8zev). It is intentionally NOT yet asserted for all cases —
        # known divergences (CoT reasoning desc dee-l9vm, typed-field type
        # hints dee-3zun, whitespace dee-qtzk, ReAct dee-kzop, JSON dee-ye3h)
        # are being fixed; enforcement lands in dee-3e4v once resolved.
        #
        # template_parity is boundary-aware (dee-idig): messages are compared
        # PER CALL, so two different call-splittings with the same concatenated
        # text no longer compare EQUAL.
        "template_parity_cases" => Enum.count(comparisons, & &1["template_parity"]),
        "message_template_parity" => Enum.all?(comparisons, & &1["template_parity"]),
        "template_parity_by_case" => Map.new(comparisons, &{&1["id"], &1["template_parity"]}),
        # Request-envelope fidelity (dee-idig): are the PER-CALL request options
        # Imp sends (response_format, tools, tool_choice, temperature, ...)
        # identical to what DSPy sends for the same fixture? The old instrument
        # compared only message role+content and so reported false parity while
        # Imp shipped `response_format: json_object` on JSON cases and DSPy
        # (capability-gated) shipped nothing. This dimension made that divergence
        # VISIBLE, and dee-ps19 then FIXED it: Imp now gates response_format on
        # the LM's capability exactly like DSPy's JSONAdapter, so the JSON cases
        # match tier-for-tier (none / json_object / json_schema).
        "envelope_parity_cases" => Enum.count(comparisons, & &1["envelope_parity"]),
        "message_envelope_parity" => Enum.all?(comparisons, & &1["envelope_parity"]),
        "envelope_parity_by_case" => Map.new(comparisons, &{&1["id"], &1["envelope_parity"]}),
        # Fully parity = byte-identical messages AND identical request envelope,
        # per call. The honest "faithful port for this case" number.
        "full_parity_cases" =>
          Enum.count(comparisons, &(&1["template_parity"] and &1["envelope_parity"])),
        "full_parity_by_case" =>
          Map.new(comparisons, &{&1["id"], &1["template_parity"] and &1["envelope_parity"]})
      },
      "imp_semantic_checks" => semantic_checks,
      "cases" => comparisons
    }
  end

  defp compare_case(fixture, imp, dspy) do
    expected_status = fixture["expected_status"] || "ok"
    expected = normalize(fixture["expected_prediction"] || %{})
    imp_prediction = normalize(imp && imp["prediction"])
    dspy_prediction = normalize(dspy && dspy["prediction"])
    expected_tool_trace = normalize(fixture["expected_tool_trace"])
    imp_tool_trace = normalize(imp && imp["tool_trace"])
    dspy_tool_trace = normalize(dspy && dspy["tool_trace"])

    # The comparable unit for prompt parity is the ordered list of LM CALLS,
    # each carrying its rendered messages AND its request envelope. Building
    # this once (instead of flat-mapping messages) preserves call boundaries so
    # a differently-split trajectory can no longer masquerade as identical.
    imp_calls = rendered_calls(imp)
    dspy_calls = rendered_calls(dspy)

    status_parity =
      (imp && dspy && imp["status"] == expected_status) and dspy["status"] == expected_status

    prediction_parity =
      status_parity and expected_status == "ok" and
        expected_projection(imp_prediction, expected) == expected and
        expected_projection(dspy_prediction, expected) == expected

    tool_trace_required? = not is_nil(expected_tool_trace)

    tool_trace_parity =
      is_nil(expected_tool_trace) or
        (status_parity and expected_status == "ok" and
           imp_tool_trace == expected_tool_trace and dspy_tool_trace == expected_tool_trace)

    error_parity =
      status_parity and expected_status == "error" and
        error_contains?(imp && imp["error"], fixture["expected_error_contains"]) and
        error_contains?(dspy && dspy["error"], fixture["expected_error_contains"])

    %{
      "id" => fixture["id"],
      "module" => fixture["module"],
      "adapter" => fixture["adapter"],
      "expected_status" => expected_status,
      "passing" => (prediction_parity and tool_trace_parity) or error_parity,
      "status_parity" => status_parity,
      "prediction_parity" => prediction_parity,
      "error_parity" => error_parity,
      "tool_trace_parity" => if(tool_trace_required?, do: tool_trace_parity),
      "expected_tool_trace" => expected_tool_trace,
      "expected_prediction" => expected,
      # Real prompt-fidelity measurement: are the rendered messages Imp sends
      # byte-identical to what DSPy sends for the same fixture? The prompt IS
      # the behavior; a divergence here means Imp instructs the model
      # differently than DSPy and is not a faithful port for this case.
      # (epic dee-8zev). Boundary-aware (dee-idig): messages are compared PER
      # CALL, so a divergence in how work is split across calls is not masked.
      "template_parity" =>
        canonical(call_messages(imp_calls)) == canonical(call_messages(dspy_calls)),
      # New dimension (dee-idig): the PER-CALL request envelope (LM opts on the
      # Imp side, adapter kwargs on the DSPy side — response_format, tools,
      # tool_choice, temperature, ...). This is the request divergence the
      # message-only instrument was blind to. It is locked to its REAL measured
      # value: false where Imp and DSPy actually send different options.
      "envelope_parity" =>
        canonical(call_envelopes(imp_calls)) == canonical(call_envelopes(dspy_calls)),
      # Surfaced so a divergence is legible in the report itself, not buried in
      # raw history (nothing silent).
      "imp_call_envelopes" => call_envelopes(imp_calls),
      "dspy_call_envelopes" => call_envelopes(dspy_calls),
      "imp" => imp,
      "dspy" => dspy,
      "intentional_deviations" => List.wrap(fixture["intentional_deviations"])
    }
  end

  # The ordered list of LM CALLS Imp/DSPy actually made, each as
  # %{"messages" => [%{role, content}], "envelope" => <request-opts>} — the
  # comparable unit for prompt AND envelope parity. Preserving call boundaries
  # (instead of flat-mapping every message together) is what lets the
  # comparison notice a differently-split trajectory (ReAct, retries) and a
  # per-call request-option divergence (dee-idig). Nil side (missing run)
  # yields [], which will not match a real run.
  defp rendered_calls(nil), do: []

  defp rendered_calls(side) do
    Enum.map(side["history"] || [], fn entry ->
      %{
        "messages" => (entry["messages"] || []) |> Enum.map(&Map.take(&1, ["role", "content"])),
        # Imp records the LM opts under "opts"; the DSPy runner records the
        # adapter kwargs under "kwargs". Either is the request envelope.
        "envelope" => entry["opts"] || entry["kwargs"] || %{}
      }
    end)
  end

  # Per-call projections used by the two parity dimensions. Keeping them as a
  # list-of-lists (outer = calls) means an unequal number of calls, or a
  # per-call difference, can never compare EQUAL.
  defp call_messages(calls), do: Enum.map(calls, & &1["messages"])
  defp call_envelopes(calls), do: Enum.map(calls, & &1["envelope"])

  # Canonical form for comparison. The Imp side is in-memory Elixir (a role can
  # be an atom like `:system`, opts can be a keyword list) while the DSPy side
  # is JSON-decoded (strings, maps); Elixir `==` distinguishes those but they
  # are the same wire value. Round-tripping both through JSON compares exactly
  # what gets sent to the model, matching the report's own serialized view.
  defp canonical(value), do: value |> Jason.encode!() |> Jason.decode!()

  defp error_contains?(_error, nil), do: true
  defp error_contains?(nil, _text), do: false
  defp error_contains?(error, text), do: error |> to_string() |> String.contains?(to_string(text))

  defp expected_projection(_prediction, expected) when expected == %{}, do: %{}
  defp expected_projection(nil, _expected), do: nil

  defp expected_projection(prediction, expected) do
    Map.take(prediction, Map.keys(expected))
  end

  defp tool_trace(%{"history" => history}) when is_list(history) do
    history
    |> Enum.reject(&(to_string(&1["tool"]) in ["submit", "finish"]))
    |> Enum.map(fn event ->
      %{
        "tool" => to_string(event["tool"]),
        "arguments" => event["arguments"] || %{},
        "result" => event["result"]
      }
    end)
  end

  defp tool_trace(_prediction), do: []

  defp imp_semantic_checks do
    [
      streaming_incremental_fields_check(),
      save_load_redaction_check(),
      req_llm_cache_check(),
      provider_stream_chunk_replay_check()
    ]
  end

  defp streaming_incremental_fields_check do
    events =
      Imp.Streaming.incremental_fields(
        ["[[ ## ans", "wer ## ]]beam", "[[ ## rationale ## ]]fast"],
        "question -> answer, rationale"
      )

    pass? = events == [%{field: :answer, value: "beam"}, %{field: :rationale, value: "fast"}]

    %{
      "id" => "streaming_incremental_fields",
      "scope" => "imp",
      "passing" => pass?,
      "evidence" => normalize(events)
    }
  end

  defp save_load_redaction_check do
    secret = "not-persisted"

    program =
      Imp.predict("question -> answer",
        lm: Imp.req_llm("openai:gpt-test", api_key: secret, opts: [temperature: 0])
      )

    dumped = Imp.Saving.dump(program)
    encoded = inspect(dumped)
    loaded = Imp.Saving.load(dumped)

    pass? =
      not String.contains?(encoded, secret) and
        match?(%Imp.Clients.ReqLLM{model: "openai:gpt-test"}, loaded.lm)

    %{
      "id" => "save_load_redacts_req_llm_credentials",
      "scope" => "imp",
      "passing" => pass?,
      "evidence" => %{
        "secret_persisted" => String.contains?(encoded, secret),
        "loaded_lm" => loaded.lm |> Map.from_struct() |> Map.take([:model, :opts]) |> normalize()
      }
    }
  end

  defp req_llm_cache_check do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    lm =
      Imp.req_llm("openai:gpt-test",
        req_module: Mix.Tasks.Imp.Benchmark.Trace.StableReqLLM,
        counter: counter
      )

    messages = [%{role: :user, content: "cache me"}]

    first = Imp.LM.generate(lm, messages, cache: true)
    second = Imp.LM.generate(lm, messages, cache: true)
    calls = Agent.get(counter, & &1)
    Agent.stop(counter)

    pass? = generated_content(first) == "Answer: cached" and second == first and calls == 1

    %{
      "id" => "req_llm_cache_hit_reuses_success",
      "scope" => "imp",
      "passing" => pass?,
      "evidence" => %{"calls" => calls, "first" => inspect(first), "second" => inspect(second)}
    }
  end

  defp generated_content(result) do
    case Imp.LM.Result.unwrap(result) do
      {:ok, content} when is_binary(content) -> content
      _other -> nil
    end
  end

  defp provider_stream_chunk_replay_check do
    lm =
      Imp.req_llm("openai:gpt-test",
        req_module: Mix.Tasks.Imp.Benchmark.Trace.StreamReqLLM
      )

    program = Imp.predict("question -> answer", lm: lm)

    chunks =
      program
      |> Imp.Streaming.stream(%{question: "pong"}, provider_stream: true)
      |> Enum.map(&normalize_stream_response/1)
      |> normalize()

    pass? =
      chunks == [
        %{"chunk" => "tool:", "done" => false},
        %{
          "chunk" => %{
            "tool_calls" => [
              %{
                "arguments" => %{"query" => "capital-france"},
                "id" => "call_1",
                "name" => "lookup"
              }
            ]
          },
          "done" => false
        },
        %{"chunk" => "Paris", "done" => false},
        %{"chunk" => nil, "done" => true}
      ]

    %{
      "id" => "provider_stream_chunk_replay",
      "scope" => "imp",
      "passing" => pass?,
      "evidence" => chunks
    }
  end

  defp normalize_stream_response(%Imp.Streaming.Messages.StreamResponse{} = response) do
    %{"chunk" => response.chunk, "done" => response.done}
  end

  defp normalize_stream_response(other), do: normalize(other)

  defp semantic_summary(checks) do
    %{
      "total" => length(checks),
      "passing" => Enum.count(checks, & &1["passing"]),
      "all_passing" => Enum.all?(checks, & &1["passing"]),
      "note" =>
        "These provider-free Imp semantic checks cover surfaces whose exact DSPy replay fixtures are still being expanded."
    }
  end

  defp python(opts) do
    path =
      Keyword.get(opts, :python) ||
        if File.exists?("tmp/dspy-parity-venv/bin/python"),
          do: "tmp/dspy-parity-venv/bin/python",
          else: "python3"

    if String.contains?(path, "/"), do: Path.expand(path), else: path
  end

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {existing_atom_or_string(key), value} end)
  end

  defp existing_atom_or_string(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  defp normalize(nil), do: nil

  defp normalize(%{} = map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), normalize(value)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Map.new()
  end

  defp normalize(values) when is_list(values) do
    if Keyword.keyword?(values) do
      values
      |> Enum.map(fn {key, value} -> {to_string(key), normalize(value)} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Map.new()
    else
      Enum.map(values, &normalize/1)
    end
  end

  defp normalize({left, right}), do: [normalize(left), normalize(right)]
  defp normalize(value), do: value

  defp file_sha256(path),
    do: :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)

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

defmodule Mix.Tasks.Imp.Benchmark.Trace.StableReqLLM do
  @moduledoc false

  def generate_text(model, messages, opts) do
    opts
    |> Keyword.fetch!(:counter)
    |> Agent.update(&(&1 + 1))

    {:ok,
     %ReqLLM.Response{
       id: "golden_cache",
       model: to_string(model),
       context: ReqLLM.Context.new(messages),
       message: ReqLLM.Context.assistant("Answer: cached")
     }}
  end
end

defmodule Mix.Tasks.Imp.Benchmark.Trace.StreamReqLLM do
  @moduledoc false

  def stream_text(model, messages, _opts) do
    {:ok,
     %ReqLLM.StreamResponse{
       stream: [
         ReqLLM.StreamChunk.text("tool:"),
         ReqLLM.StreamChunk.tool_call("lookup", %{query: "capital-france"}, %{id: "call_1"}),
         ReqLLM.StreamChunk.text("Paris"),
         ReqLLM.StreamChunk.meta(%{finish_reason: "stop"})
       ],
       metadata_handle: self(),
       cancel: fn -> :ok end,
       model: model,
       context: ReqLLM.Context.new(messages)
     }}
  end
end
