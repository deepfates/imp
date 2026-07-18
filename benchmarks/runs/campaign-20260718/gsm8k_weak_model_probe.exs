# STEP 1 probe for cell gsm8k_weak_model: pick the weak STUDENT model.
#
# Zero-shot chain-of-thought, temp 0, on 20 TRAIN rows (indices 0-19, never
# test). Candidates tried in order; the first that scores in [20%, 70%] is the
# student. Every probe is recorded to gsm8k_weak_model-probe.json.
#
#   cd .../dspy_elixir && set -a && . ./.env && set +a && \
#     mix run benchmarks/runs/campaign-20260718/gsm8k_weak_model_probe.exs

defmodule GSM8KWeakModelProbe do
  @data_relative "benchmarks/runs/campaign-20260718/data/gsm8k.json"
  @out "benchmarks/runs/campaign-20260718/gsm8k_weak_model-probe.json"
  # 20-row probe drawn from TRAIN rows only.
  @probe 0..19
  @candidates ~w(gpt-5.4-nano gpt-5-nano gpt-4.1-nano gpt-4o-mini gpt-3.5-turbo)

  # ---- numeric-exact-match metric (shared with the main cell) --------------
  def normalize(nil), do: :error
  def normalize(value) when is_number(value), do: normalize(to_string(value))

  def normalize(text) when is_binary(text) do
    cleaned = text |> String.replace(~r/[\$,%]/, "") |> String.trim()
    numbers = Regex.scan(~r/-?\d+(?:\.\d+)?/, cleaned) |> Enum.map(&hd/1)

    case List.last(numbers) do
      nil ->
        :error

      token ->
        case Float.parse(token) do
          {f, _} -> Float.round(f, 6)
          :error -> :error
        end
    end
  end

  def metric do
    fn example, prediction ->
      gold = normalize(Imp.Example.get(example, :answer))
      pred = normalize(Imp.Prediction.get(prediction, :answer))
      if gold != :error and pred != :error and gold == pred, do: 1.0, else: 0.0
    end
  end

  def load do
    path = Path.join(File.cwd!(), @data_relative)
    bytes = File.read!(path)
    data = Jason.decode!(bytes)
    rows = data["rows"]
    {rows, :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower), length(rows)}
  end

  def eval_example(row) do
    Imp.example(question: row["question"], answer: row["final_answer"])
    |> Imp.with_inputs(:question)
  end

  def probe_model(model, probeset, m) do
    IO.puts("\n== probe #{model}")
    Imp.Cache.clear()
    Imp.Cache.reset_stats()
    t0 = System.monotonic_time(:millisecond)

    result =
      try do
        lm =
          Imp.req_llm("openai:#{model}",
            api_key: System.fetch_env!("OPENAI_API_KEY"),
            temperature: 0
          )

        program = Imp.chain_of_thought("question -> answer", lm: lm)
        report = Imp.evaluate(program, probeset, m, max_concurrency: 8, timeout: 120_000)
        {:ok, report}
      rescue
        e -> {:error, Exception.format(:error, e, __STACKTRACE__)}
      catch
        kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
      end

    wall = (System.monotonic_time(:millisecond) - t0) / 1000

    case result do
      {:ok, report} ->
        IO.puts(
          "   score=#{report.score} n=#{length(report.rows)} errors=#{length(report.errors)} " <>
            "wall=#{Float.round(wall, 1)}s"
        )

        %{
          "model" => model,
          "status" => "ok",
          "score" => report.score,
          "n" => length(report.rows),
          "errors" => length(report.errors),
          "row_scores" => Enum.map(report.rows, & &1.score),
          "in_window" => report.score >= 0.20 and report.score <= 0.70,
          "wall_seconds" => Float.round(wall, 2)
        }

      {:error, err} ->
        IO.puts("   ERROR: " <> String.slice(err, 0, 300))

        %{
          "model" => model,
          "status" => "error",
          "error" => String.slice(err, 0, 2000),
          "wall_seconds" => Float.round(wall, 2)
        }
    end
  end

  def main do
    {rows, sha, n} = load()
    IO.puts("data rows=#{n} sha256=#{sha}")
    m = metric()
    probeset = @probe |> Enum.to_list() |> Enum.map(&Enum.at(rows, &1)) |> Enum.map(&eval_example/1)
    IO.puts("probe set n=#{length(probeset)} (train rows 0-19)")

    # Probe candidates in order; stop at the first in-window model but record
    # all probes attempted.
    {probes, chosen} =
      Enum.reduce_while(@candidates, {[], nil}, fn model, {acc, _} ->
        p = probe_model(model, probeset, m)
        acc = acc ++ [p]

        if p["status"] == "ok" and p["in_window"] do
          {:halt, {acc, model}}
        else
          {:cont, {acc, nil}}
        end
      end)

    # If nothing landed in-window, pick the closest to the [20,70] midpoint (45%)
    # among successful probes and flag it.
    {chosen, chosen_note} =
      if chosen do
        {chosen, "first candidate in [20%,70%] window"}
      else
        ok = Enum.filter(probes, &(&1["status"] == "ok"))

        case ok do
          [] ->
            {nil, "NO successful probe"}

          _ ->
            best =
              Enum.min_by(ok, fn p -> abs(p["score"] - 0.45) end)

            {best["model"],
             "NO candidate in window; closest to 45% midpoint (score #{best["score"]})"}
        end
      end

    IO.puts("\n== CHOSEN STUDENT: #{inspect(chosen)} (#{chosen_note})")

    artifact = %{
      "cell" => "gsm8k_weak_model",
      "phase" => "step1_probe",
      "generated_at" =>
        DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "git_sha" => git_sha(),
      "dataset" => %{"path" => @data_relative, "sha256" => sha, "rows" => n},
      "probe" => %{
        "rows" => "train 0-19",
        "n" => length(probeset),
        "program" => "Imp.chain_of_thought(\"question -> answer\") zero-shot",
        "temperature" => 0,
        "window" => [0.20, 0.70]
      },
      "candidates_in_order" => @candidates,
      "probes" => probes,
      "chosen_student" => chosen,
      "chosen_note" => chosen_note
    }

    out = Path.join(File.cwd!(), @out)
    File.write!(out, Jason.encode!(artifact, pretty: true) <> "\n")
    IO.puts("probe artifact: #{out}")
  end

  defp git_sha do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> nil
    end
  end
end

GSM8KWeakModelProbe.main()
