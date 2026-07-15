defmodule Imp.BenchmarkTruth.RLMRuntime do
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
             Imp.BenchmarkTruth.CampaignBudget.reserve(lm.budget, messages, opts),
           result <- Imp.LM.generate(lm.inner, messages, opts) do
        Imp.BenchmarkTruth.CampaignBudget.release(lm.budget, reservation)
        record_result(lm, result)
      else
        {:error, dimension} when dimension in [:requests, :input_tokens, :output_tokens, :usd] ->
          {:error, {:campaign_budget_exhausted, dimension}}
      end
    end

    defp record_result(lm, {:ok, value} = result) do
      case usage(value, lm.pricing) do
        %{} = usage ->
          Imp.BenchmarkTruth.CampaignBudget.record_usage(lm.budget, usage)
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
          Imp.BenchmarkTruth.CampaignBudget.record_usage(lm.budget, usage)
          Agent.update(lm.usage, &sum(&1, usage, lm.role))
          {:error, {:provider_error_with_usage, error_class(reason)}}

        nil ->
          raise Imp.BenchmarkTruth.RLMRuntime.AmbiguousExternalCall,
            message: "provider call returned without auditable usage (#{error_class(reason)})"
      end
    end

    defp error_class(%{__struct__: module}) when is_atom(module), do: inspect(module)
    defp error_class({tag, _value}) when is_atom(tag), do: Atom.to_string(tag)
    defp error_class(value) when is_map(value), do: "map"
    defp error_class(value) when is_atom(value), do: "atom"
    defp error_class(value) when is_tuple(value), do: "tuple"
    defp error_class(value) when is_binary(value), do: "string"
    defp error_class(_value), do: "term"

    defp usage(%{__imp_lm_metadata__: _metadata} = result, pricing) do
      with {:ok, metadata} <- Imp.LM.Result.metadata(result) do
        normalize(get_in(metadata, [:req_llm, :usage]), pricing)
      else
        _error -> nil
      end
    end

    defp usage(%{"__imp_lm_metadata__" => _metadata} = result, pricing) do
      with {:ok, metadata} <- Imp.LM.Result.metadata(result) do
        normalize(get_in(metadata, ["req_llm", "usage"]), pricing)
      else
        _error -> nil
      end
    end

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
      with {:ok, result} <- Imp.LM.generate(inner, messages, opts),
           {:ok, content} <- controller_content(result) do
        {:ok, content}
      end
    end

    defp controller_content(%{__imp_lm_metadata__: _metadata} = result) do
      with {:ok, metadata} <- Imp.LM.Result.metadata(result),
           content when is_binary(content) <- get_in(metadata, [:req_llm, :content]) do
        {:ok, content}
      else
        _error -> {:error, :missing_rlm_controller_content}
      end
    end

    defp controller_content(%{"__imp_lm_metadata__" => _metadata} = result) do
      with {:ok, metadata} <- Imp.LM.Result.metadata(result),
           content when is_binary(content) <- get_in(metadata, ["req_llm", "content"]) do
        {:ok, content}
      else
        _error -> {:error, :missing_rlm_controller_content}
      end
    end

    defp controller_content(content) when is_binary(content), do: {:ok, content}
    defp controller_content(_result), do: {:error, :missing_rlm_controller_content}
  end

  defmodule Native do
    @moduledoc false
    @behaviour Elixir.Imp.BenchmarkTruth.RLMRuntime

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
        {:ok, answer, trace_shape, trace} when is_binary(answer) ->
          if String.trim(answer) == "" do
            malformed_output(answer, trace_shape, trace, measured, latency, approach, context)
          else
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
          end

        {:ok, answer, shape, trace} ->
          malformed_output(answer, shape, trace, measured, latency, approach, context)

        {:error, reason} ->
          trace = trace_from_reason(reason)

          {:error,
           %{
             "reason" => safe_reason(reason),
             "usage" => measured,
             "latency_ms" => latency,
             "trace_shape" => Enum.map(trace, &("rlm:" <> event_action(&1))),
             "trace" => bounded_trace(trace),
             "budget_accounted" => true,
             "call_semantics" => call_semantics(approach, context, measured, trace)
           }}
      end
    end

    defp malformed_output(answer, shape, trace, usage, latency, approach, context) do
      {:error,
       %{
         "reason" =>
           "malformed output: expected a non-empty string answer, got #{malformed_type(answer)}",
         "usage" => usage,
         "latency_ms" => latency,
         "trace_shape" => shape,
         "trace" => bounded_trace(trace),
         "budget_accounted" => true,
         "call_semantics" => call_semantics(approach, context, usage, trace)
       }}
    end

    defp malformed_type(value) when is_binary(value), do: "empty string"
    defp malformed_type(value) when is_map(value), do: "map"
    defp malformed_type(value) when is_list(value), do: "list"
    defp malformed_type(value) when is_atom(value), do: "atom"
    defp malformed_type(value) when is_number(value), do: "number"
    defp malformed_type(_value), do: "term"

    defp safe_reason(reason) do
      reason
      |> Imp.Redaction.redact()
      |> inspect(limit: 50, printable_limit: 2_000)
    end

    defp trace_from_reason(reason) when is_tuple(reason) do
      reason
      |> Tuple.to_list()
      |> Enum.reverse()
      |> Enum.find_value([], fn item ->
        case trace_from_reason(item) do
          [] -> nil
          trace -> trace
        end
      end)
    end

    defp trace_from_reason(trace) when is_list(trace) do
      if Enum.all?(
           trace,
           &(is_map(&1) and (Map.has_key?(&1, :action) or Map.has_key?(&1, "action")))
         ),
         do: trace,
         else: []
    end

    defp trace_from_reason(_reason), do: []

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
        Imp.rlm_serializable(:context, fn -> full_context(row) end,
          metadata: %{family: row["family"], id: row["id"]}
        )

      settings = context["approach"]["settings"]

      program =
        Imp.rlm("context, question, choices -> answer",
          lm: root,
          sub_lm: sub,
          max_iterations: settings["max_iterations"] || 20,
          max_llm_calls: settings["max_llm_calls"] || 50,
          max_recursion_depth: settings["recursion_depth"] || 1,
          max_time_ms: context["row_timeout_ms"]
        )

      case Imp.call(program, %{
             context: serializable,
             question: row["question"],
             choices: row["choices"] || []
           }) do
        {:ok, prediction} ->
          trace =
            (get_in(prediction.metadata, [:rlm_trace]) || []) ++
              (get_in(prediction.metadata, [:rlm_child_traces]) || [])

          {:ok, to_string(Imp.get(prediction, :answer)),
           Enum.map(trace, &("rlm:" <> to_string(&1.action))), trace}

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp call_predict(lm, row, context, shape) do
      program = Imp.predict("context, question, choices -> answer", lm: lm)

      case Imp.call(program, %{
             context: context,
             question: row["question"],
             choices: row["choices"] || []
           }) do
        {:ok, prediction} -> {:ok, to_string(Imp.get(prediction, :answer)), shape, []}
        {:error, reason} -> {:error, reason}
      end
    end

    defp call_summary(lm, context) do
      program = Imp.predict("context -> summary", lm: lm)

      case Imp.call(program, %{context: context}) do
        {:ok, prediction} -> {:ok, to_string(Imp.get(prediction, :summary))}
        {:error, reason} -> {:error, reason}
      end
    end

    defp metered_lm(context, role, usage) do
      model = context["manifest"]["models"][role]
      {model_spec, api_key_env} = imp_model_spec(model["imp"])

      api_key =
        System.get_env(api_key_env) ||
          raise "#{api_key_env} is required for live RLM campaign execution"

      opts =
        [
          api_key: api_key,
          temperature: model["temperature"],
          max_tokens: model["max_output_tokens"]
        ]
        |> maybe_put_reasoning_effort(model["reasoning"])

      inner = Imp.req_llm(model_spec, opts)

      %MeteredLM{
        inner: inner,
        budget: context["budget"],
        usage: usage,
        max_tokens: model["max_output_tokens"],
        role: role,
        pricing: get_in(context, ["approach", "settings", "reservation_pricing"])
      }
    end

    defp imp_model_spec(spec) when is_binary(spec), do: {spec, legacy_api_key_env!(spec)}

    defp imp_model_spec(spec) when is_map(spec) do
      provider =
        try do
          String.to_existing_atom(spec["provider"])
        rescue
          ArgumentError ->
            reraise RuntimeError,
                    [message: "unknown ReqLLM provider in RLM manifest: #{spec["provider"]}"],
                    __STACKTRACE__
        end

      model =
        ReqLLM.model!(%{
          provider: provider,
          id: spec["id"],
          base_url: spec["base_url"],
          limits: %{context: spec["context_window"]}
        })

      {model, spec["api_key_env"]}
    end

    defp legacy_api_key_env!(spec) do
      case String.split(spec, [":", "/"], parts: 2) do
        ["openai", _model] ->
          "OPENAI_API_KEY"

        ["anthropic", _model] ->
          "ANTHROPIC_API_KEY"

        ["openrouter", _model] ->
          "OPENROUTER_API_KEY"

        [_model] ->
          "OPENAI_API_KEY"

        [provider, _model] ->
          raise "RLM string model provider #{inspect(provider)} requires an explicit model spec with api_key_env"
      end
    end

    defp maybe_put_reasoning_effort(opts, "none"), do: opts

    defp maybe_put_reasoning_effort(opts, effort),
      do: Keyword.put(opts, :reasoning_effort, String.to_existing_atom(effort))

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
            do: "shared_root_sub_and_extract_calls",
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
    @behaviour Elixir.Imp.BenchmarkTruth.RLMRuntime

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
            raise Imp.BenchmarkTruth.RLMRuntime.AmbiguousExternalCall,
              message: "DSPy sidecar exited #{status} after dispatch may have begun: #{output}"
        end
      after
        File.rm(request)
        File.rm(response)
      end
    end
  end
end
