defmodule Mix.Tasks.Dsex.Benchmark.GepaCampaign do
  @moduledoc """
  Produce DSEx GEPA rows for the GEPA paper-replication evidence lane.

      mix dsex.benchmark.gepa_campaign \\
        --dataset-root path/to/gepa-family-splits \\
        --campaign-id gepa-full-YYYYMMDD \\
        --model openai:gpt-4.1-mini-2025-04-14 \\
        --reflection-model openai:gpt-5 \\
        --api-key-env OPENAI_API_KEY \\
        --families AIMEBench,HotpotQABench \\
        --max-concurrency 8 \\
        --temperature 1.0 \\
        --max-tokens 256 \\
        --pricing-source "ReqLLM usage telemetry with provider pricing metadata" \\
        --token-cost-file path/to/fallback-costs.json \\
        --dspy-source stanfordnlp/dspy@... \\
        --gepa-artifact-source gepa-ai/gepa-artifact@...

  The dataset root must contain a `families.json` file and one directory per
  required GEPA family, each with `train.jsonl`, `dev.jsonl`, and `test.jsonl`.
  The task writes `dsex-gepa-rows-*.json`, which is then consumed by
  `mix dsex.benchmark.gepa_replication --from-gepa-artifact ... --dsex-input ...`.
  Pass `--families` to run a resumable subset; final replication still requires
  all six family rows merged into one DSEx input artifact. Completed seeds are
  checkpointed under the output directory and reused when the same campaign is
  rerun with matching settings and dataset checksums.

  ReqLLM telemetry is the preferred cost source. If telemetry is unavailable,
  `--token-cost-file` accepts JSON keyed first by family and then by seed, with
  each leaf containing `usd`, `input_tokens`, and `output_tokens`. The scalar
  cost flags are valid only for a single-family, single-seed run.
  """

  use Mix.Task

  @shortdoc "Run the DSEx side of the GEPA replication campaign"

  @impl true
  def run(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
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
          dspy_source: :string,
          gepa_artifact_source: :string
        ]
      )

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    Mix.Task.run("app.start")

    api_key_env = Keyword.get(opts, :api_key_env, "OPENAI_API_KEY")
    api_key = System.get_env(api_key_env) || Mix.raise("#{api_key_env} is required")
    model = fetch!(opts, :model)
    reflection_model = fetch!(opts, :reflection_model)

    req_llm_opts =
      Keyword.merge(
        [api_key: api_key, temperature: Keyword.get(opts, :temperature, 1.0)],
        generation_opts(opts)
      )

    families = parse_families(Keyword.get(opts, :families))
    require_upstream_bm25!(families)
    require_upstream_ifbench_descriptions!(families)

    run_context =
      DSEx.BenchmarkTruth.RunContext.capture_git!(
        source_commits: upstream_source_commits(opts),
        require_clean: true
      )

    result =
      DSEx.BenchmarkTruth.GepaCampaign.run(
        dataset_root: fetch!(opts, :dataset_root),
        campaign_id: fetch!(opts, :campaign_id),
        model: model,
        reflection_model: reflection_model,
        out_dir: Keyword.get(opts, :out, "benchmarks/results"),
        families: families,
        max_concurrency: Keyword.get(opts, :max_concurrency, 1),
        seeds: parse_seeds(Keyword.get(opts, :seeds, "0,1")),
        generations: Keyword.get(opts, :generations, :metric_budget),
        pricing_source: fetch!(opts, :pricing_source),
        token_cost: token_cost(opts),
        run_context: run_context,
        execution: execution_identity(opts),
        reporter: &report_progress/1,
        lm: DSEx.req_llm(model, req_llm_opts),
        reflection_lm: DSEx.req_llm(reflection_model, req_llm_opts)
      )

    Mix.shell().info("DSEx GEPA rows: #{result.out_path}")
  end

  defp fetch!(opts, key), do: Keyword.get(opts, key) || Mix.raise("--#{dash(key)} is required")

  defp parse_seeds(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.to_integer/1)
  end

  defp parse_families(nil), do: DSEx.BenchmarkTruth.GepaReplicationContract.required_families()

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
    case Keyword.get(opts, :max_tokens) do
      nil -> []
      max_tokens -> [max_tokens: max_tokens]
    end
  end

  defp execution_identity(opts) do
    %{
      "lm" => %{
        "provider" => "req_llm",
        "temperature" => Keyword.get(opts, :temperature, 1.0),
        "max_tokens" => Keyword.get(opts, :max_tokens)
      },
      "retrieval" => %{
        "hover_upstream_bm25" => truthy_env?("DSEX_HOVER_UPSTREAM_BM25"),
        "python" => System.get_env("DSEX_GEPA_PYTHON"),
        "gepa_root" => System.get_env("DSEX_GEPA_ROOT")
      },
      "ifbench" => %{
        "upstream_descriptions" => truthy_env?("DSEX_IFBENCH_UPSTREAM_DESCRIPTIONS")
      }
    }
  end

  defp truthy_env?(name), do: System.get_env(name) in ["1", "true", "TRUE", "yes"]

  defp require_upstream_bm25!(families) do
    retrieval_families = Enum.filter(families, &(&1 in ["HotpotQABench", "hoverBench"]))

    if retrieval_families != [] and not truthy_env?("DSEX_HOVER_UPSTREAM_BM25") do
      Mix.raise(
        "HotPotQA and HoVer GEPA campaigns require DSEX_HOVER_UPSTREAM_BM25=1 for source-exact upstream BM25S retrieval"
      )
    end
  end

  defp require_upstream_ifbench_descriptions!(families) do
    if "IFBench" in families and
         not truthy_env?("DSEX_IFBENCH_UPSTREAM_DESCRIPTIONS") do
      Mix.raise(
        "IFBench GEPA campaigns require DSEX_IFBENCH_UPSTREAM_DESCRIPTIONS=1 for source-exact reflective feedback"
      )
    end

    if "IFBench" in families and not File.dir?(System.get_env("DSEX_GEPA_ROOT") || "") do
      Mix.raise("IFBench GEPA campaigns require DSEX_GEPA_ROOT to name the pinned checkout")
    end

    if "IFBench" in families and is_nil(System.get_env("DSEX_GEPA_PYTHON")) do
      Mix.raise(
        "IFBench GEPA campaigns require DSEX_GEPA_PYTHON to name the pinned research interpreter"
      )
    end
  end

  defp upstream_source_commits(opts) do
    %{
      "dspy" => fetch!(opts, :dspy_source),
      "gepa_artifact" => fetch!(opts, :gepa_artifact_source)
    }
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

  defp format_score(score) when is_float(score), do: :erlang.float_to_binary(score, decimals: 4)
  defp format_score(score), do: to_string(score)

  defp dash(key), do: key |> Atom.to_string() |> String.replace("_", "-")
end
