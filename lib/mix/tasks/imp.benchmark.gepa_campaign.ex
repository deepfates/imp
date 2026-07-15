defmodule Mix.Tasks.Imp.Benchmark.GepaCampaign do
  @moduledoc """
  Produce Imp GEPA rows for the GEPA paper-replication evidence lane.

      mix imp.benchmark.gepa_campaign \\
        --manifest benchmarks/config/gepa-paper-campaign-v2.json

      mix imp.benchmark.gepa_campaign \\
        --dataset-root path/to/gepa-family-splits \\
        --campaign-id gepa-full-YYYYMMDD \\
        --model openai:gpt-4.1-mini-2025-04-14 \\
        --reflection-model openai:gpt-5 \\
        --api-key-env OPENAI_API_KEY \\
        --families AIMEBench,HotpotQABench \\
        --max-concurrency 32 \\
        --temperature 1.0 \\
        --max-tokens 16384 \\
        --pricing-source "ReqLLM usage telemetry with provider pricing metadata" \\
        --token-cost-file path/to/fallback-costs.json \\
        --dspy-source stanfordnlp/dspy@... \\
        --gepa-artifact-source gepa-ai/gepa-artifact@...

  The dataset root must contain a `families.json` file and one directory per
  required GEPA family, each with `train.jsonl`, `dev.jsonl`, and `test.jsonl`.
  The task writes `imp-gepa-rows-*.json`, which is then consumed by
  `mix imp.benchmark.gepa_replication --from-gepa-artifact ... --imp-input ...`.
  Pass `--families` to run a resumable subset; final replication still requires
  all six family rows merged into one Imp input artifact. Completed seeds are
  checkpointed under the output directory and reused when the same campaign is
  rerun with matching settings and dataset checksums.

  ReqLLM telemetry is the preferred cost source. If telemetry is unavailable,
  `--token-cost-file` accepts JSON keyed first by family and then by seed, with
  each leaf containing `usd`, `input_tokens`, and `output_tokens`. The scalar
  cost flags are valid only for a single-family, single-seed run.

  Manifest mode is immutable: `--manifest` cannot be combined with any other
  CLI option. Direct CLI invocation remains available for exploratory and partial
  runs; canonical claim-bearing research runs use the source-controlled manifest.
  `--manifest ... --plan` emits the immutable six-family shard plan and hard
  ceilings without starting the application, reading credentials, or making
  provider/network calls.
  Add `--shard family:<family>` to plan or run exactly one declared family
  shard. Without it, the canonical campaign runs all six families sequentially.
  """

  use Mix.Task

  @shortdoc "Run the Imp side of the GEPA replication campaign"
  @upstream_max_tokens 16_384
  @upstream_max_concurrency 32
  @upstream_max_retries 0
  @default_optimizer_timeout_ms 300_000

  @doc false
  def research_defaults do
    %{
      temperature: 1.0,
      max_tokens: @upstream_max_tokens,
      max_concurrency: @upstream_max_concurrency,
      optimizer_timeout_ms: @default_optimizer_timeout_ms,
      max_retries: @upstream_max_retries
    }
  end

  @impl true
  def run(args) do
    defaults = research_defaults()

    {opts, argv, invalid} =
      OptionParser.parse(args,
        strict: [
          manifest: :string,
          plan: :boolean,
          shard: :string,
          dataset_root: :string,
          campaign_id: :string,
          model: :string,
          reflection_model: :string,
          api_key_env: :string,
          out: :string,
          families: :string,
          seeds: :string,
          generations: :integer,
          pricing_source: :string,
          token_cost_file: :string,
          input_tokens: :integer,
          output_tokens: :integer,
          usd: :float,
          temperature: :float,
          max_concurrency: :integer,
          max_tokens: :integer,
          optimizer_timeout_ms: :integer,
          dspy_source: :string,
          gepa_artifact_source: :string
        ]
      )

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    opts = resolve_manifest_options!(opts, argv)

    if Keyword.get(opts, :plan, false) do
      plan =
        Imp.BenchmarkTruth.GepaCampaign.plan(
          dataset_root: fetch!(opts, :dataset_root),
          campaign_id: fetch!(opts, :campaign_id),
          model: Keyword.get(opts, :model),
          reflection_model: Keyword.get(opts, :reflection_model),
          families: Keyword.get(opts, :families),
          budgets: Keyword.get(opts, :budgets),
          sharding: Keyword.get(opts, :sharding),
          shard: Keyword.get(opts, :shard),
          checkpoint_dir:
            Keyword.get(
              opts,
              :checkpoint_dir,
              Path.join(Keyword.get(opts, :out, "benchmarks/results"), "gepa-checkpoints")
            ),
          manifest_identity: Keyword.get(opts, :manifest_identity),
          source_commits: %{
            "dspy" => Keyword.get(opts, :dspy_source),
            "gepa_artifact" => Keyword.get(opts, :gepa_artifact_source)
          }
        )

      Mix.shell().info(Jason.encode!(plan, pretty: true))
      :ok
    else
      Mix.Task.run("app.start")
      verify_manifest_environment!(opts)

      api_key_env = Keyword.get(opts, :api_key_env, "OPENAI_API_KEY")
      api_key = System.get_env(api_key_env) || Mix.raise("#{api_key_env} is required")
      model = fetch!(opts, :model)
      reflection_model = fetch!(opts, :reflection_model)

      req_llm_opts =
        Keyword.merge(
          [
            api_key: api_key,
            temperature: Keyword.get(opts, :temperature, defaults.temperature),
            max_retries: Keyword.get(opts, :max_retries, defaults.max_retries)
          ],
          generation_opts(opts)
        )

      families = parse_families(Keyword.get(opts, :families))
      require_upstream_bm25!(families)
      require_upstream_ifbench_descriptions!(families)

      run_context =
        Imp.BenchmarkTruth.RunContext.capture_git!(
          source_commits: upstream_source_commits(opts),
          require_clean: true
        )

      result =
        with_progress_reporter(fn reporter ->
          Imp.BenchmarkTruth.GepaCampaign.run(
            dataset_root: fetch!(opts, :dataset_root),
            campaign_id: fetch!(opts, :campaign_id),
            model: model,
            reflection_model: reflection_model,
            out_dir: Keyword.get(opts, :out, "benchmarks/results"),
            checkpoint_dir:
              Keyword.get(
                opts,
                :checkpoint_dir,
                Path.join(Keyword.get(opts, :out, "benchmarks/results"), "gepa-checkpoints")
              ),
            families: families,
            max_concurrency: Keyword.get(opts, :max_concurrency, defaults.max_concurrency),
            seeds: parse_seeds(Keyword.get(opts, :seeds, "0,1")),
            generations: Keyword.get(opts, :generations, :metric_budget),
            pricing_source: fetch!(opts, :pricing_source),
            token_cost: token_cost(opts),
            budgets: Keyword.get(opts, :budgets),
            sharding: Keyword.get(opts, :sharding),
            shard: Keyword.get(opts, :shard),
            manifest_identity: Keyword.get(opts, :manifest_identity),
            run_context: run_context,
            execution: execution_identity(opts),
            reporter: reporter,
            lm: Imp.req_llm(model, req_llm_opts),
            reflection_lm: Imp.req_llm(reflection_model, req_llm_opts),
            judge_lm: Imp.req_llm(Keyword.get(opts, :judge_model, model), req_llm_opts),
            judge_model: Keyword.get(opts, :judge_model, model)
          )
        end)

      Mix.shell().info("Imp GEPA rows: #{result.out_path}")
    end
  end

  defp fetch!(opts, key), do: Keyword.get(opts, key) || Mix.raise("--#{dash(key)} is required")

  @doc false
  def resolve_manifest_options!(opts, argv \\ []) do
    case Keyword.get(opts, :manifest) do
      nil ->
        opts

      path ->
        if Keyword.get_values(opts, :manifest) != [path] or argv != [] do
          Mix.raise(
            "--manifest must be provided exactly once and cannot use positional arguments"
          )
        end

        path
        |> Imp.BenchmarkTruth.GepaCampaignManifest.load!()
        |> Imp.BenchmarkTruth.GepaCampaignManifest.task_options!(opts)
        |> Map.to_list()
    end
  rescue
    error in [ArgumentError, File.Error, Jason.DecodeError] -> Mix.raise(Exception.message(error))
  end

  defp parse_seeds(value) when is_list(value), do: value

  defp parse_seeds(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.to_integer/1)
  end

  defp parse_families(nil), do: Imp.BenchmarkTruth.GepaReplicationContract.required_families()

  defp parse_families(value) when is_list(value), do: value

  defp parse_families(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
  end

  defp token_cost(opts) do
    scalar? =
      Keyword.has_key?(opts, :usd) or Keyword.has_key?(opts, :input_tokens) or
        Keyword.has_key?(opts, :output_tokens)

    case {Keyword.get(opts, :token_cost_file), scalar?} do
      {path, false} when is_binary(path) ->
        path |> File.read!() |> Jason.decode!()

      {nil, true} ->
        %{
          "usd" => fetch!(opts, :usd),
          "input_tokens" => fetch!(opts, :input_tokens),
          "output_tokens" => fetch!(opts, :output_tokens)
        }

      {nil, false} ->
        nil

      {_path, true} ->
        Mix.raise("--token-cost-file cannot be combined with scalar token-cost options")
    end
  end

  defp generation_opts(opts) do
    [max_tokens: Keyword.get(opts, :max_tokens, research_defaults().max_tokens)]
  end

  defp execution_identity(opts) do
    identity = %{
      "lm" => %{
        "provider" => "req_llm",
        "temperature" => Keyword.get(opts, :temperature, research_defaults().temperature),
        "max_tokens" => Keyword.get(opts, :max_tokens, research_defaults().max_tokens),
        "optimizer_timeout_ms" =>
          Keyword.get(
            opts,
            :optimizer_timeout_ms,
            research_defaults().optimizer_timeout_ms
          ),
        "max_retries" => Keyword.get(opts, :max_retries, research_defaults().max_retries)
      },
      "retrieval" => %{
        "hover_upstream_bm25" => truthy_env?("IMP_HOVER_UPSTREAM_BM25"),
        "python" => System.get_env("IMP_GEPA_PYTHON"),
        "gepa_root" => System.get_env("IMP_GEPA_ROOT")
      },
      "ifbench" => %{
        "upstream_descriptions" => truthy_env?("IMP_IFBENCH_UPSTREAM_DESCRIPTIONS")
      },
      "semantic_progress" =>
        Keyword.get(opts, :semantic_progress, %{
          "max_consecutive_proposal_errors" => 5
        })
    }

    case Keyword.get(opts, :manifest_identity) do
      nil ->
        identity

      manifest ->
        identity
        |> Map.put("manifest", manifest)
        |> Map.put("manifest_environment", Keyword.fetch!(opts, :manifest_environment))
    end
  end

  @doc false
  def verify_manifest_environment!(opts) do
    case Keyword.get(opts, :manifest_environment) do
      nil ->
        :ok

      requirements ->
        require_truthy_environment!(
          requirements,
          "hover_upstream_bm25",
          "IMP_HOVER_UPSTREAM_BM25"
        )

        require_truthy_environment!(
          requirements,
          "ifbench_upstream_descriptions",
          "IMP_IFBENCH_UPSTREAM_DESCRIPTIONS"
        )

        require_named_environment!(requirements, "python_env")
        require_named_environment!(requirements, "gepa_root_env", directory?: true)
    end
  end

  defp require_truthy_environment!(requirements, key, env_name) do
    if requirements[key] == true and not truthy_env?(env_name) do
      Mix.raise("canonical GEPA manifest requires #{env_name}=1")
    end
  end

  defp require_named_environment!(requirements, key, opts \\ []) do
    env_name = Map.fetch!(requirements, key)
    value = System.get_env(env_name)

    cond do
      is_nil(value) or String.trim(value) == "" ->
        Mix.raise("canonical GEPA manifest requires #{env_name}")

      Keyword.get(opts, :directory?, false) and not File.dir?(value) ->
        Mix.raise("canonical GEPA manifest requires #{env_name} to name an existing directory")

      true ->
        :ok
    end
  end

  defp truthy_env?(name), do: System.get_env(name) in ["1", "true", "TRUE", "yes"]

  defp require_upstream_bm25!(families) do
    retrieval_families = Enum.filter(families, &(&1 in ["HotpotQABench", "hoverBench"]))

    if retrieval_families != [] and not truthy_env?("IMP_HOVER_UPSTREAM_BM25") do
      Mix.raise(
        "HotPotQA and HoVer GEPA campaigns require IMP_HOVER_UPSTREAM_BM25=1 for source-exact upstream BM25S retrieval"
      )
    end
  end

  defp require_upstream_ifbench_descriptions!(families) do
    if "IFBench" in families and
         not truthy_env?("IMP_IFBENCH_UPSTREAM_DESCRIPTIONS") do
      Mix.raise(
        "IFBench GEPA campaigns require IMP_IFBENCH_UPSTREAM_DESCRIPTIONS=1 for source-exact reflective feedback"
      )
    end

    if "IFBench" in families and not File.dir?(System.get_env("IMP_GEPA_ROOT") || "") do
      Mix.raise("IFBench GEPA campaigns require IMP_GEPA_ROOT to name the pinned checkout")
    end

    if "IFBench" in families and is_nil(System.get_env("IMP_GEPA_PYTHON")) do
      Mix.raise(
        "IFBench GEPA campaigns require IMP_GEPA_PYTHON to name the pinned research interpreter"
      )
    end
  end

  defp upstream_source_commits(opts) do
    %{
      "dspy" => fetch!(opts, :dspy_source),
      "gepa_artifact" => fetch!(opts, :gepa_artifact_source)
    }
  end

  @doc false
  def start_progress_reporter do
    {:ok, state} =
      Agent.start_link(fn ->
        %{optimizer: nil, usage: empty_usage()}
      end)

    handler_id = {__MODULE__, state}

    :ok =
      :telemetry.attach_many(
        handler_id,
        [[:imp, :optimizer, :progress], [:req_llm, :token_usage]],
        &__MODULE__.handle_progress_telemetry/4,
        state
      )

    %{handler_id: handler_id, state: state}
  end

  @doc false
  def stop_progress_reporter(%{handler_id: handler_id, state: state}) do
    :telemetry.detach(handler_id)

    try do
      Agent.stop(state)
    catch
      :exit, {:noproc, _} -> :ok
      :exit, :noproc -> :ok
    end
  end

  @doc false
  def handle_progress_telemetry([:imp, :optimizer, :progress], measurements, _metadata, state) do
    Agent.update(state, &Map.put(&1, :optimizer, optimizer_snapshot(measurements)))
  end

  def handle_progress_telemetry([:req_llm, :token_usage], measurements, _metadata, state) do
    Agent.update(state, fn progress ->
      Map.update!(progress, :usage, &add_usage(&1, measurements))
    end)
  end

  @doc false
  def report_progress(%{state: state}, %{event: :seed_start} = event) do
    Agent.update(state, fn _ -> %{optimizer: nil, usage: empty_usage()} end)
    report_progress(event)
  end

  def report_progress(%{state: state}, %{event: :seed_checkpoint, phase: :optimizer} = event) do
    snapshot = Agent.get(state, & &1)
    Mix.shell().info(format_optimizer_progress(event, snapshot))
  end

  def report_progress(_reporter, event), do: report_progress(event)

  @doc false
  def format_optimizer_progress(event, snapshot) do
    optimizer = snapshot.optimizer || %{}
    usage = snapshot.usage
    iteration = optimizer[:iteration] || event.completed_generations
    candidates = optimizer[:candidates] || event.completed_generations + 1
    metric_calls = optimizer[:metric_calls] || "unknown"

    "[GEPA] #{event.family} seed=#{event.seed} optimizer checkpoint " <>
      "iteration=#{iteration} metric_calls=#{metric_calls} candidates=#{candidates} " <>
      "usage_usd=#{format_usd(usage.usd)} input_tokens=#{usage.input_tokens} " <>
      "output_tokens=#{usage.output_tokens}"
  end

  defp with_progress_reporter(fun) do
    reporter = start_progress_reporter()

    try do
      fun.(fn event -> report_progress(reporter, event) end)
    after
      stop_progress_reporter(reporter)
    end
  end

  defp report_progress(%{event: :family_start} = event) do
    counts = event.split_counts

    Mix.shell().info(
      "[GEPA] #{event.family} start train=#{counts.train} dev=#{counts.dev} test=#{counts.test} seeds=#{Enum.join(event.seeds, ",")} generations=#{event.generations}"
    )
  end

  defp report_progress(%{event: :seed_start} = event) do
    Mix.shell().info("[GEPA] #{event.family} seed=#{event.seed} start")
  end

  defp report_progress(%{event: :seed_done} = event) do
    Mix.shell().info(
      "[GEPA] #{event.family} seed=#{event.seed} done train=#{format_score(event.train)} dev=#{format_score(event.dev)} test=#{format_score(event.test)} candidates=#{event.candidate_count}"
    )
  end

  defp report_progress(%{event: :seed_checkpoint, phase: :baseline} = event) do
    Mix.shell().info(
      "[GEPA] #{event.family} seed=#{event.seed} baseline checkpoint splits=#{Enum.join(event.baseline_splits, ",")}"
    )
  end

  defp report_progress(%{event: :seed_resumed} = event) do
    Mix.shell().info("[GEPA] #{event.family} seed=#{event.seed} resumed from checkpoint")
  end

  defp report_progress(%{event: :family_done} = event) do
    Mix.shell().info(
      "[GEPA] #{event.family} done selected_seed=#{event.selected_seed} best_dev=#{format_score(event.best_dev)} selected_test=#{format_score(event.selected_test)} wall_clock_ms=#{event.wall_clock_ms}"
    )
  end

  defp report_progress(_event), do: :ok

  defp optimizer_snapshot(measurements) do
    %{
      iteration: Map.get(measurements, :completed_generations),
      metric_calls: Map.get(measurements, :metric_calls),
      candidates: Map.get(measurements, :candidate_count)
    }
  end

  defp empty_usage, do: %{usd: 0.0, input_tokens: 0, output_tokens: 0}

  defp add_usage(usage, measurements) do
    tokens = Map.get(measurements, :tokens, %{})

    %{
      usd: usage.usd + first_numeric(measurements, [:total_cost, :cost]),
      input_tokens: usage.input_tokens + trunc(first_numeric(tokens, [:input_tokens, :input])),
      output_tokens: usage.output_tokens + trunc(first_numeric(tokens, [:output_tokens, :output]))
    }
  end

  defp first_numeric(values, keys) do
    Enum.find_value(keys, 0.0, fn key ->
      case Map.get(values, key) do
        value when is_number(value) and value >= 0 -> value
        _other -> nil
      end
    end)
  end

  defp format_usd(usd), do: :erlang.float_to_binary(usd / 1, decimals: 6)

  defp format_score(score) when is_float(score), do: :erlang.float_to_binary(score, decimals: 4)
  defp format_score(score), do: to_string(score)

  defp dash(key), do: key |> Atom.to_string() |> String.replace("_", "-")
end
