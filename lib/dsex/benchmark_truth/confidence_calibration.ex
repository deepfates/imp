defmodule DSEx.BenchmarkTruth.ConfidenceCalibration do
  @moduledoc false

  alias DSEx.Confidence.Calibration
  alias DSEx.Optimizer.GEPA.{Candidate, ConfidenceAdapter, Evaluation}

  @labels ~w(billing technical account cancellation)
  @prompts %{
    "minimal" => "Classify the support request into exactly one allowed label.",
    "policy" =>
      "Classify by the user's primary requested outcome. Billing covers charges and invoices; technical covers broken product behavior; account covers identity, access, and ownership; cancellation covers ending or stopping renewal. Ignore secondary details."
  }

  def run(opts \\ []) do
    path = Keyword.get(opts, :data, "benchmarks/data/confidence-calibration.jsonl")
    model = Keyword.get(opts, :model, "openai:gpt-4o-mini")
    api_key = Keyword.fetch!(opts, :api_key)
    concurrency = Keyword.get(opts, :max_concurrency, 2)
    rows = load_rows!(path)
    calibration_rows = Enum.filter(rows, &(&1["split"] == "calibration"))
    heldout_rows = Enum.filter(rows, &(&1["split"] == "heldout"))

    calibration_records = evaluate(calibration_rows, "minimal", model, api_key, concurrency)

    heldout_records =
      @prompts
      |> Enum.sort()
      |> Enum.flat_map(fn {prompt_id, _prompt} ->
        evaluate(heldout_rows, prompt_id, model, api_key, concurrency)
      end)

    calibrator = Calibration.fit_histogram(calibration_records, bins: 1)
    raw_report = Calibration.report(heldout_records, bins: 10)
    calibrated_report = Calibration.evaluate_histogram(calibrator, heldout_records, bins: 10)

    artifact = %{
      schema_version: 1,
      evidence_tier: "live_calibration_probe",
      generated_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      model: model,
      provider_requirement: "OpenAI Chat Completions with returned token logprobs",
      data: %{
        path: path,
        sha256: sha256(File.read!(path)),
        provenance:
          "DSEx-authored ambiguous support-routing fixture; no external performance claim",
        calibration_count: length(calibration_rows),
        heldout_count: length(heldout_rows),
        prompt_ids: Map.keys(@prompts) |> Enum.sort()
      },
      calibration: %{
        method: "one-bin held-out empirical correctness",
        fitted_count: length(calibration_records),
        estimated_probability_correct: calibrator.estimates[0].probability_correct,
        split_overlap: false
      },
      usage: total_usage(calibration_records ++ heldout_records),
      raw_report: raw_report,
      calibrated_report: calibrated_report,
      rows: Enum.map(calibration_records ++ heldout_records, &Map.drop(&1, [:prediction]))
    }

    assert_safe!(artifact, api_key)
  end

  defp evaluate(rows, prompt_id, model, api_key, concurrency) do
    prompt = Map.fetch!(@prompts, prompt_id)

    signature =
      DSEx.signature("text -> label: enum[billing,technical,account,cancellation]", prompt)

    program =
      DSEx.predict(signature,
        lm: DSEx.req_llm(model, api_key: api_key, temperature: 0, max_tokens: 64),
        adapter: DSEx.Adapter.JSON,
        config: [native_json_schema: true]
      )

    adapter =
      ConfidenceAdapter.new(program,
        field: :label,
        expected_field: :answer,
        enum: @labels,
        max_concurrency: concurrency,
        timeout: 60_000
      )

    examples =
      Enum.map(rows, fn row ->
        DSEx.example(text: row["text"], answer: row["label"]) |> DSEx.with_inputs(:text)
      end)

    result = Evaluation.evaluate(adapter, examples, Candidate.from_program(program))

    Enum.zip([rows, result.outputs, result.objective_scores])
    |> Enum.map(fn {row, prediction, objectives} ->
      raw_confidence = Map.fetch!(objectives, :raw_confidence)
      accuracy = Map.fetch!(objectives, :accuracy)
      req = prediction.metadata.req_llm

      unless req.provider == "openai" and req.api == "chat_completions" and req.logprobs != [] do
        raise ArgumentError, "confidence calibration row lacks proven OpenAI Chat logprobs"
      end

      %{
        id: "#{prompt_id}:#{row["id"]}",
        source_id: row["id"],
        split: row["split"],
        prompt: prompt_id,
        expected: row["label"],
        predicted: DSEx.Prediction.get(prediction, :label),
        raw_confidence: raw_confidence,
        correct?: accuracy == 1.0,
        provider: req.provider,
        api: req.api,
        effective_model: req.model,
        usage: req.usage,
        prediction: prediction
      }
    end)
  end

  defp load_rows!(path) do
    rows = path |> File.stream!() |> Enum.map(&(&1 |> Jason.decode!()))
    ids = Enum.map(rows, & &1["id"])

    unless length(rows) == 24 and length(Enum.uniq(ids)) == 24 and
             Enum.all?(rows, &(&1["label"] in @labels)) and
             Enum.count(rows, &(&1["split"] == "calibration")) == 12 and
             Enum.count(rows, &(&1["split"] == "heldout")) == 12 do
      raise ArgumentError, "confidence calibration data contract mismatch"
    end

    rows
  end

  defp assert_safe!(artifact, api_key) do
    encoded = Jason.encode!(artifact)

    if String.contains?(encoded, api_key) do
      raise ArgumentError, "confidence calibration artifact retained its API key"
    end

    artifact
  end

  defp total_usage(records) do
    Enum.reduce(records, %{input_tokens: 0, output_tokens: 0, total_cost_usd: 0.0}, fn record,
                                                                                       acc ->
      usage = record.usage || %{}

      %{
        input_tokens: acc.input_tokens + map_number(usage, :input_tokens),
        output_tokens: acc.output_tokens + map_number(usage, :output_tokens),
        total_cost_usd: acc.total_cost_usd + map_number(usage, :total_cost)
      }
    end)
  end

  defp map_number(map, key) do
    case Map.get(map, key, Map.get(map, Atom.to_string(key), 0)) do
      value when is_number(value) -> value
      _ -> 0
    end
  end

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
