defmodule DSEx.BenchmarkTruth.RLMManifest do
  @moduledoc false

  @families ~w(s_niah browsecomp_plus oolong oolong_pairs longbench_v2_codeqa)
  @approaches ~w(direct simple_retrieval compaction rlm)
  @runtimes ~w(dsex dspy)
  @sha256 ~r/\A[0-9a-f]{64}\z/

  def load!(path, opts \\ []) do
    manifest = path |> File.read!() |> Jason.decode!()
    validate!(manifest, path, opts)
  rescue
    error in Jason.DecodeError ->
      raise ArgumentError,
            "invalid RLM campaign manifest JSON #{path}: #{Exception.message(error)}"
  end

  def validate!(manifest, path, opts \\ [])

  def validate!(manifest, path, opts) when is_map(manifest) do
    base_keys =
      ~w(schema_version campaign_id evidence_tier authorities models approaches execution datasets deviations)

    require_allowed_exact_keys!(manifest, base_keys, ["paper_protocol"], "manifest")

    require!(manifest["schema_version"] == 1, "schema_version must be 1")
    require_string!(manifest["campaign_id"], "campaign_id")

    require!(
      manifest["evidence_tier"] in ~w(t2_live_sample t3_paper_scale),
      "invalid evidence_tier"
    )

    validate_authorities!(manifest["authorities"])
    validate_models!(manifest["models"])
    validate_approaches!(manifest["approaches"])
    validate_execution!(manifest["execution"])

    validate_datasets!(
      manifest["datasets"],
      manifest["evidence_tier"],
      Keyword.get(opts, :allow_pending, false)
    )

    validate_deviations!(manifest["deviations"])
    validate_paper_protocol!(manifest["paper_protocol"])

    manifest
    |> Map.put("manifest_path", Path.expand(path))
    |> Map.put("manifest_sha256", sha256_file!(path))
  end

  def validate!(_manifest, _path, _opts),
    do: raise(ArgumentError, "RLM manifest must be a JSON object")

  def family_ids, do: @families
  def approach_ids, do: @approaches

  def pending?(manifest) do
    Enum.any?(manifest["datasets"], fn {_family, dataset} ->
      dataset["sha256"] == "ACQUIRE_AND_PIN_SHA256" or
        dataset["sample_ids"] == "ACQUIRE_AND_FREEZE_IDS"
    end)
  end

  def verify_sources!(manifest, root \\ File.cwd!()) do
    sources = manifest["authorities"]["sources"]

    Enum.each(sources, fn {name, source} ->
      path = Path.expand(source["path"], root)
      require!(File.regular?(path), "authority source #{name} is missing: #{path}")
      actual = sha256_file!(path)

      require!(
        actual == source["sha256"],
        "authority source hash mismatch for #{name}: expected #{source["sha256"]}, got #{actual}"
      )
    end)

    :ok
  end

  defp validate_authorities!(authorities) do
    require_exact_keys!(authorities, ~w(paper rlm dspy sources), "authorities")
    require_exact_keys!(authorities["paper"], ~w(arxiv), "authorities.paper")
    require_exact_keys!(authorities["rlm"], ~w(repository commit), "authorities.rlm")
    require_exact_keys!(authorities["dspy"], ~w(repository version commit), "authorities.dspy")

    require!(
      authorities["paper"]["arxiv"] == "2512.24601v3",
      "paper authority must be arXiv:2512.24601v3"
    )

    require!(
      authorities["rlm"]["commit"] == "72d6940142ddfb84ee6be573dc999a37e633e671",
      "RLM authority commit mismatch"
    )

    require!(authorities["dspy"]["version"] == "3.3.0b1", "DSPy authority version mismatch")
    require_string!(authorities["dspy"]["commit"], "authorities.dspy.commit")

    require!(
      is_map(authorities["sources"]) and map_size(authorities["sources"]) > 0,
      "authorities.sources must be non-empty"
    )

    Enum.each(authorities["sources"], fn {name, source} ->
      require_exact_keys!(source, ~w(path sha256), "authorities.sources.#{name}")
      require_string!(source["path"], "authorities.sources.#{name}.path")
      require_sha!(source["sha256"], "authorities.sources.#{name}.sha256")
    end)
  end

  defp validate_models!(models) do
    require_exact_keys!(models, ~w(root submodel compaction), "models")

    Enum.each(models, fn {role, settings} ->
      require_exact_keys!(
        settings,
        ~w(logical dsex dspy temperature reasoning max_output_tokens),
        "models.#{role}"
      )

      require_string!(settings["logical"], "models.#{role}.logical")
      require_string!(settings["dsex"], "models.#{role}.dsex")
      require_string!(settings["dspy"], "models.#{role}.dspy")
      require_string!(settings["reasoning"], "models.#{role}.reasoning")
      require!(is_number(settings["temperature"]), "models.#{role}.temperature must be numeric")

      require!(
        is_integer(settings["max_output_tokens"]) and settings["max_output_tokens"] > 0,
        "models.#{role}.max_output_tokens must be positive"
      )
    end)
  end

  defp validate_approaches!(approaches) do
    require!(
      is_map(approaches) and Map.keys(approaches) |> Enum.sort() == Enum.sort(@approaches),
      "approaches must be exactly #{Enum.join(@approaches, ", ")}"
    )

    Enum.each(approaches, fn {id, config} ->
      require_exact_keys!(config, ~w(enabled runtimes budget settings), "approaches.#{id}")
      require!(config["enabled"] == true, "approaches.#{id} must be enabled")

      require!(
        is_list(config["runtimes"]) and config["runtimes"] != [] and
          Enum.all?(config["runtimes"], &(&1 in @runtimes)),
        "approaches.#{id}.runtimes is invalid"
      )

      validate_budget!(config["budget"], "approaches.#{id}.budget")
      validate_approach_settings!(id, config["settings"])
    end)
  end

  defp validate_approach_settings!("direct", settings) do
    require_exact_keys!(settings, ~w(reservation_pricing), "approaches.direct.settings")
    validate_pricing!(settings["reservation_pricing"], "approaches.direct.settings")
  end

  defp validate_approach_settings!("simple_retrieval", settings) do
    require_exact_keys!(
      settings,
      ~w(k retriever reservation_pricing),
      "approaches.simple_retrieval.settings"
    )

    require!(
      is_integer(settings["k"]) and settings["k"] > 0,
      "simple retrieval k must be positive"
    )

    require_string!(settings["retriever"], "approaches.simple_retrieval.settings.retriever")
    validate_pricing!(settings["reservation_pricing"], "approaches.simple_retrieval.settings")
  end

  defp validate_approach_settings!("compaction", settings) do
    require_exact_keys!(
      settings,
      ~w(chunk_chars max_chunks reservation_pricing),
      "approaches.compaction.settings"
    )

    Enum.each(~w(chunk_chars max_chunks), fn key ->
      require!(
        is_integer(settings[key]) and settings[key] > 0,
        "compaction #{key} must be positive"
      )
    end)

    validate_pricing!(settings["reservation_pricing"], "approaches.compaction.settings")
  end

  defp validate_approach_settings!("rlm", settings) do
    require_exact_keys!(
      settings,
      ~w(max_iterations max_llm_calls recursion_depth reservation_pricing),
      "approaches.rlm.settings"
    )

    Enum.each(~w(max_iterations max_llm_calls recursion_depth), fn key ->
      require!(is_integer(settings[key]) and settings[key] > 0, "RLM #{key} must be positive")
    end)

    validate_pricing!(settings["reservation_pricing"], "approaches.rlm.settings")
  end

  defp validate_pricing!(pricing, label) do
    require_exact_keys!(
      pricing,
      ~w(input_per_million output_per_million),
      "#{label}.reservation_pricing"
    )

    Enum.each(~w(input_per_million output_per_million), fn key ->
      require!(
        is_number(pricing[key]) and pricing[key] >= 0,
        "#{label}.#{key} must be non-negative"
      )
    end)
  end

  defp validate_budget!(budget, label) do
    require_exact_keys!(budget, ~w(requests input_tokens output_tokens usd), label)

    Enum.each(~w(requests input_tokens output_tokens), fn key ->
      require!(
        is_integer(budget[key]) and budget[key] >= 0,
        "#{label}.#{key} must be a non-negative integer"
      )
    end)

    require!(is_number(budget["usd"]) and budget["usd"] >= 0, "#{label}.usd must be non-negative")
  end

  defp validate_execution!(execution) do
    require_exact_keys!(
      execution,
      ~w(seed concurrency row_timeout_ms cancellation_grace_ms bootstrap_samples confidence),
      "execution"
    )

    Enum.each(
      ~w(seed concurrency row_timeout_ms cancellation_grace_ms bootstrap_samples),
      fn key ->
        require!(
          is_integer(execution[key]) and execution[key] > 0,
          "execution.#{key} must be positive"
        )
      end
    )

    require!(
      is_number(execution["confidence"]) and execution["confidence"] > 0 and
        execution["confidence"] < 1,
      "execution.confidence must be between zero and one"
    )
  end

  defp validate_datasets!(datasets, tier, allow_pending) do
    keys = if(is_map(datasets), do: Map.keys(datasets), else: [])

    require!(
      is_map(datasets) and keys != [] and Enum.all?(keys, &(&1 in @families)) and
        (tier == "t2_live_sample" or Enum.sort(keys) == Enum.sort(@families)),
      "T2 datasets must be a non-empty paper-family subset; T3 must contain exactly all five paper families"
    )

    Enum.each(datasets, fn {family, dataset} ->
      require_exact_keys!(
        dataset,
        ~w(path sha256 source revision split sample_count sample_seed sample_ids context_grid docs_per_instance metric),
        "datasets.#{family}"
      )

      Enum.each(
        ~w(path source revision split metric),
        &require_string!(dataset[&1], "datasets.#{family}.#{&1}")
      )

      validate_pin!(
        dataset["sha256"],
        "datasets.#{family}.sha256",
        "ACQUIRE_AND_PIN_SHA256",
        allow_pending
      )

      require!(
        is_integer(dataset["sample_count"]) and dataset["sample_count"] > 0,
        "datasets.#{family}.sample_count must be positive"
      )

      require!(
        is_integer(dataset["sample_seed"]) and dataset["sample_seed"] > 0,
        "datasets.#{family}.sample_seed must be positive"
      )

      validate_sample_ids!(dataset["sample_ids"], family, dataset["sample_count"], allow_pending)
      validate_family_protocol!(family, dataset, tier)
    end)
  end

  defp validate_family_protocol!(_family, _dataset, "t2_live_sample"), do: :ok

  defp validate_family_protocol!("s_niah", dataset, "t3_paper_scale"),
    do: require!(dataset["sample_count"] == 50, "S-NIAH requires 50 instances")

  defp validate_family_protocol!("browsecomp_plus", dataset, "t3_paper_scale") do
    require!(dataset["sample_count"] == 150, "BrowseComp+ requires 150 instances")
    require!(dataset["docs_per_instance"] == 1000, "BrowseComp+ requires exactly 1,000 documents")
  end

  defp validate_family_protocol!("oolong", dataset, "t3_paper_scale") do
    require!(dataset["sample_count"] == 50, "OOLONG requires 50 instances")
    require!(dataset["split"] == "trec_coarse", "OOLONG split must be trec_coarse")
  end

  defp validate_family_protocol!("oolong_pairs", dataset, "t3_paper_scale") do
    require!(dataset["sample_count"] == 20, "OOLONG-Pairs requires 20 queries")
    require!(dataset["split"] == "trec_coarse", "OOLONG-Pairs split must be trec_coarse")

    require!(
      dataset["context_grid"] == Enum.map(10..20, &(:math.pow(2, &1) |> round())),
      "OOLONG-Pairs context grid does not match the paper"
    )
  end

  defp validate_family_protocol!("longbench_v2_codeqa", dataset, "t3_paper_scale"),
    do: require!(dataset["sample_count"] == 50, "LongBench-v2 CodeQA requires 50 instances")

  defp validate_sample_ids!("ACQUIRE_AND_FREEZE_IDS", _family, _count, true), do: :ok

  defp validate_sample_ids!(ids, family, count, _allow_pending) do
    require!(
      is_list(ids) and length(ids) == count and Enum.all?(ids, &(is_binary(&1) and &1 != "")),
      "datasets.#{family}.sample_ids must contain exactly #{count} IDs"
    )

    require!(length(Enum.uniq(ids)) == count, "datasets.#{family}.sample_ids contains duplicates")
  end

  defp validate_pin!(pending, _label, pending, true), do: :ok
  defp validate_pin!(value, label, _pending, _allow_pending), do: require_sha!(value, label)

  defp validate_deviations!(deviations) do
    require!(is_list(deviations), "deviations must be a list")

    Enum.each(deviations, fn deviation ->
      require_exact_keys!(
        deviation,
        ~w(id scope paper_behavior implementation impact),
        "deviation"
      )

      Enum.each(
        ~w(id scope paper_behavior implementation impact),
        &require_string!(deviation[&1], "deviation.#{&1}")
      )
    end)
  end

  defp validate_paper_protocol!(nil), do: :ok

  defp validate_paper_protocol!(protocol) when is_map(protocol) do
    require_exact_keys!(
      protocol,
      ~w(reference_runtime reference_commit model_method_matrix dataset_selection compaction max_llm_calls_scope provider_call_accounting cache reasoning_profiles runtime_matrix),
      "paper_protocol"
    )
  end

  defp validate_paper_protocol!(_),
    do: raise(ArgumentError, "invalid RLM manifest: paper_protocol must be an object")

  defp require_sha!(value, label),
    do:
      require!(
        is_binary(value) and Regex.match?(@sha256, value),
        "#{label} must be a lowercase SHA-256"
      )

  defp require_string!(value, label),
    do:
      require!(
        is_binary(value) and String.trim(value) != "",
        "#{label} must be a non-empty string"
      )

  defp require_exact_keys!(map, keys, label) when is_map(map) do
    actual = Map.keys(map) |> Enum.sort()
    expected = Enum.sort(keys)

    require!(
      actual == expected,
      "#{label} keys mismatch: expected #{inspect(expected)}, got #{inspect(actual)}"
    )
  end

  defp require_exact_keys!(_map, _keys, label),
    do: raise(ArgumentError, "#{label} must be an object")

  defp require_allowed_exact_keys!(map, required, optional, label) when is_map(map) do
    actual = Map.keys(map) |> Enum.sort()
    required = Enum.sort(required)
    allowed = Enum.sort(required ++ optional)

    require!(
      actual == required or actual == allowed,
      "#{label} keys mismatch: expected #{inspect(required)} with optional #{inspect(optional)}, got #{inspect(actual)}"
    )
  end

  defp require!(true, _message), do: :ok
  defp require!(false, message), do: raise(ArgumentError, "invalid RLM manifest: #{message}")

  defp sha256_file!(path),
    do: path |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
end
