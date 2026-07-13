defmodule DSEx.BenchmarkTruth.RLMRuntime do
  @moduledoc false

  @callback execute(map(), String.t(), map()) :: {:ok, map()} | {:error, term()}

  defmodule AmbiguousExternalCall do
    defexception [:message]
  end

  defmodule MeteredLM do
    @moduledoc false
    defstruct [:inner, :budget, :usage, :max_tokens, :role, :pricing]

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
      case usage(value, lm.pricing) do
        %{} = usage ->
          DSEx.BenchmarkTruth.CampaignBudget.record_usage(lm.budget, usage)
          Agent.update(lm.usage, &sum(&1, usage, lm.role))

          cond do
            usage.cost_authority == "unavailable" ->
              {:error, :provider_cost_unauditable}

            usage.input_tokens <= 0 or usage.output_tokens <= 0 ->
              {:error, :provider_success_usage_incomplete}

            true ->
              result
          end

        nil ->
          {:error, :provider_usage_missing}
      end
    end

    defp record_result(lm, {:error, reason}) do
      case usage(reason, lm.pricing) do
        %{} = usage ->
          DSEx.BenchmarkTruth.CampaignBudget.record_usage(lm.budget, usage)
          Agent.update(lm.usage, &sum(&1, usage, lm.role))
          {:error, {:provider_error_with_usage, inspect(reason)}}

        nil ->
          raise DSEx.BenchmarkTruth.RLMRuntime.AmbiguousExternalCall,
            message: "provider call returned without auditable usage: #{inspect(reason)}"
      end
    end

    defp usage(%{__dsex_lm_metadata__: metadata}, pricing),
      do: normalize(get_in(metadata, [:req_llm, :usage]), pricing)

    defp usage(%{"__dsex_lm_metadata__" => metadata}, pricing),
      do: normalize(get_in(metadata, ["req_llm", "usage"]), pricing)

    defp usage(%{usage: usage}, pricing), do: normalize(usage, pricing)
    defp usage(%{"usage" => usage}, pricing), do: normalize(usage, pricing)
    defp usage({_, value}, pricing), do: usage(value, pricing)

    defp usage(_, _pricing), do: nil

    defp normalize(usage, pricing) when is_map(usage) and is_map(pricing) do
      with {:ok, input_tokens} <- token_count(usage, :input_tokens),
           {:ok, output_tokens} <- token_count(usage, :output_tokens) do
        cost = cost(usage, input_tokens, output_tokens, pricing)

        %{
          input_tokens: input_tokens,
          output_tokens: output_tokens,
          usd: cost.usd,
          cost_authority: cost.authority,
          cost_rates: pricing,
          provider_reported_usd: cost.provider_reported_usd
        }
      else
        _ -> nil
      end
    end

    defp normalize(_, _pricing), do: nil

    defp token_count(map, key) do
      case Map.get(map, key, Map.get(map, Atom.to_string(key), 0)) do
        value when is_integer(value) and value >= 0 -> {:ok, value}
        _ -> :error
      end
    end

    defp cost(usage, input_tokens, output_tokens, pricing) do
      derived =
        input_tokens / 1_000_000 * pricing["input_per_million"] +
          output_tokens / 1_000_000 * pricing["output_per_million"]

      case provider_cost(usage) do
        {:ok, reported} when reported > 0 ->
          %{authority: "provider_reported", usd: reported, provider_reported_usd: reported}

        :absent ->
          if usage_authority(usage) == "free" do
            %{authority: "free", usd: 0.0, provider_reported_usd: 0.0}
          else
            if derived > 0,
              do: %{authority: "pricing_derived", usd: derived, provider_reported_usd: nil},
              else: %{authority: "unavailable", usd: 0.0, provider_reported_usd: nil}
          end

        _ ->
          %{authority: "unavailable", usd: 0.0, provider_reported_usd: nil}
      end
    end

    defp provider_cost(usage) do
      values =
        [:total_cost, :cost]
        |> Enum.flat_map(fn key ->
          case fetch(usage, key) do
            value when value in [:missing, nil] -> []
            value when key == :cost and is_map(value) -> []
            value -> [value]
          end
        end)

      cond do
        Enum.any?(values, &(not is_number(&1) or &1 < 0)) ->
          :invalid

        values == [] ->
          :absent

        true ->
          [first | rest] = values

          if Enum.all?(rest, &close?(&1, first)) do
            if first > 0, do: {:ok, first}, else: :absent
          else
            :invalid
          end
      end
    end

    defp fetch(map, key) do
      cond do
        Map.has_key?(map, key) -> map[key]
        Map.has_key?(map, Atom.to_string(key)) -> map[Atom.to_string(key)]
        true -> :missing
      end
    end

    defp usage_authority(usage),
      do: Map.get(usage, :cost_authority, Map.get(usage, "cost_authority"))

    defp close?(left, right),
      do: abs(left - right) <= max(1.0e-12, max(abs(left), abs(right)) * 1.0e-9)

    defp sum(left, right, role) do
      request = left["requests"] + 1
      audit_role = if(role == "root", do: "root", else: "sub")

      audit = %{
        "request" => request,
        "role" => audit_role,
        "authority" => right.cost_authority,
        "input_tokens" => right.input_tokens,
        "output_tokens" => right.output_tokens,
        "usd" => right.usd,
        "provider_reported_usd" => right.provider_reported_usd,
        "rates" => right.cost_rates
      }

      audits = left["cost_audit"] ++ [audit]

      %{
        "requests" => left["requests"] + 1,
        "root_calls" => left["root_calls"] + if(role == "root", do: 1, else: 0),
        "sub_calls" => left["sub_calls"] + if(role == "root", do: 0, else: 1),
        "input_tokens" => left["input_tokens"] + right.input_tokens,
        "output_tokens" => left["output_tokens"] + right.output_tokens,
        "usd" => left["usd"] + right.usd,
        "cost_authority" => aggregate_authority(audits),
        "cost_rates" => right.cost_rates,
        "cost_audit" => audits
      }
    end

    defp aggregate_authority(audits) do
      authorities = audits |> Enum.map(& &1["authority"]) |> Enum.uniq()

      cond do
        "unavailable" in authorities -> "unavailable"
        length(authorities) == 1 -> hd(authorities)
        true -> "mixed"
      end
    end
  end

  defmodule ControllerLM do
    @moduledoc false
    defstruct [:inner]

    def generate(%__MODULE__{inner: inner}, messages, opts) do
      with {:ok, result} <- DSEx.LM.generate(inner, messages, opts),
           {:ok, content} <- controller_content(result),
           {:ok, action} when is_map(action) <- Jason.decode(content) do
        {:ok, action}
      else
        {:ok, _other} -> {:error, :invalid_rlm_controller_json}
        {:error, _reason} = error -> error
      end
    end

    defp controller_content(%{__dsex_lm_metadata__: %{req_llm: %{content: content}}})
         when is_binary(content),
         do: {:ok, content}

    defp controller_content(%{
           "__dsex_lm_metadata__" => %{"req_llm" => %{"content" => content}}
         })
         when is_binary(content),
         do: {:ok, content}

    defp controller_content(content) when is_binary(content), do: {:ok, content}
    defp controller_content(_result), do: {:error, :missing_rlm_controller_content}
  end

  defmodule Dsex do
    @moduledoc false
    @behaviour Elixir.DSEx.BenchmarkTruth.RLMRuntime

    @impl true
    def execute(row, approach, context) do
      pricing = get_in(context, ["approach", "settings", "reservation_pricing"])
      {:ok, usage} = Agent.start_link(fn -> empty_usage(pricing) end)
      root = metered_lm(context, "root", usage)
      controller = if approach == "rlm", do: %ControllerLM{inner: root}, else: root

      sub =
        metered_lm(
          context,
          if(approach == "compaction", do: "compaction", else: "submodel"),
          usage
        )

      started = System.monotonic_time()
      result = run(approach, row, controller, sub, context)

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
             "budget_accounted" => true,
             "call_semantics" => call_semantics(approach, context, measured, trace)
           }}

        {:ok, answer, _shape, _trace} ->
          {:error, {:malformed_output, answer}}

        {:error, reason} ->
          {:error,
           %{
             "reason" => inspect(reason),
             "usage" => measured,
             "budget_accounted" => true,
             "call_semantics" => call_semantics(approach, context, measured, [])
           }}
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
        max_tokens: model["max_output_tokens"],
        role: role,
        pricing: get_in(context, ["approach", "settings", "reservation_pricing"])
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

    defp call_semantics(approach, context, usage, trace) do
      %{
        "provider_calls" => usage["requests"],
        "root_calls" => usage["root_calls"],
        "sub_calls" => usage["sub_calls"],
        "max_llm_calls_scope" =>
          if(approach == "rlm",
            do: "rlm_loop_provider_calls_excluding_extract",
            else: "not_applicable"
          ),
        "configured_max_depth" =>
          if(approach == "rlm",
            do: get_in(context, ["approach", "settings", "recursion_depth"]) || 0,
            else: 0
          ),
        "max_observed_depth" =>
          trace
          |> List.wrap()
          |> Enum.map(&Map.get(&1, :depth, Map.get(&1, "depth", 0)))
          |> Enum.filter(&is_integer/1)
          |> Enum.max(fn -> 0 end)
      }
    end

    defp empty_usage(pricing),
      do: %{
        "requests" => 0,
        "root_calls" => 0,
        "sub_calls" => 0,
        "input_tokens" => 0,
        "output_tokens" => 0,
        "usd" => 0.0,
        "cost_authority" => "unavailable",
        "cost_rates" => pricing,
        "cost_audit" => []
      }
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
            decoded = response |> File.read!() |> Jason.decode!()
            if(decoded["status"] == "error", do: {:error, decoded}, else: {:ok, decoded})

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
