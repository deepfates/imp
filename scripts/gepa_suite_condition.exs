defmodule Imp.GepaSuiteConditionCLI do
  @moduledoc false

  alias Imp.BenchmarkTruth.{GepaStudyCondition, GepaSuite}
  alias Imp.Optimizer.Artifact

  @arms ~w(baseline mipro_v2_heavy gepa_v0_1_4_no_merge)

  def main(argv) do
    {opts, positional, invalid} =
      OptionParser.parse(argv,
        strict: [
          dataset_root: :string,
          retrieval_root: :string,
          retrieval_receipt: :string,
          retrieval_python: :string,
          family: :string,
          arm: :string,
          seed: :integer,
          output: :string,
          artifact: :string,
          fresh_output: :string,
          task_model: :string,
          reflection_model: :string,
          judge_model: :string,
          task_provider: :string,
          reflection_provider: :string,
          judge_provider: :string,
          task_max_input_bytes: :integer,
          reflection_max_input_bytes: :integer,
          judge_max_input_bytes: :integer,
          task_max_output_tokens: :integer,
          reflection_max_output_tokens: :integer,
          judge_max_output_tokens: :integer,
          api_key_env: :string,
          provider_disabled_fixture: :boolean,
          run: :boolean,
          fresh: :boolean
        ]
      )

    if positional != [] or invalid != [],
      do: raise(ArgumentError, "invalid GEPA suite arguments: #{inspect(positional ++ invalid)}")

    config = config!(opts)
    prepared = prepare!(config)

    cond do
      config.fresh? -> fresh!(config, prepared)
      config.run? -> run!(config, prepared)
      true -> preflight!(config, prepared)
    end
  end

  defp config!(opts) do
    family = required!(opts, :family)
    arm = Keyword.get(opts, :arm, "baseline")

    unless family in GepaSuite.families(),
      do: raise(ArgumentError, "unknown official GEPA family: #{inspect(family)}")

    unless arm in @arms,
      do: raise(ArgumentError, "unknown matched study arm: #{inspect(arm)}")

    run? = Keyword.get(opts, :run, false)
    fresh? = Keyword.get(opts, :fresh, false)

    if run? and fresh?, do: raise(ArgumentError, "choose --run or --fresh, not both")

    %{
      dataset_root: opts |> required!(:dataset_root) |> Path.expand(),
      retrieval_root: expand(opts[:retrieval_root]),
      retrieval_receipt: expand(opts[:retrieval_receipt]),
      retrieval_python: Keyword.get(opts, :retrieval_python, "python3"),
      family: family,
      arm: String.to_existing_atom(arm),
      seed: Keyword.get(opts, :seed, 2_026_080_101),
      output: expand(opts[:output]),
      artifact: expand(opts[:artifact]),
      fresh_output: expand(opts[:fresh_output]),
      task_model: opts[:task_model],
      reflection_model: opts[:reflection_model],
      judge_model: opts[:judge_model],
      task_provider: opts[:task_provider],
      reflection_provider: opts[:reflection_provider],
      judge_provider: opts[:judge_provider],
      task_max_input_bytes: opts[:task_max_input_bytes],
      reflection_max_input_bytes: opts[:reflection_max_input_bytes],
      judge_max_input_bytes: opts[:judge_max_input_bytes],
      task_max_output_tokens: opts[:task_max_output_tokens],
      reflection_max_output_tokens: opts[:reflection_max_output_tokens],
      judge_max_output_tokens: opts[:judge_max_output_tokens],
      api_key_env: Keyword.get(opts, :api_key_env, "OPENROUTER_API_KEY"),
      provider_disabled_fixture?: Keyword.get(opts, :provider_disabled_fixture, false),
      run?: run?,
      fresh?: fresh?
    }
    |> validate_live!()
  end

  defp prepare!(config) do
    lms =
      if config.provider_disabled_fixture? do
        fixture = Imp.LM.Static.new()
        %{task: fixture, reflection: fixture, judge: fixture}
      else
        if config.run? or config.fresh? do
          %{
            task: live_lm!(config, :task),
            reflection: live_lm!(config, :reflection),
            judge: live_lm!(config, :judge)
          }
        else
          never =
            Imp.LM.Static.new(
              handler: fn _, _ -> raise "provider-disabled preflight called an LM" end
            )

          %{task: never, reflection: never, judge: never}
        end
      end

    GepaStudyCondition.prepare!(config.dataset_root, config.family, lms,
      execution: execution!(config)
    )
  end

  defp preflight!(config, prepared) do
    treatments =
      for arm <- [:mipro_v2_heavy, :gepa_v0_1_4_no_merge], into: %{} do
        optimizer = GepaStudyCondition.optimizer!(arm, prepared, config.seed)
        {arm, optimizer_receipt(arm, optimizer)}
      end

    emit(%{
      status: :provider_disabled_ready,
      family: config.family,
      arm: config.arm,
      seed: config.seed,
      heldout_decoded: false,
      split_counts: prepared.loaded.spec["split_counts"],
      treatments: treatments,
      retrieval: retrieval_disclosure(config, prepared.loaded.spec),
      provider_calls_authorized: false
    })
  end

  defp run!(config, prepared) do
    for key <- [:output], do: required_config!(config, key)

    optimized = GepaStudyCondition.optimize!(config.arm, prepared, config.seed)
    heldout = GepaStudyCondition.heldout!(prepared, optimized)

    {artifact_sha, fresh_sha} =
      case optimized.artifact do
        nil ->
          {nil, nil}

        artifact ->
          for key <- [:artifact, :fresh_output], do: required_config!(config, key)
          Artifact.write!(artifact, config.artifact)
          fresh_child!(config)
          {sha256(config.artifact), sha256(config.fresh_output)}
      end

    write_private!(config.output, %{
      status: :complete,
      family: config.family,
      arm: config.arm,
      seed: config.seed,
      baseline: evaluation(heldout.baseline),
      selected: evaluation(heldout.selected),
      causal_lift: heldout.selected.score - heldout.baseline.score,
      artifact_sha256: artifact_sha,
      fresh_sha256: fresh_sha,
      heldout_decoded: true,
      retrieval: retrieval_disclosure(config, prepared.loaded.spec)
    })
  end

  defp fresh!(config, prepared) do
    for key <- [:artifact, :fresh_output], do: required_config!(config, key)

    for file <- ~w(support_pipeline.ex callbacks.ex workflow.ex program_server.ex) do
      Code.require_file(
        Path.expand("examples/deployment/lib/imp_deployment/#{file}", File.cwd!())
      )
    end

    program = config.artifact |> Artifact.read!() |> Artifact.apply(prepared.program)
    test = GepaSuite.load_test!(prepared.loaded) |> Enum.take(4)
    supervisor = Module.concat([ImpGepaSuiteFresh, TaskSupervisor])
    {:ok, _supervisor} = Task.Supervisor.start_link(name: supervisor)

    server_options = [
      program: program,
      lm: prepared.lms.task,
      task_supervisor: supervisor,
      name: nil
    ]

    {:ok, server} = apply(ImpDeployment.ProgramServer, :start_link, [server_options])

    outcomes =
      test
      |> Task.async_stream(
        fn example ->
          inputs = example |> Imp.Example.inputs() |> Imp.Example.to_map()
          apply(ImpDeployment.ProgramServer, :call, [server, inputs, :infinity])
        end,
        ordered: true,
        max_concurrency: 4,
        timeout: :infinity
      )
      |> Enum.map(fn
        {:ok, {:ok, prediction}} -> %{status: :ok, prediction: json_safe(prediction)}
        {:ok, {:error, reason}} -> %{status: :error, reason: json_safe(reason)}
        {:exit, reason} -> %{status: :exit, reason: json_safe(reason)}
      end)

    unless length(outcomes) == 4 and Enum.all?(outcomes, &(&1.status == :ok)) do
      raise "fresh GEPA suite service did not complete all four calls: #{inspect(outcomes)}"
    end

    write_private!(config.fresh_output, %{
      status: :fresh_ok,
      family: config.family,
      arm: config.arm,
      seed: config.seed,
      calls: outcomes
    })
  end

  defp fresh_child!(config) do
    args =
      [
        "run",
        "--no-compile",
        "--no-deps-check",
        Path.expand(__ENV__.file),
        "--fresh",
        "--dataset-root",
        config.dataset_root,
        "--family",
        config.family,
        "--arm",
        Atom.to_string(config.arm),
        "--seed",
        Integer.to_string(config.seed),
        "--artifact",
        config.artifact,
        "--fresh-output",
        config.fresh_output
      ] ++ live_args(config) ++ retrieval_args(config)

    case System.cmd("mix", args,
           env: [{"MIX_ENV", "test"}],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      {output, status} -> raise "fresh GEPA suite process failed (#{status}): #{output}"
    end
  end

  defp live_args(config) do
    Enum.flat_map([:task, :reflection, :judge], fn role ->
      [
        "--#{role}-model",
        Map.fetch!(config, String.to_existing_atom("#{role}_model")),
        "--#{role}-provider",
        Map.fetch!(config, String.to_existing_atom("#{role}_provider")),
        "--#{role}-max-input-bytes",
        config |> Map.fetch!(String.to_existing_atom("#{role}_max_input_bytes")) |> to_string(),
        "--#{role}-max-output-tokens",
        config |> Map.fetch!(String.to_existing_atom("#{role}_max_output_tokens")) |> to_string()
      ]
    end) ++ ["--api-key-env", config.api_key_env]
  end

  defp retrieval_args(%{retrieval_root: nil}), do: []

  defp retrieval_args(config) do
    [
      "--retrieval-root",
      config.retrieval_root,
      "--retrieval-receipt",
      config.retrieval_receipt,
      "--retrieval-python",
      config.retrieval_python
    ]
  end

  defp execution!(%{family: family} = config)
       when family in ["HotpotQABench", "hoverBench"] do
    if is_nil(config.retrieval_root) or is_nil(config.retrieval_receipt) do
      raise ArgumentError,
            "#{family} requires --retrieval-root and --retrieval-receipt"
    end

    %{
      "retrieval" => %{
        "root" => config.retrieval_root,
        "authenticated_receipt" => config.retrieval_receipt |> File.read!() |> Jason.decode!(),
        "hover_upstream_bm25" => true,
        "python" => config.retrieval_python
      },
      "lm" => %{"json_fallback" => false}
    }
  end

  defp execution!(_config), do: %{"lm" => %{"json_fallback" => false}}

  defp live_lm!(config, role) do
    model = required_config!(config, String.to_existing_atom("#{role}_model"))
    provider = required_config!(config, String.to_existing_atom("#{role}_provider"))
    input_bytes = required_positive!(config, String.to_existing_atom("#{role}_max_input_bytes"))

    output_tokens =
      required_positive!(config, String.to_existing_atom("#{role}_max_output_tokens"))

    api_key = System.fetch_env!(config.api_key_env)

    Imp.req_llm(
      %{provider: :openrouter, id: model, model: model, base_url: "https://openrouter.ai/api/v1"},
      api_key: api_key,
      cache: false,
      max_tokens: output_tokens,
      max_retries: 0,
      input_envelope: [max_bytes: input_bytes, reservation_tokens: input_bytes],
      provider_options: [
        openrouter_provider: %{
          only: [provider],
          order: [provider],
          allow_fallbacks: false,
          require_parameters: true,
          data_collection: "deny",
          zdr: true
        },
        openrouter_usage: %{include: true}
      ],
      req_http_options: [
        headers: [
          {"X-OpenRouter-Metadata", "enabled"},
          {"X-OpenRouter-Cache", "false"}
        ],
        retry: false,
        max_retries: 0
      ]
    )
  end

  defp optimizer_receipt(:mipro_v2_heavy, optimizer) do
    %{
      auto: optimizer.config.auto,
      proposer_fidelity: optimizer.config.proposer_fidelity,
      search_fidelity: optimizer.config.search_fidelity,
      max_errors: optimizer.max_errors
    }
  end

  defp optimizer_receipt(:gepa_v0_1_4_no_merge, optimizer) do
    %{
      execution_profile: optimizer.execution_profile,
      max_metric_calls: optimizer.max_metric_calls,
      max_reflection_calls: optimizer.max_reflection_calls,
      minibatch_size: optimizer.minibatch_size,
      module_selector: optimizer.module_selector,
      use_merge: optimizer.use_merge
    }
  end

  defp evaluation(result) do
    %{score: result.score, row_count: length(result.rows), error_count: length(result.errors)}
  end

  defp retrieval_disclosure(config, %{"retrieval" => historical}) do
    receipt = config.retrieval_receipt |> File.read!() |> Jason.decode!()

    %{
      classification:
        :authenticated_current_build_of_official_retrieval_not_historical_byte_reproduction,
      corpus_sha256: get_in(receipt, ["retrieval", "extraction", "corpus_sha256"]),
      index_tree_sha256: get_in(receipt, ["retrieval", "build", "actual_tree_sha256"]),
      historical_unretained_index_sha256: historical["index_checksum"]
    }
  end

  defp retrieval_disclosure(_config, _spec), do: nil

  defp validate_live!(config) do
    if config.provider_disabled_fixture? and not config.fresh? do
      raise ArgumentError, "--provider-disabled-fixture is restricted to fresh lifecycle tests"
    end

    if (config.run? or config.fresh?) and not config.provider_disabled_fixture? do
      for role <- [:task, :reflection, :judge], suffix <- [:model, :provider] do
        required_config!(config, String.to_existing_atom("#{role}_#{suffix}"))
      end

      for role <- [:task, :reflection, :judge],
          suffix <- [:max_input_bytes, :max_output_tokens] do
        required_positive!(config, String.to_existing_atom("#{role}_#{suffix}"))
      end
    end

    config
  end

  defp required!(opts, key) do
    Keyword.get(opts, key) ||
      raise ArgumentError, "missing --#{String.replace(to_string(key), "_", "-")}"
  end

  defp required_config!(config, key) do
    Map.get(config, key) || raise ArgumentError, "missing live option #{inspect(key)}"
  end

  defp required_positive!(config, key) do
    case Map.get(config, key) do
      value when is_integer(value) and value > 0 -> value
      _ -> raise ArgumentError, "#{key} must be a positive integer"
    end
  end

  defp expand(nil), do: nil
  defp expand(path), do: Path.expand(path)

  defp write_private!(path, payload) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(json_safe(payload), pretty: true) <> "\n")
    File.chmod!(path, 0o600)
  end

  defp emit(payload), do: IO.puts(Jason.encode!(json_safe(payload)))
  defp sha256(path), do: :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)
  defp json_safe(%Imp.Example{} = value), do: value |> Imp.Example.to_map() |> json_safe()
  defp json_safe(%Imp.Prediction{} = value), do: value |> Imp.Prediction.to_map() |> json_safe()
  defp json_safe(%_{} = value), do: value |> Map.from_struct() |> json_safe()

  defp json_safe(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {to_string(key), json_safe(item)} end)

  defp json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)
  defp json_safe(value) when is_tuple(value), do: value |> Tuple.to_list() |> json_safe()
  defp json_safe(nil), do: nil
  defp json_safe(value) when is_boolean(value), do: value
  defp json_safe(value) when is_atom(value), do: Atom.to_string(value)
  defp json_safe(value) when is_binary(value) or is_number(value), do: value
  defp json_safe(value), do: inspect(value)
end

Imp.GepaSuiteConditionCLI.main(System.argv())
