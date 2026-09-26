defmodule Imp.BenchmarkTruth.Search do
  @moduledoc false

  alias Imp.Predict.Search
  alias Imp.Predict.Search.Candidate

  @candidate_specs [
    {"answer-1", %{text: "four", parsed: "4", quality: 0.5}},
    {"answer-2", %{text: "four!", parsed: "4", quality: 0.8}},
    {"answer-3", %{text: "5", parsed: "5", quality: 0.0}},
    {"answer-4", %{text: "the answer is four", parsed: "4", quality: 1.0}}
  ]

  def run(opts \\ []) do
    iterations = positive_integer!(opts, :iterations, 10)
    max_concurrency = positive_integer!(opts, :max_concurrency, 2)
    work_ms = non_negative_integer!(opts, :work_ms, 10)

    sequential = measure(:sequential, iterations, 1, work_ms)
    concurrent = measure(:concurrent, iterations, max_concurrency, work_ms)
    checks = checks(sequential, concurrent, max_concurrency)

    %{
      "schema_version" => 1,
      "runner" => "imp-search-source-checkout",
      "evidence_tier" => "provider_free_source_checkout",
      "claim_scope" =>
        "request-local search semantics, projected budget accounting, and bounded concurrency",
      "generated_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "source_checkout" => source_checkout(),
      "runtime" => %{
        "elixir" => System.version(),
        "otp" => System.otp_release(),
        "schedulers_online" => System.schedulers_online()
      },
      "configuration" => %{
        "candidate_count" => length(@candidate_specs),
        "iterations" => iterations,
        "work_ms_per_candidate" => work_ms,
        "bounded_concurrency" => max_concurrency,
        "provider_calls" => 0
      },
      "sequential" => sequential,
      "bounded_concurrent" => concurrent,
      "latency_comparison" => latency_comparison(sequential, concurrent),
      "checks" => checks,
      "summary" => %{
        "complete" => Enum.all?(checks, & &1["passing"]),
        "passing" => Enum.count(checks, & &1["passing"]),
        "total" => length(checks),
        "latency_is_release_assertion" => false,
        "provider_quality_claimed" => false,
        "actual_provider_cost_available" => false
      }
    }
  end

  defp measure(mode, iterations, max_concurrency, work_ms) do
    {:ok, tracker} = Agent.start_link(fn -> %{active: 0, peak: 0} end)

    samples =
      Enum.map(1..iterations, fn _iteration ->
        :timer.tc(fn -> run_once(mode, max_concurrency, work_ms, tracker) end)
      end)

    {latencies_us, results} = Enum.unzip(samples)
    result = List.last(results)
    peak = Agent.get(tracker, & &1.peak)
    Agent.stop(tracker)

    %{
      "mode" => Atom.to_string(mode),
      "answer" => result.best.value.text,
      "candidate_id" => result.best.candidate_id,
      "quality" => result.best.score,
      "stop_reason" => inspect(result.stop_reason),
      "candidate_order" => Enum.map(result.outcomes, & &1.candidate_id),
      "statuses" => Enum.map(result.provenance, &Atom.to_string(&1.status)),
      "cost" => %{
        "projected_admitted" => stringify_keys(result.admitted_budget),
        "observed_executed_projection" => stringify_keys(result.observed_budget),
        "actual_provider" => %{
          "available" => false,
          "amount" => nil,
          "reason" => "provider-free fixture; no billed usage is observed"
        }
      },
      "concurrency" => %{
        "configured_max" => max_concurrency,
        "observed_peak" => peak,
        "bound_respected" => peak <= max_concurrency
      },
      "latency_us" => latency_summary(latencies_us)
    }
  end

  defp run_once(mode, max_concurrency, work_ms, tracker) do
    Search.run(
      candidates(),
      fn candidate, _context ->
        Agent.update(tracker, fn state ->
          active = state.active + 1
          %{active: active, peak: max(state.peak, active)}
        end)

        try do
          Process.sleep(work_ms)
          {:ok, candidate.value, candidate.value.quality}
        after
          Agent.update(tracker, &%{&1 | active: &1.active - 1})
        end
      end,
      mode: mode,
      num_threads: max_concurrency,
      tie_policy: :first
    )
  end

  defp candidates do
    Enum.map(@candidate_specs, fn {id, value} ->
      Candidate.new(id, value, %{attempts: 1, cost_units: 1})
    end)
  end

  defp checks(sequential, concurrent, max_concurrency) do
    expected_ids = Enum.map(@candidate_specs, &elem(&1, 0))
    expected_budget = %{"attempts" => 4, "cost_units" => 4}

    [
      check("same_selected_answer", sequential["answer"] == concurrent["answer"]),
      check(
        "same_selected_candidate",
        sequential["candidate_id"] == "answer-4" and
          concurrent["candidate_id"] == sequential["candidate_id"]
      ),
      check("same_quality", sequential["quality"] == concurrent["quality"]),
      check("deterministic_candidate_order", sequential["candidate_order"] == expected_ids),
      check("concurrent_candidate_order", concurrent["candidate_order"] == expected_ids),
      check("sequential_statuses", sequential["statuses"] == List.duplicate("ok", 4)),
      check("concurrent_statuses", concurrent["statuses"] == List.duplicate("ok", 4)),
      check("sequential_projected_budget", projected_budget(sequential) == expected_budget),
      check("concurrent_projected_budget", projected_budget(concurrent) == expected_budget),
      check("sequential_observed_projection", observed_projection(sequential) == expected_budget),
      check("concurrent_observed_projection", observed_projection(concurrent) == expected_budget),
      check("sequential_peak_bounded", get_in(sequential, ["concurrency", "observed_peak"]) <= 1),
      check(
        "concurrent_peak_bounded",
        get_in(concurrent, ["concurrency", "observed_peak"]) <= max_concurrency
      )
    ]
  end

  defp projected_budget(report), do: get_in(report, ["cost", "projected_admitted"])
  defp observed_projection(report), do: get_in(report, ["cost", "observed_executed_projection"])
  defp check(id, passing), do: %{"id" => id, "passing" => passing}

  defp latency_summary(samples) do
    sorted = Enum.sort(samples)

    %{
      "samples" => length(sorted),
      "median" => percentile(sorted, 0.5),
      "p95" => percentile(sorted, 0.95),
      "min" => List.first(sorted),
      "max" => List.last(sorted)
    }
  end

  defp latency_comparison(sequential, concurrent) do
    sequential_median = get_in(sequential, ["latency_us", "median"])
    concurrent_median = get_in(concurrent, ["latency_us", "median"])

    %{
      "sequential_median_us" => sequential_median,
      "bounded_concurrent_median_us" => concurrent_median,
      "observed_ratio_sequential_over_concurrent" => ratio(sequential_median, concurrent_median),
      "measurement_only" => true,
      "speedup_required" => false
    }
  end

  defp ratio(_numerator, 0), do: nil
  defp ratio(numerator, denominator), do: Float.round(numerator / denominator, 3)

  defp percentile(sorted, quantile) do
    index = sorted |> length() |> Kernel.-(1) |> Kernel.*(quantile) |> round()
    Enum.at(sorted, index)
  end

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp source_checkout do
    %{
      "git_sha" => git_output(["rev-parse", "HEAD"]),
      "dirty" => git_output(["status", "--short"]) != ""
    }
  end

  defp git_output(args) do
    case System.cmd("git", args, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {_output, _status} -> "unavailable"
    end
  end

  defp positive_integer!(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      value -> raise ArgumentError, "#{key} must be a positive integer, got: #{inspect(value)}"
    end
  end

  defp non_negative_integer!(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value >= 0 ->
        value

      value ->
        raise ArgumentError, "#{key} must be a non-negative integer, got: #{inspect(value)}"
    end
  end
end
