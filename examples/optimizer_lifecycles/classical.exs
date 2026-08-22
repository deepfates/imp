defmodule ImpOptimizerLifecycles.Classical do
  alias Imp.Optimizer.{Artifact, BootstrapFewShot, KNNFewShot, RandomSearch, Report}

  @dataset "priv/tutorial/support_tickets.json"
  @model "openrouter:openai/gpt-5.4-mini"
  @max_output_tokens 256
  @pricing %{
    "input_per_million" => 0.75,
    "output_per_million" => 4.5,
    "source_url" => "https://openrouter.ai/models/openai/gpt-5.4-mini"
  }

  def main([]), do: run()
  def main(["fresh", family, artifact]), do: fresh(family, artifact)

  def main(args),
    do: raise("expected no arguments or: fresh FAMILY ARTIFACT; got #{inspect(args)}")

  defp run do
    require_clean!()
    output = System.get_env("IMP_CLASSICAL_OUTPUT", "/tmp/imp-classical-live") |> Path.expand()
    File.mkdir_p!(output)

    {dataset_bytes, train, selection, test} = dataset!()
    metric = Imp.exact_match(:team)

    {:ok, budget} =
      budget(requests: 500, input_tokens: 1_000_000, output_tokens: 100_000, usd: 1.0)

    base = router(lm(budget))

    baseline = %{selection: score(base, selection, metric), test: score(base, test, metric)}

    bootstrap =
      base
      |> Imp.optimize!(
        BootstrapFewShot.new(metric,
          max_bootstrapped_demos: 8,
          max_labeled_demos: 8,
          max_rounds: 1,
          timeout: 60_000
        ),
        train
      )

    random =
      base
      |> Imp.optimize!(
        RandomSearch.new(metric,
          num_candidate_programs: 2,
          max_bootstrapped_demos: 8,
          max_labeled_demos: 8,
          max_rounds: 1,
          num_threads: 4
        ),
        train,
        selection,
        restrict: [-3, -2, -1, 0],
        labeled_sample: false
      )

    knn =
      KNNFewShot.new(4, train,
        vectorizer: Imp.Embeddings.BagOfWords,
        few_shot_bootstrap_args: [
          metric: metric,
          max_bootstrapped_demos: 4,
          max_labeled_demos: 4,
          max_rounds: 1,
          timeout: 60_000
        ]
      )
      |> KNNFewShot.compile(base)

    paths = %{
      bootstrap: Path.join(output, "bootstrap-few-shot.parameters.json"),
      random_search: Path.join(output, "random-search.parameters.json"),
      knn_few_shot: Path.join(output, "knn-few-shot.program.json")
    }

    bootstrap
    |> Artifact.from_optimized_program(artifact_id: "support-bootstrap-few-shot")
    |> Artifact.write!(paths.bootstrap)

    random
    |> Artifact.from_optimized_program(artifact_id: "support-random-search")
    |> Artifact.write!(paths.random_search)

    # A live optimizer budget is process-owned runtime authority and is
    # intentionally not serializable. Persist a credential-free ReqLLM
    # descriptor, then bind a new budgeted runtime in the fresh process.
    portable_knn = Imp.with_lm(knn, Imp.req_llm(@model))
    :ok = Imp.save!(portable_knn, paths.knn_few_shot, registry: saving_registry())

    arms = %{
      bootstrap_few_shot: arm(bootstrap, selection, test, metric),
      random_search: arm(random, selection, test, metric),
      knn_few_shot: arm(knn, selection, test, metric)
    }

    fresh =
      Map.new(paths, fn {family, path} ->
        {family, fresh_process!(Atom.to_string(family), path)}
      end)

    result = %{
      schema_version: 1,
      git_sha: git_sha(),
      model: @model,
      dataset: %{
        path: @dataset,
        sha256: sha256(dataset_bytes),
        counts: %{train: length(train), selection: length(selection), test: length(test)}
      },
      baseline: baseline,
      arms: arms,
      fresh_process: fresh,
      budget: Imp.Optimizer.Budget.snapshot(budget),
      artifacts: Map.new(paths, fn {family, path} -> {family, artifact_summary(path)} end),
      scope: %{
        claimed:
          "one natural live retained lifecycle for BootstrapFewShot, RandomSearch, and KNNFewShot on the shipped support-routing task",
        not_claimed: ["general optimizer effectiveness", "DSPy parity", "multi-seed evidence"]
      }
    }

    require_success!(result)
    path = Path.join(output, "result.json")
    File.write!(path, Jason.encode!(result, pretty: true) <> "\n")
    IO.puts(Jason.encode!(summary(result), pretty: true))
    IO.puts("result: #{path}")
  end

  defp fresh(family, artifact) do
    {:ok, budget} = budget(requests: 24, input_tokens: 100_000, output_tokens: 10_000, usd: 0.25)
    runtime_lm = lm(budget)

    program =
      case family do
        name when name in ["bootstrap", "random_search"] ->
          artifact |> Artifact.read!() |> Artifact.apply(router(runtime_lm))

        "knn_few_shot" ->
          artifact |> Imp.load!(registry: saving_registry()) |> Imp.with_lm(runtime_lm)

        other ->
          raise "unknown family #{inspect(other)}"
      end

    evaluation = score(program, probes(), Imp.exact_match(:team), max_concurrency: 4)

    IO.puts(
      "CLASSICAL_FRESH_RESULT=" <>
        Jason.encode!(%{
          fresh_os_process: true,
          score: evaluation,
          artifact_sha256: artifact |> File.read!() |> sha256(),
          budget: Imp.Optimizer.Budget.snapshot(budget)
        })
    )
  end

  defp arm(program, selection, test, metric) do
    %{
      selection: score(program, selection, metric),
      test: score(program, test, metric),
      report: report_summary(program)
    }
  end

  defp report_summary(program) do
    case Report.fetch(program) do
      nil ->
        nil

      report ->
        %{
          optimizer: report.optimizer,
          best_score: report.best_score,
          candidate_count: report.candidate_count,
          error_count: length(report.errors),
          metadata: Map.take(report.metadata, [:selected_count, :candidate_seeds, :status])
        }
    end
  end

  defp fresh_process!(family, artifact) do
    {output, 0} =
      System.cmd(
        "mix",
        ["run", "--no-compile", "--no-deps-check", __ENV__.file, "fresh", family, artifact],
        env: [{"OPENROUTER_API_KEY", System.fetch_env!("OPENROUTER_API_KEY")}],
        stderr_to_stdout: true
      )

    output
    |> String.split("\n", trim: true)
    |> Enum.find_value(fn
      "CLASSICAL_FRESH_RESULT=" <> json -> Jason.decode!(json)
      _ -> nil
    end)
    |> case do
      nil -> raise "fresh process returned no receipt: #{output}"
      receipt -> receipt
    end
  end

  defp score(program, rows, metric, opts \\ []) do
    report =
      Imp.evaluate(program, rows, metric,
        max_concurrency: Keyword.get(opts, :max_concurrency, 8),
        timeout: 60_000
      )

    %{score: report.score, errors: length(report.errors), rows: length(report.rows)}
  end

  defp require_success!(result) do
    baseline = result.baseline.test.score

    Enum.each(result.arms, fn {family, arm} ->
      unless arm.test.errors == 0 and arm.test.score > baseline do
        raise "#{family} did not improve untouched test over baseline: #{inspect(arm)}"
      end
    end)

    unless Enum.all?(result.fresh_process, fn {_family, receipt} ->
             receipt["fresh_os_process"] and receipt["score"]["errors"] == 0 and
               receipt["score"]["score"] >= 0.75
           end) do
      raise "fresh-process verification failed"
    end
  end

  defp summary(result) do
    %{
      git_sha: result.git_sha,
      baseline: result.baseline,
      arms:
        Map.new(result.arms, fn {name, arm} -> {name, Map.take(arm, [:selection, :test])} end),
      fresh_scores:
        Map.new(result.fresh_process, fn {name, receipt} ->
          {name, get_in(receipt, ["score", "score"])}
        end),
      usage: result.budget["usage"]
    }
  end

  defp dataset! do
    bytes = File.read!(@dataset)
    data = Jason.decode!(bytes)
    {bytes, examples(data["train"]), examples(data["dev"]), examples(data["test"])}
  end

  defp examples(rows) do
    Enum.map(rows, fn %{"ticket" => ticket, "team" => team} ->
      Imp.example(ticket: ticket, team: team) |> Imp.with_inputs(:ticket)
    end)
  end

  defp probes do
    examples([
      %{"ticket" => "Refund the duplicate annual invoice charge.", "team" => "atlas"},
      %{"ticket" => "The API returns 502 for every customer.", "team" => "harbor"},
      %{"ticket" => "A former employee can still sign in.", "team" => "beacon"},
      %{"ticket" => "Please add dark mode to the dashboard.", "team" => "quill"}
    ])
  end

  defp router(runtime_lm) do
    "ticket -> team: enum[atlas,harbor,beacon,quill]"
    |> Imp.signature(
      "Assign the support ticket to the squad that owns it: atlas, harbor, beacon, or quill."
    )
    |> Imp.predict(lm: runtime_lm, adapter: Imp.Adapter.JSON, config: [json_retries: 1])
  end

  defp lm(budget) do
    @model
    |> Imp.req_llm(api_key: System.fetch_env!("OPENROUTER_API_KEY"))
    |> Imp.budgeted_lm(budget, max_output_tokens: @max_output_tokens)
  end

  defp saving_registry do
    Imp.Saving.Registry.new(classical_metric: Imp.exact_match(:team))
  end

  defp budget(limits) do
    Imp.start_optimizer_budget(
      limits: Map.new(limits),
      pricing: @pricing,
      default_max_output_tokens: @max_output_tokens
    )
  end

  defp artifact_summary(path) do
    %{
      path: Path.basename(path),
      sha256: path |> File.read!() |> sha256(),
      bytes: File.stat!(path).size
    }
  end

  defp require_clean! do
    case System.cmd("git", ["status", "--porcelain"]) do
      {"", 0} -> :ok
      {_dirty, 0} -> raise "classical lifecycle requires a clean Git checkout"
      {output, status} -> raise "git status failed (#{status}): #{output}"
    end
  end

  defp git_sha do
    {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"])
    String.trim(sha)
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end

ImpOptimizerLifecycles.Classical.main(System.argv())
