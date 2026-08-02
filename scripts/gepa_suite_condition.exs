defmodule Imp.GepaSuiteConditionCLI do
  @moduledoc false

  alias Imp.BenchmarkTruth.{GepaStudyCondition, GepaStudyPlan, GepaSuite}
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
          input_price_per_million: :float,
          output_price_per_million: :float,
          initial_cost_usd: :float,
          max_cost_usd: :float,
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
      arm:
        Map.fetch!(
          %{
            "baseline" => :baseline,
            "mipro_v2_heavy" => :mipro_v2_heavy,
            "gepa_v0_1_4_no_merge" => :gepa_v0_1_4_no_merge
          },
          arm
        ),
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
      input_price_per_million: opts[:input_price_per_million],
      output_price_per_million: opts[:output_price_per_million],
      initial_cost_usd: opts[:initial_cost_usd],
      max_cost_usd: opts[:max_cost_usd],
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
    reservation = admit_spend!(config)

    {wall_time_us, outcome, usage} =
      capture_runtime(fn ->
        optimized = GepaStudyCondition.optimize!(config.arm, prepared, config.seed)
        {optimized, GepaStudyCondition.heldout!(config.arm, prepared, optimized)}
      end)

    {optimized, heldout} = unwrap_run!(outcome, config, reservation, wall_time_us, usage)

    {artifact_sha, fresh_sha, fresh_usage} =
      case optimized.artifact do
        nil ->
          {nil, nil, empty_runtime()}

        artifact ->
          for key <- [:artifact, :fresh_output], do: required_config!(config, key)
          Artifact.write!(artifact, config.artifact)
          fresh_child!(config)
          fresh = config.fresh_output |> File.read!() |> Jason.decode!()
          {sha256(config.artifact), sha256(config.fresh_output), fresh["usage"]}
      end

    write_private!(config.output, %{
      status: :complete,
      family: config.family,
      arm: config.arm,
      seed: config.seed,
      heldout: evaluation(heldout.result),
      artifact_sha256: artifact_sha,
      fresh_sha256: fresh_sha,
      usage: merge_runtime(usage, fresh_usage),
      wall_time_us: wall_time_us,
      spend_admission: reservation,
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

    {wall_time_us, outcome, usage} =
      capture_runtime(fn ->
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
      end)

    outcomes = unwrap_fresh!(outcome, config, wall_time_us, usage)

    unless length(outcomes) == 4 and Enum.all?(outcomes, &(&1.status == :ok)) do
      raise "fresh GEPA suite service did not complete all four calls: #{inspect(outcomes)}"
    end

    write_private!(config.fresh_output, %{
      status: :fresh_ok,
      family: config.family,
      arm: config.arm,
      seed: config.seed,
      calls: outcomes,
      usage: usage,
      wall_time_us: wall_time_us
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
    end) ++
      [
        "--api-key-env",
        config.api_key_env,
        "--input-price-per-million",
        to_string(config.input_price_per_million),
        "--output-price-per-million",
        to_string(config.output_price_per_million)
      ]
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
      temperature: 1.0,
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
          zdr: true,
          max_price: %{
            prompt: config.input_price_per_million,
            completion: config.output_price_per_million
          }
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

  defp admit_spend!(config) do
    family =
      config.dataset_root
      |> GepaStudyPlan.plan!(seeds: 1, runtimes: 1)
      |> Map.fetch!(:families)
      |> Enum.find(&(&1.family == config.family))

    calls = Map.fetch!(family.arms, config.arm)
    task = role_reservation(config, :task)
    reflection = role_reservation(config, :reflection)
    judge = role_reservation(config, :judge)

    reserved =
      calls.task_transports * task +
        (calls.mipro_proposer_transports + calls.gepa_reflection_transports) * reflection +
        calls.judge_transports * judge

    projected = config.initial_cost_usd + reserved

    if projected > config.max_cost_usd + 1.0e-9 do
      raise Imp.OperationalSafetyError,
        kind: :budget,
        message:
          "GEPA suite condition reservation would exceed the owner cap before transport: " <>
            "$#{projected} > $#{config.max_cost_usd}"
    end

    %{
      "initial_cost_usd" => config.initial_cost_usd,
      "condition_reservation_usd" => reserved,
      "projected_max_usd" => projected,
      "owner_cap_usd" => config.max_cost_usd,
      "calls" => json_safe(calls),
      "accounting" =>
        "content-byte-as-token plus configured maximum output at route max_price; no cache discount"
    }
  end

  defp role_reservation(config, role) do
    input = Map.fetch!(config, String.to_existing_atom("#{role}_max_input_bytes"))
    output = Map.fetch!(config, String.to_existing_atom("#{role}_max_output_tokens"))

    (input * config.input_price_per_million + output * config.output_price_per_million) /
      1_000_000
  end

  defp evaluation(result) do
    rows =
      result.rows
      |> Enum.with_index()
      |> Enum.map(fn {row, index} ->
        inputs = row.example |> Imp.Example.inputs() |> Imp.Example.to_map()

        %{
          index: index,
          input_sha256: canonical_sha256(inputs),
          score: row.score,
          error: if(is_nil(row.error), do: nil, else: Imp.Redaction.redact(row.error))
        }
      end)

    %{
      score: result.score,
      row_count: length(rows),
      error_count: length(result.errors),
      rows: rows
    }
  end

  defp capture_runtime(fun) do
    id = {__MODULE__, :runtime_usage, make_ref()}
    {:ok, usage} = Agent.start_link(fn -> empty_runtime() end)

    :ok =
      :telemetry.attach_many(
        id,
        [
          [:req_llm, :request, :stop],
          [:req_llm, :request, :exception]
        ],
        &__MODULE__.handle_runtime_event/4,
        usage
      )

    started = System.monotonic_time(:microsecond)

    try do
      result =
        try do
          {:ok, fun.()}
        rescue
          error -> {:error, error, __STACKTRACE__}
        end

      runtime = Agent.get(usage, &finalize_runtime/1)
      {System.monotonic_time(:microsecond) - started, result, runtime}
    after
      :telemetry.detach(id)
      Agent.stop(usage)
    end
  end

  defp unwrap_run!({:ok, result}, _config, _reservation, _wall_time_us, _usage), do: result

  defp unwrap_run!({:error, error, stacktrace}, config, reservation, wall_time_us, usage) do
    write_private!(config.output, %{
      status: :failed,
      family: config.family,
      arm: config.arm,
      seed: config.seed,
      stage: :optimize_or_heldout,
      error: Imp.Redaction.redact(error),
      usage: usage,
      wall_time_us: wall_time_us,
      spend_admission: reservation
    })

    reraise error, stacktrace
  end

  defp unwrap_fresh!({:ok, result}, _config, _wall_time_us, _usage), do: result

  defp unwrap_fresh!({:error, error, stacktrace}, config, wall_time_us, usage) do
    write_private!(config.fresh_output, %{
      status: :failed,
      family: config.family,
      arm: config.arm,
      seed: config.seed,
      stage: :fresh_service,
      error: Imp.Redaction.redact(error),
      usage: usage,
      wall_time_us: wall_time_us
    })

    reraise error, stacktrace
  end

  @doc false
  def handle_runtime_event(event, measurements, metadata, usage)
      when event in [[:req_llm, :request, :stop], [:req_llm, :request, :exception]] do
    duration = Map.get(measurements, :duration, 0)
    provider_usage = Map.get(metadata, :usage, %{}) || %{}
    successful? = event == [:req_llm, :request, :stop]

    delta = %{
      "usage_events" => if(successful?, do: 1, else: 0),
      "request_attempts" => 1,
      "request_duration_us" => System.convert_time_unit(duration, :native, :microsecond),
      "input_tokens" => number(provider_usage, [:input_tokens, :input]) |> trunc(),
      "output_tokens" => number(provider_usage, [:output_tokens, :output]) |> trunc(),
      "cost_usd" => number(provider_usage, [:total_cost, :cost])
    }

    event_record = %{
      "sequence" => nil,
      "status" => if(successful?, do: "ok", else: "error"),
      "request_id" => Map.get(metadata, :request_id),
      "provider" => json_safe(Map.get(metadata, :provider)),
      "model" => model_id(Map.get(metadata, :model)),
      "http_status" => Map.get(metadata, :http_status),
      "finish_reason" => json_safe(Map.get(metadata, :finish_reason)),
      "request_summary" => json_safe(Map.get(metadata, :request_summary)),
      "response_summary" => json_safe(Map.get(metadata, :response_summary)),
      "duration_us" => delta["request_duration_us"],
      "input_tokens" => delta["input_tokens"],
      "output_tokens" => delta["output_tokens"],
      "cost_usd" => delta["cost_usd"],
      "error" => if(successful?, do: nil, else: Imp.Redaction.redact(Map.get(metadata, :error)))
    }

    Agent.update(usage, fn state ->
      %{
        "summary" => add_usage(state["summary"], delta),
        "events" => [event_record | state["events"]]
      }
    end)
  end

  defp empty_runtime, do: %{"summary" => empty_usage(), "events" => []}

  defp finalize_runtime(runtime) do
    events =
      runtime["events"]
      |> Enum.reverse()
      |> Enum.with_index(1)
      |> Enum.map(fn {event, index} -> %{event | "sequence" => index} end)

    %{runtime | "events" => events}
  end

  defp empty_usage do
    %{
      "usage_events" => 0,
      "request_attempts" => 0,
      "request_duration_us" => 0,
      "input_tokens" => 0,
      "output_tokens" => 0,
      "cost_usd" => 0.0
    }
  end

  defp add_usage(left, right) do
    Map.new(left, fn {key, value} -> {key, value + Map.get(right || %{}, key, 0)} end)
  end

  defp merge_runtime(left, right) do
    left = left || empty_runtime()
    right = right || empty_runtime()

    events =
      (Map.get(left, "events", []) ++ Map.get(right, "events", []))
      |> Enum.with_index(1)
      |> Enum.map(fn {event, index} -> Map.put(event, "sequence", index) end)

    %{
      "summary" => add_usage(Map.get(left, "summary", %{}), Map.get(right, "summary", %{})),
      "events" => events
    }
  end

  defp model_id(%{id: id}) when is_binary(id), do: id
  defp model_id(%{"id" => id}) when is_binary(id), do: id
  defp model_id(value), do: json_safe(value)

  defp number(map, keys) do
    Enum.find_value(keys, 0, fn key ->
      value = Map.get(map, key, Map.get(map, Atom.to_string(key)))
      if is_number(value), do: value
    end)
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

      required_nonnegative_number!(config, :input_price_per_million)
      required_nonnegative_number!(config, :output_price_per_million)

      if config.run? do
        required_nonnegative_number!(config, :initial_cost_usd)
        required_positive_number!(config, :max_cost_usd)
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

  defp required_nonnegative_number!(config, key) do
    case Map.get(config, key) do
      value when is_number(value) and value >= 0 -> value
      _ -> raise ArgumentError, "#{key} must be a nonnegative number"
    end
  end

  defp required_positive_number!(config, key) do
    case Map.get(config, key) do
      value when is_number(value) and value > 0 -> value
      _ -> raise ArgumentError, "#{key} must be a positive number"
    end
  end

  defp expand(nil), do: nil
  defp expand(path), do: Path.expand(path)

  defp write_private!(path, payload) do
    File.mkdir_p!(Path.dirname(path))
    File.chmod!(Path.dirname(path), 0o700)
    File.write!(path, Jason.encode!(json_safe(payload), pretty: true) <> "\n")
    File.chmod!(path, 0o600)
  end

  defp emit(payload), do: IO.puts(Jason.encode!(json_safe(payload)))
  defp sha256(path), do: :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)

  defp canonical_sha256(value) do
    value
    |> json_safe()
    |> canonical_json_value()
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp canonical_json_value(map) when is_map(map) and not is_struct(map) do
    values =
      map
      |> Enum.map(fn {key, value} -> {to_string(key), canonical_json_value(value)} end)
      |> Enum.sort_by(&elem(&1, 0))

    %Jason.OrderedObject{values: values}
  end

  defp canonical_json_value(list) when is_list(list), do: Enum.map(list, &canonical_json_value/1)
  defp canonical_json_value(value), do: value
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
