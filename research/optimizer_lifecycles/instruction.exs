defmodule ImpOptimizerLifecycles.Instruction do
  alias Imp.Optimizer.{Artifact, InferRules, Report, SignatureOptimizer}

  @dataset "priv/tutorial/support_tickets.json"
  @task_model "openrouter:openai/gpt-5.4-mini"
  @optimizer_model "openrouter:anthropic/claude-sonnet-4.6"
  @max_task_tokens 256
  @max_optimizer_tokens 1_024

  def main([]), do: run()
  def main(["fresh", family, artifact]), do: fresh(family, artifact)

  def main(args),
    do: raise("expected no arguments or: fresh FAMILY ARTIFACT; got #{inspect(args)}")

  defp run do
    require_clean!()

    output =
      System.get_env("IMP_INSTRUCTION_OUTPUT", "/tmp/imp-instruction-live") |> Path.expand()

    File.mkdir_p!(output)
    {dataset_bytes, train, selection, test} = dataset!()
    metric = Imp.exact_match(:team)

    {:ok, task_budget} =
      task_budget(requests: 500, input_tokens: 1_000_000, output_tokens: 100_000, usd: 1.0)

    {:ok, optimizer_budget} =
      optimizer_budget(requests: 16, input_tokens: 200_000, output_tokens: 16_384, usd: 1.0)

    base = router(task_lm(task_budget))
    proposer = optimizer_lm(optimizer_budget)
    baseline = %{selection: score(base, selection, metric), test: score(base, test, metric)}

    signature =
      Imp.optimize!(
        base,
        SignatureOptimizer.new(metric,
          proposer_lm: proposer,
          num_candidates: 3,
          seed: 23,
          temperature: 0.8,
          view_data_batch_size: length(train),
          proposal_response_format: :required
        ),
        train,
        selection
      )

    infer_rules =
      Imp.optimize!(
        base,
        InferRules.new(metric,
          rule_lm: proposer,
          num_candidates: 2,
          num_rules: 8,
          num_threads: 4,
          max_bootstrapped_demos: 6,
          max_labeled_demos: 0,
          max_rounds: 1,
          max_errors: 8,
          timeout: 60_000
        ),
        train,
        selection
      )

    programs = %{signature_optimizer: signature, infer_rules: infer_rules}

    paths =
      Map.new(programs, fn {family, program} ->
        path = Path.join(output, "#{family}.parameters.json")

        program
        |> Artifact.from_optimized_program(artifact_id: "support-#{family}")
        |> Artifact.write!(path)

        {family, path}
      end)

    arms =
      Map.new(programs, fn {family, program} ->
        {family, arm(program, selection, test, metric)}
      end)

    fresh =
      Map.new(paths, fn {family, path} ->
        {family, fresh_process!(Atom.to_string(family), path)}
      end)

    result = %{
      schema_version: 1,
      git_sha: git_sha(),
      models: %{task: @task_model, optimizer: @optimizer_model},
      dataset: %{
        path: @dataset,
        sha256: sha256(dataset_bytes),
        counts: %{train: length(train), selection: length(selection), test: length(test)}
      },
      baseline: baseline,
      arms: arms,
      fresh_process: fresh,
      budgets: %{
        task: Imp.Optimizer.Budget.snapshot(task_budget),
        optimizer: Imp.Optimizer.Budget.snapshot(optimizer_budget)
      },
      artifacts: Map.new(paths, fn {family, path} -> {family, artifact_summary(path)} end),
      scope: %{
        claimed:
          "one natural live retained lifecycle for SignatureOptimizer and InferRules on the shipped support-routing task",
        not_claimed: ["general optimizer effectiveness", "DSPy parity", "multi-seed evidence"]
      }
    }

    path = Path.join(output, "result.json")
    File.write!(path, Jason.encode!(result, pretty: true) <> "\n")
    IO.puts(Jason.encode!(summary(result), pretty: true))
    IO.puts("result: #{path}")
    require_success!(result)
  end

  defp fresh(family, artifact) do
    {:ok, budget} =
      task_budget(requests: 24, input_tokens: 100_000, output_tokens: 10_000, usd: 0.25)

    program =
      artifact
      |> Artifact.read!()
      |> Artifact.apply(router(task_lm(budget)))

    evaluation = score(program, probes(), Imp.exact_match(:team), max_concurrency: 4)

    IO.puts(
      "INSTRUCTION_FRESH_RESULT=" <>
        Jason.encode!(%{
          family: family,
          fresh_os_process: true,
          score: evaluation,
          selected_instruction: instruction(program),
          artifact_sha256: artifact |> File.read!() |> sha256(),
          budget: Imp.Optimizer.Budget.snapshot(budget)
        })
    )
  end

  defp arm(program, selection, test, metric) do
    %{
      selection: score(program, selection, metric),
      test: score(program, test, metric),
      selected_instruction: instruction(program),
      report: report_summary(program)
    }
  end

  defp report_summary(program) do
    report = Report.fetch(program)

    %{
      optimizer: report.optimizer,
      best_score: report.best_score,
      candidate_count: report.candidate_count,
      errors: Report.json_safe(report.errors),
      metadata: Report.json_safe(report.metadata),
      candidates: Report.json_safe(report.candidates)
    }
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
      "INSTRUCTION_FRESH_RESULT=" <> json -> Jason.decode!(json)
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
        num_threads: Keyword.get(opts, :max_concurrency, 8),
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

      if arm.selected_instruction == router_instruction() do
        raise "#{family} retained the source instruction"
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
        Map.new(result.arms, fn {name, arm} ->
          {name, Map.take(arm, [:selection, :test, :selected_instruction])}
        end),
      fresh_scores:
        Map.new(result.fresh_process, fn {name, receipt} ->
          {name, get_in(receipt, ["score", "score"])}
        end),
      budgets: %{
        task: get_in(result.budgets, [:task, "usage"]),
        optimizer: get_in(result.budgets, [:optimizer, "usage"])
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
    |> Imp.signature(router_instruction())
    |> Imp.predict(lm: runtime_lm, adapter: Imp.Adapter.JSON, config: [json_retries: 1])
  end

  defp router_instruction,
    do: "Assign the support ticket to the squad that owns it: atlas, harbor, beacon, or quill."

  defp instruction(program), do: program.signature.instructions

  defp task_lm(budget) do
    @task_model
    |> Imp.req_llm(api_key: System.fetch_env!("OPENROUTER_API_KEY"), cache: false, max_retries: 0)
    |> Imp.budgeted_lm(budget, max_output_tokens: @max_task_tokens)
  end

  defp optimizer_lm(budget) do
    @optimizer_model
    |> Imp.req_llm(api_key: System.fetch_env!("OPENROUTER_API_KEY"), cache: false, max_retries: 0)
    |> Imp.budgeted_lm(budget, max_output_tokens: @max_optimizer_tokens)
  end

  defp task_budget(limits) do
    Imp.start_optimizer_budget(
      limits: Map.new(limits),
      pricing: %{
        "input_per_million" => 0.75,
        "output_per_million" => 4.5,
        "source_url" => "https://openrouter.ai/models/openai/gpt-5.4-mini"
      },
      default_max_output_tokens: @max_task_tokens
    )
  end

  defp optimizer_budget(limits) do
    Imp.start_optimizer_budget(
      limits: Map.new(limits),
      pricing: %{
        "input_per_million" => 3.0,
        "output_per_million" => 15.0,
        "source_url" => "https://openrouter.ai/models/anthropic/claude-sonnet-4.6"
      },
      default_max_output_tokens: @max_optimizer_tokens
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
      {_dirty, 0} -> raise "instruction lifecycle requires a clean Git checkout"
      {output, status} -> raise "git status failed (#{status}): #{output}"
    end
  end

  defp git_sha do
    {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"])
    String.trim(sha)
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end

ImpOptimizerLifecycles.Instruction.main(System.argv())
