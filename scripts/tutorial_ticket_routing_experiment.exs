# Reproduces docs/TUTORIAL_TICKET_ROUTING.md end to end against the live
# provider and writes a provenance-stamped, content-addressed run artifact to
# benchmarks/runs/tutorial-ticket-routing/<sha256>.json.
#
#     OPENAI_API_KEY=... mix run scripts/tutorial_ticket_routing_experiment.exs
#     OPENROUTER_API_KEY=... OPENROUTER_MODEL=openai/gpt-5.4-mini \
#       mix run scripts/tutorial_ticket_routing_experiment.exs
#
# The experiment is exactly the tutorial's: a zero-shot enum router evaluated
# on the twenty held-out test tickets, then the same router compiled with
# LabeledFewShot(k: 8) on the twenty train tickets and evaluated on the same
# held-out twenty. It repeats the full experiment (default three times) so the
# artifact records honest run-to-run ranges rather than one lucky draw. The
# in-BEAM response cache is cleared before every repeat and per-repeat cache
# stats are recorded, so each repeat is genuinely live: zero cache hits is
# asserted by the artifact test, not assumed.

defmodule TutorialTicketRoutingExperiment do
  @dataset_relative "priv/tutorial/support_tickets.json"
  @out_dir "benchmarks/runs/tutorial-ticket-routing"
  @schema_version 2
  @input_per_million 0.75
  @output_per_million 4.50
  @max_output_tokens 256

  def main do
    repeats = "TUTORIAL_REPEATS" |> System.get_env("3") |> String.to_integer()
    {model, api_key} = live_provider!()

    {:ok, budget} =
      Imp.start_optimizer_budget(
        limits: %{
          requests: repeats * 80,
          input_tokens: repeats * 500_000,
          output_tokens: repeats * 20_480,
          usd: repeats * 1.00
        },
        pricing: %{
          "input_per_million" => @input_per_million,
          "output_per_million" => @output_per_million,
          "source_url" => "https://openai.com/api/pricing/"
        },
        default_max_output_tokens: @max_output_tokens
      )

    dataset_path = Application.app_dir(:imp, @dataset_relative)
    dataset_bytes = File.read!(dataset_path)
    data = Jason.decode!(dataset_bytes)

    trainset = to_examples(data["train"])
    testset = to_examples(data["test"])

    lm =
      model
      |> Imp.req_llm(api_key: api_key)
      |> Imp.budgeted_lm(budget, max_output_tokens: @max_output_tokens)

    router = router(lm)

    metric = Imp.exact_match(:team)
    optimizer = Imp.Optimizer.LabeledFewShot.new(k: 8, sample: false)

    runs =
      for run_index <- 1..repeats do
        IO.puts("== run #{run_index}/#{repeats}")

        # Every repeat must hit the live provider. Clearing the in-BEAM cache
        # and recording the per-repeat cache stats makes that checkable in the
        # committed artifact instead of an unverified claim.
        Imp.Cache.clear()
        Imp.Cache.reset_stats()

        started_at = DateTime.utc_now() |> DateTime.truncate(:second)
        t0 = System.monotonic_time(:millisecond)

        baseline = Imp.evaluate(router, testset, metric, max_concurrency: 8, timeout: 60_000)
        compiled = Imp.optimize!(router, optimizer, trainset)
        optimized = Imp.evaluate(compiled, testset, metric, max_concurrency: 8, timeout: 60_000)

        duration_ms = System.monotonic_time(:millisecond) - t0
        cache_stats = Imp.Cache.stats()

        run = %{
          "run" => run_index,
          "started_at" => DateTime.to_iso8601(started_at),
          "duration_ms" => duration_ms,
          "baseline_score" => baseline.score,
          "optimized_score" => optimized.score,
          "absolute_lift" => Float.round(optimized.score - baseline.score, 6),
          "heldout_examples" => length(testset),
          "baseline_errors" => length(baseline.errors),
          "optimized_errors" => length(optimized.errors),
          "cache" => %{
            "cleared_before_run" => true,
            "hits" => Map.get(cache_stats, :hits, 0),
            "misses" => Map.get(cache_stats, :misses, 0),
            "bypasses" => Map.get(cache_stats, :bypasses, 0)
          },
          "usage" => merge_usage([usage_from_result(baseline), usage_from_result(optimized)])
        }

        IO.puts(
          "   baseline #{baseline.score} -> optimized #{optimized.score} " <>
            "(#{duration_ms} ms, usage #{inspect(run["usage"])})"
        )

        run
      end

    baseline_scores = Enum.map(runs, & &1["baseline_score"])
    optimized_scores = Enum.map(runs, & &1["optimized_score"])
    total_usage = merge_usage(Enum.map(runs, & &1["usage"]))
    fresh_service = verify_fresh_service!(router, optimizer, trainset)

    artifact = %{
      "schema_version" => @schema_version,
      "runner" => "tutorial-ticket-routing-experiment",
      "generated_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "git_sha" => git_sha(),
      "script" => "scripts/tutorial_ticket_routing_experiment.exs",
      "tutorial" => "docs/TUTORIAL_TICKET_ROUTING.md",
      "model" => "openai:gpt-5.4-mini",
      "provider_route" => model,
      "dataset" => %{
        "path" => @dataset_relative,
        "sha256" => sha256(dataset_bytes),
        "train" => length(data["train"]),
        "dev" => length(data["dev"]),
        "test" => length(data["test"])
      },
      "configuration" => %{
        "signature" => "ticket -> team: enum[atlas,harbor,beacon,quill]",
        "adapter" => "Imp.Adapter.JSON",
        "json_retries" => 1,
        "optimizer" => "Imp.Optimizer.LabeledFewShot",
        "k" => 8,
        "metric" => "Imp.exact_match(:team)",
        "max_concurrency" => 8,
        "timeout_ms" => 60_000,
        "repeats" => repeats,
        "cache_cleared_per_repeat" => true,
        "trainset" => "train split only; dev split unused; test split held out"
      },
      "runs" => runs,
      "summary" => %{
        "repeats" => repeats,
        "baseline_score_min" => Enum.min(baseline_scores),
        "baseline_score_max" => Enum.max(baseline_scores),
        "optimized_score_min" => Enum.min(optimized_scores),
        "optimized_score_max" => Enum.max(optimized_scores),
        "min_absolute_lift" => runs |> Enum.map(& &1["absolute_lift"]) |> Enum.min(),
        "all_runs_improved" => Enum.all?(runs, &(&1["optimized_score"] > &1["baseline_score"])),
        "duration_ms_min" => runs |> Enum.map(& &1["duration_ms"]) |> Enum.min(),
        "duration_ms_max" => runs |> Enum.map(& &1["duration_ms"]) |> Enum.max(),
        "total_usage" => total_usage,
        "optimizer_budget" => Imp.Optimizer.Budget.snapshot(budget)
      },
      "fresh_service" => fresh_service,
      "doc_claims_under_test" => %{
        "source" => "docs/TUTORIAL_TICKET_ROUTING.md",
        "baseline_repeat_range" => [0.30, 0.50],
        "optimized_repeat_range" => [0.95, 1.0],
        "cost_usd_per_repeat_approx" => 0.013,
        "duration_seconds_range" => [8, 9]
      },
      "scope" => %{
        "claimed" =>
          "LabeledFewShot(k: 8) held-out lift on the shipped sixty-ticket routing task with #{model} across #{repeats} live repeats",
        "not_claimed" => [
          "generalization beyond the shipped support-ticket dataset",
          "search-optimizer (RandomSearch/MIPROv2) effectiveness",
          "DSPy-matched comparison"
        ]
      }
    }

    out_dir = System.get_env("TUTORIAL_OUTPUT_DIR", @out_dir)
    File.mkdir_p!(out_dir)
    bytes = Jason.encode!(artifact, pretty: true) <> "\n"
    path = Path.join(out_dir, sha256(bytes) <> ".json")
    File.write!(path, bytes)
    IO.puts("artifact: #{path}")
  end

  def fresh_main(artifact_path) do
    {model, api_key} = live_provider!()

    {:ok, budget} =
      Imp.start_optimizer_budget(
        limits: %{requests: 4, input_tokens: 50_000, output_tokens: 1_024, usd: 0.10},
        pricing: %{
          "input_per_million" => @input_per_million,
          "output_per_million" => @output_per_million,
          "source_url" => "https://openai.com/api/pricing/"
        },
        default_max_output_tokens: @max_output_tokens
      )

    lm =
      model
      |> Imp.req_llm(api_key: api_key)
      |> Imp.budgeted_lm(budget, max_output_tokens: @max_output_tokens)

    selected =
      artifact_path
      |> Imp.Optimizer.Artifact.read!()
      |> Imp.Optimizer.Artifact.apply(router(lm))

    probes = [
      {"Please refund the duplicate annual invoice charge.", "atlas"},
      {"The API is returning 502 errors for every customer.", "harbor"},
      {"A former employee can still sign in to our workspace.", "beacon"},
      {"Could you add dark mode to the dashboard?", "quill"}
    ]

    {:ok, supervisor} = Task.Supervisor.start_link()

    results =
      probes
      |> Enum.map(fn {ticket, expected} ->
        Task.Supervisor.async_nolink(supervisor, fn ->
          case Imp.call(selected, %{ticket: ticket}) do
            {:ok, prediction} -> %{expected: expected, actual: Imp.get(prediction, :team)}
            {:error, reason} -> raise "fresh service call failed: #{inspect(reason)}"
          end
        end)
      end)
      |> Enum.map(&Task.await(&1, 60_000))

    Supervisor.stop(supervisor)
    true = Enum.all?(results, &(&1.actual == &1.expected))

    IO.puts(
      "TUTORIAL_FRESH_RESULT=" <>
        Jason.encode!(%{
          "fresh_os_process" => true,
          "concurrency" => 4,
          "correct" => 4,
          "total" => 4,
          "artifact_sha256" => artifact_path |> File.read!() |> sha256(),
          "budget" => Imp.Optimizer.Budget.snapshot(budget)
        })
    )
  end

  defp verify_fresh_service!(router, optimizer, trainset) do
    compiled = Imp.optimize!(router, optimizer, trainset)

    artifact =
      Imp.Optimizer.Artifact.from_optimized_program(compiled, artifact_id: "ticket-router")

    artifact_path =
      Path.join(
        System.tmp_dir!(),
        "imp-ticket-router-#{System.unique_integer([:positive])}.json"
      )

    :ok = Imp.Optimizer.Artifact.write!(artifact, artifact_path)

    try do
      {output, 0} =
        System.cmd("mix", ["run", "--no-compile", "--no-deps-check", __ENV__.file],
          env: [{"TUTORIAL_FRESH_ARTIFACT", artifact_path}],
          stderr_to_stdout: true
        )

      output
      |> String.split("\n", trim: true)
      |> Enum.find_value(fn
        "TUTORIAL_FRESH_RESULT=" <> encoded -> Jason.decode!(encoded)
        _line -> nil
      end)
      |> case do
        nil -> raise "fresh service process returned no result: #{output}"
        result -> result
      end
    after
      File.rm(artifact_path)
    end
  end

  defp router(lm) do
    "ticket -> team: enum[atlas,harbor,beacon,quill]"
    |> Imp.signature(
      "Assign the support ticket to the squad that owns it: atlas, harbor, beacon, or quill."
    )
    |> Imp.predict(lm: lm, adapter: Imp.Adapter.JSON, config: [json_retries: 1])
  end

  defp live_provider! do
    cond do
      present?(System.get_env("OPENAI_API_KEY")) ->
        {"openai:gpt-5.4-mini", System.fetch_env!("OPENAI_API_KEY")}

      present?(System.get_env("OPENROUTER_API_KEY")) ->
        {"openrouter:openai/gpt-5.4-mini", System.fetch_env!("OPENROUTER_API_KEY")}

      true ->
        raise "OPENAI_API_KEY or OPENROUTER_API_KEY is required"
    end
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp to_examples(rows) do
    for %{"ticket" => ticket, "team" => team} <- rows do
      Imp.example(ticket: ticket, team: team) |> Imp.with_inputs(:ticket)
    end
  end

  # Sums the usage maps found in the prediction metadata of successful rows.
  # Usage lives in provider response metadata; the deep scan keeps this robust
  # to metadata layout while never inventing numbers: missing usage stays 0
  # and is reported via "requests_with_usage". The same usage map can appear at
  # several nesting levels of one prediction's metadata, so the scan is
  # deduplicated per prediction; token totals remain approximate provenance,
  # not a cost claim.
  defp usage_from_result(result) do
    usages =
      result.rows
      |> Enum.flat_map(fn row -> row[:prediction] |> collect_usage_maps() |> Enum.uniq() end)

    merge_usage([
      %{
        "requests_with_usage" => length(usages),
        "input_tokens" => sum_field(usages, [:input_tokens, "input_tokens"]),
        "output_tokens" => sum_field(usages, [:output_tokens, "output_tokens"]),
        "total_tokens" => sum_field(usages, [:total_tokens, "total_tokens"])
      }
    ])
  end

  defp collect_usage_maps(nil), do: []

  defp collect_usage_maps(%_struct{} = struct),
    do: struct |> Map.from_struct() |> collect_usage_maps()

  defp collect_usage_maps(map) when is_map(map) do
    own =
      if usage_map?(map) do
        [map]
      else
        []
      end

    own ++ Enum.flat_map(Map.values(map), &collect_usage_maps/1)
  end

  defp collect_usage_maps(list) when is_list(list),
    do: Enum.flat_map(list, &collect_usage_maps/1)

  defp collect_usage_maps(_other), do: []

  defp usage_map?(map) do
    Enum.any?([:input_tokens, "input_tokens"], &Map.has_key?(map, &1)) and
      Enum.any?([:output_tokens, "output_tokens"], &Map.has_key?(map, &1))
  end

  defp sum_field(maps, keys) do
    maps
    |> Enum.map(fn map ->
      keys
      |> Enum.find_value(0, fn key ->
        case Map.get(map, key) do
          value when is_number(value) -> value
          _other -> nil
        end
      end)
    end)
    |> Enum.sum()
  end

  defp merge_usage(usages) do
    usages = Enum.reject(usages, &is_nil/1)

    %{
      "requests_with_usage" => sum_field(usages, ["requests_with_usage"]),
      "input_tokens" => sum_field(usages, ["input_tokens"]),
      "output_tokens" => sum_field(usages, ["output_tokens"]),
      "total_tokens" => sum_field(usages, ["total_tokens"])
    }
  end

  defp git_sha do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _other -> nil
    end
  end

  defp sha256(bytes),
    do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end

case System.get_env("TUTORIAL_FRESH_ARTIFACT") do
  nil -> TutorialTicketRoutingExperiment.main()
  path -> TutorialTicketRoutingExperiment.fresh_main(path)
end
