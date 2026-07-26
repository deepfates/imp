defmodule Imp.LocalCOPROBanking77ExampleTest do
  use ExUnit.Case, async: true

  @source "examples/local_copro_banking77/run.exs"
  @readme "examples/local_copro_banking77/README.md"
  @stopped "examples/local_copro_banking77/exercised-pre-fenced-json-fix-stopped-result.json"

  test "front door follows pinned COPRO trainset selection semantics" do
    source = File.read!(@source)
    readme = File.read!(@readme)

    assert source =~ "COPRO.compile(baseline, examples(rows.train), []"
    refute source =~ "COPRO.compile(baseline, examples(rows.test)"
    assert source =~ "evaluation_dataset == :trainset"

    assert readme =~ "that candidate and the original instruction"
    assert readme =~ "same sixteen training rows"
    assert readme =~ "COPRO selects on its trainset"
    assert readme =~ "use a separate validation set"
  end

  test "acceptance rules out fallback, skipped baseline, and unrendered proposal success" do
    source = File.read!(@source)

    assert source =~ "stage.proposal_mode == :language_model"
    assert source =~ "stage.proposer_calls == 1 and stage.valid_json_proposal"
    assert source =~ "is_number(stage.baseline_score) and is_number(stage.candidate_score)"
    assert source =~ "stage.candidate_rendered_calls == 16 and stage.task_calls == 32"
    assert source =~ "stage.logical_calls == 33 and stage.transport_attempts == 33"
    assert source =~ "cache: false"
    assert source =~ "req_http_options: [retry: false, max_retries: 0]"
  end

  test "heldout rows open only after selection and reproduce from a parameter artifact" do
    source = File.read!(@source)

    selection = byte_offset!(source, "require_optimization!(optimization)")
    artifact = byte_offset!(source, "Artifact.from_optimized_program(selected")

    baseline_heldout =
      byte_offset!(source, ~s(evaluate_stage(baseline, rows.test, observer, "baseline_heldout"))

    selected_heldout =
      byte_offset!(source, ~s(evaluate_stage(selected, rows.test, observer, "selected_heldout"))

    assert selection < artifact
    assert artifact < baseline_heldout
    assert baseline_heldout < selected_heldout
    assert source =~ "Artifact.apply(program!(job, observer))"
    assert source =~ "fresh selected predictions/errors differ"
    assert source =~ "MLXLMDeployment.stop(job)"
  end

  test "package includes the cold consumer project" do
    assert File.read!("mix.exs") =~
             ~S|Path.wildcard("examples/local_copro_banking77/**/*")|
  end

  test "retained pre-fix fence admission does not claim heldout behavior" do
    result = @stopped |> File.read!() |> Jason.decode!()

    assert result["status"] == "stopped_before_heldout"
    assert result["search"]["admitted_candidate"] == "```"
    assert result["search"]["task_calls"] == 32
    refute result["heldout_opened"]
    refute result["fresh_process_attempted"]
    assert result["claim_boundary"] =~ "not valid proposal"
  end

  defp byte_offset!(source, needle) do
    case :binary.match(source, needle) do
      {offset, _length} -> offset
      :nomatch -> flunk("missing source contract: #{needle}")
    end
  end
end
