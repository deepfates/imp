defmodule ImpOptimizerLifecycles.Ensemble do
  alias Imp.Optimizer.{Artifact, Ensemble}

  @dataset "priv/tutorial/support_tickets.json"
  @model "openrouter:openai/gpt-5.4-mini"
  @artifacts %{
    bootstrap_few_shot:
      "research/optimizer_lifecycles/exercised-classical/bootstrap-few-shot.parameters.json",
    signature_optimizer:
      "research/optimizer_lifecycles/exercised-instruction/signature_optimizer.parameters.json",
    infer_rules: "research/optimizer_lifecycles/exercised-instruction/infer_rules.parameters.json"
  }

  def main([]), do: run()
  def main(["fresh"]), do: fresh()
  def main(args), do: raise("expected no arguments or: fresh; got #{inspect(args)}")

  defp run do
    require_clean!()
    output = System.get_env("IMP_ENSEMBLE_OUTPUT", "/tmp/imp-ensemble-live") |> Path.expand()
    File.mkdir_p!(output)
    {dataset_bytes, test} = dataset!()
    metric = Imp.exact_match(:team)
    {:ok, budget} = budget(requests: 160, input_tokens: 500_000, output_tokens: 40_000, usd: 0.5)
    base = router(lm(budget))
    children = children(base)
    ensemble = construct(children)

    result = %{
      schema_version: 1,
      git_sha: git_sha(),
      model: @model,
      dataset: %{path: @dataset, sha256: sha256(dataset_bytes), split: "test", rows: length(test)},
      baseline: score(base, test, metric),
      children: Map.new(children, fn {name, program} -> {name, score(program, test, metric)} end),
      ensemble: score(ensemble, test, metric),
      fresh_process: fresh_process!(),
      budget: Imp.Optimizer.Budget.snapshot(budget),
      artifacts:
        Map.new(@artifacts, fn {name, path} ->
          {name, %{path: path, sha256: path |> File.read!() |> sha256()}}
        end),
      configuration: %{
        deterministic: true,
        size: 3,
        reducer: "majority vote with stable child order"
      },
      scope: %{
        claimed:
          "one natural live Ensemble composition of three independently optimized support routers with fresh reconstruction",
        not_claimed: [
          "general ensemble effectiveness",
          "learned ensemble selection",
          "DSPy parity"
        ]
      }
    }

    path = Path.join(output, "result.json")
    File.write!(path, Jason.encode!(result, pretty: true) <> "\n")
    IO.puts(Jason.encode!(summary(result), pretty: true))
    IO.puts("result: #{path}")
    require_success!(result)
  end

  defp fresh do
    {:ok, budget} = budget(requests: 24, input_tokens: 100_000, output_tokens: 10_000, usd: 0.25)
    ensemble = budget |> lm() |> router() |> children() |> construct()
    evaluation = score(ensemble, probes(), Imp.exact_match(:team), max_concurrency: 4)

    IO.puts(
      "ENSEMBLE_FRESH_RESULT=" <>
        Jason.encode!(%{
          fresh_os_process: true,
          score: evaluation,
          budget: Imp.Optimizer.Budget.snapshot(budget),
          artifact_sha256s:
            Map.new(@artifacts, fn {name, path} -> {name, sha256(File.read!(path))} end)
        })
    )
  end

  def majority(predictions) do
    predictions
    |> Enum.with_index()
    |> Enum.group_by(fn {prediction, _index} -> Imp.Prediction.get(prediction, :team) end)
    |> Enum.map(fn {team, votes} ->
      {team, length(votes), votes |> Enum.map(&elem(&1, 1)) |> Enum.min()}
    end)
    |> Enum.sort_by(fn {_team, count, first_index} -> {-count, first_index} end)
    |> hd()
    |> elem(0)
    |> then(&%{team: &1})
  end

  defp children(base) do
    Map.new(@artifacts, fn {name, path} ->
      {name, path |> Artifact.read!() |> Artifact.apply(base)}
    end)
  end

  defp construct(children) do
    programs =
      Enum.map(
        [:bootstrap_few_shot, :signature_optimizer, :infer_rules],
        &Map.fetch!(children, &1)
      )

    Ensemble.new(deterministic: true, size: 3, reduce_fn: &__MODULE__.majority/1)
    |> Ensemble.compile(programs)
  end

  defp fresh_process! do
    {output, 0} =
      System.cmd(
        "mix",
        ["run", "--no-compile", "--no-deps-check", __ENV__.file, "fresh"],
        env: [{"OPENROUTER_API_KEY", System.fetch_env!("OPENROUTER_API_KEY")}],
        stderr_to_stdout: true
      )

    output
    |> String.split("\n", trim: true)
    |> Enum.find_value(fn
      "ENSEMBLE_FRESH_RESULT=" <> json -> Jason.decode!(json)
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
    best_child = result.children |> Map.values() |> Enum.map(& &1.score) |> Enum.max()

    unless result.ensemble.errors == 0 and result.ensemble.score >= best_child and
             result.ensemble.score > result.baseline.score do
      raise "ensemble did not robustly combine its children: #{inspect(summary(result))}"
    end

    fresh = result.fresh_process

    unless fresh["fresh_os_process"] and fresh["score"]["errors"] == 0 and
             fresh["score"]["score"] >= 0.75 do
      raise "fresh ensemble verification failed: #{inspect(fresh)}"
    end
  end

  defp summary(result) do
    %{
      git_sha: result.git_sha,
      baseline: result.baseline,
      children: result.children,
      ensemble: result.ensemble,
      fresh: result.fresh_process["score"],
      usage: result.budget["usage"]
    }
  end

  defp dataset! do
    bytes = File.read!(@dataset)
    data = Jason.decode!(bytes)
    {bytes, examples(data["test"])}
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
    |> Imp.req_llm(api_key: System.fetch_env!("OPENROUTER_API_KEY"), cache: false, max_retries: 0)
    |> Imp.budgeted_lm(budget, max_output_tokens: 256)
  end

  defp budget(limits) do
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

  defp require_clean! do
    case System.cmd("git", ["status", "--porcelain"]) do
      {"", 0} -> :ok
      {_dirty, 0} -> raise "ensemble lifecycle requires a clean Git checkout"
      {output, status} -> raise "git status failed (#{status}): #{output}"
    end
  end

  defp git_sha do
    {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"])
    String.trim(sha)
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end

ImpOptimizerLifecycles.Ensemble.main(System.argv())
