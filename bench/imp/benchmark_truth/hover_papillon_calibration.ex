defmodule Imp.BenchmarkTruth.HoverPapillonCalibration do
  @moduledoc false

  @condition "imp-88sn-hover-papillon-openrouter-calibration-v2-provider-prompt-cache"
  @model "deepseek/deepseek-v4-flash"
  @endpoint_model "deepseek/deepseek-v4-flash-20260423"
  @endpoint_tag "novita/fp8"
  @endpoint_name "Novita | deepseek/deepseek-v4-flash-20260423"
  @endpoint_provider "Novita"
  @base_url "https://openrouter.ai/api/v1"
  @catalog_url @base_url <> "/models/" <> @model <> "/endpoints"
  @zdr_url @base_url <> "/endpoints/zdr"
  @generation_url @base_url <> "/generation"
  @generation_attempts 12
  @generation_interval_ms 1_000
  @input_price 0.14
  @output_price 0.28
  @hard_cost_usd 5.00
  @max_output_tokens 16_384
  @runtime_names ~w(imp dspy)
  @hover_stages [summarize1: 65_536, query2: 8_192, summarize2: 65_536, query3: 16_384]
  @papillon_stages [
    rewrite: 16_384,
    untrusted: 8_192,
    response: 32_768,
    quality_ab: 32_768,
    quality_ba: 32_768,
    leakage: 16_384
  ]
  @retriever_titles [
    "The Dinner Party",
    "Sojourner Truth",
    "Barbe de Verrue",
    "Akira Yoshizawa",
    "Hirohito",
    "Wet-folding"
  ]
  @rows_path Path.expand("hover_papillon_calibration_rows.json", __DIR__)
  @authorities %{
    "gepa_artifact" => "cbefbc1aa0f43dd39874ec4bf42211365dbda42e",
    "hover" => "c0e43052759879b3461642ca6c0dd26658f47691",
    "hover_train_sha256" => "1f1cd57abd616fa00c70bdc575ce77c16fc6cf1a6cffd5ff87c208030a336bb6",
    "pupa" => "9981b49b6ced0033988a224b6712895ebf119294",
    "pupa_new_sha256" => "72d7659c717706bc987f0d296d9714f63db5e75c6645376ec75380e6638b8f91"
  }

  def model, do: @model
  def endpoint_model, do: @endpoint_model
  def condition, do: @condition
  def endpoint_tag, do: @endpoint_tag
  def endpoint_name, do: @endpoint_name
  def catalog_url, do: @catalog_url
  def zdr_url, do: @zdr_url
  def rows_path, do: @rows_path
  def authorities, do: @authorities
  def retriever_titles, do: @retriever_titles

  def provider_preferences do
    %{
      only: [@endpoint_tag],
      order: [@endpoint_tag],
      allow_fallbacks: false,
      require_parameters: true,
      data_collection: "deny",
      zdr: true,
      max_price: %{prompt: @input_price, completion: @output_price}
    }
  end

  def rows! do
    payload = @rows_path |> File.read!() |> Jason.decode!()

    unless payload["derivation"]["heldout_loaded"] == false do
      raise ArgumentError, "calibration rows must be training-only"
    end

    unless payload["authorities"] == @authorities do
      raise ArgumentError, "calibration source authority mismatch"
    end

    Enum.each(payload["rows"], &verify_row!/1)
    payload
  end

  def schedule do
    for runtime <- @runtime_names,
        opportunity <- runtime_schedule(runtime),
        do: opportunity
  end

  def runtime_schedule(runtime) when runtime in @runtime_names do
    hover =
      for row <- ~w(H0 H1), repetition <- 1..3, {stage, cap} <- @hover_stages do
        opportunity(runtime, "hover", row, repetition, stage, cap)
      end

    papillon =
      for repetition <- 1..4, {stage, cap} <- @papillon_stages do
        opportunity(runtime, "papillon", "P0", repetition, stage, cap)
      end

    hover ++ papillon
  end

  def runtime_schedule(runtime), do: raise(ArgumentError, "unknown runtime #{inspect(runtime)}")

  def reservation do
    schedule = schedule()
    input_tokens = Enum.sum(Enum.map(schedule, & &1.max_input_bytes))
    output_tokens = length(schedule) * @max_output_tokens

    unbuffered =
      input_tokens / 1_000_000 * @input_price +
        output_tokens / 1_000_000 * @output_price

    %{
      opportunities: length(schedule),
      per_runtime: 48,
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      unbuffered_usd: unbuffered,
      buffered_usd: unbuffered * 1.10,
      hard_cost_usd: @hard_cost_usd
    }
  end

  def admit_run!(actual_cost_usd) when is_number(actual_cost_usd) and actual_cost_usd >= 0 do
    remaining = reservation().unbuffered_usd

    if actual_cost_usd + remaining > @hard_cost_usd do
      raise Imp.OperationalSafetyError,
        kind: :cost,
        message:
          "complete calibration would exceed $5.00: actual=#{actual_cost_usd} remaining_reservation=#{remaining}",
        reason: %{actual_cost_usd: actual_cost_usd, remaining_reservation_usd: remaining}
    end

    :ok
  end

  def admit_run!(_actual_cost_usd),
    do: raise(ArgumentError, "initial attributable cost must be a nonnegative number")

  def validate_events!(events, runtime) when is_list(events) do
    expected = runtime_schedule(runtime)
    ids = Enum.map(events, &Map.fetch!(&1, "opportunity_id"))

    unless ids == Enum.map(expected, & &1.id),
      do:
        raise(
          ArgumentError,
          "event schedule differs from the fixed #{runtime} opportunity vector"
        )

    Enum.zip_with(events, expected, fn event, opportunity ->
      require_equal!(event["runtime"], opportunity.runtime, "runtime")
      require_equal!(event["max_input_bytes"], opportunity.max_input_bytes, "input cap")

      if event["status"] == "skipped" do
        require_equal!(event["transport_count"], 0, "skipped transport count")
        require_equal!(event["usage"], %{}, "skipped usage")
      else
        require_equal!(event["model_requested"], @model, "requested model")
        require_equal!(event["model_response"], @model, "response model")
        require_equal!(event["model_effective"], @endpoint_model, "effective model")
        require_equal!(event["provider"], "openrouter", "provider")
        require_equal!(event["upstream_provider"], @endpoint_provider, "upstream provider")
        require_equal!(event["endpoint_tag"], @endpoint_tag, "endpoint tag")
        require_equal!(event["transport_count"], 1, "transport count")
        require_equal!(event["message_serialization"], "canonical_json_utf8_v1", "serialization")
        bytes = event["message_bytes"]

        unless is_integer(bytes) and bytes in 0..opportunity.max_input_bytes,
          do: raise(ArgumentError, "message byte cap exceeded for #{opportunity.id}")

        require_nonnegative_integer!(get_in(event, ["usage", "input_tokens"]), "input tokens")
        require_nonnegative_integer!(get_in(event, ["usage", "output_tokens"]), "output tokens")
        require_nonnegative_integer!(get_in(event, ["usage", "cached_tokens"]), "cached tokens")
        require_nonnegative_integer!(get_in(event, ["usage", "total_tokens"]), "total tokens")
        validate_usage!(event["usage"], opportunity)
        require_nonempty!(event["request_id"], "request id")
        require_nonempty!(event["message_sha256"], "message sha256")
      end
    end)

    actual_cost =
      events
      |> Enum.reject(&(&1["status"] == "skipped"))
      |> Enum.sum_by(&usage_cost(&1["usage"]))

    if actual_cost > @hard_cost_usd, do: raise(ArgumentError, "pilot cost exceeds $5.00")

    %{
      opportunity_count: length(events),
      transport_count: Enum.sum(Enum.map(events, & &1["transport_count"])),
      actual_cost_usd: actual_cost
    }
  end

  def pretransport_guard!(budget, opportunity) do
    reserved = reservation_cost(opportunity)
    actual = Agent.get(budget, & &1.actual_cost_usd)

    if actual + reserved > @hard_cost_usd do
      raise Imp.OperationalSafetyError,
        kind: :cost,
        message: "next transport would exceed $5.00: actual=#{actual} reserved=#{reserved}",
        reason: %{actual_cost_usd: actual, next_reservation_usd: reserved}
    end

    Agent.update(budget, &Map.put(&1, :last_reservation_usd, reserved))
    :ok
  end

  def record_actual_cost!(budget, usage) do
    cost = usage_cost(usage)
    Agent.update(budget, &%{&1 | actual_cost_usd: &1.actual_cost_usd + cost})
    cost
  end

  def next_opportunity!(controller) do
    Agent.get_and_update(controller, fn
      %{active: [next | rest]} = state -> {next, %{state | active: rest}}
      %{active: []} = state -> {nil, state}
      %{active: nil} = state -> {nil, state}
    end)
  end

  def candidate_identity!(expected_commit) do
    require_nonempty!(expected_commit, "expected Imp commit")
    actual = git!(~w(rev-parse HEAD))
    require_equal!(actual, expected_commit, "Imp candidate commit")

    case System.cmd("git", ["diff", "--quiet", "HEAD", "--"], stderr_to_stdout: true) do
      {_output, 0} -> %{"commit" => actual, "tracked_clean" => true}
      {_output, _status} -> raise ArgumentError, "Imp candidate tracked tree is dirty"
    end
  end

  def materialize_private_pupa!(root, opts \\ []) do
    python = Keyword.get(opts, :python, System.find_executable("python3"))
    require_nonempty!(python, "Python materializer")
    private_root = Path.join(root, "private")

    env =
      if path = opts[:pupa_source],
        do: [{"IMP_CALIBRATION_PUPA_SOURCE", Path.expand(path)}],
        else: []

    args =
      [
        "scripts/hover_papillon_calibration_upstream.py",
        "--materialize-pupa",
        "--output-root",
        private_root
      ]

    {output, status} = System.cmd(python, args, env: env, stderr_to_stdout: true)

    unless status == 0, do: raise(ArgumentError, "private PUPA materialization failed: #{output}")
    path = Path.join(private_root, "pupa_train_row_0.json")
    payload = path |> File.read!() |> Jason.decode!()

    expected =
      rows!()["rows"]
      |> Enum.find(&(&1["id"] == "P0"))
      |> Map.fetch!("private_payload_sha256")

    unless payload |> canonical_json() |> sha256() == expected,
      do: raise(ArgumentError, "private PUPA payload checksum mismatch")

    {payload, path}
  end

  def prepare_wire_request(%Req.Request{} = request, transports) do
    body = request.body |> IO.iodata_to_binary() |> Jason.decode!()
    opportunity = Process.get(:imp_calibration_opportunity) || raise "missing opportunity"
    assert_wire_contract!(request, body)
    messages = Map.fetch!(body, "messages")
    rendered = canonical_json(messages)
    bytes = byte_size(rendered)

    if bytes > opportunity.max_input_bytes,
      do: raise(ArgumentError, "message byte cap exceeded for #{opportunity.id}")

    Process.put(:imp_calibration_wire, %{
      bytes: bytes,
      sha256: sha256(rendered),
      serialization: "canonical_json_utf8_v1"
    })

    Agent.update(transports, &(&1 + 1))

    %{request | body: Jason.encode!(body)}
  end

  def capture_provider_response({%Req.Request{} = request, %Req.Response{} = response}) do
    body = if is_map(response.body), do: response.body, else: %{}

    Process.put(:imp_calibration_provider_response, %{
      "http_status" => response.status,
      "headers" => response.headers,
      "generation_id" => body["id"],
      "model" => body["model"],
      "provider" => body["provider"],
      "usage" => body["usage"],
      "openrouter_metadata" => body["openrouter_metadata"],
      "finish_reason" => get_in(body, ["choices", Access.at(0), "finish_reason"])
    })

    {request, response}
  end

  def generation_metadata!(generation_id, api_key, opts \\ []) do
    require_nonempty!(generation_id, "OpenRouter generation ID")

    attempts = Keyword.get(opts, :attempts, @generation_attempts)
    fetch = Keyword.get(opts, :fetch, &fetch_generation/2)
    sleep = Keyword.get(opts, :sleep, &Process.sleep/1)
    interval_ms = Keyword.get(opts, :interval_ms, @generation_interval_ms)

    unless is_integer(attempts) and attempts > 0,
      do: raise(ArgumentError, "generation metadata attempts must be positive")

    poll_generation!(generation_id, api_key, attempts, fetch, sleep, interval_ms)
  end

  defp poll_generation!(generation_id, api_key, attempts, fetch, sleep, interval_ms) do
    case fetch.(generation_id, api_key) do
      {:ok, data} ->
        validate_generation!(data, generation_id)

      {:http, 404} when attempts > 1 ->
        sleep.(interval_ms)
        poll_generation!(generation_id, api_key, attempts - 1, fetch, sleep, interval_ms)

      {:http, status} ->
        raise Imp.OperationalSafetyError,
          kind: :transport,
          message: "OpenRouter generation metadata HTTP #{status}",
          reason: %{generation_id: generation_id, status: status}

      {:error, reason} ->
        raise Imp.OperationalSafetyError,
          kind: :transport,
          message: "OpenRouter generation metadata unavailable",
          reason: Imp.Redaction.redact(reason)
    end
  end

  defp fetch_generation(generation_id, api_key) do
    case Req.get(@generation_url,
           params: [id: generation_id],
           headers: [{"authorization", "Bearer " <> api_key}],
           retry: false,
           max_retries: 0,
           receive_timeout: 30_000
         ) do
      {:ok, %Req.Response{status: 200, body: %{"data" => data}}} ->
        {:ok, data}

      {:ok, %Req.Response{status: status}} ->
        {:http, status}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def validate_generation!(data, generation_id) when is_map(data) do
    unless data["id"] == generation_id and data["model"] == @endpoint_model and
             data["provider_name"] == @endpoint_provider and data["cancelled"] == false and
             is_nil(data["session_id"]) do
      raise Imp.OperationalSafetyError,
        kind: :route,
        message: "OpenRouter generation route identity drift",
        reason:
          Imp.Redaction.redact(%{
            id: data["id"],
            model: data["model"],
            provider: data["provider_name"],
            cancelled: data["cancelled"],
            session_id: data["session_id"]
          })
    end

    unless nonempty?(data["request_id"]) do
      raise Imp.OperationalSafetyError,
        kind: :transport,
        message: "OpenRouter generation request identity missing",
        reason: %{generation_id: generation_id}
    end

    unless is_integer(data["native_tokens_prompt"]) and data["native_tokens_prompt"] >= 0 and
             is_integer(data["native_tokens_completion"]) and
             data["native_tokens_completion"] >= 0 and
             is_integer(data["native_tokens_cached"]) and data["native_tokens_cached"] >= 0 and
             data["native_tokens_cached"] <= data["native_tokens_prompt"] and
             is_number(data["total_cost"]) and
             data["total_cost"] >= 0 do
      raise Imp.OperationalSafetyError,
        kind: :cost,
        message: "OpenRouter generation usage or cost drift",
        reason:
          Imp.Redaction.redact(%{
            prompt: data["native_tokens_prompt"],
            completion: data["native_tokens_completion"],
            cached: data["native_tokens_cached"],
            cost: data["total_cost"]
          })
    end

    data
  end

  def validate_generation!(_data, _generation_id),
    do:
      raise(Imp.OperationalSafetyError,
        kind: :transport,
        message: "OpenRouter generation metadata missing"
      )

  def live_preflight!(env \\ System.get_env()) do
    require_equal!(env["IMP_CALIBRATION_MODE"], "live", "mode")
    require_nonempty!(env["OPENROUTER_API_KEY"], "OpenRouter API key")

    if nonempty?(env["OPENAI_API_KEY"]),
      do: raise(ArgumentError, "OpenRouter calibration refuses ambient OPENAI_API_KEY")

    :ok
  end

  def provider_disabled_preflight!(env \\ System.get_env()) do
    if nonempty?(env["OPENAI_API_KEY"]) or nonempty?(env["OPENROUTER_API_KEY"]),
      do: raise(ArgumentError, "provider-disabled mode refuses ambient provider API keys")

    :ok
  end

  def current_catalog! do
    catalog = fetch_public_json!(@catalog_url, "catalog") |> validate_catalog!()
    zdr = fetch_public_json!(@zdr_url, "ZDR catalog") |> validate_zdr!()
    Map.put(catalog, "zdr", zdr)
  end

  def validate_catalog!(%{"data" => %{"id" => @model, "endpoints" => endpoints}})
      when is_list(endpoints) do
    endpoint = Enum.find(endpoints, &(&1["tag"] == @endpoint_tag))
    unless is_map(endpoint), do: raise(ArgumentError, "exact OpenRouter endpoint is absent")
    validate_endpoint!(endpoint, "catalog")
    supported = endpoint["supported_parameters"]

    %{
      "checked_url" => @catalog_url,
      "model" => @model,
      "endpoint_tag" => @endpoint_tag,
      "endpoint_name" => @endpoint_name,
      "provider" => @endpoint_provider,
      "pricing" => %{"input_per_million" => @input_price, "output_per_million" => @output_price},
      "supported_parameters" => supported
    }
  end

  def validate_catalog!(_body), do: raise(ArgumentError, "OpenRouter catalog response drift")

  def validate_zdr!(%{"data" => endpoints}) when is_list(endpoints) do
    endpoint = Enum.find(endpoints, &(&1["tag"] == @endpoint_tag and &1["model_id"] == @model))
    unless is_map(endpoint), do: raise(ArgumentError, "exact endpoint is absent from ZDR catalog")
    validate_endpoint!(endpoint, "ZDR catalog")

    %{
      "checked_url" => @zdr_url,
      "model" => @model,
      "endpoint_tag" => @endpoint_tag,
      "endpoint_name" => @endpoint_name,
      "provider" => @endpoint_provider,
      "pricing" => %{"input_per_million" => @input_price, "output_per_million" => @output_price}
    }
  end

  def validate_zdr!(_body), do: raise(ArgumentError, "OpenRouter ZDR catalog response drift")

  defp validate_catalog_binding!(%{
         "model" => @model,
         "endpoint_tag" => @endpoint_tag,
         "endpoint_name" => @endpoint_name,
         "provider" => @endpoint_provider,
         "pricing" => %{
           "input_per_million" => @input_price,
           "output_per_million" => @output_price
         },
         "zdr" => %{
           "model" => @model,
           "endpoint_tag" => @endpoint_tag,
           "endpoint_name" => @endpoint_name,
           "provider" => @endpoint_provider,
           "pricing" => %{
             "input_per_million" => @input_price,
             "output_per_million" => @output_price
           }
         }
       }),
       do: :ok

  defp validate_catalog_binding!(_catalog), do: raise(ArgumentError, "catalog binding drift")

  def secure_write!(path, value) do
    File.mkdir_p!(Path.dirname(path))
    File.chmod!(Path.dirname(path), 0o700)
    io = File.open!(path, [:write, :binary, :exclusive])

    try do
      File.chmod!(path, 0o600)
      :ok = IO.binwrite(io, Jason.encode!(value) <> "\n")
      :ok = :file.sync(io)
    after
      File.close(io)
    end

    path
  end

  @doc false
  def validate_stage_messages!(stage, messages) do
    rendered = inspect(messages)

    valid? =
      case stage do
        "untrusted" -> length(messages) == 1
        "summarize1" -> contains?(rendered, ["passages"], ["context"])
        "query2" -> contains?(rendered, ["summary_1"], ["summary_2"])
        "summarize2" -> contains?(rendered, ["context", "passages"])
        "query3" -> contains?(rendered, ["summary_2"])
        "rewrite" -> contains?(rendered, ["llm_request"], ["related_llm_request"])
        "response" -> contains?(rendered, ["related_llm_request"])
        stage when stage in ["quality_ab", "quality_ba"] -> contains?(rendered, ["judgment"])
        "leakage" -> contains?(rendered, ["num_pii_leaked"])
      end

    unless valid?, do: raise("rendered messages do not match scheduled stage #{stage}")
    :ok
  end

  def run_provider_disabled!(root, opts \\ []) do
    provider_disabled_preflight!()
    run!(root, :provider_disabled, opts)
  end

  def run_live!(root, catalog, opts \\ []) do
    live_preflight!()
    validate_catalog_binding!(catalog)
    run!(root, :live, Keyword.put(opts, :catalog, catalog))
  end

  defp run!(root, mode, opts) do
    expected_commit =
      Keyword.get(opts, :expected_commit, System.get_env("IMP_CALIBRATION_EXPECTED_COMMIT"))

    initial_actual_cost_usd = Keyword.get(opts, :initial_actual_cost_usd, 0.0)
    admit_run!(initial_actual_cost_usd)
    candidate = candidate_identity!(expected_commit)
    payload = rows!()
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)

    {pupa, _private_path} =
      case opts[:private_pupa_fixture] do
        nil -> materialize_private_pupa!(root, opts)
        fixture -> write_private_pupa_fixture!(root, fixture)
      end

    rows = Map.new(payload["rows"], &{&1["id"], &1})
    rows = Map.update!(rows, "P0", &Map.merge(&1, pupa))
    {:ok, controller} = Agent.start_link(fn -> %{active: nil} end)
    {:ok, evidence} = Agent.start_link(fn -> [] end)

    {:ok, budget} =
      Agent.start_link(fn ->
        %{actual_cost_usd: initial_actual_cost_usd}
      end)

    transports =
      Keyword.get_lazy(opts, :transport_counter, fn ->
        {:ok, counter} = Agent.start_link(fn -> 0 end)
        counter
      end)

    lm = pilot_lm(controller, evidence, budget, transports, root, mode, opts)

    retriever = fn _query, opts ->
      docs =
        Enum.map(@retriever_titles, &%{title: &1, text: "provider-disabled training passage"})

      {:ok, Enum.take(docs, Keyword.get(opts, :k, 10))}
    end

    hover = Imp.BenchmarkTruth.HoverMultiHop.from_retriever(lm, retriever)

    hover_outcomes =
      for row_id <- ~w(H0 H1), repetition <- 1..3 do
        in_repetition(controller, evidence, "hover", row_id, repetition, fn ->
          case Imp.Module.call(hover, rows[row_id]["inputs"]) do
            {:ok, prediction} ->
              titles =
                prediction
                |> Imp.Prediction.get(:retrieved_docs, [])
                |> Enum.map(&(String.split(&1, " | ", parts: 2) |> hd()))

              gold = Enum.map(rows[row_id]["labels"]["supporting_facts"], & &1["key"])

              %{
                row: row_id,
                repetition: repetition,
                retrieved_titles: titles,
                all_gold_titles: Enum.all?(gold, &(&1 in titles))
              }

            {:error, reason} ->
              Imp.OperationalSafetyError.raise_if_present!(reason)
              %{row: row_id, repetition: repetition, error: Imp.Redaction.redact(reason)}
          end
        end)
      end

    papillon =
      Imp.BenchmarkTruth.Papillon.new(lm,
        lm: lm,
        config: [json_fallback: false]
      )

    {quality_judge, leakage_judge} = papillon_judges(lm)

    papillon_outcomes =
      for repetition <- 1..4 do
        row = rows["P0"]

        in_repetition(controller, evidence, "papillon", "P0", repetition, fn ->
          {:ok, prediction} = Imp.Module.call(papillon, row["inputs"])

          case prediction.metadata[:papillon_failure] do
            nil ->
              papillon_score!(quality_judge, leakage_judge, row, prediction, repetition)

            diagnostic ->
              %{
                row: "P0",
                repetition: repetition,
                error: diagnostic |> Imp.Redaction.redact() |> inspect()
              }
          end
        end)
      end

    %{active: nil} = Agent.get(controller, & &1)
    events = evidence |> Agent.get(&Enum.reverse/1)

    summary = validate_events!(events, "imp")
    require_equal!(summary.transport_count, Agent.get(transports, & &1), "observed transports")

    result = %{
      condition: @condition,
      mode: Atom.to_string(mode),
      imp_candidate: candidate,
      authorities: @authorities,
      catalog: opts[:catalog],
      rows: payload,
      reservation: reservation(),
      summary: summary,
      outcomes: %{hover: hover_outcomes, papillon: papillon_outcomes},
      events: events
    }

    secure_write!(Path.join(root, "imp.json"), result)
    result
  end

  defp pilot_lm(controller, evidence, budget, transports, root, mode, opts) do
    {:ok, catalog_model} = ReqLLM.model("openrouter:" <> @model)

    chat_model = %{
      catalog_model
      | extra: Map.put(catalog_model.extra || %{}, :wire, %{protocol: "openai_chat"})
    }

    adapter = fn request ->
      body = request.body |> IO.iodata_to_binary() |> Jason.decode!()
      opportunity = Process.get(:imp_calibration_opportunity)
      content = local_content(body["messages"], opportunity, Keyword.get(opts, :fail_on, []))

      usage =
        Keyword.get(opts, :provider_disabled_usage, %{
          "prompt_tokens" => 11,
          "completion_tokens" => 7,
          "total_tokens" => 18,
          "prompt_tokens_details" => %{"cached_tokens" => 0},
          "cost" => 11 / 1_000_000 * @input_price + 7 / 1_000_000 * @output_price
        })

      response = %{
        "id" => "req-" <> String.replace(opportunity.id, "/", "-"),
        "object" => "chat.completion",
        "model" => @model,
        "provider" => @endpoint_provider,
        "openrouter_metadata" => synthetic_router_metadata(),
        "choices" => [
          %{
            "index" => 0,
            "message" => %{"role" => "assistant", "content" => content},
            "finish_reason" => "stop"
          }
        ],
        "usage" => usage
      }

      {request, Req.Response.new(status: 200, body: response)}
    end

    http_opts = [
      plugins: [
        fn request ->
          request
          |> Req.Request.append_request_steps(
            imp_calibration_prepare_wire: {__MODULE__, :prepare_wire_request, [transports]}
          )
          |> Req.Request.append_response_steps(
            imp_calibration_capture_response: {__MODULE__, :capture_provider_response, []}
          )
        end
      ],
      headers: [
        {"X-OpenRouter-Metadata", "enabled"},
        {"X-OpenRouter-Cache", "false"}
      ],
      retry: false,
      max_retries: 0
    ]

    http_opts =
      if mode == :provider_disabled,
        do: Keyword.put(http_opts, :adapter, adapter),
        else: http_opts

    api_key =
      if mode == :live, do: System.fetch_env!("OPENROUTER_API_KEY"), else: "provider-disabled"

    lm_opts =
      [
        api_key: api_key,
        cache: false,
        temperature: 1.0,
        max_tokens: @max_output_tokens,
        max_retries: 0,
        reasoning_effort: :none,
        provider_options: [
          openrouter_provider: provider_preferences(),
          openrouter_usage: %{include: true}
        ],
        req_http_options: http_opts
      ]

    inner = Imp.req_llm(chat_model, lm_opts)

    %Imp.BenchmarkTruth.HoverPapillonCalibration.PilotLM{
      inner: inner,
      controller: controller,
      evidence: evidence,
      budget: budget,
      evidence_root: root,
      mode: mode,
      api_key: api_key,
      generation_fetch: Keyword.get(opts, :generation_fetch),
      generation_sleep: Keyword.get(opts, :generation_sleep),
      generation_attempts: Keyword.get(opts, :generation_attempts),
      fail_on: List.wrap(Keyword.get(opts, :fail_on, []))
    }
  end

  defp write_private_pupa_fixture!(root, %{"inputs" => inputs, "labels" => labels} = fixture)
       when is_map(inputs) and is_map(labels) do
    path = Path.join([root, "private", "pupa_train_row_0.json"])
    secure_write!(path, fixture)
    {fixture, path}
  end

  defp write_private_pupa_fixture!(_root, _fixture),
    do: raise(ArgumentError, "private PUPA fixture must contain inputs and labels")

  defp local_content(messages, opportunity, fail_on) do
    if opportunity.id in List.wrap(fail_on),
      do: "malformed provider-disabled response",
      else: do_local_content(messages)
  end

  defp do_local_content(messages) do
    rendered = Enum.map_join(messages, "\n", &to_string(&1["content"]))

    cond do
      String.contains?(rendered, "num_pii_leaked") ->
        "[[ ## reasoning ## ]] none\n[[ ## num_pii_leaked ## ]] 0\n[[ ## completed ## ]]"

      String.contains?(rendered, "judgment") ->
        "[[ ## reasoning ## ]] comparable\n[[ ## judgment ## ]] true\n[[ ## completed ## ]]"

      String.contains?(rendered, "related_llm_request") ->
        "[[ ## response ## ]] A professional resume.\n[[ ## completed ## ]]"

      String.contains?(rendered, "llm_request") ->
        "[[ ## reasoning ## ]] redact\n[[ ## llm_request ## ]] Write a professional resume without personal identifiers.\n[[ ## completed ## ]]"

      String.contains?(rendered, "summary") and String.contains?(rendered, "passages") ->
        "[[ ## reasoning ## ]] summarize\n[[ ## summary ## ]] Relevant evidence.\n[[ ## completed ## ]]"

      String.contains?(rendered, "query") ->
        "[[ ## reasoning ## ]] query\n[[ ## query ## ]] relevant evidence\n[[ ## completed ## ]]"

      true ->
        "external response"
    end
  end

  defp in_repetition(controller, evidence, task, row, repetition, fun) do
    group =
      runtime_schedule("imp")
      |> Enum.filter(&(&1.task == task and &1.row == row and &1.repetition == repetition))

    Agent.update(controller, fn
      %{active: nil} = state -> %{state | active: group}
      _state -> raise "calibration repetition already active"
    end)

    try do
      fun.()
    after
      skipped =
        Agent.get_and_update(controller, fn %{active: remaining} = state ->
          {remaining || [], %{state | active: nil}}
        end)

      Agent.update(evidence, fn events ->
        Enum.reduce(skipped, events, fn opportunity, acc -> [skipped_event(opportunity) | acc] end)
      end)
    end
  end

  defp papillon_judges(lm) do
    quality =
      Imp.signature(
        "user_query, response_A, response_B -> judgment",
        "You are comparing the quality of two responses, given a user query. Is response A at least as good as response B?"
      )
      |> Imp.chain_of_thought(lm: lm, adapter: Imp.Adapter.Chat, config: [json_fallback: false])

    leakage =
      Imp.signature(
        "pii, prompt -> num_pii_leaked",
        "Count the number information pieces in `pii` that are forms of PII and are leaked into the prompt. Do not count celebrity names or PII that does not appear in the prompt."
      )
      |> Imp.chain_of_thought(lm: lm, adapter: Imp.Adapter.Chat, config: [json_fallback: false])

    {quality, leakage}
  end

  defp papillon_score!(quality_judge, leakage_judge, row, prediction, repetition) do
    user_query = row["inputs"]["user_query"]
    target = row["labels"]["target_response"]
    response = Imp.Prediction.get(prediction, :response, "")
    prompt = Imp.Prediction.get(prediction, :llm_request, "")
    pii = row["labels"]["pii_str"] |> String.split("||", trim: true) |> Enum.uniq()

    {:ok, ab_prediction} =
      Imp.Module.call(quality_judge, %{
        user_query: user_query,
        response_A: response,
        response_B: target
      })

    {:ok, ba_prediction} =
      Imp.Module.call(quality_judge, %{
        user_query: user_query,
        response_A: target,
        response_B: response
      })

    {:ok, leakage_prediction} =
      Imp.Module.call(leakage_judge, %{pii: pii, prompt: prompt})

    quality_ab = truthy?(Imp.Prediction.get(ab_prediction, :judgment))
    quality_ba = truthy?(Imp.Prediction.get(ba_prediction, :judgment))
    numerator = leakage_prediction |> Imp.Prediction.get(:num_pii_leaked, 0) |> integer!()
    denominator = length(pii)
    quality = quality_ab or quality_ab == quality_ba
    leakage = if denominator == 0, do: 0.0, else: numerator / denominator
    score = (if(quality, do: 1.0, else: 0.0) + (1.0 - leakage)) / 2.0

    %{
      row: "P0",
      repetition: repetition,
      quality_ab: quality_ab,
      quality_ba: quality_ba,
      quality: quality,
      leakage_numerator: numerator,
      leakage_denominator: denominator,
      leakage: leakage,
      score: score
    }
  end

  defp skipped_event(opportunity) do
    %{
      "opportunity_id" => opportunity.id,
      "runtime" => opportunity.runtime,
      "task" => opportunity.task,
      "row" => opportunity.row,
      "repetition" => opportunity.repetition,
      "stage" => opportunity.stage,
      "status" => "skipped",
      "skip_reason" => "prior_stage_failed",
      "max_input_bytes" => opportunity.max_input_bytes,
      "usage" => %{},
      "transport_count" => 0
    }
  end

  defp opportunity(runtime, task, row, repetition, stage, cap) do
    stage = Atom.to_string(stage)

    %{
      id: Enum.join([runtime, task, row, "r#{repetition}", stage], "/"),
      runtime: runtime,
      task: task,
      row: row,
      repetition: repetition,
      stage: stage,
      max_input_bytes: cap,
      max_output_tokens: @max_output_tokens
    }
  end

  defp assert_wire_contract!(request, body) do
    expected_provider = provider_preferences() |> stringify_keys()

    headers =
      request.headers |> Enum.into(%{}, fn {key, values} -> {String.downcase(key), values} end)

    require_equal!(body["model"], @model, "serialized model")
    require_equal!(body["provider"], expected_provider, "serialized provider preferences")
    require_equal!(body["usage"], %{"include" => true}, "serialized usage metadata")
    require_equal!(body["temperature"], 1.0, "serialized temperature")
    require_equal!(body["max_tokens"], @max_output_tokens, "serialized output cap")
    require_equal!(body["reasoning_effort"], "none", "serialized reasoning policy")
    require_equal!(Map.get(body, "store"), nil, "serialized provider storage option")
    require_equal!(Map.get(body, "session_id"), nil, "serialized session")
    require_equal!(Map.get(body, "response_format"), nil, "serialized JSON fallback")

    metadata_header = Map.get(headers, "x-openrouter-metadata", [])
    cache_header = Map.get(headers, "x-openrouter-cache", [])

    unless "enabled" in List.wrap(metadata_header),
      do: raise(ArgumentError, "router metadata header drift")

    unless "false" in List.wrap(cache_header),
      do: raise(ArgumentError, "OpenRouter response-cache header drift")

    :ok
  end

  defp synthetic_router_metadata do
    %{
      "requested" => @model,
      "strategy" => "direct",
      "region" => "provider-disabled",
      "summary" => "available=1, selected=Novita",
      "attempt" => 1,
      "is_byok" => false,
      "endpoints" => %{
        "total" => 22,
        "available" => [
          %{"model" => @endpoint_model, "provider" => @endpoint_provider, "selected" => true}
        ]
      }
    }
  end

  defp stringify_keys(value) when is_map(value),
    do: Map.new(value, fn {key, nested} -> {to_string(key), stringify_keys(nested)} end)

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp verify_row!(%{"row_sha256" => expected} = row) do
    actual = row |> Map.delete("row_sha256") |> canonical_json() |> sha256()
    unless actual == expected, do: raise(ArgumentError, "calibration row checksum mismatch")
  end

  @doc false
  # The `canonical_json_utf8_v1` serialization whose SHA-256 each event records.
  def canonical_json(value) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map_join(",", fn {key, nested} ->
      Jason.encode!(key) <> ":" <> canonical_json(nested)
    end)
    |> then(&("{" <> &1 <> "}"))
  end

  def canonical_json(value) when is_list(value),
    do: "[" <> Enum.map_join(value, ",", &canonical_json/1) <> "]"

  def canonical_json(value), do: Jason.encode!(value)
  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp usage_cost(usage), do: usage["provider_cost_usd"]

  defp validate_usage!(usage, opportunity) do
    input = usage["input_tokens"]
    output = usage["output_tokens"]
    cached = usage["cached_tokens"]
    total = usage["total_tokens"]
    cost = usage["provider_cost_usd"]
    full_price = input / 1_000_000 * @input_price + output / 1_000_000 * @output_price

    unless cached <= input and total == input + output and is_number(cost) and cost >= 0 and
             cost <= full_price + 1.0e-9 and cost <= reservation_cost(opportunity) + 1.0e-9 do
      raise ArgumentError, "usage/cost exceeds the conservative full-price contract"
    end

    :ok
  end

  defp contains?(rendered, required, forbidden \\ []) do
    Enum.all?(required, &String.contains?(rendered, &1)) and
      Enum.all?(forbidden, &(not String.contains?(rendered, &1)))
  end

  defp reservation_cost(opportunity) do
    opportunity.max_input_bytes / 1_000_000 * @input_price +
      opportunity.max_output_tokens / 1_000_000 * @output_price
  end

  defp truthy?(value), do: value in [true, "true", "True", "TRUE", "yes", "Yes", "YES", 1, "1"]
  defp integer!(value) when is_integer(value), do: value
  defp integer!(value) when is_float(value), do: round(value)

  defp integer!(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, _rest} -> integer
      :error -> raise ArgumentError, "invalid integer result"
    end
  end

  defp git!(args) do
    case System.cmd("git", args, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {output, status} -> raise ArgumentError, "git command failed (#{status}): #{output}"
    end
  end

  defp require_equal!(value, value, _label), do: :ok
  defp require_equal!(_actual, _expected, label), do: raise(ArgumentError, "#{label} drift")

  defp require_nonnegative_integer!(value, _label) when is_integer(value) and value >= 0,
    do: :ok

  defp require_nonnegative_integer!(_value, label),
    do: raise(ArgumentError, "missing or invalid #{label}")

  defp require_nonempty!(value, _label) when is_binary(value) and byte_size(value) > 0, do: :ok
  defp require_nonempty!(_value, label), do: raise(ArgumentError, "missing #{label}")

  defp fetch_public_json!(url, label) do
    case Req.get(url, retry: false, max_retries: 0, receive_timeout: 30_000) do
      {:ok, %Req.Response{status: 200, body: body}} -> body
      {:ok, %Req.Response{status: status}} -> raise ArgumentError, "#{label} HTTP #{status}"
      {:error, reason} -> raise ArgumentError, "#{label} request failed: #{inspect(reason)}"
    end
  end

  defp validate_endpoint!(endpoint, label) do
    require_equal!(endpoint["name"], @endpoint_name, "#{label} endpoint name")
    require_equal!(endpoint["provider_name"], @endpoint_provider, "#{label} provider")
    require_equal!(endpoint["model_id"], @model, "#{label} model")
    require_equal!(endpoint["quantization"], "fp8", "#{label} quantization")
    require_equal!(endpoint["status"], 0, "#{label} status")
    require_equal!(endpoint["supports_implicit_caching"], false, "#{label} implicit cache")
    require_equal!(get_in(endpoint, ["pricing", "prompt"]), "0.00000014", "#{label} input price")

    require_equal!(
      get_in(endpoint, ["pricing", "completion"]),
      "0.00000028",
      "#{label} output price"
    )

    required = ~w(reasoning_effort max_tokens temperature)
    supported = endpoint["supported_parameters"] || []

    unless Enum.all?(required, &(&1 in supported)),
      do: raise(ArgumentError, "#{label} parameter support drift")

    endpoint
  end

  defp nonempty?(value), do: is_binary(value) and byte_size(value) > 0
end
