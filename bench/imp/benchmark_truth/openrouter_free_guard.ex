defmodule Imp.BenchmarkTruth.OpenRouterFreeGuard do
  @moduledoc false

  alias Imp.BenchmarkTruth.{BudgetedLM, CampaignBudget}

  @model "openai/gpt-oss-20b:free"
  @catalog_url "https://openrouter.ai/api/v1/models"
  @max_output_tokens 32

  def model, do: @model

  def provider_guard do
    %{
      max_price: %{prompt: 0, completion: 0, request: 0, image: 0},
      allow_fallbacks: false,
      require_parameters: true,
      data_collection: "deny"
    }
  end

  def current_catalog!(model \\ @model), do: fetch_catalog() |> validate_catalog!(model)

  def strict_lm(api_key, budget, ledger, seed, opts \\ []) do
    max_output_tokens = Keyword.get(opts, :max_output_tokens, 64)
    requested_model = Keyword.get(opts, :model, @model)

    model =
      case Keyword.get(opts, :base_url) do
        nil -> "openrouter:" <> requested_model
        base_url -> %{provider: :openrouter, id: requested_model, base_url: base_url}
      end

    req_http_options =
      opts
      |> Keyword.get(:req_http_options, [])
      |> install_request_contract_audit(ledger, Keyword.get(opts, :request_contract))

    lm_opts =
      [
        api_key: api_key,
        temperature: 0.0,
        seed: seed,
        max_tokens: max_output_tokens,
        max_retries: 0,
        cache: false,
        provider_options: [
          openrouter_provider: provider_guard(),
          openrouter_usage: %{include: true}
        ]
      ]
      |> maybe_put_opt(:reasoning_effort, Keyword.get(opts, :reasoning_effort))
      |> maybe_put_opt(:req_http_options, req_http_options)

    inner = Imp.req_llm(model, lm_opts)

    budgeted = %BudgetedLM{
      inner: inner,
      budget: budget,
      max_output_tokens: max_output_tokens
    }

    struct(Imp.BenchmarkTruth.OpenRouterFreeGuard.CheckedLM,
      inner: budgeted,
      budget: budget,
      ledger: ledger,
      requested_model: requested_model,
      request_contract: Keyword.get(opts, :request_contract)
    )
  end

  def start_ledger, do: Agent.start_link(fn -> %{halted: nil, rows: [], request_audits: []} end)

  def ledger_snapshot(ledger) do
    Agent.get(ledger, fn state ->
      %{
        "halted" => state.halted && safe_error(state.halted),
        "responses" => Enum.reverse(state.rows),
        "unmatched_request_audits" => Enum.reverse(state.request_audits)
      }
    end)
  end

  @doc false
  def checked_generate(
        inner,
        budget,
        ledger,
        messages,
        opts,
        requested_model \\ @model,
        request_contract \\ nil
      ) do
    case Agent.get(ledger, & &1.halted) do
      nil ->
        do_checked_generate(
          inner,
          budget,
          ledger,
          messages,
          opts,
          requested_model,
          request_contract
        )

      reason ->
        {:error, {:openrouter_free_campaign_halted, reason}}
    end
  end

  @doc false
  def audit_campaign_request(%Req.Request{} = request, ledger, contract) do
    body = decode_body(request.body)
    provider_opts = request.options[:provider_options] || []

    audit = %{
      "model" => map_value(body, :model) || request.options[:model],
      "provider" =>
        map_value(body, :provider) || request.options[:openrouter_provider] ||
          provider_opts[:openrouter_provider],
      "usage" =>
        map_value(body, :usage) || request.options[:openrouter_usage] ||
          provider_opts[:openrouter_usage],
      "response_format" =>
        map_value(body, :response_format) || request.options[:response_format] ||
          provider_opts[:response_format],
      "max_tokens" => map_value(body, :max_tokens) || request.options[:max_tokens],
      "reasoning_effort" =>
        map_value(body, :reasoning_effort) || request.options[:reasoning_effort]
    }

    checks = %{
      "exact_model" => audit["model"] == contract[:model],
      "provider_guard" => stringify(audit["provider"]) == stringify(provider_guard()),
      "usage_include" => map_value(audit["usage"], :include) == true,
      "response_format" =>
        stringify(audit["response_format"]) == stringify(contract[:response_format]),
      "max_output_tokens" => audit["max_tokens"] == contract[:max_output_tokens],
      "reasoning_effort" => audit["reasoning_effort"] == contract[:reasoning_effort]
    }

    record = %{
      "request" => audit,
      "checks" => checks,
      "passed" => Enum.all?(checks, fn {_key, value} -> value == true end)
    }

    Agent.update(ledger, fn state ->
      halted = if record["passed"], do: state.halted, else: {:request_contract_drift, checks}
      %{state | halted: halted, request_audits: [record | state.request_audits]}
    end)

    if record["passed"] do
      request
    else
      raise "OpenRouter campaign serialized request drifted from the committed contract"
    end
  end

  def run(opts) do
    api_key = Keyword.fetch!(opts, :api_key)
    catalog_fetcher = Keyword.get(opts, :catalog_fetcher, &fetch_catalog/0)
    catalog = catalog_fetcher.() |> validate_catalog!(@model)
    owner = self()

    {:ok, budget} =
      CampaignBudget.start_link(
        limits: %{requests: 1, input_tokens: 20_000, output_tokens: @max_output_tokens, usd: 0.0},
        pricing: %{
          "input_per_million" => 0.0,
          "output_per_million" => 0.0,
          "source_url" => "https://openrouter.ai/docs/guides/routing/model-variants/free"
        },
        default_max_output_tokens: @max_output_tokens
      )

    telemetry_id = CampaignBudget.attach_req_llm(budget)

    audit_plugin = fn request ->
      Req.Request.append_request_steps(request,
        imp_openrouter_free_request_audit: {__MODULE__, :audit_request, [owner]}
      )
    end

    model =
      case Keyword.get(opts, :base_url) do
        nil -> "openrouter:" <> @model
        base_url -> %{provider: :openrouter, id: @model, base_url: base_url}
      end

    inner =
      Imp.req_llm(model,
        api_key: api_key,
        temperature: 0.0,
        seed: 17,
        max_tokens: @max_output_tokens,
        max_retries: 0,
        cache: false,
        provider_options: [
          openrouter_provider: provider_guard(),
          openrouter_usage: %{include: true}
        ],
        req_http_options: [plugins: [audit_plugin]]
      )

    lm = %BudgetedLM{inner: inner, budget: budget, max_output_tokens: @max_output_tokens}

    result =
      try do
        Imp.LM.generate(
          lm,
          [%{role: :user, content: "Reply with only the word IMP."}],
          max_tokens: @max_output_tokens
        )
      after
        :telemetry.detach(telemetry_id)
      end

    audit = receive_audit()
    snapshot = CampaignBudget.snapshot(budget)
    build_result(result, audit, snapshot, catalog)
  end

  @doc false
  def audit_request(%Req.Request{} = request, owner) do
    body = decode_body(request.body)

    send(owner, {
      :imp_openrouter_free_request_audit,
      %{
        "model" => map_value(body, :model) || request.options[:model],
        "provider" => map_value(body, :provider) || request.options[:openrouter_provider],
        "usage" => map_value(body, :usage) || request.options[:openrouter_usage]
      }
    })

    request
  end

  defp fetch_catalog do
    case Req.get(@catalog_url, retry: false, max_retries: 0, receive_timeout: 30_000) do
      {:ok, %Req.Response{status: 200, body: body}} -> body
      {:ok, %Req.Response{status: status}} -> raise "OpenRouter catalog returned HTTP #{status}"
      {:error, reason} -> raise "OpenRouter catalog request failed: #{safe_error(reason)}"
    end
  end

  defp validate_catalog!(%{"data" => models}, requested_model) when is_list(models) do
    model = Enum.find(models, &(map_value(&1, :id) == requested_model))

    if is_nil(model) do
      raise "OpenRouter catalog does not list exact model #{requested_model}"
    end

    pricing = map_value(model, :pricing)
    prompt = decimal(map_value(pricing, :prompt))
    completion = decimal(map_value(pricing, :completion))

    unless prompt == 0.0 and completion == 0.0 do
      raise "OpenRouter catalog no longer reports zero prompt and completion pricing"
    end

    %{
      "checked_url" => @catalog_url,
      "model" => requested_model,
      "canonical_model" => map_value(model, :canonical_slug),
      "pricing" => %{"prompt" => prompt, "completion" => completion},
      "supported_parameters" => map_value(model, :supported_parameters) || []
    }
  end

  defp validate_catalog!(_other, _requested_model),
    do: raise("OpenRouter catalog response is malformed")

  defp build_result({:ok, raw}, audit, snapshot, catalog) do
    with {:ok, _output, metadata} <- Imp.LM.Result.split(raw),
         {:ok, provider} <- required_binary(get_in(metadata, [:req_llm, :provider]), :provider),
         {:ok, actual_model} <-
           required_binary(get_in(metadata, [:req_llm, :model]), :actual_model),
         :ok <- validate_identity(provider, actual_model),
         {:ok, upstream_provider} <-
           required_binary(
             map_value(get_in(metadata, [:req_llm, :provider_meta]) || %{}, :provider),
             :upstream_provider
           ),
         {:ok, usage} <- required_map(get_in(metadata, [:req_llm, :usage]), :usage),
         {:ok, provider_cost} <- required_number(map_value(usage, "cost"), :provider_cost),
         :ok <- require_zero(provider_cost, :provider_cost),
         :ok <- validate_audit(audit),
         :ok <- validate_budget(snapshot) do
      computed_cost = optional_number(map_value(usage, :total_cost))

      {:ok,
       artifact(
         "passed",
         catalog,
         audit,
         snapshot,
         %{
           "gateway_provider" => provider,
           "upstream_provider" => upstream_provider,
           "actual_model" => actual_model,
           "provider_reported_cost_usd" => provider_cost,
           "computed_cost_usd" => computed_cost,
           "input_tokens" => map_value(usage, :input_tokens),
           "output_tokens" => map_value(usage, :output_tokens)
         },
         nil
       )}
    else
      {:error, reason} ->
        {:error, artifact("failed", catalog, audit, snapshot, nil, safe_error(reason))}
    end
  end

  defp build_result({:error, reason}, audit, snapshot, catalog) do
    {:error, artifact("failed", catalog, audit, snapshot, nil, safe_error(reason))}
  end

  defp build_result(other, audit, snapshot, catalog) do
    {:error, artifact("failed", catalog, audit, snapshot, nil, safe_error(other))}
  end

  defp do_checked_generate(
         inner,
         budget,
         ledger,
         messages,
         opts,
         requested_model,
         request_contract
       ) do
    result = Imp.LM.generate(inner, messages, opts)
    snapshot = CampaignBudget.snapshot(budget)
    max_output_tokens = checked_output_limit(inner, opts)
    request_audit = take_request_audit(ledger)

    case strict_response_accounting(
           result,
           snapshot,
           max_output_tokens,
           requested_model,
           request_contract,
           request_audit
         ) do
      {:ok, row} ->
        Agent.update(ledger, fn state -> %{state | rows: [row | state.rows]} end)
        result

      {:error, reason, row} ->
        Agent.update(ledger, fn state -> %{state | halted: reason, rows: [row | state.rows]} end)
        {:error, {:openrouter_free_validation_failed, reason}}
    end
  end

  defp strict_response_accounting(
         {:ok, raw},
         snapshot,
         max_output_tokens,
         requested_model,
         request_contract,
         request_audit
       ) do
    with {:ok, output, metadata} <- Imp.LM.Result.split(raw) do
      row =
        output
        |> response_accounting_row(metadata, snapshot, max_output_tokens, requested_model)
        |> attach_request_audit(request_audit)

      case validate_request_and_response(
             request_audit,
             request_contract,
             metadata,
             snapshot,
             requested_model
           ) do
        :ok ->
          {:ok, Map.put(row, "status", "passed")}

        {:error, reason} ->
          {:error, reason, Map.merge(row, failed_response_row(reason, snapshot))}
      end
    else
      {:error, reason} ->
        {:error, reason, failed_response_row(reason, snapshot)}
    end
  end

  defp strict_response_accounting(
         {:error, reason},
         snapshot,
         _max_output_tokens,
         _requested_model,
         _request_contract,
         request_audit
       ),
       do:
         {:error, {:provider_error, safe_error(reason)},
          reason |> failed_response_row(snapshot) |> attach_request_audit(request_audit)}

  defp strict_response_accounting(
         other,
         snapshot,
         _max_output_tokens,
         _requested_model,
         _request_contract,
         request_audit
       ),
       do:
         {:error, {:malformed_lm_result, safe_error(other)},
          other |> failed_response_row(snapshot) |> attach_request_audit(request_audit)}

  defp validate_request_and_response(
         request_audit,
         request_contract,
         metadata,
         snapshot,
         requested_model
       ) do
    with :ok <- validate_request_contract(request_audit, request_contract),
         :ok <- validate_response(metadata, snapshot, requested_model),
         :ok <- validate_contract_response_identity(metadata, request_contract) do
      :ok
    end
  end

  defp validate_request_contract(_request_audit, nil), do: :ok

  defp validate_request_contract(%{"passed" => true}, _request_contract), do: :ok

  defp validate_request_contract(_request_audit, _request_contract),
    do: {:error, :serialized_request_contract_missing_or_drifted}

  defp validate_contract_response_identity(_metadata, nil), do: :ok

  defp validate_contract_response_identity(metadata, %{model: exact_model}) do
    actual_model = get_in(metadata, [:req_llm, :model])

    if actual_model == exact_model,
      do: :ok,
      else: {:error, {:exact_model_response_drift, exact_model, actual_model}}
  end

  defp validate_response(metadata, snapshot, requested_model) do
    with {:ok, provider} <- required_binary(get_in(metadata, [:req_llm, :provider]), :provider),
         {:ok, actual_model} <-
           required_binary(get_in(metadata, [:req_llm, :model]), :actual_model),
         :ok <- validate_identity(provider, actual_model, requested_model),
         {:ok, _upstream_provider} <-
           required_binary(
             map_value(get_in(metadata, [:req_llm, :provider_meta]) || %{}, :provider),
             :upstream_provider
           ),
         {:ok, usage} <- required_map(get_in(metadata, [:req_llm, :usage]), :usage),
         {:ok, _finish_reason} <-
           required_finish_reason(get_in(metadata, [:req_llm, :finish_reason]), :finish_reason),
         {:ok, provider_cost} <- required_number(map_value(usage, "cost"), :provider_cost),
         {:ok, computed_cost} <- required_number(map_value(usage, :total_cost), :computed_cost),
         :ok <- require_zero(provider_cost, :provider_cost),
         :ok <- require_zero(computed_cost, :computed_cost),
         :ok <- validate_cumulative_budget(snapshot) do
      :ok
    end
  end

  defp checked_output_limit(%BudgetedLM{max_output_tokens: limit}, _opts)
       when is_integer(limit) and limit > 0,
       do: limit

  defp checked_output_limit(_inner, opts), do: Keyword.get(opts, :max_tokens)

  defp response_reference(output) do
    %{
      "raw_response_sha256" => CampaignBudget.evidence_digest(output),
      "bounded_safe_excerpt" =>
        output
        |> inspect(limit: 20, printable_limit: 256)
        |> Imp.Redaction.redact()
        |> String.slice(0, 256)
    }
  end

  defp response_accounting_row(
         output,
         metadata,
         snapshot,
         max_output_tokens,
         requested_model
       ) do
    req = get_in(metadata, [:req_llm]) || %{}
    usage = map_value(req, :usage) || %{}
    provider_meta = map_value(req, :provider_meta) || %{}
    finish_reason = map_value(req, :finish_reason)
    output_tokens = map_value(usage, :output_tokens)

    %{
      "logical_requests" => snapshot["requests"],
      "transport_attempts" => snapshot["transport_attempts"],
      "requested_model" => requested_model,
      "gateway_provider" => map_value(req, :provider),
      "upstream_provider" => map_value(provider_meta, :provider),
      "actual_model" => map_value(req, :model),
      "provider_reported_cost_usd" => map_value(usage, "cost"),
      "computed_cost_usd" => map_value(usage, :total_cost),
      "input_tokens" => map_value(usage, :input_tokens),
      "output_tokens" => output_tokens,
      "reasoning_tokens" => map_value(usage, :reasoning_tokens),
      "finish_reason" => finish_reason && to_string(finish_reason),
      "requested_max_output_tokens" => max_output_tokens,
      "truncation_indicators" => %{
        "finish_reason_is_length" => finish_reason in [:length, "length"],
        "output_tokens_reached_ceiling" =>
          is_number(output_tokens) and is_integer(max_output_tokens) and
            output_tokens >= max_output_tokens
      }
    }
    |> Map.merge(response_reference(output))
    |> Map.merge(reasoning_reference(metadata))
  end

  defp reasoning_reference(metadata) do
    reasoning = map_value(metadata, :native_reasoning)
    details = map_value(metadata, :reasoning_details) || []

    %{
      "native_reasoning_present" => is_binary(reasoning) and reasoning != "",
      "native_reasoning_bytes" => if(is_binary(reasoning), do: byte_size(reasoning), else: 0),
      "native_reasoning_sha256" =>
        if(is_binary(reasoning), do: CampaignBudget.evidence_digest(reasoning)),
      "bounded_native_reasoning_excerpt" =>
        if(is_binary(reasoning), do: bounded_safe_excerpt(reasoning)),
      "reasoning_details_count" => if(is_list(details), do: length(details), else: 0),
      "reasoning_details_sha256" =>
        if(is_list(details) and details != [], do: CampaignBudget.evidence_digest(details))
    }
  end

  defp bounded_safe_excerpt(value) do
    value
    |> inspect(limit: 20, printable_limit: 256)
    |> Imp.Redaction.redact()
    |> String.slice(0, 256)
  end

  defp validate_cumulative_budget(%{
         "requests" => requests,
         "transport_attempts" => attempts,
         "single_attempt_transport_enforced" => true,
         "usage" => %{"usd" => usd},
         "exhausted" => nil
       })
       when requests == attempts and (usd == 0 or usd == 0.0),
       do: :ok

  defp validate_cumulative_budget(_snapshot),
    do: {:error, :cumulative_attempt_or_cost_budget_mismatch}

  defp failed_response_row(reason, snapshot) do
    %{
      "status" => "failed",
      "logical_requests" => snapshot["requests"],
      "transport_attempts" => snapshot["transport_attempts"],
      "error" => safe_error(reason)
    }
  end

  defp attach_request_audit(row, nil), do: row

  defp attach_request_audit(row, audit) do
    row
    |> Map.put("request_audit", audit["request"])
    |> Map.put("request_validation", %{
      "passed" => audit["passed"],
      "checks" => audit["checks"]
    })
  end

  defp take_request_audit(ledger) do
    Agent.get_and_update(ledger, fn state ->
      case Enum.reverse(state.request_audits) do
        [audit | rest] -> {audit, %{state | request_audits: Enum.reverse(rest)}}
        [] -> {nil, state}
      end
    end)
  end

  defp validate_identity("openrouter", actual_model, requested_model) do
    canonical = String.replace_suffix(requested_model, ":free", "")

    if actual_model in [requested_model, canonical],
      do: :ok,
      else: {:error, {:unexpected_provider_or_model, "openrouter", actual_model}}
  end

  defp validate_identity(provider, model, _requested_model),
    do: {:error, {:unexpected_provider_or_model, provider, model}}

  defp validate_identity(provider, model), do: validate_identity(provider, model, @model)

  defp validate_audit(%{
         "model" => @model,
         "provider" => provider,
         "usage" => usage
       }) do
    expected = stringify(provider_guard())

    if stringify(provider) == expected and map_value(usage, :include) == true,
      do: :ok,
      else: {:error, :serialized_free_route_guard_mismatch}
  end

  defp validate_audit(_audit), do: {:error, :serialized_free_route_guard_missing}

  defp validate_budget(%{
         "requests" => 1,
         "transport_attempts" => 1,
         "single_attempt_transport_enforced" => true,
         "usage" => %{"usd" => usd}
       })
       when usd == 0 or usd == 0.0,
       do: :ok

  defp validate_budget(_snapshot), do: {:error, :campaign_budget_not_zero_or_single_attempt}

  defp artifact(status, catalog, audit, snapshot, response, error) do
    %{
      "schema_version" => 1,
      "campaign" => "openrouter-free-canary",
      "status" => status,
      "generated_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "requested_model" => @model,
      "catalog" => catalog,
      "serialized_request_guard" => audit,
      "budget" => snapshot,
      "response_accounting" => response,
      "error" => error,
      "scope" =>
        "One non-sensitive logical call proving the exact free-route, zero-cost, and single-transport-attempt boundary; no optimizer effectiveness evidence."
    }
  end

  defp receive_audit do
    receive do
      {:imp_openrouter_free_request_audit, audit} -> audit
    after
      0 -> nil
    end
  end

  defp required_binary(value, _field) when is_binary(value) and value != "", do: {:ok, value}
  defp required_binary(_value, field), do: {:error, {:missing_or_invalid, field}}
  defp required_map(value, _field) when is_map(value), do: {:ok, value}
  defp required_map(_value, field), do: {:error, {:missing_or_invalid, field}}
  defp required_number(value, _field) when is_number(value), do: {:ok, value * 1.0}
  defp required_number(_value, field), do: {:error, {:missing_or_invalid, field}}

  defp required_finish_reason(value, _field) when value in [:stop, :length, "stop", "length"],
    do: {:ok, value}

  defp required_finish_reason(_value, field), do: {:error, {:missing_or_invalid, field}}

  defp optional_number(value) when is_number(value), do: value * 1.0
  defp optional_number(_value), do: nil

  defp require_zero(value, _field) when value == 0 or value == 0.0, do: :ok
  defp require_zero(value, field), do: {:error, {:nonzero, field, value}}

  defp decimal(value) when is_number(value), do: value * 1.0

  defp decimal(value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} -> number
      _ -> raise "OpenRouter catalog price is not numeric"
    end
  end

  defp decimal(_value), do: raise("OpenRouter catalog price is absent")

  defp decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      _ -> %{}
    end
  end

  defp decode_body(body) when is_map(body), do: body
  defp decode_body(_body), do: %{}

  defp stringify(value) when is_map(value),
    do: Map.new(value, fn {key, nested} -> {to_string(key), stringify(nested)} end)

  defp stringify(value) when is_list(value), do: Enum.map(value, &stringify/1)
  defp stringify(value), do: value

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp install_request_contract_audit(req_http_options, _ledger, nil),
    do: req_http_options

  defp install_request_contract_audit(req_http_options, ledger, contract) do
    unless Keyword.keyword?(req_http_options) do
      raise ArgumentError, "campaign LM :req_http_options must be a keyword list"
    end

    plugins = Keyword.get(req_http_options, :plugins, [])
    unless is_list(plugins), do: raise(ArgumentError, "campaign LM Req :plugins must be a list")

    audit_plugin = fn request ->
      Req.Request.append_request_steps(request,
        imp_openrouter_campaign_request_audit:
          {__MODULE__, :audit_campaign_request, [ledger, contract]}
      )
    end

    Keyword.put(req_http_options, :plugins, plugins ++ [audit_plugin])
  end

  defp map_value(nil, _key), do: nil

  defp map_value(map, key) when is_map(map),
    do: Map.get(map, key, Map.get(map, to_string(key)))

  defp map_value(_other, _key), do: nil

  defp safe_error(error),
    do: error |> inspect(limit: 20, printable_limit: 500) |> Imp.Redaction.redact()
end

defmodule Imp.BenchmarkTruth.OpenRouterFreeGuard.CheckedLM do
  @moduledoc false

  @behaviour Imp.LM

  defstruct [
    :inner,
    :budget,
    :ledger,
    :request_contract,
    requested_model: "openai/gpt-oss-20b:free"
  ]

  @impl true
  def generate(%__MODULE__{} = lm, messages, opts) do
    Imp.BenchmarkTruth.OpenRouterFreeGuard.checked_generate(
      lm.inner,
      lm.budget,
      lm.ledger,
      messages,
      opts,
      lm.requested_model,
      lm.request_contract
    )
  end

  def response_format_capability(%__MODULE__{inner: inner}),
    do: Imp.LM.response_format_capability(inner)
end
