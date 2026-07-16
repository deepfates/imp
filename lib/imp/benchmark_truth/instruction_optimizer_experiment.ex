defmodule Imp.BenchmarkTruth.InstructionOptimizerExperiment do
  @moduledoc false

  alias Imp.BenchmarkTruth.{ArtifactFile, InstructionOptimizerCampaign, RunContext}

  @contract_id "t1_instruction_optimizer_differential_contract"
  @optuna_version "4.9.0"
  @arms ~w(baseline bootstrap_few_shot mipro_v2 simba)
  @python_names %{
    "baseline" => "baseline",
    "bootstrap_few_shot" => "BootstrapFewShot",
    "mipro_v2" => "MIPROv2",
    "simba" => "SIMBA"
  }
  @imp_names %{
    "baseline" => :baseline,
    "bootstrap_few_shot" => :bootstrap_few_shot,
    "mipro_v2" => :mipro_v2,
    "simba" => :simba
  }
  @splits ~w(train dev test)

  def validate_manifest!(source, opts \\ []) do
    {raw, path} = read_manifest!(source, opts)
    require!(raw["schema_version"] == 1, "manifest schema_version must be 1")
    family = string!(raw["family"], "family")

    require!(
      family == "AIMEBench",
      "one-seed instruction optimizer experiments support AIMEBench only"
    )

    normalized = %{
      "schema_version" => 1,
      "campaign_id" => string!(raw["campaign_id"] || raw["experiment_id"], "campaign_id"),
      "family" => family,
      "models" => models!(raw),
      "seed" => integer!(Map.get(raw, "seed", 17), "seed"),
      "arms" => arms!(raw["arms"]),
      "arm_configs" => arm_configs!(raw),
      "budget" => budget!(raw["per_arm_budget"] || raw["budget"]),
      "preflight" =>
        preflight!(raw["preflight"], raw["arms"], raw["per_arm_budget"] || raw["budget"]),
      "provider" => provider!(raw),
      "dataset" => dataset!(raw, path, family),
      "dspy_authority" => authority!(raw, opts),
      "dependency_identity" => dependency_identity!(raw),
      "source_commits" => source_commits!(raw),
      "scope" => scope(),
      "design" => design()
    }

    normalized = validate_source_pins!(normalized)
    Map.put(normalized, "manifest_sha256", digest(normalized))
  end

  def derive!(source, opts \\ []) do
    manifest = validate_manifest!(source, opts)
    context = run_context!(manifest, opts)
    check_imp_pin!(manifest, context)
    sources = Map.put(manifest["source_commits"], "imp", context.source_commits["imp"])
    identity = identity(manifest, sources)

    out =
      opts
      |> Keyword.get(:out_dir, Imp.BenchmarkTruth.Paths.runs("instruction-optimizer-experiment"))
      |> Path.expand()

    repo_root = opts |> Keyword.get(:repo_root, File.cwd!()) |> Path.expand()
    dspy_pythonpath = pinned_dspy_root!(Keyword.get(opts, :dspy_pythonpath), repo_root)

    checkpoints =
      opts
      |> Keyword.get(
        :checkpoint_dir,
        Imp.BenchmarkTruth.Paths.checkpoints("instruction-optimizer-experiment")
      )
      |> Path.expand()

    File.mkdir_p!(out)
    File.mkdir_p!(checkpoints)

    python = %{
      config: python_config(manifest, identity),
      config_path: Path.join(checkpoints, "#{slug(manifest["campaign_id"])}-dspy.config.json"),
      checkpoint_path:
        Path.join(checkpoints, "#{slug(manifest["campaign_id"])}-dspy.checkpoint.json"),
      output_path: Path.join(out, "#{slug(manifest["campaign_id"])}-dspy.json"),
      command:
        opts
        |> Keyword.get(:python, System.find_executable("python3") || "python3")
        |> executable(repo_root),
      script: Keyword.get(opts, :python_script, "scripts/dspy_instruction_optimizer_campaign.py"),
      dspy_pythonpath: dspy_pythonpath,
      env: [{"PYTHONPATH", prepend_pythonpath(dspy_pythonpath)}]
    }

    %{
      manifest: manifest,
      identity: identity,
      plan: plan(manifest, identity),
      run_context: context,
      out_dir: out,
      imp_options: imp_options(manifest, sources, context, out, checkpoints),
      python: Map.put(python, :args, python_args(python))
    }
  end

  def run(opts) do
    derived = derive!(Keyword.fetch!(opts, :manifest), opts)
    runtimes = runtimes!(Keyword.get(opts, :runtimes, [:imp, :dspy]))

    imp =
      if :imp in runtimes,
        do: run_imp!(derived, opts),
        else: artifact(Keyword.get(opts, :imp_artifact))

    dspy =
      if :dspy in runtimes,
        do: run_dspy!(derived, opts),
        else: artifact(Keyword.get(opts, :dspy_artifact))

    merged =
      if imp && dspy do
        report = merge_outputs!(derived, imp, dspy)
        path = Path.join(derived.out_dir, "instruction-optimizer-experiment-#{timestamp()}.json")
        ArtifactFile.write_run_json!(path, report, derived.run_context)
      end

    %{
      identity: derived.identity,
      imp: imp,
      dspy: dspy,
      merged: merged,
      python_config: derived.python.config_path
    }
  end

  def plan!(source, opts \\ []) do
    derived = derive!(source, opts)
    derived.plan
  end

  def merge_outputs!(derived, imp_source, dspy_source, _opts \\ []) do
    imp = artifact(imp_source) || raise ArgumentError, "Imp artifact is required"
    dspy = artifact(dspy_source) || raise ArgumentError, "DSPy artifact is required"
    verify_imp!(imp, derived)
    verify_dspy!(dspy, derived)

    %{
      "schema_version" => 1,
      "runner" => "imp-dspy-instruction-optimizer-experiment",
      "evidence_level" => "research_preflight",
      "claim_scope" => "matched one-seed AIME research preflight; not T3 effectiveness or parity",
      "identity" => derived.identity,
      "scope" => scope(),
      "design" => derived.manifest["design"],
      "comparisons_to_baseline" => comparisons(imp, dspy),
      "descriptive_dev_leaders" => %{
        "label" => "descriptive only; not a global selected winner",
        "imp" => leaders(imp_scores(imp), "dev"),
        "dspy" => leaders(dspy_scores(dspy), "dev")
      },
      "runtimes" => %{"imp" => imp, "dspy" => dspy},
      "summary" => %{
        "arms" => derived.manifest["arms"],
        "multi_seed" => false,
        "research_preflight" => true,
        "t3_complete" => false,
        "global_winner_selected" => false
      }
    }
  end

  defp read_manifest!(path, _opts) when is_binary(path) do
    expanded = Path.expand(path)

    manifest =
      expanded
      |> File.read!()
      |> Jason.decode!()

    {manifest, expanded}
  rescue
    error in [File.Error, Jason.DecodeError] ->
      reraise ArgumentError,
              [message: "invalid experiment manifest: #{Exception.message(error)}"],
              __STACKTRACE__
  end

  defp read_manifest!(map, opts) when is_map(map) do
    path =
      Keyword.get(
        opts,
        :manifest_path,
        Path.join(File.cwd!(), "instruction-optimizer-experiment.json")
      )

    {json(map), Path.expand(path)}
  end

  defp models!(raw) do
    model = raw["model"]
    bindings = Map.get(raw, "runtime_models", %{})

    if is_map(bindings) and map_size(bindings) > 0,
      do: exact_keys!(bindings, ~w(imp dspy), "runtime_models")

    case model do
      value when is_binary(value) ->
        %{
          "logical" => value,
          "imp" => string!(bindings["imp"] || value, "runtime_models.imp"),
          "dspy" => string!(bindings["dspy"] || value, "runtime_models.dspy")
        }

      %{} ->
        exact_keys!(model, ~w(logical imp dspy), "model")

        %{
          "logical" => string!(model["logical"], "model.logical"),
          "imp" => string!(model["imp"], "model.imp"),
          "dspy" => string!(model["dspy"], "model.dspy")
        }

      _ ->
        raise ArgumentError, "model must be a string or logical/imp/dspy object"
    end
  end

  defp arms!(arms) when is_list(arms) and arms != [] do
    names = Enum.map(arms, &arm_name!/1)
    require!(names == Enum.uniq(names), "arms must be unique")
    names
  end

  defp arms!(_), do: raise(ArgumentError, "arms must be a non-empty list")
  defp arm_name!(%{"name" => name}), do: arm_name!(name)
  defp arm_name!("BootstrapFewShot"), do: "bootstrap_few_shot"
  defp arm_name!("MIPROv2"), do: "mipro_v2"
  defp arm_name!("SIMBA"), do: "simba"
  defp arm_name!(name) when name in @arms, do: name
  defp arm_name!(name), do: raise(ArgumentError, "unsupported arm #{inspect(name)}")

  defp arm_configs!(raw) do
    configs = map!(Map.get(raw, "arm_configs", %{}), "arm_configs")
    requested = Enum.map(raw["arms"], &arm_name!/1)
    unknown_arms = Map.keys(configs) -- requested

    require!(
      unknown_arms == [],
      "arm_configs contains unrequested arms: #{Enum.join(unknown_arms, ", ")}"
    )

    requested
    |> Map.new(fn arm ->
      config = json(Map.get(configs, arm, %{}))
      reject_unknown_arm_keys!(arm, config)
      config = if arm == "mipro_v2", do: Map.put_new(config, "startup_trials", 10), else: config

      require!(
        arm != "mipro_v2" || config["startup_trials"] == 10,
        "mipro_v2.startup_trials must be 10"
      )

      {arm, config}
    end)
  end

  defp reject_unknown_arm_keys!(arm, config) do
    allowed =
      case arm do
        "baseline" ->
          []

        "bootstrap_few_shot" ->
          ~w(max_bootstrapped_demos)

        "mipro_v2" ->
          ~w(auto num_candidates num_trials minibatch max_bootstrapped_demos max_labeled_demos startup_trials max_errors timeout)

        "simba" ->
          ~w(bsize num_candidates max_steps max_demos demo_input_field_maxlen sampling_temperature candidate_temperature timeout)
      end

    unknown = Map.keys(config) -- allowed
    require!(unknown == [], "unsupported #{arm} config keys: #{Enum.join(unknown, ", ")}")
  end

  defp budget!(budget) do
    budget = map!(budget, "budget")
    input = integer!(budget["input_tokens"], "budget.input_tokens")
    output = integer!(budget["output_tokens"], "budget.output_tokens")

    require!(
      !Map.has_key?(budget, "tokens"),
      "budget.tokens is not an enforced ceiling; use input_tokens and output_tokens"
    )

    %{
      "requests" => integer!(budget["requests"], "budget.requests"),
      "input_tokens" => input,
      "output_tokens" => output,
      "usd" => number!(budget["usd"], "budget.usd")
    }
  end

  defp preflight!(raw, arms, raw_budget) do
    value = map!(raw, "preflight")
    limits = map!(value["split_limits"], "preflight.split_limits")
    ceiling = budget!(value["max_aggregate"])
    per_arm = budget!(raw_budget)
    arm_count = length(arms)
    runtime_count = 2

    split_limits =
      Map.new(@splits, fn split ->
        count = integer!(limits[split], "preflight.split_limits.#{split}")
        require!(count > 0, "preflight.split_limits.#{split} must be positive")
        {split, count}
      end)

    worst_case =
      Map.new(~w(requests input_tokens output_tokens usd), fn key ->
        {key, per_arm[key] * arm_count * runtime_count}
      end)

    Enum.each(worst_case, fn {key, exposure} ->
      require!(
        exposure <= ceiling[key],
        "planned two-runtime #{key} exposure #{exposure} exceeds preflight.max_aggregate #{ceiling[key]}"
      )
    end)

    %{
      "split_limits" => split_limits,
      "max_aggregate" => ceiling,
      "planned_runtime_count" => runtime_count,
      "worst_case" => worst_case,
      "network_calls" => 0
    }
  end

  defp provider!(raw) do
    provider = map!(Map.get(raw, "provider", %{}), "provider")
    pricing = map!(provider["pricing"] || raw["reservation_pricing"], "provider pricing")

    normalized = %{
      "api_key_env" =>
        string!(Map.get(provider, "api_key_env", "OPENAI_API_KEY"), "provider.api_key_env"),
      "temperature" =>
        number!(Map.get(provider, "temperature", Map.get(raw, "temperature", 1.0)), "temperature"),
      "max_output_tokens" =>
        integer!(provider["max_output_tokens"] || raw["max_output_tokens"], "max_output_tokens"),
      "input_tokens_per_byte" =>
        number!(Map.get(provider, "input_tokens_per_byte", 1), "input_tokens_per_byte"),
      "input_rate" =>
        number!(pricing["input_usd_per_million"] || pricing["input_per_million"], "input pricing"),
      "output_rate" =>
        number!(
          pricing["output_usd_per_million"] || pricing["output_per_million"],
          "output pricing"
        ),
      "kwargs" => json(map!(Map.get(provider, "kwargs", %{}), "provider.kwargs"))
    }

    require!(normalized["max_output_tokens"] > 0, "max_output_tokens must be positive")
    require!(normalized["input_tokens_per_byte"] >= 1, "input_tokens_per_byte must be at least 1")
    normalized
  end

  defp dataset!(raw, manifest_path, family) do
    dataset = map!(raw["dataset"], "dataset")
    base = Path.dirname(manifest_path)
    root = dataset["root"] || raw["dataset_root"]
    root = if root, do: expand(root, base), else: nil
    specs = Map.get(dataset, "splits", dataset)

    splits =
      Map.new(@splits, fn split ->
        spec = map!(specs[split], "dataset.#{split}")
        path = spec["path"] || (root && Path.join([root, family, split <> ".jsonl"]))
        path = expand(string!(path, "dataset.#{split}.path"), base)
        expected = sha!(spec["sha256"], "dataset.#{split}.sha256")
        actual = file_sha(path)
        require!(actual == expected, "dataset #{split} hash mismatch")
        {split, %{"path" => path, "sha256" => actual}}
      end)

    root = root || splits["train"]["path"] |> Path.dirname() |> Path.dirname()

    Enum.each(
      @splits,
      &require!(
        splits[&1]["path"] == Path.expand(Path.join([root, family, &1 <> ".jsonl"])),
        "dataset #{&1} path is incompatible with Imp"
      )
    )

    family_spec = root |> Path.join("families.json") |> File.read!() |> Jason.decode!()

    spec =
      Enum.find(family_spec["families"], &(&1["family"] == family)) ||
        raise ArgumentError, "families.json is missing #{family}"

    checksums = Map.new(splits, fn {split, value} -> {split, "sha256:" <> value["sha256"]} end)

    require!(
      spec["split_checksums"] == checksums,
      "manifest split hashes do not match families.json"
    )

    %{"root" => Path.expand(root), "splits" => splits, "checksums" => checksums}
  rescue
    error in [File.Error, Jason.DecodeError] ->
      reraise ArgumentError,
              [message: "invalid pinned dataset: #{Exception.message(error)}"],
              __STACKTRACE__
  end

  defp authority!(raw, opts) do
    registry =
      Imp.UpstreamAuthorityRegistry.load!(
        Keyword.get(opts, :authority_registry_path, Imp.UpstreamAuthorityRegistry.path())
      )

    authority = Imp.UpstreamAuthorityRegistry.authority!(registry, @contract_id)
    declared = Map.get(raw, "dspy_authority", %{})

    Enum.each(Map.take(declared, ["version", "commit", "repository", "source_hashes"]), fn {key,
                                                                                            value} ->
      require!(
        value == authority[key],
        "dspy_authority.#{key} does not match the authority registry"
      )
    end)

    authority
    |> Map.take(["project", "repository", "version", "commit", "source_hashes"])
    |> Map.put("contract_id", @contract_id)
  end

  defp validate_source_pins!(manifest) do
    authority = manifest["dspy_authority"]
    expected = authority["repository"] <> "@" <> authority["commit"]
    declared = manifest["source_commits"]["dspy"]

    require!(
      is_nil(declared) || declared == expected,
      "source_commits.dspy does not match DSPy authority"
    )

    put_in(manifest, ["source_commits", "dspy"], expected)
  end

  defp source_commits!(raw) do
    commits = map!(Map.get(raw, "source_commits", %{}), "source_commits")
    exact_keys!(commits, ~w(dspy imp), "source_commits")
    commits
  end

  defp dependency_identity!(raw) do
    dependency = map!(raw["dependency_identity"], "dependency_identity")

    require!(
      dependency == %{"optuna" => @optuna_version},
      "dependency_identity must pin optuna #{@optuna_version}"
    )

    dependency
  end

  defp design do
    %{
      "bootstrap_few_shot" => %{"dspy_max_labeled_demos" => 0},
      "mipro_v2" => %{
        "mapping" => "constructor and compile options are mapped explicitly",
        "startup_trials" => 10,
        "deviation" =>
          "DSPy uses its native Optuna TPE default; startup_trials=10 is the closest matched setting"
      },
      "test_policy" =>
        "each arm is compared with baseline on frozen test; dev leaders are descriptive only"
    }
  end

  defp run_context!(manifest, opts) do
    Keyword.get(opts, :run_context) ||
      RunContext.capture_git!(
        cwd: Keyword.get(opts, :repo_root, File.cwd!()),
        source_commits: Map.delete(manifest["source_commits"], "imp"),
        inputs: %{
          "protocol_id" => "instruction_live",
          "campaign_id" => manifest["campaign_id"],
          "manifest_sha256" => manifest["manifest_sha256"]
        }
      )
  end

  defp check_imp_pin!(manifest, context) do
    pin = manifest["source_commits"]["imp"]

    require!(
      is_nil(pin) || pin == "resolved from campaign git_sha" ||
        pin == context.source_commits["imp"],
      "source_commits.imp mismatch"
    )
  end

  defp identity(manifest, sources) do
    value = %{
      "schema_version" => 1,
      "campaign_id" => manifest["campaign_id"],
      "family" => manifest["family"],
      "models" => manifest["models"],
      "seed" => manifest["seed"],
      "arms" => manifest["arms"],
      "budget_scope" => "per_arm",
      "per_arm_budget" => manifest["budget"],
      "preflight" => manifest["preflight"],
      "dataset" => manifest["dataset"],
      "dspy_authority" => manifest["dspy_authority"],
      "dependency_identity" => manifest["dependency_identity"],
      "source_commits" => sources,
      "design" => manifest["design"],
      "manifest_sha256" => manifest["manifest_sha256"]
    }

    Map.put(value, "identity_sha256", digest(value))
  end

  defp imp_options(manifest, sources, context, out, checkpoints) do
    provider = manifest["provider"]

    [
      dataset_root: manifest["dataset"]["root"],
      campaign_id: manifest["campaign_id"],
      family: manifest["family"],
      model: manifest["models"]["imp"],
      seed: manifest["seed"],
      arms: Enum.map(manifest["arms"], &Map.fetch!(@imp_names, &1)),
      arm_configs: manifest["arm_configs"],
      budget: manifest["budget"],
      pricing: %{
        "input_per_million" => provider["input_rate"],
        "output_per_million" => provider["output_rate"]
      },
      max_output_tokens: provider["max_output_tokens"],
      source_commits: sources,
      git_sha: context.code_revision,
      out_dir: Path.join(out, "imp"),
      checkpoint_dir: Path.join(checkpoints, "imp"),
      split_limits: manifest["preflight"]["split_limits"]
    ]
  end

  defp python_config(manifest, identity) do
    provider = manifest["provider"]
    authority = manifest["dspy_authority"]

    %{
      "schema_version" => 1,
      "campaign_id" => manifest["campaign_id"],
      "family" => manifest["family"],
      "logical_model" => manifest["models"]["logical"],
      "experiment_identity_sha256" => identity["identity_sha256"],
      "design" => manifest["design"],
      "source_identity" => Map.take(authority, ["version", "commit"]),
      "dependency_identity" => manifest["dependency_identity"],
      "dataset" =>
        Map.new(manifest["dataset"]["splits"], fn {split, spec} ->
          {split, Map.take(spec, ["path", "sha256"])}
        end),
      "split_limits" => manifest["preflight"]["split_limits"],
      "provider" => %{
        "model" => manifest["models"]["dspy"],
        "api_key_env" => provider["api_key_env"],
        "kwargs" => Map.put_new(provider["kwargs"], "temperature", provider["temperature"]),
        "pricing" => %{
          "input_usd_per_million" => provider["input_rate"],
          "output_usd_per_million" => provider["output_rate"]
        },
        "reservation" => %{
          "max_output_tokens" => provider["max_output_tokens"],
          "input_tokens_per_byte" => provider["input_tokens_per_byte"],
          "input_usd_per_million" => provider["input_rate"],
          "output_usd_per_million" => provider["output_rate"]
        }
      },
      "budget_scope" => "per_arm",
      "per_arm_ceilings" => manifest["budget"],
      "seed" => manifest["seed"],
      "arms" => Enum.map(manifest["arms"], &python_arm(&1, manifest["arm_configs"][&1]))
    }
  end

  defp python_arm("baseline", _), do: %{"name" => "baseline", "config" => %{}}

  defp python_arm("bootstrap_few_shot", config),
    do: %{
      "name" => "BootstrapFewShot",
      "config" =>
        config
        |> Map.take(["max_bootstrapped_demos", "max_errors"])
        |> Map.put("max_labeled_demos", 0)
    }

  defp python_arm("mipro_v2", config) do
    constructor =
      Map.take(
        config,
        ~w(auto num_candidates max_bootstrapped_demos max_labeled_demos max_errors)
      )

    compile = Map.take(config, ~w(num_trials minibatch))
    %{"name" => "MIPROv2", "config" => %{"constructor" => constructor, "compile" => compile}}
  end

  defp python_arm("simba", config),
    do: %{
      "name" => "SIMBA",
      "config" =>
        config
        |> Map.drop(["timeout"])
        |> rename("sampling_temperature", "temperature_for_sampling")
        |> rename("candidate_temperature", "temperature_for_candidates")
    }

  defp rename(map, source, target) do
    case Map.pop(map, source) do
      {nil, map} -> map
      {value, map} -> Map.put(map, target, value)
    end
  end

  defp python_args(run),
    do: [
      run.script,
      "--config",
      run.config_path,
      "--checkpoint",
      run.checkpoint_path,
      "--out",
      run.output_path
    ]

  defp run_imp!(derived, opts) do
    case Keyword.get(opts, :imp_executor) do
      fun when is_function(fun, 1) ->
        artifact(fun.(maybe_lm(derived.imp_options, opts)))

      nil ->
        p = derived.manifest["provider"]
        env = Keyword.get(opts, :api_key_env, p["api_key_env"])
        key = System.get_env(env) || raise ArgumentError, "#{env} is required"

        lm =
          Keyword.get(opts, :lm) ||
            Imp.req_llm(derived.manifest["models"]["imp"],
              api_key: key,
              temperature: p["temperature"],
              max_tokens: p["max_output_tokens"],
              max_retries: 0
            )

        derived.imp_options
        |> Keyword.put(:lm, lm)
        |> InstructionOptimizerCampaign.run()
        |> artifact()

      _ ->
        raise ArgumentError, "imp_executor must accept one argument"
    end
  end

  defp run_dspy!(derived, opts) do
    write_pinned!(derived.python.config_path, derived.python.config)
    invocation = Map.put(derived.python, :cwd, Keyword.get(opts, :repo_root, File.cwd!()))
    executor = Keyword.get(opts, :python_executor, &system_python/1)
    require!(is_function(executor, 1), "python_executor must accept one argument")
    invocation |> executor.() |> unwrap() |> artifact()
  end

  defp system_python(run) do
    case System.cmd(run.command, run.args, cd: run.cwd, env: run.env, stderr_to_stdout: true) do
      {output, 0} -> %{path: run.output_path, stdout: output}
      {output, status} -> raise "DSPy runner failed with status #{status}:\n#{output}"
    end
  end

  defp write_pinned!(path, value) do
    File.mkdir_p!(Path.dirname(path))

    if File.exists?(path),
      do:
        require!(
          path |> File.read!() |> Jason.decode!() == value,
          "Python resume config identity mismatch"
        ),
      else: ArtifactFile.write_json!(path, value)

    path
  end

  defp verify_imp!(a, d) do
    id = a["identity"] || %{}
    expected_budget = d.imp_options |> Keyword.fetch!(:budget) |> json()

    checks = [
      a["runner"] == "imp-instruction-optimizer-campaign",
      a["evidence_level"] == "research_preflight",
      get_in(a, ["summary", "all_requested_arms_completed"]) == true,
      get_in(a, ["summary", "t3_complete"]) == false,
      id["campaign_id"] == d.identity["campaign_id"],
      id["family"] == d.identity["family"],
      id["model"] == d.identity["models"]["imp"],
      id["seed"] == d.identity["seed"],
      id["arms"] == d.identity["arms"],
      id["budget_scope"] == "per_arm",
      id["budget"] == expected_budget,
      id["arm_configs"] == Imp.Optimizer.Report.encode_term(d.manifest["arm_configs"]),
      id["split_limits"] == d.manifest["preflight"]["split_limits"],
      id["split_checksums"] == d.manifest["dataset"]["checksums"],
      id["source_commits"] == d.identity["source_commits"],
      Enum.sort(Map.keys(a["results"] || %{})) == Enum.sort(d.identity["arms"])
    ]

    require!(Enum.all?(checks), "Imp artifact identity or completion mismatch")
  end

  defp verify_dspy!(a, d) do
    expected_source = Map.drop(d.identity["dspy_authority"], ["contract_id"])
    config = sanitized(d.python.config)
    names = Enum.map(a["arms"] || [], &python_to_common(&1["name"]))

    checks = [
      a["runner"] == "python-dspy-instruction-optimizer-campaign",
      a["status"] == "complete",
      get_in(a, ["scope", "research_preflight"]) == true,
      get_in(a, ["scope", "not_t3"]) == true,
      a["campaign_id"] == d.identity["campaign_id"],
      a["budget_scope"] == "per_arm",
      a["per_arm_ceilings"] == d.identity["per_arm_budget"],
      a["source_identity"] == expected_source,
      a["dependency_identity"] == d.identity["dependency_identity"],
      a["config"] == config,
      a["config_sha256"] == digest_raw(d.python.config),
      dspy_dataset_matches?(
        a["dataset"],
        d.manifest["dataset"],
        d.manifest["preflight"]["split_limits"]
      ),
      Enum.sort(names) == Enum.sort(d.identity["arms"])
    ]

    require!(Enum.all?(checks), "DSPy artifact identity or completion mismatch")
  end

  defp comparisons(imp, dspy) do
    %{"imp" => baseline_deltas(imp_scores(imp)), "dspy" => baseline_deltas(dspy_scores(dspy))}
  end

  defp imp_scores(a),
    do:
      Map.new(a["results"], fn {arm, row} ->
        {arm, %{"dev" => row["dev"], "test" => row["test"]}}
      end)

  defp dspy_scores(a),
    do:
      Map.new(a["arms"], fn row ->
        {python_to_common(row["name"]),
         %{"dev" => get_in(row, ["dev", "score"]), "test" => get_in(row, ["test", "score"])}}
      end)

  defp baseline_deltas(scores) do
    baseline = get_in(scores, ["baseline", "test"])

    Map.new(scores, fn {arm, row} ->
      {arm, Map.put(row, "frozen_test_delta_vs_baseline", row["test"] - baseline)}
    end)
  end

  defp leaders(scores, split) do
    best = scores |> Map.values() |> Enum.map(& &1[split]) |> Enum.max()

    scores
    |> Enum.filter(fn {_arm, row} -> row[split] == best end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  defp python_to_common(name),
    do:
      Enum.find_value(@python_names, fn {common, python} -> if python == name, do: common end) ||
        raise(ArgumentError, "unknown DSPy arm #{inspect(name)}")

  defp dspy_dataset_matches?(actual, expected, limits) when is_map(actual) do
    Enum.all?(@splits, fn split ->
      actual[split]["path"] == expected["splits"][split]["path"] and
        actual[split]["sha256"] == expected["splits"][split]["sha256"] and
        actual[split]["count"] == limits[split]
    end)
  rescue
    _ -> false
  end

  defp dspy_dataset_matches?(_, _, _), do: false

  defp sanitized(config),
    do:
      update_in(
        config,
        ["provider", "kwargs"],
        &Map.new(&1, fn {k, v} ->
          {k,
           if(
             Enum.any?(~w(key token secret password), fn part ->
               String.contains?(String.downcase(k), part)
             end),
             do: "[REDACTED]",
             else: v
           )}
        end)
      )

  defp artifact(nil), do: nil
  defp artifact(%{"runner" => _} = value), do: value
  defp artifact(%{artifact: value}), do: artifact(value)
  defp artifact(%{path: path}), do: artifact(path)
  defp artifact(path) when is_binary(path), do: path |> File.read!() |> Jason.decode!()
  defp artifact(other), do: raise(ArgumentError, "invalid runtime artifact #{inspect(other)}")
  defp unwrap({:ok, value}), do: value
  defp unwrap({:error, reason}), do: raise("runtime executor failed: #{inspect(reason)}")
  defp unwrap(value), do: value

  defp maybe_lm(options, opts),
    do: if(Keyword.has_key?(opts, :lm), do: Keyword.put(options, :lm, opts[:lm]), else: options)

  defp runtimes!(items) when is_list(items),
    do:
      Enum.map(items, fn
        x when x in [:imp, "imp"] -> :imp
        x when x in [:dspy, "dspy"] -> :dspy
        x -> raise ArgumentError, "unknown runtime #{inspect(x)}"
      end)
      |> Enum.uniq()

  defp pinned_dspy_root!(nil, repo_root),
    do: pinned_dspy_root!(Path.join(repo_root, "tmp/dspy-current-target"), repo_root)

  defp pinned_dspy_root!(path, repo_root) do
    path = expand(string!(path, "dspy_pythonpath"), repo_root)

    require!(
      File.regular?(Path.join([path, "dspy", "__init__.py"])),
      "pinned DSPy source root is absent: #{path}"
    )

    path
  end

  defp prepend_pythonpath(root) do
    case System.get_env("PYTHONPATH") do
      nil -> root
      "" -> root
      current -> root <> ":" <> current
    end
  end

  defp executable(command, repo_root) do
    command = string!(command, "python")

    if Path.type(command) == :relative and String.contains?(command, "/"),
      do: Path.expand(command, repo_root),
      else: command
  end

  defp scope,
    do: %{
      "research_preflight" => true,
      "evidence_tier" => "research_preflight",
      "one_seed" => true,
      "not_t3" => true
    }

  defp plan(manifest, identity) do
    %{
      "schema_version" => 1,
      "kind" => "instruction_optimizer_preflight_plan",
      "campaign_id" => manifest["campaign_id"],
      "identity_sha256" => identity["identity_sha256"],
      "model" => manifest["models"]["logical"],
      "seed" => manifest["seed"],
      "arms" => manifest["arms"],
      "split_limits" => manifest["preflight"]["split_limits"],
      "per_arm_ceiling" => manifest["budget"],
      "planned_runtime_count" => 2,
      "worst_case_aggregate" => manifest["preflight"]["worst_case"],
      "approved_aggregate_ceiling" => manifest["preflight"]["max_aggregate"],
      "network_calls" => 0,
      "claim_scope" => "bounded held-out preflight; not T3"
    }
  end

  defp map!(value, _) when is_map(value), do: value
  defp map!(_, label), do: raise(ArgumentError, "#{label} must be an object")

  defp exact_keys!(map, expected, label) do
    require!(
      Map.keys(map) |> Enum.sort() == Enum.sort(expected),
      "#{label} keys must be exactly #{Enum.join(expected, ", ")}"
    )
  end

  defp string!(value, _) when is_binary(value) and value != "", do: value
  defp string!(_, label), do: raise(ArgumentError, "#{label} must be a non-empty string")
  defp integer!(value, _) when is_integer(value) and value >= 0, do: value
  defp integer!(_, label), do: raise(ArgumentError, "#{label} must be a non-negative integer")
  defp number!(value, _) when is_number(value) and value >= 0, do: value
  defp number!(_, label), do: raise(ArgumentError, "#{label} must be a non-negative number")
  defp require!(true, _), do: :ok
  defp require!(false, message), do: raise(ArgumentError, message)

  defp expand(path, base),
    do: if(Path.type(path) == :absolute, do: Path.expand(path), else: Path.expand(path, base))

  defp sha!("sha256:" <> sha, label), do: sha!(sha, label)

  defp sha!(sha, _) when is_binary(sha) and byte_size(sha) == 64,
    do:
      if(Regex.match?(~r/\A[0-9a-f]{64}\z/, sha),
        do: sha,
        else: raise(ArgumentError, "invalid SHA-256")
      )

  defp sha!(_, label), do: raise(ArgumentError, "#{label} must be a SHA-256")

  defp file_sha(path),
    do: path |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

  defp json(value), do: value |> Jason.encode!() |> Jason.decode!()
  defp digest(value), do: "sha256:" <> digest_raw(value)

  defp digest_raw(value),
    do: value |> canonical() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

  defp canonical(%{} = map),
    do:
      "{" <>
        (map
         |> Enum.sort_by(&elem(&1, 0))
         |> Enum.map_join(",", fn {k, v} -> Jason.encode!(k) <> ":" <> canonical(v) end)) <> "}"

  defp canonical(list) when is_list(list),
    do: "[" <> Enum.map_join(list, ",", &canonical/1) <> "]"

  defp canonical(value), do: Jason.encode!(value)
  defp slug(value), do: String.replace(value, ~r/[^A-Za-z0-9_.-]+/, "-")
  defp timestamp, do: Calendar.strftime(DateTime.utc_now(), "%Y%m%dT%H%M%SZ")
end
