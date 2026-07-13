Mix.Task.run("app.start")

defmodule DSEx.Benchmarks.GEPAComBee do
  alias DSEx.Optimizer.GEPA.ComBee

  @dataset "benchmarks/data/gsm8k-test-0-1319.jsonl"
  @model "openai:gpt-4.1-mini-2025-04-14"
  @seed 17
  @row_count 8
  @small_batch_size 2
  @max_output_tokens 512

  def run do
    mode = mode!()
    records = load_records!()
    source = Map.new(records, &{&1["id"], &1["canonical_answer"]})
    lm = if mode == :live, do: live_lm!()

    arms = [
      {:small_batch_gepa, &small_batch/2},
      {:naive_large_batch, &naive/2},
      {:combee, &combee/2}
    ]

    results =
      Map.new(arms, fn {name, strategy} ->
        {name, run_arm(name, strategy, records, source, mode, lm)}
      end)

    output = %{
      schema_version: 2,
      campaign: "combee-matched-natural-data-preflight",
      claim_scope: "bounded preflight; not a paper replication",
      mode: mode,
      dataset: %{
        source: @dataset,
        source_task: "gsm8k",
        row_ids: Enum.map(records, & &1["id"]),
        rows: length(records)
      },
      matching: %{
        seed: @seed,
        model: if(mode == :live, do: @model, else: "deterministic-fixture-v2"),
        max_output_tokens: @max_output_tokens,
        small_batch_size: @small_batch_size,
        large_batch_size: length(records),
        same_rows: true,
        same_reducer_contract: true,
        arm_order: Enum.map(arms, &elem(&1, 0))
      },
      results: results
    }

    path = output_path(mode)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(output, pretty: true) <> "\n")
    IO.puts(Jason.encode!(Map.put(output, :artifact_path, path), pretty: true))
  end

  def handle_usage(_event, measurements, _metadata, agent) do
    tokens = Map.get(measurements, :tokens, %{})

    delta = %{
      input_tokens: number(tokens, [:input_tokens, :input]),
      output_tokens: number(tokens, [:output_tokens, :output]),
      cost_usd: number(measurements, [:total_cost, :cost])
    }

    Agent.update(agent, fn usage ->
      Map.new(usage, fn {key, value} -> {key, value + delta[key]} end)
    end)
  end

  defp run_arm(name, strategy, records, source, mode, lm) do
    {:ok, calls_agent} = Agent.start_link(fn -> 0 end)

    {:ok, usage_agent} =
      Agent.start_link(fn -> %{input_tokens: 0, output_tokens: 0, cost_usd: 0.0} end)

    handler = {__MODULE__, name, make_ref()}

    if mode == :live do
      :ok =
        :telemetry.attach(
          handler,
          [:req_llm, :token_usage],
          &__MODULE__.handle_usage/4,
          usage_agent
        )
    end

    reducer = reducer(mode, lm, calls_agent, usage_agent)
    started = System.monotonic_time(:microsecond)

    result =
      try do
        strategy.(reducer, records)
      after
        if mode == :live, do: :telemetry.detach(handler)
      end

    wall_ms = (System.monotonic_time(:microsecond) - started) / 1_000
    call_count = Agent.get(calls_agent, & &1)
    usage = Agent.get(usage_agent, & &1)
    Agent.stop(calls_agent)
    Agent.stop(usage_agent)

    retained = result |> decode_entries!() |> Enum.uniq_by(& &1["id"])
    retained_source = Enum.filter(retained, &Map.has_key?(source, &1["id"]))
    retained_ids = Enum.map(retained_source, & &1["id"])

    correct =
      Enum.count(retained_source, fn entry ->
        Map.get(source, entry["id"]) == to_string(entry["canonical_answer"])
      end)

    if mode == :live and
         (usage.input_tokens <= 0 or usage.output_tokens <= 0 or usage.cost_usd <= 0) do
      raise "live ComBee preflight requires positive provider usage and cost telemetry"
    end

    %{
      status: :ok,
      quality: correct / map_size(source),
      retained_correct: correct,
      retained_unique: length(retained_ids),
      retention: length(retained_ids) / map_size(source),
      latency_ms: wall_ms,
      provider_calls: call_count,
      input_tokens: trunc(usage.input_tokens),
      output_tokens: trunc(usage.output_tokens),
      cost_usd: usage.cost_usd,
      accounting_source: if(mode == :live, do: :req_llm_telemetry, else: :fixture_estimate),
      retained_ids: retained_ids
    }
  end

  defp small_batch(reducer, records) do
    records
    |> Enum.chunk_every(@small_batch_size)
    |> Enum.reduce([], fn batch, accumulated ->
      reducer.(
        %{main: Jason.encode!(accumulated)},
        :main,
        batch,
        1,
        %{aggregation: :naive, phase: :small_batch}
      )
      |> decode_entries!()
    end)
    |> Jason.encode!()
  end

  defp naive(reducer, records) do
    reducer.(%{main: "[]"}, :main, records, 1, %{aggregation: :naive, phase: :single})
  end

  defp combee(reducer, records) do
    policy =
      [duplication_factor: 2, max_concurrency: 2]
      |> ComBee.resolve(length(records), length(records), @seed)
      |> ComBee.resolve_concurrency(2, 1)
      |> ComBee.bound_timeout(60_000)

    case ComBee.aggregate(reducer, %{main: "[]"}, :main, records, 1, policy) do
      {:ok, update, _report} -> update
      {:error, reason, report} -> raise "ComBee arm failed: #{inspect({reason, report})}"
    end
  end

  defp reducer(mode, lm, calls, usage) do
    fn candidate, _component, records, _iteration, metadata ->
      Agent.update(calls, &(&1 + 1))
      prompt = prompt(candidate, records, metadata)

      case mode do
        :fixture ->
          output = fixture_reduce(candidate, records, metadata)
          estimate_fixture_usage(usage, prompt, output)
          output

        :live ->
          case DSEx.LM.generate(lm, [%{role: "user", content: prompt}],
                 max_tokens: @max_output_tokens,
                 temperature: 0
               ) do
            {:ok, %{__dsex_lm_output__: output}} when is_binary(output) -> output
            {:ok, output} when is_binary(output) -> output
            {:error, reason} -> raise "provider reducer failed: #{inspect(reason)}"
            other -> raise "invalid provider reducer response: #{inspect(other)}"
          end
      end
    end
  end

  defp prompt(candidate, records, metadata) do
    existing = if metadata.phase == :small_batch, do: candidate.main, else: "[]"

    inputs =
      Enum.map(records, fn record ->
        case record do
          %{"ComBeeIntermediateUpdate" => update} ->
            %{"intermediate" => decode_entries!(update)}

          record ->
            Map.take(record, ["id", "question", "canonical_answer"])
        end
      end)

    """
    Merge the records into a JSON array. Return JSON only, with no markdown.
    Preserve every unique fact you can. Each output object must contain exactly
    {"id": string, "canonical_answer": string}. Never invent or alter answers.

    Existing accumulator:
    #{existing}

    New records:
    #{Jason.encode!(inputs)}
    """
  end

  defp fixture_reduce(candidate, records, metadata) do
    existing = if metadata.phase == :small_batch, do: decode_entries!(candidate.main), else: []

    incoming =
      Enum.flat_map(records, fn
        %{"ComBeeIntermediateUpdate" => update} -> decode_entries!(update)
        record -> [Map.take(record, ["id", "canonical_answer"])]
      end)

    capacity = if metadata.phase in [:final, :small_batch], do: @row_count, else: 4

    (existing ++ incoming)
    |> Enum.uniq_by(& &1["id"])
    |> Enum.take(capacity)
    |> Jason.encode!()
  end

  defp estimate_fixture_usage(agent, prompt, output) do
    Agent.update(agent, fn usage ->
      %{
        usage
        | input_tokens: usage.input_tokens + div(byte_size(prompt) + 3, 4),
          output_tokens: usage.output_tokens + div(byte_size(output) + 3, 4)
      }
    end)
  end

  defp decode_entries!(text) when is_binary(text) do
    text
    |> String.trim()
    |> String.replace_prefix("```json", "")
    |> String.replace_prefix("```", "")
    |> String.replace_suffix("```", "")
    |> String.trim()
    |> Jason.decode!()
    |> normalize_entries!()
  end

  defp normalize_entries!(entries) when is_list(entries) do
    Enum.map(entries, fn entry ->
      %{
        "id" => entry |> Map.fetch!("id") |> to_string(),
        "canonical_answer" => entry |> Map.fetch!("canonical_answer") |> to_string()
      }
    end)
  end

  defp normalize_entries!(other), do: raise("expected reducer JSON array, got: #{inspect(other)}")

  defp load_records! do
    @dataset
    |> File.stream!()
    |> Stream.map(&Jason.decode!/1)
    |> Stream.take(@row_count)
    |> Stream.with_index()
    |> Enum.map(fn {row, index} ->
      %{
        "id" => "gsm8k-#{index}",
        "question" => Map.fetch!(row, "question"),
        "canonical_answer" => row |> Map.fetch!("canonical_answer") |> to_string()
      }
    end)
  end

  defp live_lm! do
    unless System.get_env("COMBEE_LIVE_PROVIDER") == "1" do
      raise "live mode requires COMBEE_LIVE_PROVIDER=1 after fixture validation"
    end

    key = System.get_env("OPENAI_API_KEY")

    unless is_binary(key) and byte_size(key) > 20 do
      raise "live mode requires OPENAI_API_KEY"
    end

    DSEx.req_llm(@model, api_key: key, temperature: 0, max_completion_tokens: @max_output_tokens)
  end

  defp mode! do
    case System.get_env("COMBEE_PREFLIGHT_MODE", "fixture") do
      "fixture" -> :fixture
      "live" -> :live
      other -> raise "COMBEE_PREFLIGHT_MODE must be fixture or live, got: #{inspect(other)}"
    end
  end

  defp output_path(mode),
    do: "benchmarks/results/gepa-combee-preflight-#{mode}-#{timestamp()}.json"

  defp timestamp, do: DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")

  defp number(map, keys) do
    Enum.find_value(keys, 0, fn key ->
      value = Map.get(map, key, Map.get(map, Atom.to_string(key)))
      if is_number(value), do: value
    end)
  end
end

DSEx.Benchmarks.GEPAComBee.run()
