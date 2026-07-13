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
    bins = Keyword.get(opts, :bins, 5)
    min_bin_size = Keyword.get(opts, :min_bin_size, 2)
    rows = load_rows!(path)
    calibration_rows = Enum.filter(rows, &(&1["split"] == "calibration"))
    heldout_rows = Enum.filter(rows, &(&1["split"] == "heldout"))

    calibration_records = evaluate_by_prompt(calibration_rows, model, api_key, concurrency)
    heldout_records = evaluate_by_prompt(heldout_rows, model, api_key, concurrency)

    calibrator =
      Calibration.fit_histogram(calibration_records, bins: bins, min_bin_size: min_bin_size)

    calibration = Calibration.histogram_summary(calibrator)
    raw_report = Calibration.report(heldout_records, bins: 10)

    calibrated_report =
      if Calibration.authoritative?(calibrator) do
        Calibration.evaluate_histogram(calibrator, heldout_records, bins: 10)
      end

    artifact = %{
      schema_version: 2,
      evidence_tier:
        if(calibration.authoritative?,
          do: "live_calibration_probe_narrow_fixture",
          else: "live_raw_confidence_probe_non_authoritative"
        ),
      generated_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      model: model,
      provider_requirement: "OpenAI Chat Completions with returned token logprobs",
      claims: %{
        provider_logprobs_observed: true,
        learned_calibration: calibration.authoritative?,
        narrow_fixture_only: true
      },
      limitations: [
        "DSEx-authored support-routing fixture; no external performance or broad calibration claim",
        "Prompt drift compares disjoint source sets and is descriptive, not a paired causal estimate",
        "A structurally authoritative fit still requires larger representative deployment data"
      ],
      data: %{
        path: path,
        sha256: sha256(File.read!(path)),
        provenance:
          "DSEx-authored ambiguous support-routing fixture; no external performance claim",
        calibration_count: length(calibration_rows),
        heldout_count: length(heldout_rows),
        prompt_ids: rows |> Enum.map(& &1["prompt"]) |> Enum.uniq() |> Enum.sort()
      },
      calibration: calibration,
      usage: total_usage(calibration_records ++ heldout_records),
      raw_report: raw_report,
      calibrated_report: calibrated_report,
      rows: Enum.map(calibration_records ++ heldout_records, &Map.drop(&1, [:prediction]))
    }

    assert_safe!(artifact, api_key)
  end

  @doc false
  def validate_data!(path) do
    _rows = load_rows!(path)
    :ok
  end

  defp evaluate_by_prompt(rows, model, api_key, concurrency) do
    rows
    |> Enum.group_by(& &1["prompt"])
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(fn {prompt_id, prompt_rows} ->
      evaluate(prompt_rows, prompt_id, model, api_key, concurrency)
    end)
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

    candidate = Candidate.from_program(program)
    result = Evaluation.evaluate(adapter, examples, candidate, capture_traces: true)
    [component] = Map.keys(candidate)
    trajectories = Map.fetch!(result.trajectories, component)

    Enum.zip([rows, result.outputs, result.objective_scores, trajectories])
    |> Enum.map(fn {row, prediction, objectives, trajectory} ->
      raw_confidence = get_in(trajectory.metric_metadata, [:confidence, :raw_confidence])
      accuracy = Map.fetch!(objectives, :accuracy)
      confidence_quality = Map.fetch!(objectives, :confidence_quality)
      req = prediction.metadata.req_llm

      unless is_number(raw_confidence) and req.provider == "openai" and
               req.api == "chat_completions" and req.logprobs != [] do
        raise ArgumentError, "confidence calibration row lacks proven OpenAI Chat logprobs"
      end

      %{
        id: row["id"],
        source_id: row["source_id"],
        group_id: row["group_id"],
        split: row["split"],
        prompt: prompt_id,
        expected: row["label"],
        predicted: DSEx.Prediction.get(prediction, :label),
        raw_confidence: raw_confidence,
        confidence_quality: confidence_quality,
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
    source_ids = Enum.map(rows, & &1["source_id"])
    calibration_rows = Enum.filter(rows, &(&1["split"] == "calibration"))
    heldout_rows = Enum.filter(rows, &(&1["split"] == "heldout"))

    unless length(rows) == 24 and unique?(ids) and unique?(source_ids) and
             Enum.all?(rows, &valid_row?/1) and length(calibration_rows) == 12 and
             length(heldout_rows) == 12 and disjoint?(calibration_rows, heldout_rows, "source_id") and
             disjoint?(calibration_rows, heldout_rows, "group_id") do
      raise ArgumentError, "confidence calibration data contract mismatch"
    end

    rows
  end

  defp valid_row?(row) do
    row["label"] in @labels and row["split"] in ["calibration", "heldout"] and
      is_binary(row["id"]) and row["id"] != "" and is_binary(row["source_id"]) and
      row["source_id"] != "" and is_binary(row["group_id"]) and row["group_id"] != "" and
      Map.has_key?(@prompts, row["prompt"])
  end

  defp unique?(values), do: length(values) == MapSet.size(MapSet.new(values))

  defp disjoint?(left, right, key) do
    left_ids = MapSet.new(left, & &1[key])
    right_ids = MapSet.new(right, & &1[key])
    MapSet.disjoint?(left_ids, right_ids)
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
