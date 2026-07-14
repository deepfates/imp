defmodule Mix.Tasks.Imp.Benchmark.Parity do
  @moduledoc """
  Compare Imp against the real Python DSPy package on the same benchmark rows.

      mix imp.benchmark.parity --gsm8k benchmarks/data/gsm8k-test-0-2.jsonl \\
        --hotpotqa benchmarks/data/hotpotqa-validation-0-2.jsonl --max-examples 2

  The task expects Python DSPy to be installed. By default it uses
  `tmp/dspy-parity-venv/bin/python` when present. OpenAI remains the default
  provider; pass `--model` or set `OPENAI_MODEL` for reproducible evidence.
  When neither is supplied, the task queries the OpenAI-compatible `/models`
  endpoint and only auto-selects if exactly one text-generation candidate is
  visible. Otherwise it stops and prints candidate ids so the operator chooses
  deliberately. Pass an explicit ReqLLM model spec and matching DSPy/LiteLLM
  model when validating another provider.

      mix imp.benchmark.parity --model "$IMP_PROVIDER_MODEL" \\
        --dspy-model "$IMP_DSPY_MODEL" --api-key-env PROVIDER_API_KEY
  """

  use Mix.Task

  alias Imp.BenchmarkTruth.ParitySidecar

  @shortdoc "Run Imp-vs-DSPy live parity comparison"
  @full_lengths %{"gsm8k" => 1319, "hotpotqa" => 7405}

  @impl true
  def run(args) do
    {opts, _argv, invalid} = parse_args(args)

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    Imp.BenchmarkEnv.load_files!(Keyword.get_values(opts, :env_file))
    python = python_executable!(opts)
    configure_req_llm_pool!(opts)
    Mix.Task.run("app.start")

    tasks = tasks(opts)

    if tasks == [] do
      Mix.raise("provide at least one dataset path with --gsm8k or --hotpotqa")
    end

    api_key_env = api_key_env(opts)
    api_key = System.get_env(api_key_env) || Mix.raise("#{api_key_env} is required")
    models = models(opts, api_key)
    out_dir = Keyword.get(opts, :out, "benchmarks/results")
    max_examples = Keyword.get(opts, :max_examples, 20)
    max_concurrency = Keyword.get(opts, :max_concurrency, 1)
    generation_opts = generation_opts(opts)
    dspy_model = Keyword.get(opts, :dspy_model)
    campaign_id = Keyword.get(opts, :campaign_id)
    runner_order = runner_order(opts)
    File.mkdir_p!(out_dir)

    Enum.each(models, fn model ->
      run_model!(
        opts,
        tasks,
        model,
        api_key,
        api_key_env,
        max_examples,
        max_concurrency,
        generation_opts,
        dspy_model,
        campaign_id,
        runner_order,
        out_dir,
        python
      )
    end)
  end

  defp run_model!(
         opts,
         tasks,
         model,
         api_key,
         api_key_env,
         max_examples,
         max_concurrency,
         generation_opts,
         dspy_model,
         campaign_id,
         runner_order,
         out_dir,
         python
       ) do
    imp_model = imp_model_spec(opts, model)
    dspy_model = validate_dspy_model!(dspy_model || default_dspy_model(imp_model, model))

    {imp, dspy_path} =
      case runner_order do
        :imp_first ->
          imp =
            run_imp!(
              opts,
              tasks,
              model,
              imp_model,
              api_key,
              max_examples,
              max_concurrency,
              generation_opts,
              campaign_id,
              out_dir
            )

          ensure_runner_clean!(imp.report, "Imp", imp.out_path)

          dspy_path =
            run_dspy!(
              python,
              tasks,
              Keyword.get(opts, :offset, 0),
              max_examples,
              max_concurrency,
              generation_opts,
              dspy_model,
              api_key_env,
              campaign_id,
              out_dir,
              dspy_timeout(opts)
            )

          {imp, dspy_path}

        :dspy_first ->
          dspy_path =
            run_dspy!(
              python,
              tasks,
              Keyword.get(opts, :offset, 0),
              max_examples,
              max_concurrency,
              generation_opts,
              dspy_model,
              api_key_env,
              campaign_id,
              out_dir,
              dspy_timeout(opts)
            )

          dspy_report = dspy_path |> File.read!() |> Jason.decode!()
          ensure_runner_clean!(dspy_report, "DSPy", dspy_path)

          imp =
            run_imp!(
              opts,
              tasks,
              model,
              imp_model,
              api_key,
              max_examples,
              max_concurrency,
              generation_opts,
              campaign_id,
              out_dir
            )

          {imp, dspy_path}
      end

    dspy = dspy_path |> File.read!() |> Jason.decode!()
    report = parity_report(imp.report, dspy, generation_opts, campaign_id, runner_order)

    out_path =
      Path.join(
        out_dir,
        "imp-dspy-parity-#{model_slug(model)}-vs-#{model_slug(dspy_model)}-#{timestamp_slug()}.json"
      )

    File.write!(out_path, Jason.encode!(report, pretty: true) <> "\n")

    Mix.shell().info("imp report: #{imp.out_path}")
    Mix.shell().info("dspy report: #{dspy_path}")
    Mix.shell().info("parity report: #{out_path}")
    Mix.shell().info("runner order: #{runner_order}")
    Mix.shell().info("aggregate score delta: #{report["aggregate"]["score_delta"]}")
  end

  @doc false
  def runner_errors?(report) when is_map(report) do
    report
    |> Map.get("tasks", [])
    |> Enum.any?(fn task -> positive_error_count?(task["errors"]) end)
  end

  def runner_errors?(_report), do: true

  defp ensure_runner_clean!(report, runtime, path) do
    if runner_errors?(report) do
      Mix.raise(
        "#{runtime} runner produced API/execution errors; skipping the paired runtime. Inspect #{path}"
      )
    end
  end

  defp positive_error_count?(count) when is_integer(count), do: count > 0
  defp positive_error_count?([_head | _tail]), do: true
  defp positive_error_count?([]), do: false
  defp positive_error_count?(nil), do: false
  defp positive_error_count?(_other), do: true

  defp run_imp!(
         opts,
         tasks,
         model,
         imp_model,
         api_key,
         max_examples,
         max_concurrency,
         generation_opts,
         campaign_id,
         out_dir
       ) do
    Imp.BenchmarkTruth.run(
      tasks: tasks,
      mode: :live,
      lm: Imp.req_llm(imp_model, Keyword.merge([api_key: api_key], generation_opts)),
      model: %{provider: "req_llm", model: model, model_spec: imp_model},
      generation: generation_metadata(imp_model, generation_opts, "imp_req_llm", opts),
      campaign_id: campaign_id,
      out_dir: out_dir,
      offset: Keyword.get(opts, :offset, 0),
      max_examples: max_examples,
      max_concurrency: max_concurrency,
      optimizer_comparisons: false
    )
  end

  defp models(opts, api_key) do
    cond do
      Keyword.has_key?(opts, :models) ->
        opts |> Keyword.fetch!(:models) |> split_csv()

      Keyword.has_key?(opts, :model) ->
        [Keyword.fetch!(opts, :model)]

      model = System.get_env("OPENAI_MODEL") ->
        [model]

      true ->
        [discover_default_model(api_key)]
    end
  end

  defp split_csv(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  @doc false
  def parse_args(args) do
    OptionParser.parse(args,
      strict: [
        gsm8k: :string,
        hotpotqa: :string,
        offset: :integer,
        max_examples: :integer,
        max_concurrency: :integer,
        out: :string,
        model: :string,
        models: :string,
        imp_model: :string,
        dspy_model: :string,
        api_key_env: :string,
        env_file: :string,
        campaign_id: :string,
        temperature: :float,
        max_tokens: :integer,
        reasoning_effort: :string,
        runner_order: :string,
        req_llm_pool_protocols: :string,
        req_llm_pool_size: :integer,
        req_llm_pool_count: :integer,
        python: :string,
        dspy_timeout_ms: :integer
      ]
    )
  end

  @doc false
  def configure_req_llm_pool!(opts) do
    pool_opts =
      []
      |> maybe_keyword(:stream_pool_protocols, req_llm_pool_protocols(opts))
      |> maybe_keyword(:stream_pool_size, Keyword.get(opts, :req_llm_pool_size))
      |> maybe_keyword(:stream_pool_count, Keyword.get(opts, :req_llm_pool_count))

    Enum.each(pool_opts, fn {key, value} -> Application.put_env(:req_llm, key, value) end)

    pool_opts
  end

  defp req_llm_pool_protocols(opts) do
    case Keyword.get(opts, :req_llm_pool_protocols) do
      nil ->
        nil

      value ->
        value
        |> split_csv()
        |> Enum.map(fn
          "http1" ->
            :http1

          "http2" ->
            :http2

          other ->
            Mix.raise("--req-llm-pool-protocols accepts http1,http2, got: #{inspect(other)}")
        end)
    end
  end

  @doc false
  def generation_opts(opts) do
    generation =
      [
        temperature: Keyword.get(opts, :temperature, 0.0),
        max_tokens: Keyword.get(opts, :max_tokens, 700)
      ]

    maybe_keyword(generation, :reasoning_effort, Keyword.get(opts, :reasoning_effort))
  end

  @doc false
  def api_key_env(opts), do: Keyword.get(opts, :api_key_env, "OPENAI_API_KEY")

  @doc false
  def imp_model_spec(opts, model) do
    Keyword.get(opts, :imp_model) || System.get_env("IMP_MODEL") ||
      provider_prefixed_model(model)
  end

  @doc false
  def provider_prefixed_model(model) do
    model = to_string(model)

    if String.contains?(model, ":"),
      do: model,
      else: "openai:#{model}"
  end

  @doc false
  def default_dspy_model(imp_model, model) do
    case String.split(to_string(imp_model), ":", parts: 2) do
      ["openai", _model_id] -> model
      [provider, model_id] -> "#{provider}/#{model_id}"
      _other -> model
    end
  end

  @doc false
  def validate_dspy_model!(model) do
    model = to_string(model)
    downcased = String.downcase(model)

    if String.starts_with?(downcased, ["anthropic:", "gemini:", "google:"]) do
      Mix.raise(
        "--dspy-model expects a Python DSPy/LiteLLM model id such as #{String.replace(model, ":", "/", parts: 2)}; " <>
          "ReqLLM provider specs such as #{inspect(model)} belong in --model. Omit --dspy-model to let Imp derive the matching LiteLLM id."
      )
    end

    model
  end

  defp maybe_keyword(opts, _key, nil), do: opts
  defp maybe_keyword(opts, key, value), do: Keyword.put(opts, key, value)

  defp runner_order(opts) do
    case Keyword.get(opts, :runner_order, "imp_first") do
      value when value in ["imp_first", "imp-first"] ->
        :imp_first

      value when value in ["dspy_first", "dspy-first"] ->
        :dspy_first

      other ->
        Mix.raise("--runner-order must be imp_first or dspy_first, got: #{inspect(other)}")
    end
  end

  defp discover_default_model(api_key) do
    case select_default_openai_model(openai_models(api_key)) do
      {:ok, model} ->
        model

      {:error, :no_models} ->
        Mix.raise(
          "could not discover OpenAI models from /models; pass --model or set OPENAI_MODEL to an explicitly verified provider model id"
        )

      {:error, {:no_text_generation_model, available}} ->
        sample = available |> Enum.sort() |> Enum.take(10) |> Enum.join(", ")

        Mix.raise(
          "OpenAI /models returned #{length(available)} model id(s), but none looked like a text-generation model for parity; pass --model explicitly. Sample: #{sample}"
        )

      {:error, {:ambiguous_text_generation_models, candidates}} ->
        sample = Enum.join(candidates, ", ")

        Mix.raise(
          "OpenAI /models returned multiple text-generation candidates; pass --model or set OPENAI_MODEL explicitly. Candidates: #{sample}"
        )
    end
  end

  @doc false
  def select_default_openai_model([]), do: {:error, :no_models}

  def select_default_openai_model(available) when is_list(available) do
    candidates =
      available
      |> Enum.map(&to_string/1)
      |> Enum.filter(&text_generation_model?/1)
      |> Enum.sort()

    case candidates do
      [model] -> {:ok, model}
      [] -> {:error, {:no_text_generation_model, Enum.map(available, &to_string/1)}}
      candidates -> {:error, {:ambiguous_text_generation_models, candidates}}
    end
  end

  defp text_generation_model?(model) do
    model = String.downcase(model)

    (String.starts_with?(model, "gpt-") or String.match?(model, ~r/^o\d/)) and
      not String.contains?(model, "embedding") and
      not String.contains?(model, "audio") and
      not String.contains?(model, "realtime") and
      not String.contains?(model, "transcrib") and
      not String.contains?(model, "tts") and
      not String.contains?(model, "image") and
      not String.contains?(model, "moderation") and
      not String.contains?(model, "search")
  end

  defp openai_models(api_key) do
    :inets.start()
    :ssl.start()

    base_url = System.get_env("OPENAI_BASE_URL") || "https://api.openai.com/v1"
    url = String.trim_trailing(base_url, "/") <> "/models"
    headers = [{~c"authorization", ~c"Bearer " ++ String.to_charlist(api_key)}]

    case :httpc.request(:get, {String.to_charlist(url), headers}, [], body_format: :binary) do
      {:ok, {{_, status, _}, _headers, body}} when status in 200..299 ->
        body
        |> Jason.decode!()
        |> Map.get("data", [])
        |> Enum.map(& &1["id"])

      _other ->
        []
    end
  end

  defp tasks(opts) do
    []
    |> maybe_put(:gsm8k, Keyword.get(opts, :gsm8k))
    |> maybe_put(:hotpotqa, Keyword.get(opts, :hotpotqa))
  end

  defp maybe_put(tasks, _task, nil), do: tasks
  defp maybe_put(tasks, task, path), do: [{task, path} | tasks] |> Enum.reverse()

  defp python(opts) do
    path =
      Keyword.get(opts, :python) ||
        if File.exists?("tmp/dspy-parity-venv/bin/python"),
          do: "tmp/dspy-parity-venv/bin/python",
          else: "python3"

    if String.contains?(path, "/"), do: Path.expand(path), else: path
  end

  @doc false
  def python_executable!(opts) do
    requested = python(opts)

    if String.contains?(requested, "/") do
      resolved = Path.expand(requested)

      if executable_file?(resolved) do
        resolved
      else
        invalid_python!(requested)
      end
    else
      case System.find_executable(requested) do
        nil -> invalid_python!(requested)
        resolved -> resolved
      end
    end
  end

  defp executable_file?(path) do
    case File.stat(path) do
      {:ok, %{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _other -> false
    end
  end

  defp invalid_python!(path) do
    Mix.raise("--python must name an executable: #{inspect(path)}")
  end

  defp run_dspy!(
         python,
         tasks,
         offset,
         max_examples,
         max_concurrency,
         generation_opts,
         dspy_model,
         api_key_env,
         campaign_id,
         out_dir,
         timeout
       ) do
    args =
      [
        "scripts/dspy_parity_runner.py",
        "--model",
        dspy_model,
        "--offset",
        to_string(offset),
        "--max-examples",
        to_string(max_examples),
        "--max-concurrency",
        to_string(max_concurrency),
        "--temperature",
        to_string(Keyword.fetch!(generation_opts, :temperature)),
        "--max-tokens",
        to_string(Keyword.fetch!(generation_opts, :max_tokens)),
        "--api-key-env",
        api_key_env
      ] ++
        reasoning_effort_args(generation_opts) ++
        [
          "--out",
          out_dir
        ] ++
        campaign_args(campaign_id) ++
        Enum.flat_map(tasks, fn {task, path} -> ["--#{task}", path] end)

    case ParitySidecar.run(python, args,
           timeout: timeout,
           secrets: [System.get_env(api_key_env)]
         ) do
      {:ok, output, 0} ->
        case parse_dspy_report_path(output.text) do
          {:ok, path} ->
            path

          :error ->
            Mix.raise(
              "DSPy runner did not print DSPY_REPORT_PATH sentinel:\n#{ParitySidecar.diagnostic(output)}"
            )
        end

      {:ok, output, status} ->
        Mix.raise(
          "DSPy runner failed with status #{status}:\n#{ParitySidecar.diagnostic(output)}"
        )

      {:error, :timeout, output} ->
        Mix.raise(
          "DSPy runner timed out after #{timeout}ms:\n#{ParitySidecar.diagnostic(output)}"
        )
    end
  end

  defp dspy_timeout(opts) do
    case Keyword.get(opts, :dspy_timeout_ms) do
      nil ->
        :infinity

      timeout when is_integer(timeout) and timeout > 0 ->
        timeout

      timeout ->
        Mix.raise("--dspy-timeout-ms must be a positive integer, got: #{inspect(timeout)}")
    end
  end

  @doc false
  def parse_dspy_report_path(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.find_value(fn
      "DSPY_REPORT_PATH=" <> path -> {:ok, path}
      _line -> nil
    end)
    |> case do
      nil -> :error
      {:ok, path} -> {:ok, path}
    end
  end

  defp campaign_args(nil), do: []
  defp campaign_args(campaign_id), do: ["--campaign-id", campaign_id]

  defp reasoning_effort_args(generation_opts) do
    case Keyword.get(generation_opts, :reasoning_effort) do
      nil -> []
      value -> ["--reasoning-effort", to_string(value)]
    end
  end

  defp parity_report(imp, dspy, generation_opts, campaign_id, runner_order) do
    imp_tasks = Map.new(imp["tasks"], &{&1["task"], &1})
    dspy_tasks = Map.new(dspy["tasks"], &{&1["task"], &1})
    task_names = Enum.sort((Map.keys(imp_tasks) ++ Map.keys(dspy_tasks)) |> Enum.uniq())

    tasks =
      Enum.map(task_names, fn task ->
        compare_task(task, imp_tasks[task], dspy_tasks[task])
      end)

    %{
      "schema_version" => 1,
      "generated_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "git_sha" => git_sha(),
      "campaign_id" => campaign_id,
      "runner_order" => Atom.to_string(runner_order),
      "imp" => Map.take(imp, ["git_sha", "elixir", "otp", "model", "mode"]),
      "dspy" => Map.take(dspy, ["git_sha", "python", "dspy_version", "model", "mode"]),
      "execution" => %{
        "max_concurrency" =>
          tasks
          |> Enum.map(&(&1["max_concurrency"] || 1))
          |> Enum.max(fn -> 1 end),
        "runner_order" => Atom.to_string(runner_order)
      },
      "generation" => %{
        "temperature" => Keyword.fetch!(generation_opts, :temperature),
        "max_tokens" => Keyword.fetch!(generation_opts, :max_tokens),
        "reasoning_effort" => Keyword.get(generation_opts, :reasoning_effort),
        "prompt_contract" => prompt_contract(),
        "requested" => Map.new(generation_opts),
        "imp" => imp["generation"],
        "dspy" => dspy["generation"]
      },
      "aggregate" => %{
        "imp_score" => imp["aggregate_score"],
        "dspy_score" => dspy["aggregate_score"],
        "score_delta" => imp["aggregate_score"] - dspy["aggregate_score"],
        "imp_duration_ms" => total_duration(imp["tasks"]),
        "dspy_duration_ms" => total_duration(dspy["tasks"]),
        "latency_ratio_imp_over_dspy" =>
          ratio(total_duration(imp["tasks"]), total_duration(dspy["tasks"]))
      },
      "tasks" => tasks,
      "evidence" => evidence_summary(tasks),
      "parity" => parity_summary(tasks, imp["aggregate_score"], dspy["aggregate_score"])
    }
  end

  defp compare_task(task, imp, dspy) do
    row_agreement = row_agreement(imp, dspy)

    %{
      "task" => task,
      "offset" => max((imp && imp["offset"]) || 0, (dspy && dspy["offset"]) || 0),
      "examples" => max((imp && imp["examples"]) || 0, (dspy && dspy["examples"]) || 0),
      "max_concurrency" =>
        max((imp && imp["max_concurrency"]) || 1, (dspy && dspy["max_concurrency"]) || 1),
      "imp_score" => imp && imp["score"],
      "dspy_score" => dspy && dspy["score"],
      "score_delta" => score_delta(imp, dspy),
      "imp_duration_ms" => imp && imp["duration_ms"],
      "dspy_duration_ms" => dspy && dspy["duration_ms"],
      "latency_ratio_imp_over_dspy" =>
        ratio(imp && imp["duration_ms"], dspy && dspy["duration_ms"]),
      "imp_errors" => imp |> errors(),
      "dspy_errors" => dspy |> errors(),
      "evidence_complete" => Enum.all?(row_agreement, &(&1["row_evidence_complete"] == true)),
      "evidence_issues" => evidence_issues(imp, dspy, row_agreement),
      "row_agreement" => row_agreement,
      "supporting_metrics" => supporting_metrics(task, imp, dspy)
    }
  end

  defp generation_metadata(model, generation_opts, runtime, opts) do
    requested = Map.new(generation_opts)
    {effective, warnings} = effective_generation(model, generation_opts)

    requested
    |> Map.merge(%{
      "runtime" => runtime,
      "prompt_contract" => prompt_contract()[runtime],
      "requested" => requested,
      "effective" => effective,
      "wire_api" => wire_api(model, runtime),
      "warnings" => warnings,
      "note" =>
        "requested records the benchmark intent; effective and wire_api record deterministic runtime/provider translation known before the request is sent"
    })
    |> maybe_put_transport(opts)
  end

  defp maybe_put_transport(metadata, opts) do
    case req_llm_pool_config(opts) do
      nil -> metadata
      pool -> Map.put(metadata, "transport", %{"req_llm_pool" => pool})
    end
  end

  @doc false
  def req_llm_pool_config(opts) do
    pool =
      %{}
      |> maybe_put_pool("protocols", req_llm_pool_protocols(opts))
      |> maybe_put_pool("size", Keyword.get(opts, :req_llm_pool_size))
      |> maybe_put_pool("count", Keyword.get(opts, :req_llm_pool_count))

    if map_size(pool) == 0, do: nil, else: pool
  end

  defp maybe_put_pool(pool, _key, nil), do: pool
  defp maybe_put_pool(pool, key, value), do: Map.put(pool, key, value)

  defp effective_generation(model, generation_opts) do
    model = model |> to_string() |> String.downcase()
    max_tokens = Keyword.fetch!(generation_opts, :max_tokens)
    temperature = Keyword.fetch!(generation_opts, :temperature)
    reasoning_effort = Keyword.get(generation_opts, :reasoning_effort)

    cond do
      reasoning_model?(model) ->
        {%{"max_completion_tokens" => max_tokens}
         |> maybe_put_string("reasoning_effort", reasoning_effort),
         [
           "Renamed max_tokens to max_completion_tokens for reasoning model profile",
           "Dropped temperature because this model profile does not support sampling parameters"
         ]}

      fixed_temperature_model?(model) ->
        {%{"max_tokens" => max_tokens},
         [
           "Dropped temperature because this model profile only supports provider default temperature"
         ]}

      true ->
        {%{"temperature" => temperature, "max_tokens" => max_tokens}
         |> maybe_put_string("reasoning_effort", reasoning_effort), []}
    end
  end

  defp maybe_put_string(map, _key, nil), do: map
  defp maybe_put_string(map, key, value), do: Map.put(map, key, value)

  defp reasoning_model?(model),
    do: String.match?(model, ~r/(^|[-_:])(gpt-5|o[134])/) or String.contains?(model, "reasoning")

  defp fixed_temperature_model?(model), do: model in ["chat-latest"]

  defp wire_api(model, "imp_req_llm") do
    model = model |> to_string() |> String.downcase()

    cond do
      String.starts_with?(model, "anthropic:") ->
        "anthropic_messages"

      String.starts_with?(model, "google:") ->
        "google_generate_content"

      reasoning_model?(model) or String.match?(model, ~r/(gpt-4o|gpt-4\.1)/) ->
        "openai_responses"

      true ->
        "openai_chat_completions"
    end
  end

  defp wire_api(model, "python_dspy") do
    model = model |> to_string() |> String.downcase()

    cond do
      String.starts_with?(model, "anthropic/") ->
        "litellm_anthropic_messages"

      String.starts_with?(model, "gemini/") or String.starts_with?(model, "google/") ->
        "litellm_google_generate_content"

      dspy_responses_model?(model) ->
        "openai_responses"

      dspy_reasoning_model?(model) ->
        "litellm_chat_completion_with_max_completion_tokens"

      true ->
        "litellm_chat_completion"
    end
  end

  defp dspy_reasoning_model?(model), do: String.match?(model, ~r/(^|[-_:])o[134]/)
  defp dspy_responses_model?(model), do: String.contains?(String.trim(model, "/"), "responses/")

  defp prompt_contract do
    Imp.BenchmarkTruth.Contract.current_prompt_contract()
  end

  defp row_agreement(nil, _dspy), do: []
  defp row_agreement(_imp, nil), do: []

  defp row_agreement(imp, dspy) do
    imp_rows = rows_by_absolute_index(imp)
    dspy_rows = rows_by_absolute_index(dspy)

    (Map.keys(imp_rows) ++ Map.keys(dspy_rows))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn absolute_index ->
      row = imp_rows[absolute_index]
      other = dspy_rows[absolute_index]
      imp_answer = answer(row)
      dspy_answer = other && get_in(other, ["prediction", "answer"])
      pass_agreement = other && row["passed"] == other["passed"]
      answer_agreement = other && normalize_answer(imp_answer) == normalize_answer(dspy_answer)

      agreement = %{
        "index" => local_index(row, other, absolute_index),
        "absolute_index" => absolute_index,
        "imp_row_present" => row != nil,
        "dspy_row_present" => other != nil,
        "row_evidence_complete" => row != nil and other != nil,
        "imp_passed" => row && row["passed"],
        "dspy_passed" => other && other["passed"],
        "pass_agreement" => pass_agreement,
        "answer_agreement" => answer_agreement,
        "imp_answer" => imp_answer,
        "dspy_answer" => dspy_answer,
        "imp_duration_ms" => row && row["duration_ms"],
        "dspy_duration_ms" => other && other["duration_ms"],
        "imp_instrumentation" => (row && row["instrumentation"]) || %{},
        "dspy_instrumentation" => (other && other["instrumentation"]) || %{},
        "imp_metric_metadata" => (row && row["metric_metadata"]) || %{},
        "dspy_metric_metadata" => (other && other["metric_metadata"]) || %{}
      }

      if pass_agreement == true and answer_agreement == true do
        agreement
      else
        Map.put(agreement, "diagnostic", %{
          "imp" => row && row["diagnostic"],
          "imp_error" => row && row["error"],
          "dspy_error" => other && other["error"]
        })
      end
    end)
  end

  defp rows_by_absolute_index(nil), do: %{}

  defp rows_by_absolute_index(task) do
    offset = task["offset"] || 0

    task
    |> Map.get("rows", [])
    |> Map.new(fn row ->
      absolute_index = row["absolute_index"] || offset + row["index"]
      {absolute_index, row}
    end)
  end

  defp local_index(row, _other, _absolute_index) when is_map(row), do: row["index"]
  defp local_index(_row, other, _absolute_index) when is_map(other), do: other["index"]
  defp local_index(_row, _other, absolute_index), do: absolute_index

  defp evidence_issues(imp, dspy, row_agreement) do
    []
    |> maybe_issue(imp == nil, "missing_imp_task")
    |> maybe_issue(dspy == nil, "missing_dspy_task")
    |> maybe_issue(imp && dspy && imp["offset"] != dspy["offset"], "offset_mismatch")
    |> maybe_issue(imp && dspy && imp["examples"] != dspy["examples"], "example_count_mismatch")
    |> maybe_issue(imp && dspy && imp["sha256"] != dspy["sha256"], "dataset_sha256_mismatch")
    |> maybe_issue(errors(imp) not in [nil, 0], "imp_runner_errors")
    |> maybe_issue(errors(dspy) not in [nil, 0], "dspy_runner_errors")
    |> maybe_issue(
      Enum.any?(row_agreement, &(&1["row_evidence_complete"] != true)),
      "missing_counterpart_rows"
    )
  end

  defp maybe_issue(issues, true, issue), do: [issue | issues]
  defp maybe_issue(issues, _condition, _issue), do: issues

  defp supporting_metrics("hotpotqa", imp, dspy) do
    %{
      "official_hotpotqa_f1" => %{
        "imp" => average_metric(imp, "official_hotpotqa_f1"),
        "dspy" => average_metric(dspy, "official_hotpotqa_f1"),
        "delta" =>
          metric_delta(
            average_metric(imp, "official_hotpotqa_f1"),
            average_metric(dspy, "official_hotpotqa_f1")
          ),
        "note" =>
          "Supporting evidence only: strict parity score remains exact match for this campaign lineage."
      }
    }
  end

  defp supporting_metrics(_task, _imp, _dspy), do: %{}

  defp average_metric(nil, _key), do: nil

  defp average_metric(task, key) do
    values =
      task
      |> Map.get("rows", [])
      |> Enum.map(&get_in(&1, ["metric_metadata", key]))
      |> Enum.filter(&is_number/1)

    case values do
      [] -> nil
      _values -> Enum.sum(values) / length(values)
    end
  end

  defp metric_delta(nil, _right), do: nil
  defp metric_delta(_left, nil), do: nil
  defp metric_delta(left, right), do: left - right

  defp answer(%{"prediction" => nil}), do: nil

  defp answer(%{"prediction" => prediction}) when is_map(prediction) do
    Map.get(prediction, "answer") || Map.get(prediction, :answer)
  end

  defp answer(_row), do: nil

  defp evidence_summary(tasks) do
    examples = tasks |> Enum.map(&(&1["examples"] || 0)) |> Enum.sum()
    full_examples = tasks |> Enum.map(&Map.get(@full_lengths, &1["task"], 0)) |> Enum.sum()

    %{
      "examples" => examples,
      "full_examples" => full_examples,
      "scale" => evidence_scale(examples, full_examples),
      "adequate_for_research_sample" => examples >= 200 or examples == full_examples,
      "adequate_for_full_parity_claim" => examples == full_examples and full_examples > 0,
      "note" =>
        "Smoke samples prove wiring only. Use full fetched manifests and repeated current-model runs before making production parity claims."
    }
  end

  defp evidence_scale(examples, full_examples)
       when examples == full_examples and full_examples > 0,
       do: "full"

  defp evidence_scale(examples, _full_examples) when examples >= 200, do: "research_sample"
  defp evidence_scale(_examples, _full_examples), do: "smoke"

  defp parity_summary(tasks, imp_score, dspy_score) do
    task_score_gaps = Enum.map(tasks, &abs(&1["score_delta"] || 0.0))
    max_task_gap = Enum.max(task_score_gaps, fn -> 0.0 end)
    score_parity? = abs(imp_score - dspy_score) <= 0.01 and max_task_gap <= 0.01

    %{
      "score_parity" => score_parity?,
      "max_task_score_gap" => max_task_gap,
      "note" => parity_note(score_parity?)
    }
  end

  defp parity_note(true) do
    "Strict score parity passed on this sample. Latency is reported as evidence, not pass/fail, because provider variance and DSPy retries/cache behavior can dominate small runs."
  end

  defp parity_note(false) do
    "Strict score parity did not pass on this sample. Inspect task score gaps and row-level pass/answer agreement before making parity claims."
  end

  defp score_delta(nil, _dspy), do: nil
  defp score_delta(_imp, nil), do: nil
  defp score_delta(imp, dspy), do: imp["score"] - dspy["score"]

  defp errors(nil), do: nil
  defp errors(task), do: length(task["errors"] || [])

  defp total_duration(tasks), do: Enum.sum(Enum.map(tasks || [], &(&1["duration_ms"] || 0.0)))

  defp ratio(_left, nil), do: nil
  defp ratio(_left, 0), do: nil
  defp ratio(nil, _right), do: nil
  defp ratio(left, right), do: Float.round(left / right, 3)

  defp normalize_answer(nil), do: nil

  defp normalize_answer(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}\s]/u, " ")
    |> String.split()
    |> Enum.reject(&(&1 in ["a", "an", "the"]))
    |> Enum.join(" ")
  end

  defp git_sha do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _other -> nil
    end
  end

  defp timestamp_slug do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
    |> String.replace(~r/[^0-9A-Za-z]/, "")
  end

  defp model_slug(model), do: String.replace(model, ~r/[^0-9A-Za-z_.-]/, "_")
end
