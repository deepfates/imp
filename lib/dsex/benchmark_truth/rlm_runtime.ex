defmodule DSEx.BenchmarkTruth.RLMRuntime do
  @moduledoc false

  @callback execute(map(), String.t(), map()) :: {:ok, map()} | {:error, term()}

  defmodule AmbiguousExternalCall do
    defexception [:message]
  end

  defmodule MeteredLM do
    @moduledoc false
    defstruct [:inner, :budget, :usage, :max_tokens]

    def generate(%__MODULE__{} = lm, messages, opts) do
      opts = Keyword.put_new(opts, :max_tokens, lm.max_tokens)

      with {:ok, reservation} <-
             DSEx.BenchmarkTruth.CampaignBudget.reserve(lm.budget, messages, opts),
           result <- DSEx.LM.generate(lm.inner, messages, opts) do
        DSEx.BenchmarkTruth.CampaignBudget.release(lm.budget, reservation)
        record_result(lm, result)
      else
        {:error, dimension} when dimension in [:requests, :input_tokens, :output_tokens, :usd] ->
          {:error, {:campaign_budget_exhausted, dimension}}
      end
    end

    defp record_result(lm, {:ok, value} = result) do
      case usage(value) do
        %{} = usage ->
          DSEx.BenchmarkTruth.CampaignBudget.record_usage(lm.budget, usage)
          Agent.update(lm.usage, &sum(&1, usage))
          result

        nil ->
          {:error, :provider_usage_missing}
      end
    end

    defp record_result(_lm, {:error, reason}) do
      raise DSEx.BenchmarkTruth.RLMRuntime.AmbiguousExternalCall,
        message: "provider call returned without auditable usage: #{inspect(reason)}"
    end

    defp usage(%{__dsex_lm_metadata__: metadata}),
      do: normalize(get_in(metadata, [:req_llm, :usage]))

    defp usage(%{"__dsex_lm_metadata__" => metadata}),
      do: normalize(get_in(metadata, ["req_llm", "usage"]))

    defp usage(_), do: nil

    defp normalize(usage) when is_map(usage) do
      %{
        input_tokens: number(usage, :input_tokens),
        output_tokens: number(usage, :output_tokens),
        usd: number(usage, :total_cost, number(usage, :cost, 0.0))
      }
    end

    defp normalize(_), do: nil

    defp number(map, key, default \\ 0),
      do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

    defp sum(left, right),
      do: %{
        "requests" => left["requests"] + 1,
        "input_tokens" => left["input_tokens"] + right.input_tokens,
        "output_tokens" => left["output_tokens"] + right.output_tokens,
        "usd" => left["usd"] + right.usd
      }
  end

  defmodule Dsex do
    @moduledoc false
    @behaviour Elixir.DSEx.BenchmarkTruth.RLMRuntime

    @impl true
    def execute(row, approach, context) do
      {:ok, usage} = Agent.start_link(fn -> empty_usage() end)
      root = metered_lm(context, "root", usage)

      sub =
        metered_lm(
          context,
          if(approach == "compaction", do: "compaction", else: "submodel"),
          usage
        )

      started = System.monotonic_time()
      result = run(approach, row, root, sub, context)

      latency =
        System.convert_time_unit(System.monotonic_time() - started, :native, :microsecond) / 1000

      measured = Agent.get(usage, & &1)
      Agent.stop(usage)

      case result do
        {:ok, answer, trace_shape, trace} when is_binary(answer) and answer != "" ->
          {:ok,
           %{
             "answer" => answer,
             "latency_ms" => latency,
             "usage" => measured,
             "trace_shape" => trace_shape,
             "trace" => bounded_trace(trace),
             "budget_accounted" => true
           }}

        {:ok, answer, _shape, _trace} ->
          {:error, {:malformed_output, answer}}

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp run("direct", row, root, _sub, _context) do
      call_predict(root, row, full_context(row), ["predict:direct"])
    end

    defp run("simple_retrieval", row, root, _sub, context) do
      k = get_in(context, ["approach", "settings", "k"]) || 8
      retrieved = retrieve(row, k)
      call_predict(root, row, retrieved, ["retrieve:lexical", "predict"])
    end

    defp run("compaction", row, root, sub, context) do
      settings = context["approach"]["settings"]

      chunks =
        full_context(row)
        |> chunk(settings["chunk_chars"] || 100_000)
        |> Enum.take(settings["max_chunks"] || 32)

      with {:ok, summaries} <- map_ok(chunks, fn value -> call_summary(sub, value) end) do
        call_predict(
          root,
          row,
          Enum.join(summaries, "\n\n"),
          Enum.map(chunks, fn _ -> "summarize" end) ++ ["predict"]
        )
      end
    end

    defp run("rlm", row, root, sub, context) do
      serializable =
        DSEx.rlm_serializable(:context, fn -> full_context(row) end,
          metadata: %{family: row["family"], id: row["id"]}
        )

      settings = context["approach"]["settings"]

      program =
        DSEx.rlm("context, question, choices -> answer",
          lm: root,
          sub_lm: sub,
          max_iterations: settings["max_iterations"] || 20,
          max_llm_calls: settings["max_llm_calls"] || 50,
          max_recursion_depth: settings["recursion_depth"] || 1,
          max_time_ms: context["row_timeout_ms"]
        )

      case DSEx.call(program, %{
             context: serializable,
             question: row["question"],
             choices: row["choices"] || []
           }) do
        {:ok, prediction} ->
          trace = get_in(prediction.metadata, [:rlm_trace]) || []

          {:ok, to_string(DSEx.get(prediction, :answer)),
           Enum.map(trace, &("rlm:" <> to_string(&1.action))), trace}

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp call_predict(lm, row, context, shape) do
      program = DSEx.predict("context, question, choices -> answer", lm: lm)

      case DSEx.call(program, %{
             context: context,
             question: row["question"],
             choices: row["choices"] || []
           }) do
        {:ok, prediction} -> {:ok, to_string(DSEx.get(prediction, :answer)), shape, []}
        {:error, reason} -> {:error, reason}
      end
    end

    defp call_summary(lm, context) do
      program = DSEx.predict("context -> summary", lm: lm)

      case DSEx.call(program, %{context: context}) do
        {:ok, prediction} -> {:ok, to_string(DSEx.get(prediction, :summary))}
        {:error, reason} -> {:error, reason}
      end
    end

    defp metered_lm(context, role, usage) do
      model = context["manifest"]["models"][role]

      api_key =
        System.get_env("OPENAI_API_KEY") ||
          raise "OPENAI_API_KEY is required for live RLM campaign execution"

      inner =
        DSEx.req_llm(model["dsex"],
          api_key: api_key,
          temperature: model["temperature"],
          reasoning_effort: model["reasoning"],
          max_tokens: model["max_output_tokens"]
        )

      %MeteredLM{
        inner: inner,
        budget: context["budget"],
        usage: usage,
        max_tokens: model["max_output_tokens"]
      }
    end

    defp retrieve(row, k) do
      terms =
        row["question"]
        |> String.downcase()
        |> String.split(~r/[^a-z0-9]+/, trim: true)
        |> MapSet.new()

      row
      |> documents()
      |> Enum.sort_by(fn text ->
        -Enum.count(
          String.split(String.downcase(text), ~r/[^a-z0-9]+/, trim: true),
          &MapSet.member?(terms, &1)
        )
      end)
      |> Enum.take(k)
      |> Enum.join("\n\n")
    end

    defp documents(%{"documents" => docs}), do: Enum.map(docs, & &1["text"])
    defp documents(row), do: full_context(row) |> String.split(~r/\n{2,}/, trim: true)
    defp full_context(%{"documents" => docs}), do: Jason.encode!(docs)
    defp full_context(%{"context" => context}) when is_binary(context), do: context
    defp full_context(%{"context" => context}), do: Jason.encode!(context)

    defp chunk(text, size) do
      text
      |> String.codepoints()
      |> Enum.chunk_every(size)
      |> Enum.map(&Enum.join/1)
    end

    defp map_ok(values, fun),
      do:
        Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
          case fun.(value) do
            {:ok, result} -> {:cont, {:ok, [result | acc]}}
            error -> {:halt, error}
          end
        end)
        |> then(fn
          {:ok, values} -> {:ok, Enum.reverse(values)}
          error -> error
        end)

    defp bounded_trace(trace) do
      trace
      |> List.wrap()
      |> Enum.with_index()
      |> Enum.map(fn {event, index} ->
        encoded = inspect(event, limit: 100, printable_limit: 2_000)

        %{
          "index" => index,
          "action" => event_action(event),
          "bytes" => byte_size(encoded),
          "sha256" => :crypto.hash(:sha256, encoded) |> Base.encode16(case: :lower)
        }
      end)
    end

    defp event_action(%{action: action}), do: to_string(action)
    defp event_action(_event), do: "event"

    defp empty_usage,
      do: %{"requests" => 0, "input_tokens" => 0, "output_tokens" => 0, "usd" => 0.0}
  end

  defmodule DSPy do
    @moduledoc false
    @behaviour Elixir.DSEx.BenchmarkTruth.RLMRuntime

    @impl true
    def execute(row, approach, context) do
      root = context["work_dir"]
      id = System.unique_integer([:positive, :monotonic])
      request = Path.join(root, "dspy-row-#{id}.request.json")
      response = Path.join(root, "dspy-row-#{id}.response.json")
      File.mkdir_p!(root)

      try do
        File.write!(
          request,
          Jason.encode!(%{
            "row" => row,
            "approach" => approach,
            "manifest" => context["manifest"],
            "budget_remaining" => context["budget_remaining"]
          }),
          [:sync]
        )

        env = [
          {"PYTHONPATH", Path.expand("tmp/dspy-current-target")},
          {"PYTHONDONTWRITEBYTECODE", "1"}
        ]

        result =
          System.cmd(
            context["python"],
            ["scripts/dspy_rlm_campaign.py", "--request", request, "--response", response],
            env: env,
            stderr_to_stdout: true
          )

        case result do
          {_output, 0} ->
            {:ok, response |> File.read!() |> Jason.decode!()}

          {output, status} ->
            raise DSEx.BenchmarkTruth.RLMRuntime.AmbiguousExternalCall,
              message: "DSPy sidecar exited #{status} after dispatch may have begun: #{output}"
        end
      after
        File.rm(request)
        File.rm(response)
      end
    end
  end
end
