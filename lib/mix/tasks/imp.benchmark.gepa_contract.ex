defmodule Mix.Tasks.Imp.Benchmark.GepaContract do
  @moduledoc """
  Run provider-free structural contracts against pinned GEPA v0.1.1.

  This is T1 control-flow evidence only. It does not reproduce the GEPA paper,
  establish optimizer effectiveness, or prove full optimizer parity.
  """

  use Mix.Task

  alias Imp.BenchmarkTruth.ArtifactFile

  alias Imp.Optimizer.GEPA.{
    Acceptance,
    Candidate,
    Engine,
    Frontier,
    Merge,
    Pareto,
    Result,
    Stopper
  }

  @shortdoc "Run matched Imp/GEPA v0.1.1 structural contracts"
  @default_out "tmp/gepa-v011-contract"

  defmodule ContractAdapter do
    @moduledoc false
    @behaviour Imp.Optimizer.GEPA.Adapter
    defstruct []

    @impl true
    def evaluate(_adapter, batch, candidate, opts) do
      score =
        Enum.sum(
          for {_name, text} <- candidate,
              do: text |> String.graphemes() |> Enum.count(&(&1 == "#"))
        )

      trajectories =
        if Keyword.get(opts, :capture_traces, false) do
          Map.new(candidate, fn {component, _text} ->
            {component, List.duplicate(nil, length(batch))}
          end)
        else
          %{}
        end

      Result.new(List.duplicate(nil, length(batch)), List.duplicate(score * 1.0, length(batch)),
        trajectories: trajectories,
        metadata: %{metric_calls: length(batch)}
      )
    end

    @impl true
    def make_reflective_dataset(_adapter, _candidate, _result, components) do
      Map.new(components, &{&1, []})
    end
  end

  defmodule NamedProgram do
    @moduledoc false
    defstruct [:planner, :writer]

    def optimizer_predictors(%__MODULE__{} = program),
      do: [planner: program.planner, writer: program.writer]

    def update_optimizer_predictor(%__MODULE__{} = program, name, update)
        when name in [:planner, :writer] do
      Map.update!(program, name, update)
    end
  end

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [out: :string, python: :string, gepa_root: :string]
      )

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    out_dir = Keyword.get(opts, :out, @default_out)
    python = opts |> Keyword.get(:python, current_gepa_python()) |> resolve_executable!()
    gepa_root = Keyword.get(opts, :gepa_root, current_gepa_root()) |> Path.expand()
    File.mkdir_p!(out_dir)

    upstream = run_gepa!(python, gepa_root, out_dir)
    comparison = compare(upstream)

    artifact =
      Map.merge(comparison, %{
        "schema_version" => 1,
        "evidence_tier" => "t1_gepa_v011_structural_differential_contract",
        "claim_scope" => "provider-free GEPA v0.1.1 structural semantics",
        "generated_at" =>
          DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
        "git_sha" => git_sha(),
        "gepa" => sanitized_gepa_identity(upstream["gepa"])
      })

    path =
      Path.join(out_dir, "gepa-v011-contract-#{timestamp_slug()}.json")
      |> ArtifactFile.write_json!(artifact)

    Mix.shell().info("GEPA v0.1.1 T1 structural contract: #{path}")

    unless artifact["summary"]["structural_contract_complete"] do
      Mix.raise("GEPA v0.1.1 T1 structural contract failed; inspect #{path}")
    end
  end

  @doc false
  def compare(upstream) when is_map(upstream) do
    rows = contract_rows(upstream)
    required = Enum.filter(rows, & &1["required"])
    complete = required != [] and Enum.all?(required, & &1["passing"])

    %{
      "summary" => %{
        "total_cases" => length(rows),
        "required_cases" => length(required),
        "required_passing" => Enum.count(required, & &1["passing"]),
        "structural_contract_complete" => complete,
        "paper_reproduction" => false,
        "optimizer_effectiveness" => false,
        "full_optimizer_parity" => false,
        "exact_rng_sequence_parity" => false
      },
      "declared_native_deviations" => declared_native_deviations(),
      "rows" => rows
    }
  end

  defp contract_rows(upstream) do
    acceptance_rows(upstream["acceptance"]) ++
      [pareto_row(upstream["pareto_selection"])] ++
      [component_rotation_row(upstream["component_rotation"])] ++
      merge_rows(upstream["merge"]) ++
      frontier_rows(upstream["frontier_mappings"]) ++
      [budget_stops_row(upstream["budget_stops"])] ++
      [json_resume_row(upstream["json_result_resume"])] ++
      [named_mutation_row(upstream["named_program_mutation"])]
  end

  defp acceptance_rows(upstream) do
    mutation_actual =
      Enum.map(upstream["mutation"], fn fixture ->
        before = result(fixture["before"])
        after_result = result(fixture["after"])

        Map.put(
          Map.take(fixture, ["before", "after"]),
          "accepted",
          Acceptance.accept?(:strict_improvement, before, after_result)
        )
      end)

    merge_actual =
      Enum.map(upstream["merge"], fn fixture ->
        before = fixture["parent_scores"] |> Enum.max() |> result()
        after_result = result(fixture["after"])

        Map.put(
          Map.take(fixture, ["parent_scores", "after"]),
          "accepted",
          Acceptance.accept?(:equal_or_better, before, after_result)
        )
      end)

    [
      row("strict_mutation_acceptance", upstream["mutation"], mutation_actual),
      row("equal_or_better_merge_acceptance", upstream["merge"], merge_actual)
    ]
  end

  defp pareto_row(upstream) do
    mapping = %{"x" => MapSet.new([0]), "y" => MapSet.new([0]), "z" => MapSet.new([1])}
    reduced = Pareto.remove_dominated(mapping, %{0 => 0.7, 1 => 0.8})
    rng = :rand.seed_s(:exsss, {18, 19, 20})

    {draws, _rng} =
      Enum.map_reduce(1..upstream["draw_count"], rng, fn _, rng ->
        Pareto.sample(mapping, %{0 => 0.7, 1 => 0.8}, rng)
      end)

    counts = Enum.frequencies(draws)

    actual = %{
      "mapping" => normalize_mapping(mapping),
      "reduced_mapping" => normalize_mapping(reduced),
      "draw_count" => length(draws),
      "counts" => Map.new(counts, fn {id, count} -> {to_string(id), count} end),
      "coverage_weighted_invariant" => Map.get(counts, 0, 0) > Map.get(counts, 1, 0)
    }

    row("weighted_pareto_selection", upstream, actual, fn expected, actual ->
      expected["reduced_mapping"] == actual["reduced_mapping"] and
        expected["draw_count"] == actual["draw_count"] and
        expected["coverage_weighted_invariant"] and actual["coverage_weighted_invariant"]
    end)
  end

  defp component_rotation_row(upstream) do
    Process.put(:gepa_contract_components, [])

    state =
      Engine.run(
        %ContractAdapter{},
        %{planner: "base planner", writer: "base writer", critic: "base critic"},
        [:train],
        [:validation],
        fn candidate, component, _records, _iteration ->
          Process.put(
            :gepa_contract_components,
            Process.get(:gepa_contract_components, []) ++ [to_string(component)]
          )

          Map.fetch!(candidate, component) <> "#"
        end,
        max_iterations: 5,
        minibatch_size: 1,
        seed: 3
      )

    actual = %{
      "selected" => Process.delete(:gepa_contract_components),
      "next_cursor" => rem(List.last(state.candidates).next_component, 3)
    }

    expected = Map.take(upstream, ["selected", "next_cursor"])
    row("round_robin_component_rotation", expected, actual)
  end

  defp merge_rows(upstream) do
    fixture = merge_fixture()
    rng = fn -> :rand.seed_s(:exsss, {2, 3, 4}) end

    normal =
      Merge.propose_source(
        fixture.candidates,
        fixture.lineage,
        fixture.scores,
        fixture.aggregate_scores,
        [1, 2],
        %{},
        rng.()
      )

    quality_filtered =
      Merge.propose_source(
        fixture.candidates,
        fixture.lineage,
        fixture.scores,
        %{0 => 0.9, 1 => 0.6, 2 => 0.7},
        [1, 2],
        %{},
        rng.()
      )

    repeated =
      Merge.propose_source(
        fixture.candidates,
        fixture.lineage,
        fixture.scores,
        fixture.aggregate_scores,
        [1, 2],
        %{ancestors: [{1, 2, 0}], descriptions: []},
        rng.()
      )

    {:ok, proposal, _attempts, _rng} = normal

    filtering_actual = %{
      "eligible_ancestors" => [proposal.ancestor],
      "quality_filtered" => if(match?({:none, _, _}, quality_filtered), do: [], else: [:failed]),
      "repeated_filtered" => if(match?({:none, _, _}, repeated), do: [], else: [:failed]),
      "ancestor_triplet" => proposal.parent_ids ++ [proposal.ancestor]
    }

    crossover_actual = %{
      "merged_candidate" => stringify_keys(proposal.candidate),
      "merged_parent_ids" => proposal.parent_ids,
      "merged_ancestor" => proposal.ancestor
    }

    overlap_scores = %{1 => %{"only" => 1.0}, 2 => %{"only" => 0.0}}

    overlap =
      Merge.propose_source(
        fixture.candidates,
        fixture.lineage,
        overlap_scores,
        fixture.aggregate_scores,
        [1, 2],
        %{},
        rng.(),
        overlap_floor: 2
      )

    [
      row(
        "common_ancestor_merge_filtering",
        Map.take(upstream, [
          "eligible_ancestors",
          "quality_filtered",
          "repeated_filtered",
          "ancestor_triplet"
        ]),
        filtering_actual
      ),
      row(
        "common_ancestor_merge_crossover",
        Map.take(upstream, ["merged_candidate", "merged_parent_ids", "merged_ancestor"]),
        crossover_actual
      ),
      row(
        "common_ancestor_merge_overlap_gate",
        upstream["overlap_blocked"],
        match?({:none, _, _}, overlap)
      )
    ]
  end

  defp frontier_rows(upstream) do
    candidates = frontier_candidates()

    Enum.map([:instance, :objective, :hybrid, :cartesian], fn policy ->
      row(
        "frontier_mapping_#{policy}",
        upstream[Atom.to_string(policy)],
        candidates |> Frontier.mapping(policy) |> canonical_frontier(policy)
      )
    end)
  end

  defp budget_stops_row(upstream) do
    metric =
      for calls <- [9, 10] do
        stopper_stops?(Stopper.max_metric_calls(10), %{metric_calls: calls, best_score: 0.0})
      end

    threshold =
      for score <- [0.89, 0.9] do
        stopper_stops?(Stopper.score_threshold(0.9), %{metric_calls: 0, best_score: score})
      end

    policy = Stopper.no_improvement(2)

    {no_improvement, _state} =
      Enum.map_reduce([0.5, 0.5, 0.6, 0.59, 0.6], Stopper.new(policy, now: 0), fn score, state ->
        case Stopper.check(policy, state, %{best_score: score}, now: 0) do
          {:continue, state} -> {false, state}
          {:stop, _reasons, state} -> {true, state}
        end
      end)

    expected =
      Map.take(upstream, [
        "metric_calls_at_9_10",
        "score_threshold_at_089_09",
        "no_improvement_sequence"
      ])

    actual = %{
      "metric_calls_at_9_10" => metric,
      "score_threshold_at_089_09" => threshold,
      "no_improvement_sequence" => no_improvement
    }

    row("budget_and_stopper_boundaries", expected, actual)
  end

  defp json_resume_row(upstream) do
    seed_candidate = %{planner: "base", writer: "clear"}

    state =
      Engine.run(
        %ContractAdapter{},
        seed_candidate,
        [:train],
        [:validation],
        fn _, _, _, _ -> "unused" end,
        max_iterations: 0,
        seed: upstream["seed"]
      )

    checkpoint = state |> Engine.dump_state() |> Jason.encode!() |> Jason.decode!()

    resumed =
      Engine.run(
        %ContractAdapter{},
        seed_candidate,
        [:train],
        [:validation],
        fn _, _, _, _ -> "unused" end,
        max_iterations: 0,
        resume_state: checkpoint
      )

    resumed_checkpoint = Engine.dump_state(resumed)

    actual = %{
      "json_roundtrip" => true,
      "candidate_roundtrip" => List.first(resumed.candidates).candidate == seed_candidate,
      "live_rng_state_serialized" => is_map(checkpoint["rng_state"]),
      "live_rng_state_preserved" => checkpoint["rng_state"] == resumed_checkpoint["rng_state"]
    }

    row("json_result_resume_and_rng", upstream, actual, fn expected, actual ->
      expected["roundtrip_equal"] and expected["seed"] == 19 and
        expected["live_rng_state_serialized"] == false and actual["json_roundtrip"] and
        actual["candidate_roundtrip"] and actual["live_rng_state_serialized"] and
        actual["live_rng_state_preserved"]
    end)
  end

  defp named_mutation_row(upstream) do
    Code.ensure_loaded!(NamedProgram)
    planner = Imp.predict("question -> answer")
    writer = Imp.predict("draft -> answer")
    planner = put_in(planner.signature.instructions, upstream["before"]["planner"])
    writer = put_in(writer.signature.instructions, upstream["before"]["writer"])
    program = %NamedProgram{planner: planner, writer: writer}

    candidate = Candidate.from_program(program)
    mutated = Candidate.apply_to_program(program, Map.put(candidate, :writer, upstream["text"]))

    actual = %{
      "before" => candidate |> stringify_keys(),
      "component" => "writer",
      "text" => upstream["text"],
      "after" => mutated |> Candidate.from_program() |> stringify_keys(),
      "unchanged_components" => ["planner"]
    }

    expected =
      Map.take(upstream, ["before", "component", "text", "after", "unchanged_components"])

    row("named_program_mutation", expected, actual)
  end

  defp result(score), do: Result.new([nil], [score])

  defp merge_fixture do
    candidates = %{
      0 => %{"planner" => "base planner", "writer" => "base writer", "critic" => "base critic"},
      1 => %{"planner" => "left planner", "writer" => "base writer", "critic" => "left critic"},
      2 => %{"planner" => "base planner", "writer" => "right writer", "critic" => "right critic"}
    }

    scores = %{
      1 => %{"a" => 1.0, "b" => 0.0, "c" => 0.5, "d" => 0.5, "e" => 0.5},
      2 => %{"a" => 0.0, "b" => 1.0, "c" => 0.5, "d" => 0.5, "e" => 0.5}
    }

    %{
      candidates: candidates,
      lineage: %{0 => [], 1 => [0], 2 => [0]},
      scores: scores,
      aggregate_scores: %{0 => 0.1, 1 => 0.6, 2 => 0.7}
    }
  end

  defp frontier_candidates do
    [
      {0,
       Result.new([nil, nil], [0.2, 0.2],
         objective_scores: [%{quality: 0.5, safety: 0.5}, %{quality: 0.5, safety: 0.5}],
         metadata: %{validation_ids: ["v0", "v1"]}
       )},
      {1,
       Result.new([nil, nil], [1.0, 0.0],
         objective_scores: [%{quality: 1.0, safety: 0.2}, %{quality: 0.8, safety: 0.4}],
         metadata: %{validation_ids: ["v0", "v1"]}
       )},
      {2,
       Result.new([nil, nil], [0.0, 1.0],
         objective_scores: [%{quality: 0.6, safety: 1.0}, %{quality: 0.6, safety: 1.0}],
         metadata: %{validation_ids: ["v0", "v1"]}
       )}
    ]
  end

  defp canonical_frontier(mapping, policy) do
    mapping
    |> Enum.map(fn {key, winners} ->
      dimension =
        case {policy, key} do
          {:instance, {:instance, id}} ->
            ["instance", to_string(id)]

          {:objective, {:objective, objective}} ->
            ["objective", to_string(objective)]

          {:hybrid, {:instance, id}} ->
            ["instance", to_string(id)]

          {:hybrid, {:objective, objective}} ->
            ["objective", to_string(objective)]

          {:cartesian, {:cartesian, id, objective}} ->
            ["cartesian", to_string(id), to_string(objective)]
        end

      %{"dimension" => dimension, "winners" => winners |> Enum.sort()}
    end)
    |> Enum.sort_by(&Jason.encode!(&1["dimension"]))
  end

  defp stopper_stops?(policy, context) do
    case Stopper.check(policy, Stopper.new(policy, now: 0), context, now: 0) do
      {:continue, _state} -> false
      {:stop, _reasons, _state} -> true
    end
  end

  defp normalize_mapping(mapping) do
    Map.new(mapping, fn {key, values} -> {to_string(key), values |> Enum.sort()} end)
  end

  defp row(id, expected, actual, comparator \\ &Kernel.==/2) do
    passing = comparator.(expected, actual)

    %{
      "id" => id,
      "required" => true,
      "status" => if(passing, do: "matched", else: "mismatch"),
      "passing" => passing,
      "expected" => expected,
      "actual" => actual,
      "errors" => if(passing, do: [], else: ["Imp result differs from pinned GEPA contract"])
    }
  end

  defp stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_keys(value), do: value

  defp declared_native_deviations do
    [
      %{
        "id" => "optimizer_rng_sequence",
        "gepa" => "Python random.Random",
        "imp" => "BEAM :rand exsss",
        "consequence" => "weighted sampling invariants match; exact seeded draws do not"
      },
      %{
        "id" => "resume_rng_persistence",
        "gepa" =>
          "GEPAResult JSON records the seed; live GEPAState uses pickle and does not embed Random state",
        "imp" => "JSON checkpoint embeds the exported :rand state",
        "consequence" =>
          "result JSON round-trips in both; Imp additionally resumes the exact native RNG stream"
      },
      %{
        "id" => "release_metadata_version",
        "gepa" => "tag v0.1.1 retains project version 0.1.0 in pyproject.toml",
        "imp" => "contract identifies the release as 0.1.1",
        "consequence" =>
          "tag, commit, project metadata value, and source hashes are pinned independently"
      }
    ]
  end

  defp run_gepa!(python, gepa_root, out_dir) do
    path = Path.join(out_dir, "gepa-v011-upstream-#{timestamp_slug()}.json")

    case System.cmd(
           python,
           ["scripts/gepa_v011_contract.py", "--gepa-root", gepa_root, "--out", path],
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        path |> File.read!() |> Jason.decode!()

      {output, status} ->
        Mix.raise("GEPA v0.1.1 contract failed with status #{status}:\n#{output}")
    end
  end

  defp current_gepa_python do
    System.get_env("IMP_GEPA_V011_PYTHON") || System.get_env("IMP_GEPA_PYTHON") ||
      "python3"
  end

  defp sanitized_gepa_identity(identity) do
    identity
    |> Map.drop(["checkout"])
    |> Map.put("source_materialization", "exact pinned git checkout")
  end

  defp resolve_executable!(path) do
    if Path.type(path) == :absolute or String.contains?(path, "/") do
      expanded = Path.expand(path)

      if File.exists?(expanded),
        do: expanded,
        else: Mix.raise("executable not found: #{expanded}")
    else
      System.find_executable(path) || Mix.raise("executable not found on PATH: #{path}")
    end
  end

  defp current_gepa_root do
    System.get_env("IMP_GEPA_V011_ROOT") || System.get_env("IMP_GEPA_ROOT") ||
      "tmp/gepa-v0.1.1"
  end

  defp git_sha do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> "unknown"
    end
  end

  defp timestamp_slug, do: Calendar.strftime(DateTime.utc_now(), "%Y%m%dT%H%M%SZ")
end
