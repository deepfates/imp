defmodule DSEx.IdentityCheckpoint do
  @moduledoc false

  @atlas_path "identity/atlas.json"
  @inbox_glob "identity/inbox/*.json"

  @type portfolio_entry :: %{
          path: String.t(),
          sha256: String.t(),
          data: map()
        }

  @spec load_atlas!(Path.t()) :: map()
  def load_atlas!(path \\ @atlas_path) do
    path
    |> File.read!()
    |> Jason.decode!()
  end

  @spec load_portfolios!(String.t()) :: [portfolio_entry()]
  def load_portfolios!(glob \\ @inbox_glob) do
    glob
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(fn path ->
      body = File.read!(path)

      %{
        path: path,
        sha256: sha256(body),
        data: Jason.decode!(body)
      }
    end)
  end

  @spec compile(map(), [portfolio_entry()]) ::
          {:ok, %{events: [map()], report: map()}} | {:error, [String.t()]}
  def compile(atlas, portfolios) when is_map(atlas) and is_list(portfolios) do
    context = atlas_context(atlas)

    errors =
      context.errors ++
        duplicate_run_errors(portfolios) ++
        Enum.flat_map(portfolios, &validate_portfolio(&1, context))

    if errors == [] do
      events = Enum.flat_map(portfolios, &portfolio_events/1)
      {:ok, %{events: events, report: coverage_report(atlas, events)}}
    else
      {:error, Enum.sort(errors)}
    end
  end

  @spec normalize_surface(String.t()) :: String.t()
  def normalize_surface(surface) when is_binary(surface) do
    surface
    |> String.normalize(:nfkc)
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}]+/u, "")
  end

  @spec candidate_id(String.t()) :: String.t()
  def candidate_id(surface) do
    "cand-" <> (surface |> normalize_surface() |> sha256() |> binary_part(0, 16))
  end

  @spec render_registry([map()]) :: String.t()
  def render_registry(events) do
    Enum.map_join(events, "\n", &Jason.encode!/1) <> if(events == [], do: "", else: "\n")
  end

  @spec write_atomic!(Path.t(), iodata()) :: :ok
  def write_atomic!(path, contents) do
    File.mkdir_p!(Path.dirname(path))
    temporary = path <> ".tmp-#{System.unique_integer([:positive])}"
    File.write!(temporary, contents)
    File.rename!(temporary, path)
  end

  defp atlas_context(atlas) do
    required_collections = [
      "territories",
      "lexical_strategies",
      "audiences",
      "brand_architectures",
      "assessment_axes"
    ]

    collection_errors =
      Enum.flat_map(required_collections, fn key ->
        case Map.get(atlas, key) do
          values when is_list(values) and values != [] -> []
          _ -> ["atlas.#{key} must be a non-empty array"]
        end
      end)

    %{
      version: Map.get(atlas, "atlas_version"),
      territory_ids: id_set(atlas, "territories"),
      strategy_ids: id_set(atlas, "lexical_strategies"),
      audience_ids: id_set(atlas, "audiences"),
      architecture_ids: id_set(atlas, "brand_architectures"),
      errors:
        collection_errors ++
          if(is_integer(Map.get(atlas, "atlas_version")),
            do: [],
            else: ["atlas.atlas_version must be an integer"]
          )
    }
  end

  defp id_set(atlas, key) do
    atlas
    |> Map.get(key, [])
    |> Enum.map(&Map.get(&1, "id"))
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp duplicate_run_errors(portfolios) do
    portfolios
    |> Enum.group_by(&get_in(&1, [:data, "run", "id"]))
    |> Enum.flat_map(fn
      {nil, _entries} ->
        []

      {_run_id, [_entry]} ->
        []

      {run_id, entries} ->
        paths = Enum.map_join(entries, ", ", & &1.path)
        ["duplicate run id #{inspect(run_id)} in #{paths}"]
    end)
  end

  defp validate_portfolio(%{path: path, data: data}, context) do
    run = Map.get(data, "run", %{})
    candidates = Map.get(data, "candidates")

    []
    |> require_equal(Map.get(data, "schema_version"), 1, "#{path}: schema_version")
    |> require_nonempty(Map.get(run, "id"), "#{path}: run.id")
    |> require_datetime(Map.get(run, "generated_at"), "#{path}: run.generated_at")
    |> require_nonempty(Map.get(run, "method"), "#{path}: run.method")
    |> require_nonempty(Map.get(run, "brief"), "#{path}: run.brief")
    |> require_equal(
      Map.get(run, "atlas_version"),
      context.version,
      "#{path}: run.atlas_version"
    )
    |> require_generator(Map.get(run, "generator"), "#{path}: run.generator")
    |> validate_ids(
      Map.get(run, "intended_territories"),
      context.territory_ids,
      "#{path}: run.intended_territories"
    )
    |> validate_ids(
      Map.get(run, "intended_strategies"),
      context.strategy_ids,
      "#{path}: run.intended_strategies"
    )
    |> validate_ids(
      Map.get(run, "intended_audiences"),
      context.audience_ids,
      "#{path}: run.intended_audiences"
    )
    |> validate_candidates(candidates, path, context)
  end

  defp validate_candidates(errors, candidates, path, _context)
       when not is_list(candidates) or candidates == [] do
    ["#{path}: candidates must be a non-empty array" | errors]
  end

  defp validate_candidates(errors, candidates, path, context) do
    ordinals = Enum.map(candidates, &Map.get(&1, "ordinal"))
    expected = Enum.to_list(1..length(candidates))

    errors =
      if ordinals == expected,
        do: errors,
        else: ["#{path}: candidate ordinals must be contiguous from 1" | errors]

    Enum.reduce(candidates, errors, fn candidate, acc ->
      prefix = "#{path}: candidate #{inspect(Map.get(candidate, "ordinal"))}"

      acc
      |> require_nonempty(Map.get(candidate, "surface"), "#{prefix}.surface")
      |> require_nonempty(Map.get(candidate, "rationale"), "#{prefix}.rationale")
      |> validate_ids(
        Map.get(candidate, "territories"),
        context.territory_ids,
        "#{prefix}.territories",
        require_nonempty: true
      )
      |> validate_ids(
        Map.get(candidate, "strategies"),
        context.strategy_ids,
        "#{prefix}.strategies",
        require_nonempty: true
      )
      |> validate_ids(
        Map.get(candidate, "audience_lenses", []),
        context.audience_ids,
        "#{prefix}.audience_lenses"
      )
      |> validate_ids(
        Map.get(candidate, "architecture_lenses", []),
        context.architecture_ids,
        "#{prefix}.architecture_lenses"
      )
    end)
  end

  defp require_generator(errors, generator, label) when is_map(generator) do
    errors
    |> require_nonempty(Map.get(generator, "kind"), "#{label}.kind")
    |> require_nonempty(Map.get(generator, "name"), "#{label}.name")
  end

  defp require_generator(errors, _generator, label),
    do: ["#{label} must be an object" | errors]

  defp require_nonempty(errors, value, _label) when is_binary(value) and value != "", do: errors

  defp require_nonempty(errors, _value, label),
    do: ["#{label} must be a non-empty string" | errors]

  defp require_equal(errors, value, value, _label), do: errors

  defp require_equal(errors, actual, expected, label),
    do: ["#{label} must be #{inspect(expected)}, got #{inspect(actual)}" | errors]

  defp require_datetime(errors, value, label) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, _datetime, _offset} -> errors
      _ -> ["#{label} must be an ISO 8601 UTC timestamp" | errors]
    end
  end

  defp require_datetime(errors, _value, label),
    do: ["#{label} must be an ISO 8601 UTC timestamp" | errors]

  defp validate_ids(errors, values, allowed, label, opts \\ [])

  defp validate_ids(errors, values, allowed, label, opts) when is_list(values) do
    errors =
      if Keyword.get(opts, :require_nonempty, false) and values == [],
        do: ["#{label} must not be empty" | errors],
        else: errors

    unknown =
      values |> MapSet.new() |> MapSet.difference(allowed) |> MapSet.to_list() |> Enum.sort()

    if unknown == [],
      do: errors,
      else: ["#{label} contains unknown ids: #{Enum.join(unknown, ", ")}" | errors]
  end

  defp validate_ids(errors, _values, _allowed, label, _opts),
    do: ["#{label} must be an array" | errors]

  defp portfolio_events(%{path: path, sha256: file_sha, data: data}) do
    run = Map.fetch!(data, "run")
    run_id = Map.fetch!(run, "id")
    generated_at = Map.fetch!(run, "generated_at")

    run_event = %{
      "event_type" => "generation_run",
      "event_id" => stable_id("event", "run:#{run_id}"),
      "run_id" => run_id,
      "occurred_at" => generated_at,
      "source_path" => path,
      "source_sha256" => file_sha,
      "candidate_count" => length(Map.fetch!(data, "candidates")),
      "run" => run
    }

    candidate_events =
      Enum.map(Map.fetch!(data, "candidates"), fn candidate ->
        surface = Map.fetch!(candidate, "surface")
        ordinal = Map.fetch!(candidate, "ordinal")
        normalized = normalize_surface(surface)

        %{
          "event_type" => "candidate_observed",
          "event_id" => stable_id("event", "candidate:#{run_id}:#{ordinal}"),
          "occurrence_id" => stable_id("occ", "#{run_id}:#{ordinal}"),
          "candidate_id" => "cand-" <> binary_part(sha256(normalized), 0, 16),
          "run_id" => run_id,
          "ordinal" => ordinal,
          "occurred_at" => generated_at,
          "source_path" => path,
          "source_sha256" => file_sha,
          "surface" => surface,
          "normalized" => normalized,
          "candidate" => candidate
        }
      end)

    [run_event | candidate_events]
  end

  defp coverage_report(atlas, events) do
    runs = Enum.filter(events, &(&1["event_type"] == "generation_run"))
    candidates = Enum.filter(events, &(&1["event_type"] == "candidate_observed"))
    requirements = Map.get(atlas, "coverage_requirements", %{})

    territory_counts = occurrence_counts(candidates, "territories")
    strategy_counts = occurrence_counts(candidates, "strategies")
    audience_counts = run_intent_counts(runs, "intended_audiences")

    run_ids_by_territory =
      candidates
      |> Enum.reduce(%{}, fn event, acc ->
        Enum.reduce(get_in(event, ["candidate", "territories"]) || [], acc, fn territory, inner ->
          Map.update(
            inner,
            territory,
            MapSet.new([event["run_id"]]),
            &MapSet.put(&1, event["run_id"])
          )
        end)
      end)
      |> Map.new(fn {territory, run_ids} -> {territory, MapSet.size(run_ids)} end)

    raw_count = length(candidates)
    distinct_count = candidates |> Enum.map(& &1["candidate_id"]) |> MapSet.new() |> MapSet.size()
    wildcard_count = Enum.count(candidates, &(get_in(&1, ["candidate", "wildcard"]) == true))
    wildcard_fraction = if raw_count == 0, do: 0.0, else: wildcard_count / raw_count

    methods = runs |> Enum.map(&get_in(&1, ["run", "method"])) |> MapSet.new()

    generators =
      runs
      |> Enum.map(fn event ->
        generator = get_in(event, ["run", "generator"]) || %{}
        Map.get(generator, "model") || Map.get(generator, "name")
      end)
      |> MapSet.new()

    gaps =
      []
      |> minimum_gap("raw occurrences", raw_count, requirements["minimum_raw_occurrences"])
      |> minimum_gap(
        "distinct normalized candidates",
        distinct_count,
        requirements["minimum_distinct_normalized_candidates"]
      )
      |> minimum_gap("independent runs", length(runs), requirements["minimum_independent_runs"])
      |> minimum_gap(
        "generator models or methods",
        MapSet.size(MapSet.union(methods, generators)),
        requirements["minimum_generator_models_or_methods"]
      )
      |> minimum_per_id_gaps(
        "runs for territory",
        Enum.map(atlas["territories"] || [], & &1["id"]),
        run_ids_by_territory,
        requirements["minimum_runs_per_territory"]
      )
      |> minimum_per_id_gaps(
        "candidates for lexical strategy",
        Enum.map(atlas["lexical_strategies"] || [], & &1["id"]),
        strategy_counts,
        requirements["minimum_candidates_per_lexical_strategy"]
      )
      |> minimum_gap(
        "wildcard fraction basis points",
        round(wildcard_fraction * 10_000),
        round((requirements["minimum_wildcard_fraction"] || 0) * 10_000)
      )
      |> audience_gaps(atlas, audience_counts)
      |> Enum.reverse()

    %{
      "atlas_version" => atlas["atlas_version"],
      "generated_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "generation_floor_pass" => gaps == [],
      "summary" => %{
        "runs" => length(runs),
        "raw_occurrences" => raw_count,
        "distinct_normalized_candidates" => distinct_count,
        "duplicate_occurrences" => raw_count - distinct_count,
        "wildcard_occurrences" => wildcard_count,
        "wildcard_fraction" => wildcard_fraction,
        "methods" => MapSet.size(methods),
        "generators" => MapSet.size(generators)
      },
      "coverage" => %{
        "territory_occurrences" => territory_counts,
        "territory_independent_runs" => run_ids_by_territory,
        "lexical_strategy_occurrences" => strategy_counts,
        "audience_intended_runs" => audience_counts
      },
      "gaps" => gaps
    }
  end

  defp occurrence_counts(events, candidate_key) do
    events
    |> Enum.flat_map(&(get_in(&1, ["candidate", candidate_key]) || []))
    |> Enum.frequencies()
  end

  defp run_intent_counts(events, run_key) do
    events
    |> Enum.flat_map(&(get_in(&1, ["run", run_key]) || []))
    |> Enum.frequencies()
  end

  defp minimum_gap(gaps, _label, _actual, nil), do: gaps

  defp minimum_gap(gaps, _label, actual, minimum) when actual >= minimum, do: gaps

  defp minimum_gap(gaps, label, actual, minimum),
    do: ["#{label}: #{actual}/#{minimum}" | gaps]

  defp minimum_per_id_gaps(gaps, _label, _ids, _counts, nil), do: gaps

  defp minimum_per_id_gaps(gaps, label, ids, counts, minimum) do
    Enum.reduce(ids, gaps, fn id, acc ->
      minimum_gap(acc, "#{label} #{id}", Map.get(counts, id, 0), minimum)
    end)
  end

  defp audience_gaps(gaps, atlas, counts) do
    if get_in(atlas, ["coverage_requirements", "required_audience_challenge_coverage"]) == "all" do
      Enum.reduce(atlas["audiences"] || [], gaps, fn audience, acc ->
        minimum_gap(
          acc,
          "runs for audience #{audience["id"]}",
          Map.get(counts, audience["id"], 0),
          1
        )
      end)
    else
      gaps
    end
  end

  defp stable_id(prefix, value), do: prefix <> "-" <> binary_part(sha256(value), 0, 16)

  defp sha256(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
  end
end
