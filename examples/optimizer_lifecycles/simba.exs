defmodule ImpOptimizerLifecycles.SIMBA do
  alias Imp.Optimizer.{Artifact, Report, SIMBA}

  @dataset "priv/tutorial/support_tickets.json"
  @task_model "openrouter:openai/gpt-5.4-mini"
  @reflection_model "openrouter:anthropic/claude-sonnet-4.6"

  def main([]), do: run()
  def main(["fresh", artifact]), do: fresh(artifact)
  def main(args), do: raise("expected no arguments or: fresh ARTIFACT; got #{inspect(args)}")

  defp run do
    require_clean!()
    output = System.get_env("IMP_SIMBA_OUTPUT", "/tmp/imp-simba-live") |> Path.expand()
    File.mkdir_p!(output)
    {dataset_bytes, train, selection, test} = dataset!()

    {:ok, task_budget} =
      task_budget(requests: 500, input_tokens: 1_000_000, output_tokens: 100_000, usd: 1.0)

    {:ok, reflection_budget} =
      reflection_budget(requests: 24, input_tokens: 300_000, output_tokens: 24_576, usd: 2.0)

    metric = &__MODULE__.metric/2
    base = router(task_lm(task_budget))
    baseline = %{selection: score(base, selection, metric), test: score(base, test, metric)}

    selected =
      Imp.optimize!(
        base,
        SIMBA.new(metric,
          prompt_lm: reflection_lm(reflection_budget),
          reflection_grounding: :structure,
          bsize: 5,
          num_candidates: 2,
          max_steps: 4,
          max_demos: 0,
          max_concurrency: 4,
          timeout: 60_000,
          sampling_temperature: 0.7,
          candidate_temperature: 0.3,
          seed: 23
        ),
        train,
        selection
      )

    artifact_path = Path.join(output, "simba.parameters.json")

    selected
    |> Artifact.from_optimized_program(artifact_id: "support-simba")
    |> Artifact.write!(artifact_path)

    report = Report.fetch(selected)

    result = %{
      schema_version: 1,
      git_sha: git_sha(),
      models: %{task: @task_model, reflection: @reflection_model},
      dataset: %{
        path: @dataset,
        sha256: sha256(dataset_bytes),
        counts: %{train: length(train), selection: length(selection), test: length(test)}
      },
      baseline: baseline,
      selected: %{
        selection: score(selected, selection, metric),
        test: score(selected, test, metric),
        instruction: instruction(selected)
      },
      report: %{
        optimizer: report.optimizer,
        best_score: report.best_score,
        candidate_count: report.candidate_count,
        errors: Report.json_safe(report.errors),
        metadata: Report.json_safe(report.metadata),
        candidates: Report.json_safe(report.candidates)
      },
      fresh_process: fresh_process!(artifact_path),
      budgets: %{
        task: Imp.Optimizer.Budget.snapshot(task_budget),
        reflection: Imp.Optimizer.Budget.snapshot(reflection_budget)
      },
      artifact: %{
        path: Path.basename(artifact_path),
        sha256: artifact_path |> File.read!() |> sha256(),
        bytes: File.stat!(artifact_path).size
      },
      scope: %{
        claimed:
          "one natural live SIMBA reflective-mutation lifecycle on the shipped support-routing task",
        not_claimed: ["general SIMBA effectiveness", "DSPy parity", "multi-seed evidence"]
      }
    }

    result_path = Path.join(output, "result.json")
    File.write!(result_path, Jason.encode!(result, pretty: true) <> "\n")
    IO.puts(Jason.encode!(summary(result), pretty: true))
    IO.puts("result: #{result_path}")
    require_success!(result)
  end

  defp fresh(artifact) do
    {:ok, budget} =
      task_budget(requests: 24, input_tokens: 100_000, output_tokens: 10_000, usd: 0.25)

    program = artifact |> Artifact.read!() |> Artifact.apply(router(task_lm(budget)))
    evaluation = score(program, probes(), &__MODULE__.metric/2, max_concurrency: 4)

    IO.puts(
      "SIMBA_FRESH_RESULT=" <>
        Jason.encode!(%{
          fresh_os_process: true,
          score: evaluation,
          instruction: instruction(program),
          artifact_sha256: artifact |> File.read!() |> sha256(),
          budget: Imp.Optimizer.Budget.snapshot(budget)
        })
    )
  end

  def metric(example, prediction) do
    expected = Imp.Example.get(example, :team)
    actual = Imp.Prediction.get(prediction, :team)
    score = if expected == actual, do: 1.0, else: 0.0

    %{
      score: score,
      feedback:
        if(score == 1.0,
          do: "Correct: #{expected} handles #{meaning(expected)}.",
          else:
            "Expected #{expected} for #{meaning(expected)}; #{actual} handles #{meaning(actual)}."
        ),
      metadata: %{expected_team: expected, predicted_team: actual}
    }
  end

  defp fresh_process!(artifact) do
    {output, 0} =
      System.cmd(
        "mix",
        ["run", "--no-compile", "--no-deps-check", __ENV__.file, "fresh", artifact],
        env: [{"OPENROUTER_API_KEY", System.fetch_env!("OPENROUTER_API_KEY")}],
        stderr_to_stdout: true
      )

    output
    |> String.split("\n", trim: true)
    |> Enum.find_value(fn
      "SIMBA_FRESH_RESULT=" <> json -> Jason.decode!(json)
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
    unless result.selected.instruction != source_instruction() and
             result.selected.selection.score > result.baseline.selection.score and
             result.selected.test.score > result.baseline.test.score and
             result.selected.test.errors == 0 do
      raise "SIMBA did not select a useful reflective mutation: #{inspect(summary(result))}"
    end

    fresh = result.fresh_process

    unless fresh["fresh_os_process"] and fresh["score"]["errors"] == 0 and
             fresh["score"]["score"] >= 0.75 do
      raise "fresh SIMBA verification failed: #{inspect(fresh)}"
    end
  end

  defp summary(result) do
    %{
      git_sha: result.git_sha,
      baseline: result.baseline,
      selected: result.selected,
      report: Map.take(result.report, [:best_score, :candidate_count, :errors]),
      fresh: result.fresh_process["score"],
      budgets: %{
        task: result.budgets.task["usage"],
        reflection: result.budgets.reflection["usage"]
      }
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
    |> Imp.signature(source_instruction())
    |> Imp.predict(lm: runtime_lm, adapter: Imp.Adapter.JSON, config: [json_retries: 1])
  end

  defp source_instruction,
    do: "Assign the support ticket to the squad that owns it: atlas, harbor, beacon, or quill."

  defp instruction(program), do: Imp.ProgramAccess.task_signature(program).instructions

  defp meaning("atlas"), do: "billing, invoices, charges, refunds, and subscriptions"
  defp meaning("harbor"), do: "outages, API errors, performance, and delivery failures"
  defp meaning("beacon"), do: "login, authentication, access, and security"
  defp meaning("quill"), do: "features, how-to questions, documentation, and usability"
  defp meaning(other), do: "an unknown or invalid category (#{inspect(other)})"

  defp task_lm(budget) do
    @task_model
    |> Imp.req_llm(api_key: System.fetch_env!("OPENROUTER_API_KEY"), cache: false, max_retries: 0)
    |> Imp.budgeted_lm(budget, max_output_tokens: 256)
  end

  defp reflection_lm(budget) do
    @reflection_model
    |> Imp.req_llm(api_key: System.fetch_env!("OPENROUTER_API_KEY"), cache: false, max_retries: 0)
    |> Imp.budgeted_lm(budget, max_output_tokens: 1_024)
  end

  defp task_budget(limits) do
    Imp.start_optimizer_budget(
      limits: Map.new(limits),
      pricing: %{
        "input_per_million" => 0.75,
        "output_per_million" => 4.5,
        "source_url" => "https://openrouter.ai/models/openai/gpt-5.4-mini"
      },
      default_max_output_tokens: 256
    )
  end

  defp reflection_budget(limits) do
    Imp.start_optimizer_budget(
      limits: Map.new(limits),
      pricing: %{
        "input_per_million" => 3.0,
        "output_per_million" => 15.0,
        "source_url" => "https://openrouter.ai/models/anthropic/claude-sonnet-4.6"
      },
      default_max_output_tokens: 1_024
    )
  end

  defp require_clean! do
    case System.cmd("git", ["status", "--porcelain"]) do
      {"", 0} -> :ok
      {_dirty, 0} -> raise "SIMBA lifecycle requires a clean Git checkout"
      {output, status} -> raise "git status failed (#{status}): #{output}"
    end
  end

  defp git_sha do
    {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"])
    String.trim(sha)
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end

ImpOptimizerLifecycles.SIMBA.main(System.argv())
