defmodule Imp.ResearchPortfolio do
  @moduledoc false

  @evidence_tiers ~w(exact_replication reference_differential adapted_public_protocol ecological_field_benchmark imp_native_extension)

  def load!(path \\ "benchmarks/research_portfolio.json", opts \\ []) do
    portfolio = path |> File.read!() |> Jason.decode!()
    claims_path = Keyword.get(opts, :claims_path, "benchmarks/claims.json")
    root = Keyword.get(opts, :root, File.cwd!())
    claims = claims_path |> File.read!() |> Jason.decode!()
    validate!(portfolio, claims, root)
  rescue
    error in [File.Error, Jason.DecodeError, ArgumentError, KeyError] ->
      reraise ArgumentError,
              [
                message:
                  "invalid research portfolio #{Path.expand(path)}: #{Exception.message(error)}"
              ],
              __STACKTRACE__
  end

  def validate!(
        %{"schema_version" => 2, "lanes" => lanes} = portfolio,
        %{"claims" => claims},
        root
      )
      when is_list(lanes) and lanes != [] and is_list(claims) do
    ids = Enum.map(lanes, &Map.fetch!(&1, "id"))
    claim_ids = Enum.flat_map(lanes, &Map.fetch!(&1, "claim_ids"))

    unless ids == Enum.uniq(ids), do: raise(ArgumentError, "research lane ids must be unique")

    unless claim_ids == Enum.uniq(claim_ids),
      do: raise(ArgumentError, "research claims must be owned by exactly one lane")

    active_claim_ids =
      claims
      |> Enum.filter(&(&1["claim_state"] == "target"))
      |> Enum.map(&Map.fetch!(&1, "id"))
      |> Enum.sort()

    unless Enum.sort(claim_ids) == active_claim_ids do
      raise ArgumentError,
            "research claim coverage differs: missing=#{inspect(active_claim_ids -- claim_ids)} extra=#{inspect(claim_ids -- active_claim_ids)}"
    end

    Enum.each(lanes, &validate_lane!(&1, root))
    portfolio
  end

  def validate!(_portfolio, _claims, _root),
    do: raise(ArgumentError, "expected schema_version 2 with non-empty lanes and claims")

  def render(%{"lanes" => lanes}) do
    header = [
      "| Research lane | Capacity under test | Evidence portfolio | Falsification rule |",
      "| --- | --- | --- | --- |"
    ]

    rows =
      Enum.map(lanes, fn lane ->
        views =
          Enum.map_join(lane["benchmark_views"], "<br>", fn view ->
            "#{view["name"]} (#{view["evidence_tier"]})"
          end)

        values = [
          lane["name"],
          lane["capacity"],
          views,
          lane["decision_rules"]["fail"]
        ]

        "| " <> Enum.map_join(values, " | ", &escape_cell/1) <> " |"
      end)

    Enum.join(header ++ rows, "\n")
  end

  def replace_summary!(body, table) do
    start_marker = "<!-- research-portfolio:start -->"
    end_marker = "<!-- research-portfolio:end -->"
    pattern = ~r/#{Regex.escape(start_marker)}.*?#{Regex.escape(end_marker)}/s

    unless Regex.match?(pattern, body),
      do: raise(ArgumentError, "research portfolio summary markers are missing")

    Regex.replace(pattern, body, Enum.join([start_marker, table, end_marker], "\n"))
  end

  defp validate_lane!(lane, root) do
    id = require_nonempty!(lane["id"], "lane id")
    require_nonempty!(lane["name"], "lane #{id} name")
    require_nonempty!(lane["capacity"], "lane #{id} capacity")

    if Map.has_key?(lane, "status"),
      do:
        raise(ArgumentError, "lane #{id} must not cache mutable status; use tk and the dashboard")

    unless is_list(lane["claim_ids"]) and Enum.all?(lane["claim_ids"], &is_binary/1),
      do: raise(ArgumentError, "lane #{id} claim_ids must be a list")

    validate_references!(lane["references"], id)
    validate_views!(lane["benchmark_views"], id)
    require_nonempty_list!(lane["matched_controls"], "lane #{id} matched_controls")
    require_nonempty_list!(lane["metrics"], "lane #{id} metrics")
    require_nonempty_list!(lane["confounders"], "lane #{id} confounders")
    validate_decision_rules!(lane["decision_rules"], id)
    validate_cost!(lane["cost_ceiling_usd"], id)
    validate_preflight!(lane["preflight"], id, root)
  end

  defp validate_references!(references, id) do
    require_nonempty_list!(references, "lane #{id} references")

    unless Enum.any?(references, &(&1["role"] == "upstream_implementation")),
      do: raise(ArgumentError, "lane #{id} must name an upstream implementation")

    Enum.each(references, fn reference ->
      require_nonempty!(reference["role"], "lane #{id} reference role")
      require_nonempty!(reference["locator"], "lane #{id} reference locator")
      require_nonempty!(reference["revision"], "lane #{id} reference revision")
    end)
  end

  defp validate_views!(views, id) do
    require_nonempty_list!(views, "lane #{id} benchmark_views")

    Enum.each(views, fn view ->
      require_nonempty!(view["name"], "lane #{id} benchmark name")
      require_nonempty!(view["construct"], "lane #{id} benchmark construct")
      require_nonempty!(view["protocol"], "lane #{id} benchmark protocol")
      require_member!(view["evidence_tier"], @evidence_tiers, "lane #{id} evidence tier")
    end)
  end

  defp validate_decision_rules!(rules, id) when is_map(rules) do
    require_nonempty!(rules["go"], "lane #{id} go rule")
    require_nonempty!(rules["fail"], "lane #{id} fail rule")
    require_nonempty!(rules["inconclusive"], "lane #{id} inconclusive rule")
  end

  defp validate_decision_rules!(_, id),
    do: raise(ArgumentError, "lane #{id} must declare decision rules")

  defp validate_cost!(cost, id) do
    unless is_number(cost) and cost >= 0,
      do: raise(ArgumentError, "lane #{id} cost ceiling must be non-negative")
  end

  defp validate_preflight!(%{"command" => command, "manifest" => manifest}, id, root) do
    require_nonempty!(command, "lane #{id} preflight command")
    validate_mix_task!(command, id)

    if manifest do
      require_nonempty!(manifest, "lane #{id} preflight manifest")

      if Path.type(manifest) == :absolute or String.contains?(manifest, ["..", "*", "?"]) or
           not File.regular?(Path.join(root, manifest)) do
        raise ArgumentError, "lane #{id} preflight manifest does not resolve: #{manifest}"
      end
    end
  end

  defp validate_preflight!(_, id, _root),
    do: raise(ArgumentError, "lane #{id} must declare a preflight")

  defp validate_mix_task!(command, id) do
    case OptionParser.split(command) do
      ["mix", task | _args] ->
        Mix.Task.load_all()

        unless Mix.Task.get(task),
          do: raise(ArgumentError, "lane #{id} preflight task does not resolve: #{task}")

      _ ->
        raise ArgumentError, "lane #{id} preflight must invoke a Mix task"
    end
  end

  defp require_nonempty_list!(values, context) do
    unless is_list(values) and values != [] and Enum.all?(values, &(is_map(&1) or is_binary(&1))),
      do: raise(ArgumentError, "#{context} must be a non-empty list")
  end

  defp require_member!(value, allowed, context) do
    unless value in allowed,
      do: raise(ArgumentError, "#{context} must be one of #{Enum.join(allowed, ", ")}")
  end

  defp require_nonempty!(value, context) do
    unless is_binary(value) and value != "",
      do: raise(ArgumentError, "#{context} must be non-empty")

    value
  end

  defp escape_cell(value), do: value |> to_string() |> String.replace("|", "\\|")
end
