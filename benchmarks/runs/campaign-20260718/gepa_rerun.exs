# GEPA-only rerun of the ticket cell, on main AFTER the connect_options fix
# (PR #33, 26d0cca). Same task, split, metric, controls as the campaign cell;
# the only question is whether GEPA now drives live and what it scores.
#
#   OPENAI_API_KEY=... mix run benchmarks/runs/campaign-20260718/gepa_rerun.exs

defmodule GepaRerun do
  @model "openai:gpt-5.4-mini"
  @dataset_relative "priv/tutorial/support_tickets.json"
  @out_dir "benchmarks/runs/campaign-20260718"
  @out_file "gepa_rerun-result.json"

  def main do
    api_key = System.fetch_env!("OPENAI_API_KEY")

    dataset_bytes = :imp |> Application.app_dir(@dataset_relative) |> File.read!()
    data = Jason.decode!(dataset_bytes)
    trainset = to_examples(data["train"])
    devset = to_examples(data["dev"])
    testset = to_examples(data["test"])
    data_sha = sha256(dataset_bytes)

    lm = Imp.req_llm(@model, api_key: api_key, temperature: 0)

    router =
      "ticket -> team: enum[atlas,harbor,beacon,quill]"
      |> Imp.signature(
        "Assign the support ticket to the squad that owns it: atlas, harbor, beacon, or quill."
      )
      |> Imp.predict(lm: lm, adapter: Imp.Adapter.JSON, config: [json_retries: 1])

    metric = Imp.exact_match(:team)

    charter = %{
      "atlas" => "money: charges, refunds, invoices, plans, taxes, receipts",
      "harbor" => "platform: outages, errors, latency, technical failures even when payment/email is involved",
      "beacon" => "identity & trust: accounts, credentials, sessions, permissions, data exposure, lockouts",
      "quill" => "product experience: feature requests, how-to questions, documentation"
    }

    gepa_metric = fn example, prediction ->
      gold = normalize(Imp.Example.get(example, :team))
      pred = normalize(Imp.Prediction.get(prediction, :team))
      score = if gold == pred and gold != "", do: 1.0, else: 0.0

      feedback =
        if score == 1.0,
          do: "correct: #{gold}",
          else: "expected #{gold} (#{Map.get(charter, gold, "the correct squad")}); got #{inspect(pred)}"

      %{score: score, feedback: feedback}
    end

    repeats =
      for repeat <- 1..2 do
        Imp.Cache.clear()
        Imp.Cache.reset_stats()
        t0 = System.monotonic_time(:millisecond)

        result =
          try do
            opt =
              Imp.Optimizer.GEPA.new(gepa_metric,
                reflection_lm: lm,
                generations: 2,
                minibatch_size: 5,
                max_concurrency: 8,
                max_metric_calls: 200
              )

            compiled = Imp.optimize(router, opt, trainset, devset)
            report = Imp.evaluate(compiled, testset, metric, max_concurrency: 8, timeout: 60_000)

            instruction =
              case compiled do
                %{signature: %{instructions: ins}} -> ins
                _ -> nil
              end

            %{
              status: "ok",
              score: report.score,
              row_scores: Enum.map(report.rows, & &1.score),
              cache: Imp.Cache.stats() |> Map.take([:hits, :misses, :bypasses]),
              compiled_instruction: instruction,
              demo_count: length(Map.get(compiled, :demos, []))
            }
          rescue
            e -> %{status: "error", error: Exception.message(e), kind: inspect(e.__struct__)}
          catch
            kind, reason -> %{status: "error", error: inspect({kind, reason})}
          end

        wall = (System.monotonic_time(:millisecond) - t0) / 1000
        IO.puts("repeat #{repeat}: #{inspect(Map.take(result, [:status, :score, :error]))} (#{wall}s)")
        Map.put(result, :repeat, repeat) |> Map.put(:wall_seconds, wall)
      end

    artifact = %{
      "cell" => "gepa_rerun",
      "purpose" => "GEPA arm rerun after connect_options fix (PR #33, main 26d0cca)",
      "model" => @model,
      "git_sha" => String.trim(System.cmd("git", ["rev-parse", "HEAD"]) |> elem(0)),
      "dataset" => %{"path" => @dataset_relative, "sha256" => data_sha,
                     "train" => length(trainset), "dev" => length(devset), "test" => length(testset)},
      "reference" => %{"zero_shot" => 0.30, "labeled_fewshot_k8" => 0.85, "miprov2" => 0.85},
      "generated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "repeats" => repeats
    }

    File.mkdir_p!(@out_dir)
    File.write!(Path.join(@out_dir, @out_file), Jason.encode!(artifact, pretty: true) <> "\n")
    IO.puts("\nartifact: #{Path.join(@out_dir, @out_file)}")
  end

  defp to_examples(rows) do
    for %{"ticket" => t, "team" => team} <- rows,
        do: Imp.example(ticket: t, team: team) |> Imp.with_inputs(:ticket)
  end

  defp normalize(nil), do: ""
  defp normalize(v), do: v |> to_string() |> String.trim() |> String.downcase()
  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end

GepaRerun.main()
