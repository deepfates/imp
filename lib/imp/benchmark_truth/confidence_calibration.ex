defmodule Imp.BenchmarkTruth.ConfidenceCalibration do
  @moduledoc false

  alias Imp.Confidence.Calibration
  alias Imp.Optimizer.GEPA.{Candidate, ConfidenceAdapter, Evaluation}

  @support_labels ~w(billing technical account cancellation)
  @support_prompts %{
    "minimal" => "Classify the support request into exactly one allowed label.",
    "policy" =>
      "Classify by the user's primary requested outcome. Billing covers charges and invoices; technical covers broken product behavior; account covers identity, access, and ownership; cancellation covers ending or stopping renewal. Ignore secondary details."
  }

  @trec_revision "eb1e45c1ba990fecca7cf84b67ce845edbcf49bf"
  @trec_source_hashes %{
    "train" => "9e4c8bdcaffb96ed61041bd64b564183d52793a8e91d84fc3a8646885f466ec3",
    "test" => "033f22c028c2bbba9ca682f68ffe204dc1aa6e1cf35dd6207f2d4ca67f0d0e8e"
  }
  @trec_labels ~w(
    ABBR:abb ABBR:exp
    ENTY:animal ENTY:body ENTY:color ENTY:cremat ENTY:currency ENTY:dismed
    ENTY:event ENTY:food ENTY:instru ENTY:lang ENTY:letter ENTY:other ENTY:plant
    ENTY:product ENTY:religion ENTY:sport ENTY:substance ENTY:symbol ENTY:techmeth
    ENTY:termeq ENTY:veh ENTY:word
    DESC:def DESC:desc DESC:manner DESC:reason
    HUM:gr HUM:ind HUM:title HUM:desc
    LOC:city LOC:country LOC:mount LOC:other LOC:state
    NUM:code NUM:count NUM:date NUM:dist NUM:money NUM:ord NUM:other NUM:period
    NUM:perc NUM:speed NUM:temp NUM:volsize NUM:weight
  )
  @trec_taxonomy """
  ABBR:abb abbreviation; ABBR:exp expanded form of an abbreviation.
  ENTY:animal animal; ENTY:body body organ; ENTY:color color; ENTY:cremat creative work or invention; ENTY:currency currency; ENTY:dismed disease or medicine; ENTY:event event; ENTY:food food; ENTY:instru musical instrument; ENTY:lang language; ENTY:letter letter or character; ENTY:other other entity; ENTY:plant plant; ENTY:product product; ENTY:religion religion; ENTY:sport sport; ENTY:substance element or substance; ENTY:symbol symbol or sign; ENTY:techmeth technique or method; ENTY:termeq equivalent term; ENTY:veh vehicle; ENTY:word word with a special property.
  DESC:def definition; DESC:desc description; DESC:manner manner of an action; DESC:reason reason.
  HUM:gr group or organization of people; HUM:ind individual person; HUM:title title of a person; HUM:desc description of a person.
  LOC:city city; LOC:country country; LOC:mount mountain; LOC:other other location; LOC:state state.
  NUM:code postcode or other code; NUM:count count; NUM:date date; NUM:dist distance; NUM:money price or money; NUM:ord order or rank; NUM:other other number; NUM:period duration; NUM:perc percent or fraction; NUM:speed speed; NUM:temp temperature; NUM:volsize size, area, or volume; NUM:weight weight.
  """
  @trec_prompts %{
    "taxonomy_full_v1" => """
    Classify the expected answer type of the English question using the TREC fine-label taxonomy below. Focus on the type of answer requested, not merely a topic word in the question. Return exactly one taxonomy code.

    #{@trec_taxonomy}
    """,
    "taxonomy_compact_v1" => """
    Choose exactly one TREC code for the kind of answer that would correctly answer the question. Resolve fine-grained distinctions using this codebook.

    #{@trec_taxonomy}
    """
  }

  @tasks %{
    "support_routing_v1" => %{labels: @support_labels, prompts: @support_prompts},
    "trec_fine_v1" => %{labels: @trec_labels, prompts: @trec_prompts}
  }

  def run(opts \\ []) do
    path =
      Keyword.get(opts, :data, "benchmarks/data/confidence-calibration-trec-fine.jsonl")

    model = Keyword.get(opts, :model, "openai:gpt-4.1-mini-2025-04-14")
    api_key = Keyword.fetch!(opts, :api_key)
    concurrency = Keyword.get(opts, :max_concurrency, 4)
    bins = Keyword.get(opts, :bins, 10)
    min_bin_size = Keyword.get(opts, :min_bin_size, 5)
    dataset = load_dataset!(path, opts)
    rows = dataset.rows
    calibration_rows = Enum.filter(rows, &(&1["split"] == "calibration"))
    heldout_rows = Enum.filter(rows, &(&1["split"] == "heldout"))

    calibration_records =
      evaluate_by_prompt(calibration_rows, dataset.task, model, api_key, concurrency)

    heldout_records =
      evaluate_by_prompt(heldout_rows, dataset.task, model, api_key, concurrency)

    calibrator =
      Calibration.fit_histogram(calibration_records, bins: bins, min_bin_size: min_bin_size)

    calibration = Calibration.histogram_summary(calibrator)
    raw_report = Calibration.report(heldout_records, bins: 10)

    calibrated_report =
      if Calibration.authoritative?(calibrator) do
        Calibration.evaluate_histogram(calibrator, heldout_records, bins: 10)
      end

    brier_comparison =
      if calibrated_report do
        Calibration.compare_brier(raw_report, calibrated_report)
      end

    authority = authority(dataset, calibration, raw_report, calibrated_report, brier_comparison)
    all_records = calibration_records ++ heldout_records

    artifact = %{
      schema_version: 3,
      evidence_tier:
        if(authority.passed?,
          do: "live_source_disjoint_calibration_evaluation_narrow_benchmark",
          else: "live_confidence_probe_non_authoritative"
        ),
      generated_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      model: model,
      effective_models:
        all_records |> Enum.map(& &1.effective_model) |> Enum.uniq() |> Enum.sort(),
      provider_requirement: "OpenAI Chat Completions with returned token logprobs",
      authority: authority,
      claims: %{
        provider_logprobs_observed: true,
        learned_calibration: authority.passed?,
        calibrated_brier_outcome: brier_comparison && brier_comparison.outcome,
        calibrated_brier_improved: brier_comparison && brier_comparison.improved?,
        narrow_benchmark_only: true
      },
      limitations: [
        "This 400-question public TREC subset is a narrow operational benchmark, not a deployment calibration claim",
        "Public TREC questions may have appeared in model training data; this run does not establish uncontaminated model capability",
        "Prompt drift compares disjoint source sets and is descriptive, not a paired causal estimate",
        "The empirical mapping must be refitted on representative source- and group-disjoint deployment data"
      ],
      data: %{
        path: path,
        sha256: dataset.data_sha256,
        provenance: dataset.provenance,
        task: dataset.task_id,
        calibration_count: length(calibration_rows),
        heldout_count: length(heldout_rows),
        label_count: length(dataset.task.labels),
        prompt_counts: frequencies(rows, "prompt")
      },
      calibration: calibration,
      usage: total_usage(all_records),
      raw_report: raw_report,
      calibrated_report: calibrated_report,
      brier_comparison: brier_comparison,
      rows: Enum.map(all_records, &Map.drop(&1, [:prediction]))
    }

    assert_safe!(artifact, api_key)
  end

  @doc false
  def validate_data!(path, opts \\ []) do
    _dataset = load_dataset!(path, opts)
    :ok
  end

  defp evaluate_by_prompt(rows, task, model, api_key, concurrency) do
    rows
    |> Enum.group_by(& &1["prompt"])
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(fn {prompt_id, prompt_rows} ->
      evaluate(prompt_rows, prompt_id, task, model, api_key, concurrency)
    end)
  end

  defp evaluate(rows, prompt_id, task, model, api_key, concurrency) do
    prompt = Map.fetch!(task.prompts, prompt_id)
    enum = Enum.join(task.labels, ",")
    signature = Imp.signature("text -> label: enum[#{enum}]", prompt)

    program =
      Imp.predict(signature,
        lm: Imp.req_llm(model, api_key: api_key, temperature: 0, max_tokens: 32),
        adapter: Imp.Adapter.JSON,
        config: [native_json_schema: true]
      )

    adapter =
      ConfidenceAdapter.new(program,
        field: :label,
        expected_field: :answer,
        enum: task.labels,
        max_concurrency: concurrency,
        timeout: 60_000
      )

    examples =
      Enum.map(rows, fn row ->
        Imp.example(text: row["text"], answer: row["label"]) |> Imp.with_inputs(:text)
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
        predicted: Imp.Prediction.get(prediction, :label),
        raw_confidence: raw_confidence,
        confidence_quality: confidence_quality,
        correct?: accuracy == 1.0,
        provider: req.provider,
        api: req.api,
        effective_model: req.model,
        usage: compact_usage(req.usage),
        source: %{
          dataset: row["dataset"],
          dataset_revision: row["dataset_revision"],
          file_sha256: row["source_file_sha256"],
          label: row["source_label"],
          row: row["source_row"],
          split: row["source_split"]
        },
        input_sha256: sha256(row["text"]),
        prediction: prediction
      }
    end)
  end

  defp load_dataset!(path, opts) do
    rows =
      path
      |> File.stream!()
      |> Enum.reject(&(String.trim(&1) == ""))
      |> Enum.map(&Jason.decode!/1)

    task_id = single_task_id!(rows)
    task = Map.fetch!(@tasks, task_id)
    calibration_rows = Enum.filter(rows, &(&1["split"] == "calibration"))
    heldout_rows = Enum.filter(rows, &(&1["split"] == "heldout"))
    ids = Enum.map(rows, & &1["id"])
    source_ids = Enum.map(rows, & &1["source_id"])

    valid? =
      rows != [] and calibration_rows != [] and heldout_rows != [] and unique?(ids) and
        unique?(source_ids) and Enum.all?(rows, &valid_row?(&1, task_id, task)) and
        disjoint?(calibration_rows, heldout_rows, "source_id") and
        disjoint?(calibration_rows, heldout_rows, "group_id") and
        task_contract?(task_id, rows, calibration_rows, heldout_rows)

    unless valid? do
      raise ArgumentError, "confidence calibration data contract mismatch"
    end

    data_sha256 = sha256(File.read!(path))
    provenance = verify_provenance!(task_id, path, data_sha256, rows, opts)

    %{
      rows: rows,
      task_id: task_id,
      task: task,
      data_sha256: data_sha256,
      provenance: provenance
    }
  end

  defp single_task_id!([]), do: raise(ArgumentError, "confidence calibration data is empty")

  defp single_task_id!(rows) do
    case rows |> Enum.map(&(&1["task"] || "support_routing_v1")) |> Enum.uniq() do
      [task_id] when is_map_key(@tasks, task_id) -> task_id
      _ -> raise ArgumentError, "confidence calibration data must contain one supported task"
    end
  end

  defp valid_row?(row, task_id, task) do
    (row["task"] || "support_routing_v1") == task_id and row["label"] in task.labels and
      row["split"] in ["calibration", "heldout"] and is_binary(row["id"]) and
      row["id"] != "" and is_binary(row["source_id"]) and row["source_id"] != "" and
      is_binary(row["group_id"]) and row["group_id"] != "" and is_binary(row["text"]) and
      row["text"] != "" and Map.has_key?(task.prompts, row["prompt"])
  end

  defp task_contract?("support_routing_v1", rows, calibration_rows, heldout_rows) do
    length(rows) == 24 and length(calibration_rows) == 12 and length(heldout_rows) == 12
  end

  defp task_contract?("trec_fine_v1", rows, calibration_rows, heldout_rows) do
    unique?(Enum.map(rows, & &1["group_id"])) and
      length(calibration_rows) == length(heldout_rows) and
      Enum.all?(rows, &valid_trec_source?/1)
  end

  defp valid_trec_source?(row) do
    expected_source_split = if(row["split"] == "calibration", do: "train", else: "test")
    source_split = row["source_split"]

    row["dataset"] == "CogComp/trec" and row["dataset_revision"] == @trec_revision and
      row["source_label"] == row["label"] and source_split == expected_source_split and
      row["source_file_sha256"] == @trec_source_hashes[source_split] and
      is_integer(row["source_row"]) and row["source_row"] >= 0
  end

  defp verify_provenance!("support_routing_v1", _path, _data_sha256, _rows, _opts) do
    %{
      verified?: false,
      reason: "Imp-authored narrow fixture has no external label provenance"
    }
  end

  defp verify_provenance!("trec_fine_v1", path, data_sha256, rows, opts) do
    provenance_path =
      Keyword.get(opts, :provenance) || Path.rootname(path) <> ".provenance.json"

    provenance = provenance_path |> File.read!() |> Jason.decode!()
    calibration_count = Enum.count(rows, &(&1["split"] == "calibration"))
    heldout_count = Enum.count(rows, &(&1["split"] == "heldout"))

    valid? =
      provenance["dataset"] == "CogComp/trec" and
        provenance["dataset_loader_revision"] == @trec_revision and
        get_in(provenance, ["labels", "ordered_values"]) == @trec_labels and
        get_in(provenance, ["output", "sha256"]) == data_sha256 and
        get_in(provenance, ["output", "calibration_count"]) == calibration_count and
        get_in(provenance, ["output", "heldout_count"]) == heldout_count and
        Enum.all?(@trec_source_hashes, fn {split, digest} ->
          get_in(provenance, ["sources", split, "sha256"]) == digest
        end)

    unless valid? do
      raise ArgumentError, "confidence calibration provenance contract mismatch"
    end

    %{
      verified?: true,
      path: provenance_path,
      sha256: sha256(File.read!(provenance_path)),
      dataset: provenance["dataset"],
      dataset_loader_revision: provenance["dataset_loader_revision"],
      homepage: provenance["homepage"],
      labels_origin: get_in(provenance, ["labels", "origin"]),
      partition_contract: provenance["partition_contract"],
      selection: provenance["selection"],
      sources: provenance["sources"]
    }
  end

  defp authority(dataset, calibration, raw_report, calibrated_report, brier_comparison) do
    gates = %{
      source_label_provenance_verified: dataset.provenance.verified?,
      evaluation_and_source_ids_unique: true,
      calibration_and_heldout_sources_disjoint: true,
      calibration_and_heldout_groups_disjoint: true,
      calibration_sample_count_at_least_100: calibration.sample_count >= 100,
      heldout_sample_count_at_least_100: raw_report.sample_count >= 100,
      calibration_has_correct_and_incorrect: mixed_balance?(calibration.class_balance),
      heldout_has_correct_and_incorrect: mixed_balance?(raw_report.class_balance),
      multiple_supported_calibration_bins: calibration.supported_bin_count >= 2,
      calibration_fit_authoritative: calibration.authoritative?,
      calibrated_heldout_report_available: not is_nil(calibrated_report),
      proper_correctness_aware_metric_compared: not is_nil(brier_comparison)
    }

    %{
      passed?: Enum.all?(Map.values(gates)),
      gates: gates,
      failed_gates:
        gates
        |> Enum.reject(fn {_gate, passed?} -> passed? end)
        |> Enum.map(&elem(&1, 0))
        |> Enum.sort()
    }
  end

  defp mixed_balance?(%{correct: correct, incorrect: incorrect}),
    do: correct > 0 and incorrect > 0

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

  defp compact_usage(usage) do
    %{
      input_tokens: map_number(usage || %{}, :input_tokens),
      output_tokens: map_number(usage || %{}, :output_tokens),
      reasoning_tokens: map_number(usage || %{}, :reasoning_tokens),
      total_cost: map_number(usage || %{}, :total_cost)
    }
  end

  defp total_usage(records) do
    Enum.reduce(
      records,
      %{input_tokens: 0, output_tokens: 0, reasoning_tokens: 0, total_cost_usd: 0.0},
      fn record, acc ->
        %{
          input_tokens: acc.input_tokens + map_number(record.usage, :input_tokens),
          output_tokens: acc.output_tokens + map_number(record.usage, :output_tokens),
          reasoning_tokens: acc.reasoning_tokens + map_number(record.usage, :reasoning_tokens),
          total_cost_usd: acc.total_cost_usd + map_number(record.usage, :total_cost)
        }
      end
    )
  end

  defp map_number(map, key) do
    case Map.get(map, key, Map.get(map, Atom.to_string(key), 0)) do
      value when is_number(value) -> value
      _ -> 0
    end
  end

  defp frequencies(rows, key) do
    rows |> Enum.frequencies_by(& &1[key]) |> Map.new()
  end

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
