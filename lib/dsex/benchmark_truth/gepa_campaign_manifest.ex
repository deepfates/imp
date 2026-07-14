defmodule DSEx.BenchmarkTruth.GepaCampaignManifest do
  @moduledoc false

  @families DSEx.BenchmarkTruth.GepaReplicationContract.required_families()
  @sha256 ~r/\A[0-9a-f]{64}\z/
  @manifest_only_error "--manifest cannot be combined with scientific or output CLI overrides"

  def load!(path) do
    expanded_path = Path.expand(path)
    manifest = expanded_path |> File.read!() |> Jason.decode!()

    manifest
    |> validate!(expanded_path)
    |> verify_dataset!()
  rescue
    error in Jason.DecodeError ->
      raise ArgumentError,
            "invalid GEPA campaign manifest JSON #{path}: #{Exception.message(error)}"
  end

  def validate!(manifest, path) when is_map(manifest) do
    require_exact_keys!(
      manifest,
      ~w(schema_version campaign_id dataset models families optimizer execution environment request pricing budgets sharding source_commits output),
      "manifest"
    )

    require!(manifest["schema_version"] == 1, "schema_version must be 1")

    require!(
      is_binary(manifest["campaign_id"]) and
        Regex.match?(~r/\A[a-z0-9][a-z0-9._-]*\z/, manifest["campaign_id"]),
      "campaign_id must be a lowercase stable identifier"
    )

    validate_dataset!(manifest["dataset"])
    validate_models!(manifest["models"])
    validate_families!(manifest["families"])
    validate_optimizer!(manifest["optimizer"])
    validate_execution!(manifest["execution"])
    validate_environment!(manifest["environment"])
    validate_request!(manifest["request"])
    validate_pricing!(manifest["pricing"])
    validate_budgets!(manifest["budgets"], manifest["families"])
    validate_sharding!(manifest["sharding"], manifest["families"])
    validate_source_commits!(manifest["source_commits"], manifest["dataset"])
    validate_output!(manifest["output"])

    manifest
    |> Map.put("manifest_path", Path.expand(path))
    |> Map.put("manifest_sha256", sha256_file!(path))
  end

  def validate!(_manifest, _path),
    do: raise(ArgumentError, "GEPA campaign manifest must be a JSON object")

  def task_options!(manifest, cli_opts) do
    overrides = Keyword.drop(cli_opts, [:manifest, :plan, :shard])
    validate_shard_selector!(manifest, Keyword.get(cli_opts, :shard))

    require!(
      overrides == [],
      "#{@manifest_only_error}: #{format_flags(overrides)}"
    )

    %{
      campaign_id: manifest["campaign_id"],
      dataset_root: manifest["dataset"]["resolved_root"],
      model: manifest["models"]["task"],
      reflection_model: manifest["models"]["reflection"],
      judge_model: manifest["models"]["judge"],
      families: manifest["families"],
      seeds: manifest["optimizer"]["seeds"],
      generations: generation_policy(manifest["optimizer"]["generations"]),
      max_concurrency: manifest["execution"]["max_concurrency"],
      api_key_env: manifest["request"]["api_key_env"],
      temperature: manifest["request"]["temperature"],
      max_tokens: manifest["request"]["max_tokens"],
      optimizer_timeout_ms: manifest["request"]["optimizer_timeout_ms"],
      max_retries: manifest["request"]["max_retries"],
      pricing_source: manifest["pricing"]["source"],
      dspy_source: manifest["source_commits"]["dspy"],
      gepa_artifact_source: manifest["source_commits"]["gepa_artifact"],
      out: manifest["output"]["resolved_out_dir"],
      checkpoint_dir: manifest["output"]["resolved_checkpoint_dir"],
      manifest_environment: manifest["environment"],
      budgets: manifest["budgets"],
      sharding: manifest["sharding"],
      plan: Keyword.get(cli_opts, :plan, false),
      shard: Keyword.get(cli_opts, :shard),
      manifest_identity: %{
        "path" => Path.relative_to_cwd(manifest["manifest_path"]),
        "sha256" => manifest["manifest_sha256"]
      }
    }
  end

  defp validate_dataset!(dataset) do
    require_exact_keys!(
      dataset,
      ~w(root families_manifest_sha256 scope provenance),
      "dataset"
    )

    require_string!(dataset["root"], "dataset.root")
    require_sha!(dataset["families_manifest_sha256"], "dataset.families_manifest_sha256")
    require!(dataset["scope"] == "full", "dataset.scope must be full")
    require_exact_keys!(dataset["provenance"], ~w(repository commit), "dataset.provenance")
    require_string!(dataset["provenance"]["repository"], "dataset.provenance.repository")
    require_commit!(dataset["provenance"]["commit"], "dataset.provenance.commit")
  end

  defp validate_models!(models) do
    require_exact_keys!(models, ~w(task reflection judge), "models")

    Enum.each(models, fn {role, model} ->
      require!(
        is_binary(model) and
          Regex.match?(~r/\A[a-z0-9_]+:[A-Za-z0-9._-]+-\d{4}-\d{2}-\d{2}\z/, model),
        "models.#{role} must be a provider-qualified, dated model identifier"
      )
    end)
  end

  defp validate_families!(families) do
    require!(
      is_list(families) and families == @families,
      "families must be exactly #{Enum.join(@families, ", ")} in canonical order"
    )
  end

  defp validate_optimizer!(optimizer) do
    require_exact_keys!(optimizer, ~w(seeds generations metric_call_budgets), "optimizer")

    require!(
      is_list(optimizer["seeds"]) and optimizer["seeds"] != [] and
        Enum.all?(optimizer["seeds"], &(is_integer(&1) and &1 >= 0)) and
        Enum.uniq(optimizer["seeds"]) == optimizer["seeds"],
      "optimizer.seeds must be a non-empty unique list of non-negative integers"
    )

    generations = optimizer["generations"]

    require!(
      generations == "metric_budget" or (is_integer(generations) and generations > 0),
      "optimizer.generations must be metric_budget or a positive integer"
    )

    budgets = optimizer["metric_call_budgets"]
    require_exact_keys!(budgets, @families, "optimizer.metric_call_budgets")

    Enum.each(budgets, fn {family, budget} ->
      require!(
        is_integer(budget) and budget > 0,
        "optimizer.metric_call_budgets.#{family} must be positive"
      )
    end)
  end

  defp validate_execution!(execution) do
    require_exact_keys!(execution, ~w(max_concurrency), "execution")

    require!(
      is_integer(execution["max_concurrency"]) and execution["max_concurrency"] > 0,
      "execution.max_concurrency must be positive"
    )
  end

  defp validate_environment!(environment) do
    require_exact_keys!(
      environment,
      ~w(hover_upstream_bm25 ifbench_upstream_descriptions python_env gepa_root_env),
      "environment"
    )

    require!(
      environment["hover_upstream_bm25"] == true,
      "environment.hover_upstream_bm25 must be true"
    )

    require!(
      environment["ifbench_upstream_descriptions"] == true,
      "environment.ifbench_upstream_descriptions must be true"
    )

    require_string!(environment["python_env"], "environment.python_env")
    require_string!(environment["gepa_root_env"], "environment.gepa_root_env")
  end

  defp validate_request!(request) do
    require_exact_keys!(
      request,
      ~w(provider api_key_env temperature max_tokens optimizer_timeout_ms max_retries),
      "request"
    )

    require!(request["provider"] == "req_llm", "request.provider must be req_llm")
    require_string!(request["api_key_env"], "request.api_key_env")
    require!(is_number(request["temperature"]), "request.temperature must be numeric")

    Enum.each(~w(max_tokens optimizer_timeout_ms), fn key ->
      require!(is_integer(request[key]) and request[key] > 0, "request.#{key} must be positive")
    end)

    require!(request["max_retries"] == 0, "request.max_retries must be 0")
  end

  defp validate_pricing!(pricing) do
    require_exact_keys!(pricing, ~w(source cost_accounting), "pricing")
    require_string!(pricing["source"], "pricing.source")

    require!(
      pricing["cost_accounting"] == "req_llm_telemetry",
      "pricing.cost_accounting must be req_llm_telemetry"
    )
  end

  defp validate_budgets!(budgets, families) do
    require_exact_keys!(budgets, ~w(aggregate per_shard reservation_pricing), "budgets")
    validate_budget_limits!(budgets["aggregate"], "budgets.aggregate")

    require_exact_keys!(budgets["per_shard"], families, "budgets.per_shard")

    Enum.each(families, fn family ->
      validate_budget_limits!(budgets["per_shard"][family], "budgets.per_shard.#{family}")
    end)

    pricing = budgets["reservation_pricing"]

    require_exact_keys!(
      pricing,
      ~w(input_per_million output_per_million),
      "budgets.reservation_pricing"
    )

    Enum.each(pricing, fn {key, value} ->
      require!(
        is_number(value) and value >= 0,
        "budgets.reservation_pricing.#{key} must be non-negative"
      )
    end)

    aggregate = budgets["aggregate"]

    Enum.each(~w(requests input_tokens output_tokens usd), fn key ->
      total =
        Enum.reduce(families, 0, fn family, acc -> acc + budgets["per_shard"][family][key] end)

      require!(
        aggregate[key] >= total,
        "budgets.aggregate.#{key} must cover all per-shard ceilings"
      )
    end)
  end

  defp validate_budget_limits!(limits, label) do
    require_exact_keys!(limits, ~w(requests input_tokens output_tokens usd), label)

    Enum.each(~w(requests input_tokens output_tokens), fn key ->
      require!(
        is_integer(limits[key]) and limits[key] >= 0,
        "#{label}.#{key} must be a non-negative integer"
      )
    end)

    require!(is_number(limits["usd"]) and limits["usd"] >= 0, "#{label}.usd must be non-negative")
  end

  defp validate_sharding!(sharding, families) do
    require_exact_keys!(sharding, ~w(immutable strategy shards), "sharding")
    require!(sharding["immutable"] == true, "sharding.immutable must be true")
    require!(sharding["strategy"] == "one_family_per_shard", "sharding.strategy is unsupported")

    shards = sharding["shards"]

    require!(
      is_list(shards) and length(shards) == length(families),
      "sharding.shards must contain one shard per family"
    )

    Enum.each(Enum.zip(shards, families), fn {shard, family} ->
      require_exact_keys!(shard, ~w(id families), "sharding.shard")
      require!(shard["id"] == "family:" <> family, "sharding shard id must be family:#{family}")
      require!(shard["families"] == [family], "sharding shard must contain only #{family}")
    end)
  end

  defp validate_shard_selector!(_manifest, nil), do: :ok

  defp validate_shard_selector!(manifest, selector) when is_binary(selector) do
    declared = Enum.map(manifest["sharding"]["shards"], & &1["id"])

    require!(selector in declared, "unknown GEPA campaign shard selector: #{selector}")
  end

  defp validate_shard_selector!(_manifest, selector),
    do: raise(ArgumentError, "unknown GEPA campaign shard selector: #{inspect(selector)}")

  defp validate_source_commits!(commits, dataset) do
    require_exact_keys!(commits, ~w(dspy gepa_artifact), "source_commits")

    Enum.each(commits, fn {name, value} ->
      require_source_pin!(value, "source_commits.#{name}")
    end)

    require!(
      String.ends_with?(commits["gepa_artifact"], dataset["provenance"]["commit"]),
      "source_commits.gepa_artifact must match dataset.provenance.commit"
    )
  end

  defp validate_output!(output) do
    require_exact_keys!(
      output,
      ~w(out_dir checkpoint_dir artifact_naming checkpoint_reuse),
      "output"
    )

    require_string!(output["out_dir"], "output.out_dir")
    require_string!(output["checkpoint_dir"], "output.checkpoint_dir")

    require!(
      output["artifact_naming"] == "timestamped_no_overwrite",
      "output.artifact_naming must be timestamped_no_overwrite"
    )

    require!(
      output["checkpoint_reuse"] == "matching_campaign_contract_only",
      "output.checkpoint_reuse must be matching_campaign_contract_only"
    )
  end

  defp verify_dataset!(manifest) do
    manifest_dir = Path.dirname(manifest["manifest_path"])
    root = Path.expand(manifest["dataset"]["root"], manifest_dir)
    families_path = Path.join(root, "families.json")

    require!(
      File.regular?(families_path),
      "dataset families manifest is missing: #{families_path}"
    )

    actual_sha = sha256_file!(families_path)

    require!(
      actual_sha == manifest["dataset"]["families_manifest_sha256"],
      "dataset families manifest hash mismatch: expected #{manifest["dataset"]["families_manifest_sha256"]}, got #{actual_sha}"
    )

    dataset_manifest = families_path |> File.read!() |> Jason.decode!()
    verify_dataset_manifest!(dataset_manifest, manifest)

    output = manifest["output"]

    manifest
    |> put_in(["dataset", "resolved_root"], root)
    |> put_in(["output", "resolved_out_dir"], Path.expand(output["out_dir"], manifest_dir))
    |> put_in(
      ["output", "resolved_checkpoint_dir"],
      Path.expand(output["checkpoint_dir"], manifest_dir)
    )
  end

  defp verify_dataset_manifest!(dataset_manifest, manifest) do
    require!(dataset_manifest["dataset_scope"] == "full", "dataset manifest scope must be full")
    require!(is_nil(dataset_manifest["max_per_split"]), "dataset manifest must be uncapped")

    provenance = dataset_manifest["upstream_source"] || %{}

    require!(
      provenance["repository"] == manifest["dataset"]["provenance"]["repository"] and
        provenance["commit"] == manifest["dataset"]["provenance"]["commit"],
      "dataset manifest provenance does not match manifest dataset.provenance"
    )

    specs = dataset_manifest["families"]

    require!(
      is_list(specs) and Enum.map(specs, & &1["family"]) == manifest["families"],
      "dataset manifest families do not match manifest families"
    )

    Enum.each(specs, fn spec ->
      family = spec["family"]

      require!(spec["dataset_scope"] == "full", "dataset family #{family} must be full")
      require!(is_nil(spec["max_per_split"]), "dataset family #{family} must be uncapped")

      require!(
        spec["metric_calls"] == manifest["optimizer"]["metric_call_budgets"][family],
        "dataset family #{family} metric-call budget does not match manifest"
      )
    end)
  end

  defp generation_policy("metric_budget"), do: :metric_budget
  defp generation_policy(value), do: value

  defp format_flags(opts) do
    opts
    |> Keyword.keys()
    |> Enum.map_join(", ", &("--" <> (&1 |> Atom.to_string() |> String.replace("_", "-"))))
  end

  defp require_exact_keys!(map, keys, label) when is_map(map) do
    actual = Map.keys(map) |> Enum.sort()
    expected = Enum.sort(keys)
    require!(actual == expected, "#{label} keys must be exactly #{Enum.join(expected, ", ")}")
  end

  defp require_exact_keys!(_map, _keys, label),
    do: raise(ArgumentError, "#{label} must be an object")

  defp require_string!(value, label),
    do:
      require!(
        is_binary(value) and String.trim(value) != "",
        "#{label} must be a non-empty string"
      )

  defp require_sha!(value, label),
    do:
      require!(
        is_binary(value) and Regex.match?(@sha256, value),
        "#{label} must be lowercase SHA-256"
      )

  defp require_commit!(value, label),
    do:
      require!(
        is_binary(value) and Regex.match?(~r/\A[0-9a-f]{40}\z/, value),
        "#{label} must be a full lowercase git commit"
      )

  defp require_source_pin!(value, label),
    do:
      require!(
        is_binary(value) and Regex.match?(~r/@[0-9a-f]{40}\z/, value),
        "#{label} must end in a full lowercase git commit"
      )

  defp require!(true, _message), do: :ok

  defp require!(false, message),
    do: raise(ArgumentError, "invalid GEPA campaign manifest: #{message}")

  defp sha256_file!(path),
    do: path |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
end
