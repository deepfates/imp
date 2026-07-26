defmodule MatchedInstructionOptimizersTREC.Contract do
  @moduledoc false

  @schema_version 2
  @runtime_count 2
  @runtimes ~w(imp upstream)
  @arms ~w(baseline gepa mipro_v2)
  @routes ~w(K11 K47)
  @sha256 ~r/\A[0-9a-f]{64}\z/

  def load!(path) when is_binary(path) do
    expanded = Path.expand(path)

    expanded
    |> File.read!()
    |> Jason.decode!()
    |> validate!(expanded)
  rescue
    error in [File.Error, Jason.DecodeError] ->
      reraise ArgumentError,
              [
                message:
                  "invalid instruction-optimizer diagnostic manifest: #{Exception.message(error)}"
              ],
              __STACKTRACE__
  end

  def load_optimization!(path) when is_binary(path) do
    expanded = Path.expand(path)

    expanded
    |> File.read!()
    |> Jason.decode!()
    |> validate!(expanded, :defer_held_out)
  end

  def validate!(manifest, path) when is_map(manifest) and is_binary(path) do
    validate!(manifest, path, :all)
  end

  def validate!(_manifest, _path), do: raise(ArgumentError, "manifest must be a JSON object")

  defp validate!(manifest, path, held_out_mode)
       when is_map(manifest) and is_binary(path) and held_out_mode in [:all, :defer_held_out] do
    exact_keys!(
      manifest,
      ~w(schema_version campaign_id intent authorities dataset models seeds arms optimizer execution output_contract metrics accounting capture source_commits),
      "manifest"
    )

    require!(manifest["schema_version"] == @schema_version, "schema_version must be 2")
    require_string!(manifest["campaign_id"], "campaign_id")

    require!(
      manifest["intent"] == "bounded_local_diagnostic_not_flagship_parity_or_effectiveness",
      "diagnostic intent drift"
    )

    validate_authorities!(manifest["authorities"], Path.dirname(path))
    dataset = validate_dataset!(manifest["dataset"], Path.dirname(path), held_out_mode)
    validate_models!(manifest["models"])
    validate_seeds!(manifest["seeds"])
    require!(manifest["arms"] == @arms, "arms must be exactly baseline, gepa, mipro_v2")
    validate_optimizer!(manifest["optimizer"])
    validate_execution!(manifest["execution"])
    validate_output_contract!(manifest["output_contract"])
    validate_metrics!(manifest["metrics"])
    validate_accounting!(manifest["accounting"])
    validate_capture!(manifest["capture"])
    validate_source_commits!(manifest["source_commits"])

    manifest
    |> Map.put("dataset", dataset)
    |> Map.put("manifest_path", Path.expand(path))
    |> Map.put("manifest_sha256", sha256_file(path))
  end

  def plan!(path) do
    manifest = load!(path)
    counts = split_counts(manifest)

    per_seed_runtime =
      Map.new(@arms, fn arm ->
        ceiling = manifest["execution"]["call_ceilings"][arm]
        {arm, call_row(ceiling["task_logical"], ceiling["optimizer_logical"])}
      end)

    calls_per_seed_runtime =
      per_seed_runtime |> Map.values() |> Enum.map(& &1["total_calls"]) |> Enum.sum()

    seed_count = length(manifest["seeds"])
    total_calls = calls_per_seed_runtime * seed_count * @runtime_count

    task_calls =
      per_seed_runtime
      |> Map.values()
      |> Enum.map(& &1["task_calls"])
      |> Enum.sum()
      |> Kernel.*(seed_count * @runtime_count)

    optimizer_calls = total_calls - task_calls

    request = manifest["execution"]["request"]

    %{
      "schema_version" => 2,
      "kind" => "matched_local_instruction_optimizer_diagnostic_plan",
      "campaign_id" => manifest["campaign_id"],
      "manifest_sha256" => manifest["manifest_sha256"],
      "network_calls" => 0,
      "models_started" => 0,
      "downloads" => 0,
      "runtimes" => @runtimes,
      "seeds" => manifest["seeds"],
      "arms" => manifest["arms"],
      "split_counts" => %{
        "train" => counts.train,
        "selection" => counts.selection,
        "held_out" => counts.held_out
      },
      "per_seed_per_runtime" => per_seed_runtime,
      "worst_case" => %{
        "task_calls" => task_calls,
        "optimizer_calls" => optimizer_calls,
        "total_calls" => total_calls,
        "input_tokens" =>
          task_calls * request["task"]["max_input_tokens"] +
            optimizer_calls * request["optimizer"]["max_input_tokens"],
        "output_tokens" =>
          task_calls * request["task"]["max_tokens"] +
            optimizer_calls * request["optimizer"]["max_tokens"],
        "usd" => 0.0
      },
      "runtime_configs" => runtime_configs(manifest, per_seed_runtime),
      "claim_boundary" =>
        "bounded local diagnostic only; not flagship parity, general effectiveness, or BEAM superiority"
    }
  end

  @doc false
  def parse_route(value) when is_binary(value) do
    case Regex.run(
           ~r/\A\s*\[\[ ## route ## \]\]\s*\n(K11|K47)\s*\n\s*\[\[ ## completed ## \]\]\s*\z/,
           value,
           capture: :all_but_first
         ) do
      [route] -> {:ok, route}
      _ -> {:error, :invalid_exact_chat_marker_envelope}
    end
  end

  def parse_route(%{"route" => route} = value) when map_size(value) == 1 and route in @routes,
    do: {:ok, route}

  def parse_route(%{route: route} = value) when map_size(value) == 1 and route in @routes,
    do: {:ok, route}

  def parse_route(%{"route" => route} = value) when map_size(value) == 1 and is_binary(route),
    do: {:error, {:invalid_route, route}}

  def parse_route(%{route: route} = value) when map_size(value) == 1 and is_binary(route),
    do: {:error, {:invalid_route, route}}

  def parse_route(_), do: {:error, :invalid_exact_route_envelope}

  defp validate_authorities!(value, base) do
    exact_keys!(value, ~w(dspy gepa), "authorities")

    validate_authority!(
      value["dspy"],
      "3.2.1",
      "29448ae12756abdd14bd8796c819247ebb83673c",
      "authorities.dspy",
      base
    )

    validate_authority!(
      value["gepa"],
      "0.1.4",
      "8b0ce6cd99a234f6b74daf37558a2ac0ce18f975",
      "authorities.gepa",
      base
    )
  end

  defp validate_authority!(value, version, commit, label, base) do
    exact_keys!(value, ~w(repository version commit source_manifest), label)
    require!(value["version"] == version, "#{label}.version drift")
    require!(value["commit"] == commit, "#{label}.commit drift")
    require_string!(value["repository"], "#{label}.repository")
    source_path = resolve_path!(value["source_manifest"], base, "#{label}.source_manifest")
    source = source_path |> File.read!() |> Jason.decode!()
    require!(source["commit"] == commit, "#{label}.source_manifest commit drift")
  end

  defp validate_dataset!(value, base, held_out_mode) do
    exact_keys!(
      value,
      ~w(contract_path contract_sha256 data_path data_sha256 train_path train_sha256 selection_path selection_sha256 held_out_path held_out_sha256 provenance_path provenance_sha256 revision splits selection_derivation),
      "dataset"
    )

    contract_path =
      verified_path!(value["contract_path"], value["contract_sha256"], base, "dataset.contract")

    data_path =
      if held_out_mode == :all,
        do: verified_path!(value["data_path"], value["data_sha256"], base, "dataset.data"),
        else: resolve_path!(value["data_path"], base, "dataset.data")

    train_path = verified_path!(value["train_path"], value["train_sha256"], base, "dataset.train")

    selection_path =
      verified_path!(
        value["selection_path"],
        value["selection_sha256"],
        base,
        "dataset.selection"
      )

    held_out_path =
      if held_out_mode == :all do
        verified_path!(
          value["held_out_path"],
          value["held_out_sha256"],
          base,
          "dataset.held_out"
        )
      else
        resolve_path!(value["held_out_path"], base, "dataset.held_out")
      end

    provenance_path =
      verified_path!(
        value["provenance_path"],
        value["provenance_sha256"],
        base,
        "dataset.provenance"
      )

    contract = contract_path |> File.read!() |> Jason.decode!()
    rows = if held_out_mode == :all, do: load_rows!(data_path), else: %{}
    ids = value["splits"]
    exact_keys!(ids, ~w(train_ids selection_ids held_out_ids), "diagnostic dataset splits")
    all_ids = ids["train_ids"] ++ ids["selection_ids"] ++ ids["held_out_ids"]

    require!(
      length(all_ids) == 80 and length(Enum.uniq(all_ids)) == 80,
      "dataset split IDs must be 20/20/40 and disjoint"
    )

    if held_out_mode == :all do
      require!(
        Enum.all?(all_ids, &Map.has_key?(rows, &1)),
        "dataset contract references an unknown source_id"
      )
    end

    require!(contract["source"]["revision"] == value["revision"], "dataset revision drift")

    require!(
      value["selection_derivation"] ==
        "retain_v1_six_then_lexicographic_unused_calibration_ids_per_route_to_10_each_no_heldout",
      "selection derivation drift"
    )

    split_specs =
      [
        {"train", train_path, ids["train_ids"]},
        {"selection", selection_path, ids["selection_ids"]}
      ] ++
        if(held_out_mode == :all,
          do: [{"held_out", held_out_path, ids["held_out_ids"]}],
          else: []
        )

    for {label, path, expected_ids} <- split_specs do
      split_rows = load_rows_in_order!(path)

      require!(
        Enum.map(split_rows, &(&1["id"] || &1["source_id"])) == expected_ids,
        "dataset #{label} file IDs/order drift"
      )

      if held_out_mode == :all do
        require!(
          Enum.all?(split_rows, fn row ->
            row == Map.fetch!(rows, row["id"] || row["source_id"])
          end),
          "dataset #{label} file content drift from pinned source"
        )
      end
    end

    if held_out_mode == :all do
      validate_route_balance!(rows, ids["train_ids"], 10, "train")
      validate_route_balance!(rows, ids["selection_ids"], 10, "selection")
      validate_route_balance!(rows, ids["held_out_ids"], 20, "held_out")
      validate_selection_derivation!(rows, contract["splits"]["validation_ids"], ids)
    end

    Map.merge(value, %{
      "contract_path" => contract_path,
      "data_path" => data_path,
      "train_path" => train_path,
      "selection_path" => selection_path,
      "held_out_path" => held_out_path,
      "provenance_path" => provenance_path,
      "splits" => ids
    })
  end

  defp load_rows!(path) do
    path |> load_rows_in_order!() |> Map.new(fn row -> {row["id"] || row["source_id"], row} end)
  end

  defp load_rows_in_order!(path) do
    path
    |> File.stream!()
    |> Enum.map(fn line ->
      row = Jason.decode!(line)
      id = row["id"] || row["source_id"]
      require_string!(id, "dataset row source_id")
      row
    end)
  end

  defp validate_route_balance!(rows, ids, per_route, label) do
    counts =
      ids
      |> Enum.map(fn id ->
        rows |> Map.fetch!(id) |> Map.fetch!("label") |> String.split(":") |> hd()
      end)
      |> Enum.frequencies()

    require!(
      counts == %{"DESC" => per_route, "ENTY" => per_route},
      "#{label} route balance drift"
    )
  end

  defp validate_selection_derivation!(rows, original_validation_ids, ids) do
    train = MapSet.new(ids["train_ids"])

    derived =
      Enum.reduce(["DESC", "ENTY"], original_validation_ids, fn route, selected ->
        have =
          Enum.count(selected, fn id ->
            rows |> Map.fetch!(id) |> Map.fetch!("label") |> String.starts_with?(route <> ":")
          end)

        additions =
          rows
          |> Map.values()
          |> Enum.sort_by(& &1["id"])
          |> Enum.filter(fn row ->
            row["split"] == "calibration" and String.starts_with?(row["label"], route <> ":") and
              not MapSet.member?(train, row["id"]) and row["id"] not in selected
          end)
          |> Enum.take(10 - have)
          |> Enum.map(& &1["id"])

        selected ++ additions
      end)

    require!(
      derived == ids["selection_ids"],
      "selection derivation no longer reproduces frozen IDs"
    )
  end

  defp validate_models!(value) do
    exact_keys!(value, ~w(task optimizer), "models")
    validate_model!(value["task"], "models.task")
    validate_model!(value["optimizer"], "models.optimizer")
  end

  defp validate_model!(value, label) do
    exact_keys!(value, ~w(logical imp upstream digest local_size_bytes), label)
    Enum.each(~w(logical imp upstream), &require_string!(value[&1], "#{label}.#{&1}"))
    require_sha!(value["digest"], "#{label}.digest")

    require!(
      is_integer(value["local_size_bytes"]) and value["local_size_bytes"] > 0,
      "#{label}.local_size_bytes must be positive"
    )
  end

  defp validate_seeds!(seeds) do
    require!(
      is_list(seeds) and length(seeds) == 1 and Enum.uniq(seeds) == seeds and
        Enum.all?(seeds, &(is_integer(&1) and &1 >= 0)),
      "diagnostic seeds must contain exactly one non-negative integer"
    )
  end

  defp validate_optimizer!(value) do
    exact_keys!(value, ~w(gepa mipro_v2), "optimizer")

    exact_keys!(
      value["gepa"],
      ~w(iterations minibatch_size candidate_selection module_selection acceptance selection use_merge),
      "optimizer.gepa"
    )

    require!(value["gepa"]["iterations"] == 1, "GEPA iterations must be 1")
    require!(value["gepa"]["minibatch_size"] == 5, "GEPA minibatch_size must be 5")
    require!(value["gepa"]["candidate_selection"] == "pareto", "GEPA candidate selection drift")
    require!(value["gepa"]["module_selection"] == "round_robin", "GEPA module selection drift")
    require!(value["gepa"]["acceptance"] == "strict_improvement", "GEPA acceptance drift")
    require!(value["gepa"]["selection"] == "all_improvements", "GEPA proposal selection drift")
    require!(value["gepa"]["use_merge"] == false, "GEPA merge must remain disabled")

    exact_keys!(
      value["mipro_v2"],
      ~w(num_candidates trials minibatch max_bootstrapped_demos max_labeled_demos startup_trials),
      "optimizer.mipro_v2"
    )

    require!(value["mipro_v2"]["num_candidates"] == 2, "MIPRO num_candidates must be 2")
    require!(value["mipro_v2"]["trials"] == 1, "MIPRO trials must be 1")
    require!(value["mipro_v2"]["minibatch"] == false, "MIPRO minibatch must be false")

    require!(
      value["mipro_v2"]["max_bootstrapped_demos"] == 0 and
        value["mipro_v2"]["max_labeled_demos"] == 0,
      "MIPRO must remain zero-shot"
    )

    require!(value["mipro_v2"]["startup_trials"] == 10, "MIPRO startup_trials must be 10")
  end

  defp validate_execution!(value) do
    exact_keys!(
      value,
      ~w(concurrency cache retry max_retries json_fallback fallbacks data_collection route_guard cost_guard request call_ceilings),
      "execution"
    )

    require!(value["concurrency"] == 1, "execution.concurrency must be 1")
    require!(value["cache"] == false, "execution.cache must be false")

    require!(
      value["retry"] == false and value["max_retries"] == 0,
      "execution retries must be disabled"
    )

    require!(
      value["json_fallback"] == false and value["fallbacks"] == false,
      "execution fallbacks must be disabled"
    )

    require!(
      value["data_collection"] == "local_only",
      "execution.data_collection must be local_only"
    )

    require!(value["route_guard"] == "exact_configured_local_model", "route guard drift")

    require!(
      value["cost_guard"] == "local_non_billable_no_external_spend",
      "cost guard drift"
    )

    exact_keys!(value["request"], ~w(task optimizer), "execution.request")
    validate_request!(value["request"]["task"], 0.0, 64, "execution.request.task")
    validate_request!(value["request"]["optimizer"], 1.0, 512, "execution.request.optimizer")
    validate_call_ceilings!(value["call_ceilings"])
  end

  defp validate_request!(value, temperature, max_tokens, label) do
    exact_keys!(value, ~w(temperature max_tokens max_input_tokens), label)
    require!(value["temperature"] == temperature, "#{label}.temperature drift")
    require!(value["max_tokens"] == max_tokens, "#{label}.max_tokens drift")

    require!(
      is_integer(value["max_input_tokens"]) and value["max_input_tokens"] > 0,
      "#{label}.max_input_tokens must be positive"
    )
  end

  defp validate_call_ceilings!(value) do
    exact_keys!(value, @arms, "execution.call_ceilings")

    expected = %{
      "baseline" => %{
        "task_logical" => 60,
        "optimizer_logical" => 0,
        "transports" => 60,
        "total_logical" => 60
      },
      "gepa" => %{
        "task_logical" => 110,
        "optimizer_logical" => 1,
        "transports" => 111,
        "total_logical" => 111
      },
      "mipro_v2" => %{
        "task_logical" => 100,
        "optimizer_logical" => 14,
        "transports" => 114,
        "total_logical" => 114
      }
    }

    require!(value == expected, "execution call ceilings drift")
  end

  defp validate_output_contract!(value) do
    exact_keys!(
      value,
      ~w(field routes envelope additional_properties normalization),
      "output_contract"
    )

    require!(
      value["field"] == "route" and value["routes"] == @routes,
      "output route contract drift"
    )

    require!(
      value["envelope"] == "dspy_chat_marker_sections",
      "output envelope must be dspy_chat_marker_sections"
    )

    require!(
      value["additional_properties"] == false,
      "output additional properties must be rejected"
    )

    require!(value["normalization"] == "none", "output normalization must remain disabled")
  end

  defp validate_metrics!(value) do
    exact_keys!(value, ~w(selection held_out uncertainty), "metrics")
    require!(value["selection"] == ~w(accuracy macro_f1), "selection metrics drift")
    require!(value["held_out"] == ~w(accuracy macro_f1 parse_errors), "held-out metrics drift")

    require!(
      value["uncertainty"] ==
        "paired_seed_delta_with_exact_observed_range_not_confidence_interval",
      "uncertainty contract drift"
    )
  end

  defp validate_accounting!(value) do
    exact_keys!(value, ~w(per_row fail_closed), "accounting")

    require!(
      value["per_row"] ==
        ~w(source_id expected raw_response parsed_route correct input_tokens output_tokens wall_seconds error actual_model actual_route transport_attempts cost),
      "per-row accounting drift"
    )

    require!(
      value["fail_closed"] == ~w(model route cost transport_attempt parser budget),
      "fail-closed accounting drift"
    )
  end

  defp validate_capture!(value) do
    exact_keys!(
      value,
      ~w(rendered_messages adapter runtime arm seed phase candidate_id),
      "capture"
    )

    require!(
      Enum.all?(value, fn {_key, enabled} -> enabled == true end),
      "all capture fields must remain enabled"
    )
  end

  defp validate_source_commits!(value) do
    exact_keys!(value, ~w(imp dspy gepa), "source_commits")

    require!(
      value["imp"] == "resolved from clean launch git_sha",
      "Imp source must bind at launch"
    )

    require!(
      String.ends_with?(value["dspy"], "@29448ae12756abdd14bd8796c819247ebb83673c"),
      "DSPy source commit drift"
    )

    require!(
      String.ends_with?(value["gepa"], "@8b0ce6cd99a234f6b74daf37558a2ac0ce18f975"),
      "GEPA source commit drift"
    )
  end

  defp runtime_configs(manifest, arm_calls) do
    Map.new(@runtimes, fn runtime ->
      {runtime,
       %{
         "task_model" => manifest["models"]["task"][runtime_model_key(runtime)],
         "optimizer_model" => manifest["models"]["optimizer"][runtime_model_key(runtime)],
         "model_digests" => %{
           "task" => manifest["models"]["task"]["digest"],
           "optimizer" => manifest["models"]["optimizer"]["digest"]
         },
         "seeds" => manifest["seeds"],
         "arms" => manifest["arms"],
         "arm_call_ceilings" => arm_calls,
         "execution" => manifest["execution"],
         "output_contract" => manifest["output_contract"],
         "capture" => manifest["capture"],
         "adapter_rendering" =>
           "matched_dspy_chat_adapter_markers_json_fallback_disabled_captured_exactly"
       }}
    end)
  end

  defp runtime_model_key("imp"), do: "imp"
  defp runtime_model_key("upstream"), do: "upstream"

  defp split_counts(manifest) do
    ids = manifest["dataset"]["splits"]

    %{
      train: length(ids["train_ids"]),
      selection: length(ids["selection_ids"]),
      held_out: length(ids["held_out_ids"])
    }
  end

  defp call_row(task, optimizer),
    do: %{"task_calls" => task, "optimizer_calls" => optimizer, "total_calls" => task + optimizer}

  defp verified_path!(path, sha, base, label) do
    require_string!(path, "#{label}_path")
    require_sha!(sha, "#{label}_sha256")

    resolved =
      if Path.type(path) == :absolute, do: Path.expand(path), else: Path.expand(path, base)

    require!(File.regular?(resolved), "#{label} file is missing")
    require!(sha256_file(resolved) == sha, "#{label} SHA-256 drift")
    resolved
  end

  defp resolve_path!(path, base, label) do
    require_string!(path, label)

    resolved =
      if Path.type(path) == :absolute, do: Path.expand(path), else: Path.expand(path, base)

    require!(File.regular?(resolved), "#{label} file is missing")
    resolved
  end

  defp exact_keys!(value, keys, label) when is_map(value) do
    require!(
      Map.keys(value) |> Enum.sort() == Enum.sort(keys),
      "#{label} keys must be exactly #{Enum.join(keys, ", ")}"
    )
  end

  defp exact_keys!(_, _keys, label), do: raise(ArgumentError, "#{label} must be an object")
  defp require_string!(value, _label) when is_binary(value) and value != "", do: :ok
  defp require_string!(_, label), do: raise(ArgumentError, "#{label} must be a non-empty string")

  defp require_sha!(value, label) when is_binary(value) do
    if Regex.match?(@sha256, value),
      do: :ok,
      else: raise(ArgumentError, "#{label} must be a lowercase SHA-256")
  end

  defp require_sha!(_, label), do: raise(ArgumentError, "#{label} must be a lowercase SHA-256")
  defp require!(true, _message), do: :ok
  defp require!(false, message), do: raise(ArgumentError, message)

  defp sha256_file(path),
    do: path |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
end
