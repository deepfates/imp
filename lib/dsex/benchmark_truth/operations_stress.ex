defmodule DSEx.BenchmarkTruth.OperationsStress do
  @moduledoc false

  defmodule StableReqLLM do
    @moduledoc false

    def generate_text(_model, _messages, opts) do
      counter = Keyword.fetch!(opts, :counter)
      Agent.update(counter, &(&1 + 1))

      {:ok,
       %ReqLLM.Response{
         id: "ops-cache",
         model: "gpt-test",
         context: ReqLLM.Context.new([]),
         message: ReqLLM.Context.assistant("cached answer"),
         object: nil
       }}
    end
  end

  defmodule IsolatedProgram do
    @moduledoc false
    @behaviour DSEx.Module

    defstruct []

    @impl true
    def call(%__MODULE__{}, :raise), do: raise("ops branch failed")
    def call(%__MODULE__{}, :throw), do: throw(:ops_branch_thrown)
    def call(%__MODULE__{}, :invalid), do: :not_a_module_result
    def call(%__MODULE__{}, value), do: {:ok, DSEx.Prediction.new(value: value)}
  end

  def run(opts \\ []) do
    max_concurrency = Keyword.get(opts, :max_concurrency, 4)

    checks = [
      malformed_json_check(),
      malformed_xml_check(),
      malformed_chat_check(),
      partial_stream_check(),
      native_schema_shape_check(),
      save_load_round_trip_check(),
      cache_telemetry_check(),
      redacted_telemetry_check(),
      parallel_failure_isolation_check(max_concurrency)
    ]

    %{
      "schema_version" => 1,
      "generated_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "summary" => summary(checks),
      "checks" => checks
    }
  end

  defp malformed_json_check do
    signature = DSEx.signature("text -> label: string, score: number")
    result = DSEx.Adapter.JSON.parse(signature, ~s({"label": "ok", "score":), [])

    check("malformed_json_rejected", "adapter", match?({:error, _}, result), %{
      "result" => inspect(result)
    })
  end

  defp malformed_xml_check do
    signature = DSEx.signature("text -> label: string, score: number")
    result = DSEx.Adapter.XML.parse(signature, "<label>ok</label><score>", [])

    check("malformed_xml_rejected", "adapter", match?({:error, _}, result), %{
      "result" => inspect(result)
    })
  end

  defp malformed_chat_check do
    signature = DSEx.signature("question -> answer: string, rationale: string")
    result = DSEx.Adapter.Chat.parse(signature, "[[ ## answer ## ]]\nParis", [])

    check("malformed_chat_missing_fields_rejected", "adapter", match?({:error, _}, result), %{
      "result" => inspect(result)
    })
  end

  defp partial_stream_check do
    events =
      DSEx.Streaming.incremental_fields(
        ["[[ ## ans", "wer ## ]]Paris", "\n[[ ## rationale ## ]]capital"],
        "question -> answer, rationale"
      )

    check(
      "partial_stream_incremental_fields",
      "streaming",
      events == [
        %{field: :answer, value: "Paris"},
        %{field: :rationale, value: "capital"}
      ],
      %{"events" => json_safe(events)}
    )
  end

  defp native_schema_shape_check do
    signature = DSEx.signature("text -> label: enum[yes,no], score: number")
    opts = DSEx.Adapter.JSON.lm_opts(signature, native_json_schema: true)
    schema = get_in(opts, [:response_format, :json_schema, :schema])

    pass? =
      get_in(opts, [:response_format, :type]) == "json_schema" and
        get_in(schema, ["properties", "label", "enum"]) == ["yes", "no"] and
        get_in(schema, ["properties", "score", "type"]) == "number"

    check("provider_native_schema_shape", "structured_io", pass?, %{"lm_opts" => json_safe(opts)})
  end

  defp save_load_round_trip_check do
    secret = "sk-test-operations-secret-1234567890"

    program =
      DSEx.predict("question -> answer",
        adapter: DSEx.Adapter.JSON,
        lm: DSEx.req_llm("openai:gpt-test", api_key: secret, opts: [temperature: 0])
      )

    dumped = DSEx.Saving.dump(program)
    encoded = Jason.encode!(json_safe(dumped))
    loaded = DSEx.Saving.load(dumped)

    pass? =
      not String.contains?(encoded, secret) and
        match?(%DSEx.Predict.Predict{adapter: DSEx.Adapter.JSON}, loaded) and
        match?(%DSEx.Clients.ReqLLM{model: "openai:gpt-test"}, loaded.lm)

    check("save_load_round_trip_redacts_credentials", "persistence", pass?, %{
      "secret_persisted" => String.contains?(encoded, secret),
      "loaded_adapter" => inspect(loaded.adapter),
      "loaded_lm" => loaded.lm |> Map.from_struct() |> Map.take([:model, :opts]) |> json_safe()
    })
  end

  defp cache_telemetry_check do
    DSEx.Cache.clear()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    ref =
      attach_events([
        [:dsex, :cache, :miss],
        [:dsex, :cache, :hit],
        [:dsex, :lm, :start],
        [:dsex, :lm, :stop]
      ])

    lm =
      DSEx.req_llm("openai:gpt-test",
        req_module: __MODULE__.StableReqLLM,
        counter: counter,
        api_key: "sk-test-cache-secret-1234567890"
      )

    messages = [%{role: :user, content: "cache me"}]
    first = DSEx.LM.generate(lm, messages, cache: true)
    second = DSEx.LM.generate(lm, messages, cache: true)
    calls = Agent.get(counter, & &1)
    events = flush_events(ref)
    detach_events(ref)
    Agent.stop(counter)

    pass? =
      first == {:ok, "cached answer"} and second == first and calls == 1 and
        Enum.any?(events, &(&1["event"] == ["dsex", "cache", "miss"])) and
        Enum.any?(events, &(&1["event"] == ["dsex", "cache", "hit"])) and
        not (inspect(events) =~ "sk-test-cache-secret")

    check("cache_hit_miss_telemetry_redacted", "cache_telemetry", pass?, %{
      "calls" => calls,
      "events" => events
    })
  end

  defp redacted_telemetry_check do
    ref = attach_events([[:dsex, :ops, :stress]])

    DSEx.Telemetry.execute([:dsex, :ops, :stress], %{count: 1}, %{
      api_key: "sk-test-redacted-secret-1234567890",
      nested: %{authorization: "Bearer abcdefghijklmnopqrstuvwxyz"}
    })

    events = flush_events(ref)
    detach_events(ref)

    pass? =
      inspect(events) =~ "[REDACTED]" and
        not (inspect(events) =~ "sk-test-redacted-secret") and
        not (inspect(events) =~ "abcdefghijklmnopqrstuvwxyz")

    check("telemetry_metadata_redaction", "redaction", pass?, %{"events" => events})
  end

  defp parallel_failure_isolation_check(max_concurrency) do
    results =
      DSEx.Predict.Parallel.map(%IsolatedProgram{}, [:ok, :raise, :throw, :invalid],
        max_concurrency: max_concurrency,
        timeout: 5_000
      )

    pass? =
      match?(
        [
          {:ok, %DSEx.Prediction{}},
          {:error, {:parallel_program_failed, "ops branch failed"}},
          {:error, {:parallel_program_failed, "{:throw, :ops_branch_thrown}"}},
          {:error, {:invalid_parallel_result, ":not_a_module_result"}}
        ],
        results
      )

    check("parallel_failure_isolation", "supervised_concurrency", pass?, %{
      "max_concurrency" => max_concurrency,
      "results" => json_safe(results)
    })
  end

  defp check(id, category, passing?, evidence) do
    %{
      "id" => id,
      "category" => category,
      "passing" => passing?,
      "evidence" => evidence
    }
  end

  defp summary(checks) do
    categories = checks |> Enum.map(& &1["category"]) |> Enum.uniq() |> Enum.sort()

    %{
      "total" => length(checks),
      "passing" => Enum.count(checks, & &1["passing"]),
      "failed" => Enum.count(checks, &(not &1["passing"])),
      "categories" => categories,
      "complete" => Enum.all?(checks, & &1["passing"])
    }
  end

  defp attach_events(events) do
    ref = make_ref()
    parent = self()

    :telemetry.attach_many(
      "dsex-ops-stress-#{System.unique_integer([:positive])}",
      events,
      &__MODULE__.handle_telemetry/4,
      {parent, ref}
    )

    ref
  end

  def handle_telemetry(event, measurements, metadata, {parent, ref}) do
    send(parent, {ref, event, measurements, metadata})
  end

  defp detach_events(ref) do
    :telemetry.list_handlers([])
    |> Enum.filter(&String.starts_with?(&1.id, "dsex-ops-stress-"))
    |> Enum.each(&:telemetry.detach(&1.id))

    flush_events(ref)
    :ok
  end

  defp flush_events(ref), do: flush_events(ref, [])

  defp flush_events(ref, acc) do
    receive do
      {^ref, event, measurements, metadata} ->
        flush_events(ref, [
          %{
            "event" => Enum.map(event, &to_string/1),
            "measurements" => json_safe(measurements),
            "metadata" => json_safe(metadata)
          }
          | acc
        ])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp json_safe(%DSEx.Prediction{} = prediction),
    do: prediction |> DSEx.Prediction.to_map() |> json_safe()

  defp json_safe(%{} = map),
    do: Map.new(map, fn {key, value} -> {to_string(key), json_safe(value)} end)

  defp json_safe(list) when is_list(list), do: Enum.map(list, &json_safe/1)
  defp json_safe(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> json_safe()
  defp json_safe(value) when is_atom(value), do: to_string(value)
  defp json_safe(value), do: value
end
