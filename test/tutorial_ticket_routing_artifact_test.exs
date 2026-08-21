defmodule TutorialTicketRoutingArtifactTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Guards the committed evidence behind
  `claim.docs.tutorial_ticket_routing.optimizer_lift`.

  `docs/TUTORIAL_TICKET_ROUTING.md` publishes concrete held-out numbers. This
  test does not assert the doc's exact scores (run-to-run variance is real and
  documented); it asserts that a committed live run artifact exists, that its
  provenance matches the shipped dataset and runner, and that every recorded
  repeat shows positive held-out lift. If the tutorial's numbers ever lose
  their committed evidence, this fails loudly.
  """

  @artifact_glob "benchmarks/evidence/admitted/tutorial_ticket_routing/*.json"
  @dataset_path "priv/tutorial/support_tickets.json"

  test "the committed artifact is content-addressed by its own SHA-256" do
    Enum.each(Path.wildcard(@artifact_glob), fn path ->
      assert Path.basename(path, ".json") == sha256(File.read!(path)),
             "#{path} is not named by the SHA-256 of its content; " <>
               "admitted evidence must be immutable and content-addressed"
    end)
  end

  test "a committed tutorial run artifact exists with verified dataset provenance" do
    artifact = latest_artifact!()

    assert artifact["schema_version"] in [1, 2]
    assert artifact["runner"] == "tutorial-ticket-routing-experiment"
    assert artifact["script"] == "scripts/tutorial_ticket_routing_experiment.exs"
    assert artifact["tutorial"] == "docs/TUTORIAL_TICKET_ROUTING.md"
    assert artifact["model"] == "openai:gpt-5.4-mini"
    assert artifact["git_sha"] =~ ~r/^[0-9a-f]{40}$/

    dataset = artifact["dataset"]
    assert dataset["path"] == @dataset_path
    assert dataset["sha256"] == sha256(File.read!(@dataset_path))
    assert dataset["train"] == 20
    assert dataset["test"] == 20
  end

  test "every recorded repeat shows positive held-out lift over its own baseline" do
    artifact = latest_artifact!()
    runs = artifact["runs"]

    assert is_list(runs) and length(runs) >= 3,
           "the tutorial claim requires at least three recorded live repeats"

    Enum.each(runs, fn run ->
      assert run["heldout_examples"] == 20
      assert is_number(run["baseline_score"])
      assert is_number(run["optimized_score"])

      assert run["optimized_score"] > run["baseline_score"],
             "run #{run["run"]} shows no held-out lift: " <>
               "#{run["baseline_score"]} -> #{run["optimized_score"]}"

      cache = run["cache"]

      assert cache["cleared_before_run"] == true and cache["hits"] == 0,
             "run #{run["run"]} is not a live repeat: cache stats #{inspect(cache)}"

      if budget = summary_budget(artifact) do
        assert budget["single_attempt_transport_enforced"] == true
        assert budget["transport_attempts"] == budget["requests"]
        assert budget["active_reservations"] == 0
      else
        assert cache["misses"] >= 40,
               "run #{run["run"]} recorded fewer cache misses than the 40 live " <>
                 "evaluation calls it must make: #{inspect(cache)}"
      end
    end)

    summary = artifact["summary"]
    assert summary["all_runs_improved"] == true
    assert summary["min_absolute_lift"] > 0
    assert summary["repeats"] == length(runs)
  end

  defp summary_budget(artifact), do: get_in(artifact, ["summary", "optimizer_budget"])

  test "the artifact records the doc's published numbers as claims under test" do
    artifact = latest_artifact!()
    doc_claims = artifact["doc_claims_under_test"]

    assert doc_claims["source"] == "docs/TUTORIAL_TICKET_ROUTING.md"

    if artifact["schema_version"] == 2 do
      assert doc_claims["baseline_repeat_range"] == [0.25, 0.45]
      assert doc_claims["optimized_repeat_range"] == [0.85, 1.0]
    else
      assert is_number(doc_claims["baseline_score"])
      assert is_number(doc_claims["optimized_score"])
    end
  end

  test "the selected parameters serve concurrently from a fresh OS process" do
    artifact = latest_artifact!()

    if artifact["schema_version"] == 1 do
      assert is_nil(artifact["fresh_service"])
    else
      assert_fresh_service!(artifact["fresh_service"])
    end
  end

  defp assert_fresh_service!(fresh) do
    assert fresh["fresh_os_process"] == true
    assert fresh["concurrency"] == 4
    assert fresh["correct"] == fresh["total"]
    assert fresh["artifact_sha256"] =~ ~r/^[0-9a-f]{64}$/
    assert fresh["budget"]["transport_attempts"] == 4
    assert fresh["budget"]["active_reservations"] == 0
  end

  defp latest_artifact! do
    paths = Path.wildcard(@artifact_glob)

    assert paths != [],
           "no committed tutorial run artifact matches #{@artifact_glob}; " <>
             "run scripts/tutorial_ticket_routing_experiment.exs and commit the result"

    paths
    |> Enum.map(fn path -> path |> File.read!() |> Jason.decode!() end)
    |> Enum.max_by(& &1["generated_at"])
  end

  defp sha256(bytes),
    do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
