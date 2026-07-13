defmodule DSEx.IdentityCollision do
  @moduledoc false

  alias DSEx.HTTP.Hackneyless
  alias DSEx.{IdentityCheckpoint, IdentityEvaluation}

  @default_delay_ms 1_000
  @default_checks_out "identity/research/package-collision-checks.jsonl"
  @default_flags_out "identity/research/package-collision-flags.jsonl"
  @user_agent "Deepfates-Identity-Collision-Audit/1.0 (+https://github.com/deepfates)"

  @source_specs [
    {"hex", %{label: "Hex", base_url: "https://hex.pm/api/packages/"}},
    {"npm", %{label: "npm", base_url: "https://registry.npmjs.org/"}},
    {"pypi", %{label: "PyPI", base_url: "https://pypi.org/pypi/", suffix: "/json"}},
    {"crates", %{label: "crates.io", base_url: "https://crates.io/api/v1/crates/"}}
  ]
  @source_ids Enum.map(@source_specs, &elem(&1, 0))
  @source_map Map.new(@source_specs)
  @status_order ["collision", "no-exact-record", "rate-limited", "unverified", "skipped"]

  @type fetch_result ::
          {:ok,
           %{
             required(:status) => non_neg_integer(),
             optional(:headers) => list(),
             optional(:body) => binary()
           }}
          | {:error, term()}

  @spec source_ids() :: [String.t()]
  def source_ids, do: @source_ids

  @spec default_delay_ms() :: non_neg_integer()
  def default_delay_ms, do: @default_delay_ms

  @spec default_checks_out() :: String.t()
  def default_checks_out, do: @default_checks_out

  @spec default_flags_out() :: String.t()
  def default_flags_out, do: @default_flags_out

  @spec normalize_sources!([String.t()]) :: [String.t()]
  def normalize_sources!(sources) when is_list(sources) do
    requested = sources |> Enum.map(&String.downcase/1) |> Enum.uniq()
    invalid = requested -- ["all" | @source_ids]

    if invalid != [] do
      raise ArgumentError,
            "invalid collision sources #{inspect(invalid)}; expected all or #{Enum.join(@source_ids, ", ")}"
    end

    if requested == [] or "all" in requested do
      @source_ids
    else
      Enum.filter(@source_ids, &(&1 in requested))
    end
  end

  @spec url_for(String.t(), String.t()) :: String.t()
  def url_for(source, query) when is_binary(source) and is_binary(query) do
    spec = source_spec!(source)
    encoded = URI.encode(query, &URI.char_unreserved?/1)
    spec.base_url <> encoded <> Map.get(spec, :suffix, "")
  end

  @spec classify(String.t(), String.t(), fetch_result()) :: map()
  def classify(source, query, {:ok, %{status: status} = response})
      when is_integer(status) do
    metadata = response_metadata(Map.get(response, :headers, []), Map.get(response, :body, ""))
    label = source_spec!(source).label

    finding =
      case status do
        200 ->
          %{
            "status" => "collision",
            "claim_basis" => "observed",
            "confidence" => 1.0,
            "summary" =>
              "Exact #{label} package record observed for #{inspect(query)} at the checked endpoint."
          }

        404 ->
          %{
            "status" => "no-exact-record",
            "claim_basis" => "observed",
            "confidence" => 1.0,
            "summary" =>
              "No exact #{label} package record was observed for #{inspect(query)} at check time; this is not an availability or trademark conclusion."
          }

        status when status in [403, 429] ->
          %{
            "status" => "rate-limited",
            "claim_basis" => "unverified",
            "confidence" => 0.0,
            "summary" =>
              "#{label} returned HTTP #{status}; exact package collision status remains unverified."
          }

        other ->
          %{
            "status" => "unverified",
            "claim_basis" => "unverified",
            "confidence" => 0.0,
            "summary" =>
              "#{label} returned HTTP #{other}; exact package collision status remains unverified."
          }
      end

    finding
    |> Map.put("http_status", status)
    |> Map.put("response_metadata", metadata)
  end

  def classify(source, _query, {:error, reason}) do
    %{
      "status" => "unverified",
      "http_status" => nil,
      "claim_basis" => "unverified",
      "confidence" => 0.0,
      "summary" =>
        "#{source_spec!(source).label} request failed in transport; exact package collision status remains unverified.",
      "response_metadata" => %{"transport_error" => inspect(reason)}
    }
  end

  def classify(source, _query, unexpected) do
    classify(source, "", {:error, {:invalid_fetch_result, unexpected}})
  end

  @spec run([map()], [map()], [map()], keyword()) :: map()
  def run(enrichments, existing_checks, existing_flags, opts \\ [])
      when is_list(enrichments) and is_list(existing_checks) and is_list(existing_flags) do
    sources = opts |> Keyword.get(:sources, @source_ids) |> normalize_sources!()
    checked_at = opts |> Keyword.get_lazy(:checked_at, &now_iso8601/0) |> validate_checked_at!()
    delay_ms = opts |> Keyword.get(:delay_ms, @default_delay_ms) |> validate_delay!()
    refresh? = Keyword.get(opts, :refresh, false)
    fetcher = Keyword.get(opts, :fetcher, &httpc_fetch/1)
    sleeper = Keyword.get(opts, :sleep, &Process.sleep/1)
    max_retry_after_ms = Keyword.get(opts, :max_retry_after_ms, 30_000)

    validate_function!(fetcher, :fetcher)
    validate_function!(sleeper, :sleep)
    validate_delay!(max_retry_after_ms)

    enrichments = validate_enrichments!(enrichments)
    checks = unique_records!(existing_checks, "check")
    flags = unique_records!(existing_flags, "flag")
    checks_by_key = Enum.group_by(checks, &record_check_key/1)

    initial = %{
      new_checks: [],
      current_checks: [],
      resumed: 0,
      network_started?: false,
      network_attempts: 0
    }

    state =
      enrichments
      |> Enum.sort_by(& &1["candidate_id"])
      |> Enum.flat_map(fn enrichment ->
        Enum.map(sources, &work_item(enrichment, &1))
      end)
      |> Enum.reduce(initial, fn item, state ->
        previous = Map.get(checks_by_key, item.check_key, [])

        if previous != [] and not refresh? do
          %{
            state
            | current_checks: [List.last(previous) | state.current_checks],
              resumed: state.resumed + 1
          }
        else
          state = maybe_delay(state, item.checkable?, delay_ms, sleeper)
          attempt = length(previous) + 1

          {check, network_attempts} =
            observe(item, attempt, checked_at,
              fetcher: fetcher,
              sleep: sleeper,
              max_retry_after_ms: max_retry_after_ms
            )

          %{
            state
            | new_checks: [check | state.new_checks],
              current_checks: [check | state.current_checks],
              network_started?: state.network_started? or item.checkable?,
              network_attempts: state.network_attempts + network_attempts
          }
        end
      end)

    new_checks = Enum.reverse(state.new_checks)
    all_checks = checks ++ new_checks
    generated_flags = all_checks |> Enum.filter(&collision?/1) |> Enum.map(&flag_for_check/1)
    all_flags = append_missing(flags, generated_flags)
    current_checks = Enum.reverse(state.current_checks)

    %{
      checks: all_checks,
      flags: all_flags,
      current_checks: current_checks,
      stats: %{
        candidates: length(enrichments),
        sources: sources,
        total: length(current_checks),
        new_checks: length(new_checks),
        resumed_checks: state.resumed,
        network_attempts: state.network_attempts,
        flags_added: length(all_flags) - length(flags),
        by_status: status_totals(current_checks),
        by_source: source_totals(current_checks, sources)
      }
    }
  end

  @spec run_files!(keyword()) :: map()
  def run_files!(opts \\ []) do
    enrichments_path = Keyword.get(opts, :enrichments, "identity/enrichments.jsonl")
    checks_out = Keyword.get(opts, :checks_out, @default_checks_out)
    flags_out = Keyword.get(opts, :flags_out, @default_flags_out)
    ensure_distinct_paths!(enrichments_path, checks_out, flags_out)

    result =
      run(
        IdentityEvaluation.load_jsonl!(enrichments_path),
        IdentityEvaluation.load_jsonl!(checks_out, optional: true),
        IdentityEvaluation.load_jsonl!(flags_out, optional: true),
        Keyword.drop(opts, [:enrichments, :checks_out, :flags_out])
      )

    IdentityCheckpoint.write_atomic!(checks_out, render_jsonl(result.checks))
    IdentityCheckpoint.write_atomic!(flags_out, render_jsonl(result.flags))
    result
  end

  @spec render_jsonl([map()]) :: String.t()
  def render_jsonl(records) do
    Enum.map_join(records, "\n", &Jason.encode!/1) <> if(records == [], do: "", else: "\n")
  end

  @spec httpc_fetch(map()) :: fetch_result()
  def httpc_fetch(request) when is_map(request) do
    :inets.start()
    :ssl.start()

    headers =
      Enum.map(request.headers, fn {key, value} ->
        {String.to_charlist(key), String.to_charlist(value)}
      end)

    http_options = [
      timeout: request.timeout_ms,
      connect_timeout: request.connect_timeout_ms,
      autoredirect: true,
      ssl: Hackneyless.default_ssl_opts()
    ]

    case :httpc.request(
           :get,
           {String.to_charlist(request.url), headers},
           http_options,
           body_format: :binary
         ) do
      {:ok, {{_version, status, _reason}, response_headers, body}} ->
        {:ok, %{status: status, headers: response_headers, body: body}}

      {:error, reason} ->
        {:error, reason}

      unexpected ->
        {:error, {:unexpected_httpc_result, unexpected}}
    end
  rescue
    error -> {:error, {:exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @spec retry_after_ms(list()) :: non_neg_integer() | nil
  def retry_after_ms(headers) do
    case header_value(headers, "retry-after") do
      nil ->
        nil

      value ->
        case Integer.parse(String.trim(value)) do
          {seconds, ""} when seconds >= 0 -> seconds * 1_000
          _other -> retry_after_date_ms(value)
        end
    end
  end

  defp work_item(enrichment, source) do
    candidate_id = enrichment["candidate_id"]
    {query, checkable?, reason} = exact_query(enrichment)

    %{
      candidate_id: candidate_id,
      source: source,
      query: query,
      checkable?: checkable?,
      reason: reason,
      check_key: check_key(candidate_id, source, query)
    }
  end

  defp exact_query(%{"code_forms" => %{"hex_package" => query}}) when is_binary(query) do
    cond do
      query == "" -> {query, false, "Derived Hex package form is blank."}
      String.match?(query, ~r/^[a-z][a-z0-9_]*$/) -> {query, true, nil}
      true -> {query, false, "Derived Hex package form is not a conventional package token."}
    end
  end

  defp exact_query(%{"code_forms" => %{"hex_package" => nil}}),
    do: {nil, false, "No derived Hex package form is available for this candidate."}

  defp exact_query(%{"code_forms" => code_forms}) when is_map(code_forms),
    do: {nil, false, "The code_forms record has no usable hex_package value."}

  defp exact_query(_enrichment),
    do: {nil, false, "The enrichment has no usable code_forms record."}

  defp observe(item, attempt, checked_at, opts) do
    base = %{
      "id" => check_id(item.check_key, attempt),
      "check_key" => item.check_key,
      "attempt" => attempt,
      "candidate_id" => item.candidate_id,
      "checked_at" => checked_at,
      "source" => item.source,
      "query" => item.query,
      "url" => if(is_binary(item.query), do: url_for(item.source, item.query), else: nil)
    }

    if item.checkable? do
      request = request(item.source, item.query)

      {response, retry_metadata, network_attempts} =
        fetch_with_retry(request, Keyword.fetch!(opts, :fetcher), opts)

      finding = classify(item.source, item.query, response)

      finding =
        Map.update!(finding, "response_metadata", &Map.merge(&1, retry_metadata))

      {Map.merge(base, finding), network_attempts}
    else
      {Map.merge(base, skipped_finding(item.reason)), 0}
    end
  end

  defp request(source, query) do
    %{
      source: source,
      query: query,
      url: url_for(source, query),
      headers: [{"user-agent", @user_agent}, {"accept", "application/json"}],
      timeout_ms: 15_000,
      connect_timeout_ms: 5_000,
      attempt: 1
    }
  end

  defp fetch_with_retry(request, fetcher, opts) do
    first = fetcher.(request)
    retry_after = retry_delay(first)
    maximum = Keyword.fetch!(opts, :max_retry_after_ms)

    if is_integer(retry_after) and retry_after <= maximum do
      Keyword.fetch!(opts, :sleep).(retry_after)
      second = fetcher.(%{request | attempt: 2})

      {second,
       %{
         "attempt_count" => 2,
         "honored_retry_after_ms" => retry_after,
         "prior_http_statuses" => [response_status(first)]
       }, 2}
    else
      metadata =
        %{"attempt_count" => 1}
        |> maybe_put("retry_after_ms", retry_after)
        |> maybe_put("retry_deferred", is_integer(retry_after) and retry_after > maximum)

      {first, metadata, 1}
    end
  end

  defp retry_delay({:ok, %{status: status, headers: headers}}) when status in [403, 429],
    do: retry_after_ms(headers)

  defp retry_delay(_response), do: nil

  defp response_status({:ok, %{status: status}}), do: status
  defp response_status(_response), do: nil

  defp skipped_finding(reason) do
    %{
      "status" => "skipped",
      "http_status" => nil,
      "claim_basis" => "unverified",
      "confidence" => 0.0,
      "summary" => "Exact registry check skipped: #{reason}",
      "response_metadata" => %{"request_sent" => false}
    }
  end

  defp response_metadata(headers, body) do
    body = if is_binary(body), do: body, else: IO.iodata_to_binary(body)

    %{
      "body_bytes" => byte_size(body),
      "body_sha256" => sha256(body)
    }
    |> maybe_put("content_type", header_value(headers, "content-type"))
    |> maybe_put("etag", header_value(headers, "etag"))
    |> maybe_put("last_modified", header_value(headers, "last-modified"))
    |> maybe_put("retry_after", header_value(headers, "retry-after"))
    |> maybe_put("request_id", request_id(headers))
  end

  defp request_id(headers) do
    header_value(headers, "x-request-id") ||
      header_value(headers, "request-id") ||
      header_value(headers, "x-amz-request-id")
  end

  defp collision?(check),
    do: check["status"] == "collision" and check["claim_basis"] == "observed"

  defp flag_for_check(check) do
    source = check["source"]
    query = check["query"]

    %{
      "id" => stable_id("flag-package-collision", check["id"]),
      "candidate_id" => check["candidate_id"],
      "flagged_at" => check["checked_at"],
      "assessor" => %{
        "kind" => "research",
        "name" => "#{source_spec!(source).label} exact package registry check"
      },
      "kind" => "package-collision",
      "severity" => "high",
      "status" => "observed",
      "scope" => "registry:#{source}:package:#{query}",
      "summary" =>
        "Exact #{source_spec!(source).label} package record observed for #{inspect(query)}.",
      "confidence" => 1.0,
      "evidence_refs" => [check["id"]],
      "supersedes" => nil
    }
  end

  defp check_key(candidate_id, source, query) do
    stable_id("package-check-key", Jason.encode!([candidate_id, source, query]))
  end

  defp check_id(check_key, attempt), do: stable_id("package-check", "#{check_key}:#{attempt}")

  defp record_check_key(record) do
    check_key(record["candidate_id"], record["source"], record["query"])
  end

  defp source_totals(checks, sources) do
    Map.new(sources, fn source ->
      source_checks = Enum.filter(checks, &(&1["source"] == source))
      {source, Map.put(status_totals(source_checks), "total", length(source_checks))}
    end)
  end

  defp status_totals(checks) do
    frequencies = Enum.frequencies_by(checks, & &1["status"])
    Map.new(@status_order, &{&1, Map.get(frequencies, &1, 0)})
  end

  defp validate_enrichments!(enrichments) do
    Enum.each(enrichments, fn enrichment ->
      candidate_id = enrichment["candidate_id"]

      unless is_binary(candidate_id) and candidate_id != "" do
        raise ArgumentError, "every enrichment must have a non-empty candidate_id"
      end
    end)

    duplicate_ids =
      enrichments
      |> Enum.frequencies_by(& &1["candidate_id"])
      |> Enum.filter(fn {_id, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))

    if duplicate_ids != [] do
      raise ArgumentError, "duplicate enrichment candidate IDs: #{Enum.join(duplicate_ids, ", ")}"
    end

    enrichments
  end

  defp unique_records!(records, kind) do
    {records, _ids} =
      Enum.reduce(records, {[], MapSet.new()}, fn record, {kept, ids} ->
        id = record["id"]

        unless is_binary(id) and id != "" do
          raise ArgumentError, "existing #{kind} records must have a non-empty id"
        end

        if MapSet.member?(ids, id) do
          {kept, ids}
        else
          {[record | kept], MapSet.put(ids, id)}
        end
      end)

    Enum.reverse(records)
  end

  defp append_missing(existing, generated) do
    ids = MapSet.new(existing, & &1["id"])
    existing ++ Enum.reject(generated, &MapSet.member?(ids, &1["id"]))
  end

  defp maybe_delay(state, true, delay_ms, sleeper)
       when state.network_started? and delay_ms > 0 do
    sleeper.(delay_ms)
    state
  end

  defp maybe_delay(state, _checkable?, _delay_ms, _sleeper), do: state

  defp ensure_distinct_paths!(enrichments, checks, flags) do
    paths = Enum.map([enrichments, checks, flags], &Path.expand/1)

    if length(Enum.uniq(paths)) != length(paths) do
      raise ArgumentError, "enrichments, checks output, and flags output paths must be distinct"
    end
  end

  defp validate_checked_at!(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, _datetime, _offset} -> value
      {:error, _reason} -> raise ArgumentError, "checked_at must be an ISO 8601 datetime"
    end
  end

  defp validate_checked_at!(_value),
    do: raise(ArgumentError, "checked_at must be an ISO 8601 datetime")

  defp validate_delay!(value) when is_integer(value) and value >= 0, do: value

  defp validate_delay!(value),
    do: raise(ArgumentError, "delay must be a non-negative integer, got: #{inspect(value)}")

  defp validate_function!(value, _name) when is_function(value, 1), do: :ok

  defp validate_function!(_value, name),
    do: raise(ArgumentError, "#{name} must be an arity-1 function")

  defp source_spec!(source) do
    case Map.fetch(@source_map, source) do
      {:ok, spec} -> spec
      :error -> raise ArgumentError, "unknown package registry source: #{inspect(source)}"
    end
  end

  defp header_value(headers, expected) do
    Enum.find_value(headers, fn
      {key, value} ->
        if key |> safe_string() |> String.downcase() == expected, do: safe_string(value)

      _other ->
        nil
    end)
  end

  defp safe_string(value) when is_binary(value), do: value
  defp safe_string(value) when is_list(value), do: List.to_string(value)
  defp safe_string(value) when is_atom(value), do: Atom.to_string(value)
  defp safe_string(value), do: to_string(value)

  defp retry_after_date_ms(value) do
    target = value |> String.to_charlist() |> :httpd_util.convert_request_date()
    target_seconds = :calendar.datetime_to_gregorian_seconds(target)
    now_seconds = :calendar.datetime_to_gregorian_seconds(:calendar.universal_time())
    max(target_seconds - now_seconds, 0) * 1_000
  rescue
    _error -> nil
  catch
    _kind, _reason -> nil
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, false), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp now_iso8601 do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  defp stable_id(prefix, value), do: prefix <> "-" <> binary_part(sha256(value), 0, 16)

  defp sha256(value) do
    :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  end
end
