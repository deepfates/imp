defmodule Mix.Tasks.Dsex.Benchmark.Trace do
  @moduledoc """
  Run provider-free golden trace parity fixtures through DSEx and Python DSPy.

      mix dsex.benchmark.trace

  The task is intentionally deterministic: fixture responses are replayed by
  static local LMs on both sides. It proves library semantics without provider latency
  or model nondeterminism.
  """

  use Mix.Task

  @shortdoc "Run DSEx-vs-DSPy golden trace parity fixtures"

  @default_fixtures "test/fixtures/golden_trace/cases.json"
  @default_out_dir "benchmarks/results"

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
    dsex = dsex_report(cases)
    dspy = dspy_report(fixtures_path, python(opts), out_dir)
    report = comparison_report(fixtures_path, cases, dsex, dspy, dsex_semantic_checks())

    out_path = Path.join(out_dir, "golden-trace-parity-#{timestamp_slug()}.json")
    File.write!(out_path, Jason.encode!(report, pretty: true) <> "\n")

    Mix.shell().info("golden trace parity report: #{out_path}")
    Mix.shell().info("golden trace passing: #{report["summary"]["all_cases_passing"]}")

    Mix.shell().info(
      "passing cases: #{report["summary"]["passing"]}/#{report["summary"]["total"]}"
    )

    unless report["summary"]["all_cases_passing"] and
             report["summary"]["dsex_semantic_checks"]["all_passing"] do
      Mix.raise("golden trace parity failed; inspect #{out_path}")
    end
  end

  defp dsex_report(cases) do
    %{
      "schema_version" => 1,
      "runner" => "dsex-golden-trace",
      "elixir" => System.version(),
      "otp" => System.otp_release(),
      "git_sha" => git_sha(),
      "cases" => Enum.map(cases, &run_dsex_case/1)
    }
  end

  defp run_dsex_case(case) do
    {:ok, queue} = Agent.start_link(fn -> Map.get(case, "dsex_responses", case["responses"]) end)
    {:ok, calls} = Agent.start_link(fn -> [] end)

    lm = fn messages, opts ->
      Agent.update(
        calls,
        &(&1 ++ [%{"messages" => normalize(messages), "opts" => normalize(opts)}])
      )

      Agent.get_and_update(queue, fn
        [response | rest] -> {{:ok, response}, rest}
        [] -> {{:error, :fixture_response_queue_exhausted}, []}
      end)
    end

    try do
      signature = DSEx.signature(case["signature"], case["instructions"] || "")
      Process.put(:dsex_golden_trace_tools, build_dsex_tools(case))
      Process.put(:dsex_golden_trace_max_iters, case["max_iters"] || 20)
      program = build_dsex_program(case["module"], signature, case["adapter"], lm)

      case safe_call(program, atomize_keys(case["inputs"])) do
        {:ok, prediction} -> dsex_success(case, prediction, calls, queue)
        {:error, reason} -> dsex_error(case, reason, calls, queue)
      end
    after
      Process.delete(:dsex_golden_trace_tools)
      Process.delete(:dsex_golden_trace_max_iters)
      Agent.stop(queue)
      Agent.stop(calls)
    end
  end

  defp build_dsex_program("predict", signature, adapter, lm),
    do: DSEx.predict(signature, lm: lm, adapter: adapter_module(adapter))

  defp build_dsex_program("chain_of_thought", signature, adapter, lm),
    do: DSEx.chain_of_thought(signature, lm: lm, adapter: adapter_module(adapter))

  defp build_dsex_program("react", signature, _adapter, lm),
    do:
      DSEx.react(signature, Process.get(:dsex_golden_trace_tools, []),
        lm: lm,
        max_iters: Process.get(:dsex_golden_trace_max_iters, 20)
      )

  defp build_dsex_program(module, _signature, _adapter, _lm),
    do: Mix.raise("unsupported fixture module: #{module}")

  defp build_dsex_tools(case) do
    Enum.map(case["tools"] || [], fn spec ->
      outputs = spec["outputs"] || %{}

      DSEx.Tool.new(
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
    DSEx.Module.call(program, inputs)
  rescue
    exception -> {:error, exception}
  end

  defp dsex_success(case, prediction, calls, queue) do
    prediction_map = prediction |> DSEx.Prediction.to_map() |> normalize()

    %{
      "id" => case["id"],
      "status" => "ok",
      "prediction" => prediction_map,
      "tool_trace" => tool_trace(prediction_map),
      "error" => nil,
      "history" => Agent.get(calls, & &1),
      "remaining_responses" => Agent.get(queue, &length/1)
    }
  end

  defp dsex_error(case, reason, calls, queue) do
    %{
      "id" => case["id"],
      "status" => "error",
      "prediction" => nil,
      "tool_trace" => [],
      "error" => Exception.format(:error, reason),
      "history" => Agent.get(calls, & &1),
      "remaining_responses" => Agent.get(queue, &length/1)
    }
  end

  defp adapter_module("chat"), do: DSEx.Adapter.Chat
  defp adapter_module("json"), do: DSEx.Adapter.JSON
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

  defp comparison_report(fixtures_path, cases, dsex, dspy, semantic_checks) do
    dsex_cases = Map.new(dsex["cases"], &{&1["id"], &1})
    dspy_cases = Map.new(dspy["cases"], &{&1["id"], &1})

    comparisons =
      Enum.map(cases, fn case ->
        compare_case(case, dsex_cases[case["id"]], dspy_cases[case["id"]])
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
      "dsex" => Map.take(dsex, ["runner", "elixir", "otp", "git_sha"]),
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
        "dsex_semantic_checks" => semantic_summary(semantic_checks),
        "message_template_parity" => false,
        "message_template_note" =>
          "DSEx and DSPy intentionally use different prompt templates; this lane records message traces and asserts normalized prediction parity first."
      },
      "dsex_semantic_checks" => semantic_checks,
      "cases" => comparisons
    }
  end

  defp compare_case(fixture, dsex, dspy) do
    expected_status = fixture["expected_status"] || "ok"
    expected = normalize(fixture["expected_prediction"] || %{})
    dsex_prediction = normalize(dsex && dsex["prediction"])
    dspy_prediction = normalize(dspy && dspy["prediction"])
    expected_tool_trace = normalize(fixture["expected_tool_trace"])
    dsex_tool_trace = normalize(dsex && dsex["tool_trace"])
    dspy_tool_trace = normalize(dspy && dspy["tool_trace"])

    status_parity =
      (dsex && dspy && dsex["status"] == expected_status) and dspy["status"] == expected_status

    prediction_parity =
      status_parity and expected_status == "ok" and
        expected_projection(dsex_prediction, expected) == expected and
        expected_projection(dspy_prediction, expected) == expected

    tool_trace_required? = not is_nil(expected_tool_trace)

    tool_trace_parity =
      is_nil(expected_tool_trace) or
        (status_parity and expected_status == "ok" and
           dsex_tool_trace == expected_tool_trace and dspy_tool_trace == expected_tool_trace)

    error_parity =
      status_parity and expected_status == "error" and
        error_contains?(dsex && dsex["error"], fixture["expected_error_contains"]) and
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
      "dsex" => dsex,
      "dspy" => dspy,
      "intentional_deviations" =>
        List.wrap(fixture["intentional_deviations"]) ++
          [
            "Prompt template byte parity is not asserted in this initial lane; normalized message traces are retained for review."
          ]
    }
  end

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
    |> Enum.reject(&(to_string(&1["tool"]) == "submit"))
    |> Enum.map(fn event ->
      %{
        "tool" => to_string(event["tool"]),
        "arguments" => event["arguments"] || %{},
        "result" => event["result"]
      }
    end)
  end

  defp tool_trace(_prediction), do: []

  defp dsex_semantic_checks do
    [
      streaming_incremental_fields_check(),
      save_load_redaction_check(),
      req_llm_cache_check(),
      provider_stream_chunk_replay_check()
    ]
  end

  defp streaming_incremental_fields_check do
    events =
      DSEx.Streaming.incremental_fields(
        ["[[ ## ans", "wer ## ]]beam", "[[ ## rationale ## ]]fast"],
        "question -> answer, rationale"
      )

    pass? = events == [%{field: :answer, value: "beam"}, %{field: :rationale, value: "fast"}]

    %{
      "id" => "streaming_incremental_fields",
      "scope" => "dsex",
      "passing" => pass?,
      "evidence" => normalize(events)
    }
  end

  defp save_load_redaction_check do
    secret = "not-persisted"

    program =
      DSEx.predict("question -> answer",
        lm: DSEx.req_llm("openai:gpt-test", api_key: secret, opts: [temperature: 0])
      )

    dumped = DSEx.Saving.dump(program)
    encoded = inspect(dumped)
    loaded = DSEx.Saving.load(dumped)

    pass? =
      not String.contains?(encoded, secret) and
        match?(%DSEx.Clients.ReqLLM{model: "openai:gpt-test"}, loaded.lm)

    %{
      "id" => "save_load_redacts_req_llm_credentials",
      "scope" => "dsex",
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
      DSEx.req_llm("openai:gpt-test",
        req_module: Mix.Tasks.Dsex.Benchmark.Trace.StableReqLLM,
        counter: counter
      )

    messages = [%{role: :user, content: "cache me"}]

    first = DSEx.LM.generate(lm, messages, cache: true)
    second = DSEx.LM.generate(lm, messages, cache: true)
    calls = Agent.get(counter, & &1)
    Agent.stop(counter)

    pass? = generated_content(first) == "Answer: cached" and second == first and calls == 1

    %{
      "id" => "req_llm_cache_hit_reuses_success",
      "scope" => "dsex",
      "passing" => pass?,
      "evidence" => %{"calls" => calls, "first" => inspect(first), "second" => inspect(second)}
    }
  end

  defp generated_content({:ok, content}) when is_binary(content), do: content

  defp generated_content({:ok, %{__dsex_lm_output__: content}}) when is_binary(content),
    do: content

  defp generated_content(_result), do: nil

  defp provider_stream_chunk_replay_check do
    lm =
      DSEx.req_llm("openai:gpt-test",
        req_module: Mix.Tasks.Dsex.Benchmark.Trace.StreamReqLLM
      )

    program = DSEx.predict("question -> answer", lm: lm)

    chunks =
      program
      |> DSEx.Streaming.stream(%{question: "pong"}, provider_stream: true)
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
      "scope" => "dsex",
      "passing" => pass?,
      "evidence" => chunks
    }
  end

  defp normalize_stream_response(%DSEx.Streaming.Messages.StreamResponse{} = response) do
    %{"chunk" => response.chunk, "done" => response.done}
  end

  defp normalize_stream_response(other), do: normalize(other)

  defp semantic_summary(checks) do
    %{
      "total" => length(checks),
      "passing" => Enum.count(checks, & &1["passing"]),
      "all_passing" => Enum.all?(checks, & &1["passing"]),
      "note" =>
        "These provider-free DSEx semantic checks cover surfaces whose exact DSPy replay fixtures are still being expanded."
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

defmodule Mix.Tasks.Dsex.Benchmark.Trace.StableReqLLM do
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

defmodule Mix.Tasks.Dsex.Benchmark.Trace.StreamReqLLM do
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
