# Campaign-20260718 cell: operate_roundtrip
#
# THE QUESTION: does the deploy-what-you-measured loop — compile, persist,
# reload, identical behavior, observable — actually close on a real task?
#
# Task: priv/tutorial/support_tickets.json, train-20 / test-20.
# Steps:
#   0. Fixed split recorded (indices + sha256 of data file) before any arm.
#   1. Compile LabeledFewShot k=8 on train-20; evaluate on test-20 live
#      (cache cleared first, per-repeat cache stats recorded). Record per-row
#      scores. [arm: presave]
#   a. Imp.save! the compiled program -> operate-artifact.json; Imp.load! it;
#      rebind live LM with Imp.with_lm; re-evaluate on the SAME test-20.
#      Scores must match the presave run exactly at temp 0. [arm: reload]
#      (Reload eval runs with cache WARM: cache hits prove the reloaded
#       program issues byte-identical requests, isolating roundtrip fidelity
#       from LM nondeterminism. A cross-check eval with cache CLEARED is also
#       run to confirm the reloaded program is genuinely live and still scores
#       identically.) [arm: reload_live]
#   b. grep the artifact file for api-key material (must find none).
#   c. Imp.stream/3 one live call through the LOADED program with
#      provider_stream: true; record incremental chunk count.
#   d. Imp.trace/2 around one call through the loaded program; record which
#      telemetry events fired.

defmodule OperateRoundtrip do
  @model "openai:gpt-5.4-mini"
  @dataset_relative "priv/tutorial/support_tickets.json"
  @out_dir "benchmarks/runs/campaign-20260718"
  @artifact_path "benchmarks/runs/campaign-20260718/operate-artifact.json"
  @result_path "benchmarks/runs/campaign-20260718/operate_roundtrip-result.json"
  @k 8

  def main do
    api_key = System.fetch_env!("OPENAI_API_KEY")

    dataset_path = Application.app_dir(:imp, @dataset_relative)
    dataset_bytes = File.read!(dataset_path)
    data = Jason.decode!(dataset_bytes)
    data_sha = sha256(dataset_bytes)

    train_rows = data["train"]
    test_rows = data["test"]
    train_indices = Enum.to_list(0..(length(train_rows) - 1))
    test_indices = Enum.to_list(0..(length(test_rows) - 1))

    trainset = to_examples(train_rows)
    testset = to_examples(test_rows)

    lm = Imp.req_llm(@model, api_key: api_key, temperature: 0)

    sig =
      "ticket -> team: enum[atlas,harbor,beacon,quill]"
      |> Imp.signature(
        "Assign the support ticket to the squad that owns it: atlas, harbor, beacon, or quill."
      )

    metric = Imp.exact_match(:team)
    optimizer = Imp.Optimizer.LabeledFewShot.new(k: @k)

    # ---- Arm A: EXACTLY the shipped tutorial config (json_retries: 1) -----
    # Tests the roundtrip a user following docs/TUTORIAL_TICKET_ROUTING.md /
    # scripts/tutorial_ticket_routing_experiment.exs would actually attempt.
    router_a =
      Imp.predict(sig, lm: lm, adapter: Imp.Adapter.JSON, config: [json_retries: 1])

    Imp.Cache.clear()
    Imp.Cache.reset_stats()
    compiled_a = Imp.optimize(router_a, optimizer, trainset)
    :ok = Imp.save!(compiled_a, @artifact_path <> ".arm_a")

    arm_a_roundtrip =
      try do
        loaded = Imp.load!(@artifact_path <> ".arm_a")
        _ = Imp.with_lm(loaded, lm)
        %{"save_ok" => true, "load_ok" => true, "error" => nil}
      rescue
        e ->
          %{
            "save_ok" => true,
            "load_ok" => false,
            "error" => Exception.message(e),
            "error_type" => inspect(e.__struct__)
          }
      end

    IO.puts("ARM A (json_retries:1) roundtrip: #{inspect(arm_a_roundtrip)}")

    # ---- Arm B: roundtrip-safe config (control) --------------------------
    # Same signature, adapter, optimizer, held-out set — no json_retries.
    # This is the program that completes the full deploy loop.
    router =
      Imp.predict(sig, lm: lm, adapter: Imp.Adapter.JSON)

    # ---- Step 1: compile + presave eval (live) ---------------------------
    Imp.Cache.clear()
    Imp.Cache.reset_stats()
    t0 = System.monotonic_time(:millisecond)
    compiled = Imp.optimize(router, optimizer, trainset)
    presave = Imp.evaluate(compiled, testset, metric, max_concurrency: 8, timeout: 60_000)
    presave_ms = System.monotonic_time(:millisecond) - t0
    presave_cache = Imp.Cache.stats()
    presave_scores = row_scores(presave)
    IO.puts("presave score=#{presave.score} cache=#{inspect(presave_cache)} (#{presave_ms}ms)")

    # ---- Step a: save! -> load! -> with_lm -> re-evaluate ----------------
    :ok = Imp.save!(compiled, @artifact_path)
    loaded_raw = Imp.load!(@artifact_path)
    loaded = Imp.with_lm(loaded_raw, lm)

    # reload eval, cache WARM: identical requests => cache hits => exact match
    Imp.Cache.reset_stats()
    t1 = System.monotonic_time(:millisecond)
    reload = Imp.evaluate(loaded, testset, metric, max_concurrency: 8, timeout: 60_000)
    reload_ms = System.monotonic_time(:millisecond) - t1
    reload_cache = Imp.Cache.stats()
    reload_scores = row_scores(reload)
    IO.puts("reload(warm) score=#{reload.score} cache=#{inspect(reload_cache)} (#{reload_ms}ms)")

    # reload eval, cache CLEARED: prove the reloaded program is genuinely live
    Imp.Cache.clear()
    Imp.Cache.reset_stats()
    t2 = System.monotonic_time(:millisecond)
    reload_live = Imp.evaluate(loaded, testset, metric, max_concurrency: 8, timeout: 60_000)
    reload_live_ms = System.monotonic_time(:millisecond) - t2
    reload_live_cache = Imp.Cache.stats()
    reload_live_scores = row_scores(reload_live)

    IO.puts(
      "reload(live) score=#{reload_live.score} cache=#{inspect(reload_live_cache)} (#{reload_live_ms}ms)"
    )

    scores_match_warm = presave_scores == reload_scores
    scores_match_live = presave_scores == reload_live_scores
    agg_match_warm = presave.score == reload.score
    agg_match_live = presave.score == reload_live.score

    # ---- Step b: artifact contains no api-key material -------------------
    artifact_bytes = File.read!(@artifact_path)
    key_tail = String.slice(api_key, -12, 12)

    key_hits =
      ["sk-", "OPENAI_API_KEY", key_tail]
      |> Enum.filter(fn needle -> needle != "" and String.contains?(artifact_bytes, needle) end)

    no_key_material = key_hits == []
    IO.puts("artifact no-key-material=#{no_key_material} (hits=#{inspect(key_hits)})")

    # ---- Step c: streaming one live call through the LOADED program ------
    # Clear cache so this is unambiguously a live provider stream, not a replay.
    Imp.Cache.clear()
    stream_ticket = List.first(test_rows)["ticket"]

    stream_chunks =
      loaded
      |> Imp.stream(%{ticket: stream_ticket}, provider_stream: true)
      |> Enum.to_list()

    stream_chunk_count = length(stream_chunks)

    stream_error =
      Enum.find_value(stream_chunks, fn
        %Imp.Streaming.Messages.StreamResponse{chunk: {:error, r}} -> inspect(r)
        _ -> nil
      end)

    stream_incremental = stream_chunk_count > 1 and is_nil(stream_error)

    stream_collected =
      loaded
      |> Imp.collect(%{ticket: stream_ticket}, provider_stream: true)

    stream_collected_str =
      case stream_collected do
        {:error, r} -> "ERROR: " <> inspect(r)
        s when is_binary(s) -> s
      end

    IO.puts(
      "stream chunks=#{stream_chunk_count} incremental=#{stream_incremental} err=#{inspect(stream_error)}"
    )

    # ---- Step d: trace one call through the loaded program ---------------
    # Clear cache so the traced call actually reaches the LM and fires
    # [:imp, :lm, :*] telemetry rather than replaying a cached prediction.
    Imp.Cache.clear()
    trace_ticket = List.last(test_rows)["ticket"]
    trace = Imp.trace(fn -> Imp.call(loaded, %{ticket: trace_ticket}) end)

    trace_event_names =
      trace.events
      |> Enum.map(fn {event, _measurements, _metadata} -> Enum.join(event, ".") end)

    trace_unique_events = trace_event_names |> Enum.uniq() |> Enum.sort()
    IO.puts("trace events=#{inspect(trace_unique_events)}")

    # ---- artifact --------------------------------------------------------
    result = %{
      "cell" => "operate_roundtrip",
      "generated_at" =>
        DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "git_sha" => git_sha(),
      "model" => @model,
      "temperature" => 0,
      "dataset" => %{
        "path" => @dataset_relative,
        "sha256" => data_sha,
        "train" => length(train_rows),
        "dev" => length(data["dev"]),
        "test" => length(test_rows)
      },
      "split" => %{
        "train_indices" => train_indices,
        "test_indices" => test_indices,
        "held_out_scored_once_per_arm" => true,
        "optimizer_saw" => "train split only (LabeledFewShot uses no dev)"
      },
      "optimizer" => %{"name" => "Imp.Optimizer.LabeledFewShot", "k" => @k},
      "arm_a_shipped_config" => Map.merge(arm_a_roundtrip, %{
        "config" => "[json_retries: 1] (exactly the shipped tutorial template)",
        "note" =>
          if arm_a_roundtrip["load_ok"] do
            "save! + load! + with_lm all succeed with the shipped json_retries:1 config; " <>
              "config keys survive the artifact boundary as atoms."
          else
            "save! succeeds but load! raises: config key json_retries did not survive " <>
              "the artifact boundary as a usable atom keyword. See error field."
          end
      }),
      "arms" => %{
        "presave" => %{
          "score" => presave.score,
          "row_scores" => presave_scores,
          "errors" => length(presave.errors),
          "wall_ms" => presave_ms,
          "cache" => cache_map(presave_cache)
        },
        "reload_warm" => %{
          "score" => reload.score,
          "row_scores" => reload_scores,
          "errors" => length(reload.errors),
          "wall_ms" => reload_ms,
          "cache" => cache_map(reload_cache),
          "note" => "cache warm; hits prove reloaded program issues identical requests"
        },
        "reload_live" => %{
          "score" => reload_live.score,
          "row_scores" => reload_live_scores,
          "errors" => length(reload_live.errors),
          "wall_ms" => reload_live_ms,
          "cache" => cache_map(reload_live_cache),
          "note" => "cache cleared; genuinely live re-eval of reloaded program"
        }
      },
      "roundtrip" => %{
        "row_scores_match_warm" => scores_match_warm,
        "row_scores_match_live" => scores_match_live,
        "aggregate_match_warm" => agg_match_warm,
        "aggregate_match_live" => agg_match_live
      },
      "no_key_material" => %{
        "clean" => no_key_material,
        "needles_checked" => ["sk-", "OPENAI_API_KEY", "<key_tail>"],
        "hits" => key_hits,
        "artifact_bytes" => byte_size(artifact_bytes)
      },
      "streaming" => %{
        "ticket" => stream_ticket,
        "chunk_count" => stream_chunk_count,
        "incremental" => stream_incremental,
        "error" => stream_error,
        "collected" => stream_collected_str
      },
      "trace" => %{
        "ticket" => trace_ticket,
        "event_count" => length(trace_event_names),
        "unique_events" => trace_unique_events,
        "result_ok" => match?({:ok, _}, trace.result)
      }
    }

    File.mkdir_p!(@out_dir)
    File.write!(@result_path, Jason.encode!(result, pretty: true) <> "\n")
    IO.puts("result: #{@result_path}")
    IO.puts("SUMMARY " <> Jason.encode!(Map.drop(result, ["split"])))
  end

  defp row_scores(result) do
    result.rows
    |> Enum.sort_by(& &1.index)
    |> Enum.map(& &1.score)
  end

  defp cache_map(stats) do
    %{
      "hits" => Map.get(stats, :hits, 0),
      "misses" => Map.get(stats, :misses, 0),
      "bypasses" => Map.get(stats, :bypasses, 0)
    }
  end

  defp to_examples(rows) do
    for %{"ticket" => ticket, "team" => team} <- rows do
      Imp.example(ticket: ticket, team: team) |> Imp.with_inputs(:ticket)
    end
  end

  defp git_sha do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> nil
    end
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end

OperateRoundtrip.main()
