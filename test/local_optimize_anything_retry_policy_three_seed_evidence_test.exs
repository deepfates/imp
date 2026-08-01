defmodule Imp.LocalOptimizeAnythingRetryPolicyThreeSeedEvidenceTest do
  use ExUnit.Case, async: false

  alias Imp.Optimizer.Artifact

  @manifest "benchmarks/evidence/archive/optimize_anything/retry-policy-v2/manifest.json"
  @manifest_sha "b80b0c32d142863eb7d89ca89773cacb9846913503bd7c7e3b8faa24d52326fc"
  @source "examples/local_optimize_anything_retry_policy/run.exs"
  @test_path "examples/local_optimize_anything_retry_policy/data/untouched-v2.jsonl"
  @test_sha "522245b0d7ec8d896c4b88c0475572a6325c2f25986d8b588d633bffa00590ff"

  setup_all do
    previous = System.get_env("IMP_OA_DEFINE_ONLY")
    System.put_env("IMP_OA_DEFINE_ONLY", "1")
    Code.require_file(@source, File.cwd!())

    on_exit(fn ->
      if previous,
        do: System.put_env("IMP_OA_DEFINE_ONLY", previous),
        else: System.delete_env("IMP_OA_DEFINE_ONLY")
    end)

    :ok
  end

  test "three exact artifacts recompute the scoped positive and execute fresh" do
    assert file_sha(@manifest) == @manifest_sha
    manifest = @manifest |> File.read!() |> Jason.decode!()
    assert manifest["condition"] == "imp-88sn-oa"
    assert manifest["task"]["test_sha256"] == @test_sha
    assert file_sha(@test_path) == @test_sha
    assert manifest["task"]["replay_source_path"] == @source
    assert file_sha(@source) == manifest["task"]["replay_source_sha256"]

    train = task(:train)
    selection = task(:selection)
    test_rows = test_rows!()
    assert {length(train), length(selection), length(test_rows)} == {8, 6, 6}

    expected_optimization_rows = canonical_rows(train ++ selection)
    expected_optimization_sha = sha(Jason.encode!(expected_optimization_rows))
    train_ids = train |> Enum.map(& &1.id) |> MapSet.new()
    selection_ids = selection |> Enum.map(& &1.id) |> MapSet.new()

    assert dataset_digest(train) == manifest["task"]["trainset_term_sha256"]
    assert dataset_digest(selection) == manifest["task"]["selection_term_sha256"]

    id_sets = Enum.map([train, selection, test_rows], &MapSet.new(&1, fn row -> row.id end))
    assert pairwise_disjoint?(id_sets)

    seed_value = task(:seed)
    baseline = evaluate(seed_value, test_rows)
    assert baseline.exact_count == 3

    expected = %{
      2_026_073_101 => %{scores: [0.5636503770362039, 0.8625005207682372], exact: 5},
      2_026_073_102 => %{
        scores: [0.5636503770362039, 0.8625005207682372, 0.8583343748698079],
        exact: 5
      },
      2_026_073_103 => %{scores: [0.5636503770362039, 0.265321001541474], exact: 3}
    }

    outcomes =
      Enum.map(manifest["seeds"], fn entry ->
        path = entry["artifact_path"]
        bytes = File.read!(path)
        assert byte_size(bytes) == entry["artifact_bytes"]
        assert sha(bytes) == entry["artifact_sha256"]
        refute bytes =~ ~r/(authorization|bearer\s+|api[_-]?key|sk-or-|password)/i
        refute bytes =~ "/Users/"

        raw = Jason.decode!(bytes)
        payload = raw["payload"]
        provenance = payload["provenance"]
        seed = provenance["seed"]
        assert raw["schema_version"] == 3
        assert provenance["condition"] == "imp-88sn-oa"
        assert provenance["test_sha256"] == @test_sha

        embedded_rows = embedded_optimization_rows(payload)
        assert canonical_rows(embedded_rows) == expected_optimization_rows
        assert sha(Jason.encode!(canonical_rows(embedded_rows))) == expected_optimization_sha

        embedded_ids = MapSet.new(embedded_rows, & &1["id"])
        assert embedded_ids == MapSet.union(train_ids, selection_ids)
        assert selection_side_info_ids(payload) == selection_ids
        assert MapSet.difference(embedded_ids, selection_side_info_ids(payload)) == train_ids

        assert payload["security"] == %{
                 "credentials_absent" => true,
                 "functions_absent" => true,
                 "json_safe" => true,
                 "redaction_policy" => "imp_default_v1"
               }

        artifact = Artifact.read!(path)
        selected = Artifact.value(artifact)
        inspected = Artifact.inspect(artifact)
        candidates = payload["candidates"] |> Map.values() |> Enum.sort_by(& &1["id"])
        assert Enum.map(candidates, & &1["score"]) == expected[seed].scores
        assert inspected.champion_id == first_max_id(candidates)

        report = payload["candidates"][inspected.champion_id]["report"]
        run_identity = report["checkpoint"]["adapter_state"]["run_identity"]
        assert run_identity["trainset_sha256"] == manifest["task"]["trainset_term_sha256"]
        assert run_identity["valset_sha256"] == manifest["task"]["selection_term_sha256"]
        assert report["validation_schema_version"] == 2
        assert report["seed"] == seed
        assert report["mode"] == %{"__imp_type__" => "atom", "value" => "generalization"}
        assert report["reflection_calls"] == 6

        assert report["stop_reason"] == %{
                 "__imp_type__" => "atom",
                 "value" => "max_iterations"
               }

        recomputed_selection_scores =
          Enum.map(candidates, fn candidate ->
            artifact
            |> Artifact.value(candidate["id"])
            |> mean_score(selection)
          end)

        assert recomputed_selection_scores == entry["selection_scores"]
        assert recomputed_selection_scores == expected[seed].scores
        assert inspected.champion_id == entry["selected_candidate_id"]

        selected_result = evaluate(selected, test_rows)
        assert selected_result.exact_count == expected[seed].exact
        assert entry["baseline_test_exact"] == baseline.exact_count
        assert entry["selected_test_exact"] == selected_result.exact_count
        assert entry["exact_lift"] == selected_result.exact_count - baseline.exact_count

        fresh_outputs = fresh_outputs!(path)
        assert fresh_outputs == selected_result.outputs
        assert sha(Jason.encode!(fresh_outputs)) == entry["fresh_outputs_sha256"]

        %{
          seed: seed,
          exact_lift: selected_result.exact_count - baseline.exact_count,
          proposer_generated: selected != seed_value
        }
      end)

    assert Enum.map(outcomes, & &1.exact_lift) == [2, 2, 0]
    assert Enum.count(outcomes, &(&1.exact_lift > 0)) == 2
    assert Enum.sum(Enum.map(outcomes, & &1.exact_lift)) / 3 == 4 / 3
    assert Enum.map(outcomes, & &1.proposer_generated) == [true, true, false]

    assert manifest["aggregate"] == %{
             "exact_lifts" => Enum.map(outcomes, & &1.exact_lift),
             "mean_exact_lift" => 4 / 3,
             "positive_seeds" => Enum.count(outcomes, &(&1.exact_lift > 0)),
             "fresh_artifacts" => 3
           }
  end

  defp test_rows! do
    @test_path
    |> File.stream!()
    |> Enum.map(fn line ->
      row = Jason.decode!(line)

      %{
        id: row["id"],
        attempt: row["attempt"],
        retryable: row["retryable"],
        urgent: row["urgent"],
        retry_after_ms: row["retry_after_ms"],
        jitter_slot: row["jitter_slot"],
        expected: row["expected"]
      }
    end)
  end

  defp evaluate(candidate, rows) do
    outputs =
      Enum.map(rows, fn row ->
        {score, info} = task(:evaluate, [candidate, row])
        %{"id" => row.id, "expected" => row.expected, "actual" => info.actual, "score" => score}
      end)

    %{exact_count: Enum.count(outputs, &(&1["score"] == 1.0)), outputs: outputs}
  end

  defp mean_score(candidate, rows) do
    scores = Enum.map(rows, fn row -> task(:evaluate, [candidate, row]) |> elem(0) end)
    Enum.sum(scores) / length(scores)
  end

  defp fresh_outputs!(artifact_path) do
    script = """
    System.put_env("IMP_OA_DEFINE_ONLY", "1")
    Code.require_file(#{inspect(@source)}, File.cwd!())
    artifact = Imp.Optimizer.Artifact.read!(System.fetch_env!("IMP_OA_ARTIFACT"))
    candidate = Imp.Optimizer.Artifact.value(artifact)
    rows =
      #{inspect(@test_path)}
      |> File.stream!()
      |> Enum.map(fn line ->
        row = Jason.decode!(line)
        %{id: row["id"], attempt: row["attempt"], retryable: row["retryable"], urgent: row["urgent"], retry_after_ms: row["retry_after_ms"], jitter_slot: row["jitter_slot"], expected: row["expected"]}
      end)
    outputs = Enum.map(rows, fn row ->
      {score, info} = LocalOptimizeAnythingRetryPolicy.Task.evaluate(candidate, row)
      %{"id" => row.id, "expected" => row.expected, "actual" => info.actual, "score" => score}
    end)
    IO.write(Jason.encode!(outputs))
    """

    {output, 0} =
      System.cmd("mix", ["run", "--no-compile", "--no-deps-check", "-e", script],
        env: [{"IMP_OA_ARTIFACT", Path.expand(artifact_path)}],
        stderr_to_stdout: true
      )

    output |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()
  end

  defp first_max_id(candidates) do
    candidates
    |> Enum.max_by(& &1["score"], fn -> nil end)
    |> Map.fetch!("id")
  end

  defp embedded_optimization_rows(payload) do
    champion_id = payload["champion_id"]

    payload["candidates"][champion_id]["report"]["checkpoint"]["adapter_state"][
      "optimization_state"
    ]["entries"]
    |> Enum.map(fn [encoded_row, _trajectories] -> decode_imp_value(encoded_row) end)
  end

  defp selection_side_info_ids(payload) do
    champion_id = payload["champion_id"]

    payload["candidates"][champion_id]["report"]["candidate_side_information"]
    |> Enum.flat_map(&Map.values/1)
    |> List.flatten()
    |> Enum.map(&decode_imp_value/1)
    |> Enum.map(& &1["id"])
    |> MapSet.new()
  end

  defp decode_imp_value(%{"__imp_type__" => "map", "entries" => entries}) do
    Map.new(entries, fn [key, value] -> {decode_imp_value(key), decode_imp_value(value)} end)
  end

  defp decode_imp_value(%{"__imp_type__" => "atom", "value" => "true"}), do: true
  defp decode_imp_value(%{"__imp_type__" => "atom", "value" => "false"}), do: false
  defp decode_imp_value(%{"__imp_type__" => "atom", "value" => "nil"}), do: nil
  defp decode_imp_value(%{"__imp_type__" => "atom", "value" => value}), do: value
  defp decode_imp_value(value), do: value

  defp canonical_rows(rows) do
    rows
    |> Enum.map(fn row ->
      Map.new(row, fn {key, value} -> {to_string(key), value} end)
    end)
    |> Enum.sort_by(& &1["id"])
  end

  defp pairwise_disjoint?([first, second, third]) do
    MapSet.disjoint?(first, second) and MapSet.disjoint?(first, third) and
      MapSet.disjoint?(second, third)
  end

  defp file_sha(path), do: path |> File.read!() |> sha()
  defp dataset_digest(rows), do: rows |> :erlang.term_to_binary([:deterministic]) |> sha()
  defp sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp task(function, arguments \\ []),
    do: apply(LocalOptimizeAnythingRetryPolicy.Task, function, arguments)
end
