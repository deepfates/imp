defmodule Imp.BenchmarkTruth.HoverGepaNoMergePlan do
  @moduledoc false

  alias Imp.Optimizer.GEPA

  @gepa_artifact_commit "cbefbc1aa0f43dd39874ec4bf42211365dbda42e"
  @dspy_commit "29448ae12756abdd14bd8796c819247ebb83673c"
  @gepa_commit "8b0ce6cd99a234f6b74daf37558a2ac0ce18f975"
  @model "openai:gpt-4.1-mini-2025-04-14"
  @seeds [2_026_080_201, 2_026_080_202, 2_026_080_203]
  @train_size 150
  @selection_size 300
  @test_size 300
  @stages 4
  @repetitions 3
  @semantic_metric_calls 1_200
  @minibatch_size 3
  @service_calls_per_seed 4

  @split_sha256 %{
    train: "448048cc80de7982b344ef3c8767816164eeabe3d2a1ad4f776245e3dff39370",
    selection: "b342dbaaa4516e55b7f4f7ac046828c2201952e69de5b97751173238674a74a7",
    test: "cf1b51ca6ed32c21355a954624d88b396d3e963585549cea68308b519c5a8807"
  }

  @retrieval_sha256 %{
    corpus: "c006527c7c600f85ed594afa36d2a34d0598996405f560474227738342463724",
    index: "c35ec78680306e6521110e714083998edc653926ea0641fb272908b744629d22"
  }

  @source_files %{
    "gepa_artifact/benchmarks/hover/hover_data.py" =>
      "702cbecdf5bb1c6725910cd6cfd37804d6be3f03778549bb37ffc11871bcf183",
    "gepa_artifact/benchmarks/hover/hover_program.py" =>
      "705a1d4fa5452d66d21c00d8d915d5dcd57e820b077a68bf3786407d040d3522",
    "gepa_artifact/benchmarks/hover/hover_utils.py" =>
      "1bb0203800caa8c347aab173df319fc2d0507db4c737bec45b6ade915f101f5a"
  }

  @upstream_files %{
    "src/gepa/core/engine.py" =>
      "ba361b477de74c20eb813b277b0fb85b6898ca534e09c8e878604fb1c8980c53",
    "src/gepa/proposer/merge.py" =>
      "cd0a3254927e399d0cae4a212076f7577161027b3c4ff19d03c3d2150408ee5a"
  }

  def design(opts \\ []) do
    envelope = GEPA.v014_budget_envelope(@selection_size, @minibatch_size, @semantic_metric_calls)

    outer_program_evaluations =
      @repetitions * (2 * @selection_size + 2 * @test_size)

    nominal_task_per_runtime_seed =
      @stages * (@semantic_metric_calls + outer_program_evaluations)

    legal_task_per_runtime_seed =
      @stages * (envelope.max_metric_calls + outer_program_evaluations)

    %{
      condition: "imp-88sn-hover-gepa-no-merge-current-v1",
      status: :readiness_only,
      target_claim: "adapted current-source matched-information/opportunity noninferiority",
      excluded_claims: ["paper replication", "runtime parity", "GEPA-with-merge"],
      authorities: %{
        gepa_artifact: @gepa_artifact_commit,
        dspy: @dspy_commit,
        gepa: @gepa_commit
      },
      model: @model,
      seeds: @seeds,
      rows: %{train: @train_size, selection: @selection_size, test: @test_size},
      split_sha256: @split_sha256,
      retrieval_sha256: @retrieval_sha256,
      data_readiness: data_readiness(opts),
      optimizer: %{
        execution_profile: :gepa_v0_1_4,
        use_merge: false,
        module_selector: :round_robin,
        minibatch_size: @minibatch_size,
        semantic_max_metric_calls: @semantic_metric_calls,
        generations: envelope.max_iterations,
        logical_iterations: envelope.max_iterations,
        operational_metric_calls: envelope.max_metric_calls,
        logical_reflections: envelope.max_iterations,
        legal_reflection_transports: envelope.max_reflection_calls
      },
      outer: %{
        repetitions: @repetitions,
        aggregation: :mean,
        strict_baseline_on_tie: true,
        compare_baseline_on_test: true,
        program_evaluations_per_runtime_seed: outer_program_evaluations
      },
      transports: %{
        nominal_task_per_runtime_seed: nominal_task_per_runtime_seed,
        legal_task_per_runtime_seed: legal_task_per_runtime_seed,
        nominal_task_all_runtimes_seeds: nominal_task_per_runtime_seed * 2 * length(@seeds),
        legal_task_all_runtimes_seeds: legal_task_per_runtime_seed * 2 * length(@seeds),
        imp_fresh_service: @service_calls_per_seed * @stages * length(@seeds),
        nominal_total:
          nominal_task_per_runtime_seed * 2 * length(@seeds) +
            @service_calls_per_seed * @stages * length(@seeds),
        legal_total:
          legal_task_per_runtime_seed * 2 * length(@seeds) +
            @service_calls_per_seed * @stages * length(@seeds),
        logical_reflections_all_runtimes_seeds: envelope.max_iterations * 2 * length(@seeds),
        legal_reflection_transports_all_runtimes_seeds:
          envelope.max_reflection_calls * 2 * length(@seeds)
      }
    }
  end

  def optimizer(metric, reflection_lm, seed) when seed in @seeds do
    GEPA.new(metric,
      execution_profile: :gepa_v0_1_4,
      reflection_record_mode: :gepa_v0_1_4,
      reflection_lm: reflection_lm,
      component_feedback: Imp.BenchmarkTruth.HoverFeedback.callbacks(),
      module_selector: :round_robin,
      use_merge: false,
      minibatch_size: @minibatch_size,
      generations: design().optimizer.generations,
      max_metric_calls: @semantic_metric_calls,
      max_reflection_calls: design().optimizer.legal_reflection_transports,
      seed: seed,
      max_concurrency: 1
    )
  end

  def optimizer(_metric, _reflection_lm, seed) do
    raise ArgumentError, "unfrozen HoVer seed: #{inspect(seed)}"
  end

  def verify_authorities!(opts \\ []) do
    artifact_root = Keyword.get(opts, :artifact_root, "tmp/gepa-artifact")
    gepa_root = Keyword.get(opts, :gepa_root, "tmp/gepa-v0.1.4")
    dspy_root = Keyword.get(opts, :dspy_root, "tmp/dspy-3.2.1")

    verify_git!(artifact_root, @gepa_artifact_commit)
    verify_git!(gepa_root, @gepa_commit)
    verify_git!(dspy_root, @dspy_commit)
    verify_files!(artifact_root, @source_files)
    verify_files!(gepa_root, @upstream_files)
    :ok
  end

  def data_readiness(opts \\ []) do
    data_root = Keyword.get(opts, :data_root)
    retrieval = Keyword.get(opts, :retrieval)

    if is_binary(data_root) and is_map(retrieval) do
      verify_materialized!(data_root, retrieval)
      %{data_ready: true, data_root: Path.expand(data_root)}
    else
      %{
        data_ready: false,
        reason:
          "full 150/300/300 exported rows and source-exact 5.2M-document corpus/index are not materialized on this machine"
      }
    end
  end

  def verify_materialized!(data_root, retrieval)
      when is_binary(data_root) and is_map(retrieval) do
    expected = [
      {"train.jsonl", @train_size, @split_sha256.train},
      {"dev.jsonl", @selection_size, @split_sha256.selection},
      {"test.jsonl", @test_size, @split_sha256.test}
    ]

    Enum.each(expected, fn {filename, count, digest} ->
      path = Path.join(data_root, filename)

      unless File.exists?(path) and line_count(path) == count and file_sha256(path) == digest do
        raise ArgumentError, "HoVer materialized split does not match the frozen source: #{path}"
      end
    end)

    verify_retrieval!(retrieval)
  end

  def verify_retrieval!(retrieval) when is_map(retrieval) do
    expected = %{
      "corpus_checksum" => "sha256:" <> @retrieval_sha256.corpus,
      "index_checksum" => "sha256:" <> @retrieval_sha256.index
    }

    unless Map.take(retrieval, Map.keys(expected)) == expected do
      raise ArgumentError, "HoVer retrieval identity does not match the frozen source"
    end

    Imp.BenchmarkTruth.HoverBM25.verify_source!(retrieval)
  end

  def provider_disabled_lifecycle!(root, seed) when seed in @seeds do
    File.mkdir_p!(root)
    program = provider_disabled_program()
    metric = provider_disabled_metric()
    data = provider_disabled_data()
    {optimizer, reflection_counter} = provider_disabled_optimizer(metric, seed)
    artifact_path = Path.join(root, "artifact-#{seed}.json")
    result_path = Path.join(root, "result-#{seed}.json")
    receipt_path = Path.join(root, "fresh-#{seed}.json")

    result =
      try do
        {:ok, result} =
          Imp.Experiment.check(program, optimizer, data, metric,
            artifact_id: "hover-no-merge-#{seed}",
            compare_baseline_on_test: true,
            evaluation_options: [repetitions: @repetitions, aggregation: :mean, max_errors: 0],
            config: %{condition: design().condition, seed: seed}
          )

        result
      after
        Agent.stop(reflection_counter)
      end

    :ok = Imp.Experiment.Result.write!(result, result_path)
    :ok = Imp.Optimizer.Artifact.write!(result.artifact, artifact_path)

    fresh_service!(artifact_path, receipt_path)
    receipt = receipt_path |> File.read!() |> Jason.decode!()

    optimizer_report =
      result.artifact
      |> Imp.Optimizer.Artifact.inspect()
      |> Map.fetch!(:candidates)
      |> Enum.find_value(fn candidate -> candidate["report"] end)
      |> Imp.Optimizer.Report.decode_term_portable()

    proposal_components = proposal_components(optimizer_report["candidates"])

    best_parameters =
      optimizer_report["candidates"]
      |> Enum.max_by(& &1["score"])
      |> Map.fetch!("parameters")

    %{
      seed: seed,
      selected: result.selected,
      baseline_selection: result.baseline_selection.score,
      optimized_selection: result.optimized_selection.score,
      baseline_test: result.baseline_test.score,
      selected_test: result.test.score,
      optimizer_metric_calls: get_in(optimizer_report, ["metadata", "metric_calls"]),
      optimizer_reflection_calls: get_in(optimizer_report, ["metadata", "reflection_calls"]),
      optimizer_candidate_count: optimizer_report["candidate_count"],
      optimizer_errors: optimizer_report["errors"],
      rejected_candidates: get_in(optimizer_report, ["metadata", "rejected_candidates"]),
      proposal_components: proposal_components,
      changed_predictors: Enum.sort(for {name, "Improved."} <- best_parameters, do: name),
      artifact_sha256: file_sha256(artifact_path),
      result_sha256: file_sha256(result_path),
      fresh_service: receipt
    }
  end

  def provider_disabled_lifecycle!(_root, seed),
    do: raise(ArgumentError, "unfrozen HoVer seed: #{inspect(seed)}")

  def provider_disabled_program do
    Imp.BenchmarkTruth.HoverMultiHop.from_retriever(static_task_lm(), static_retriever())
  end

  def provider_disabled_example do
    hd(provider_disabled_rows("probe", 1))
  end

  defp provider_disabled_data do
    alias Imp.Experiment.Data

    Data.new(
      train: provider_disabled_rows("train", 4),
      selection: provider_disabled_rows("selection", 4),
      test: provider_disabled_rows("test", 4),
      id: :id
    )
  end

  defp provider_disabled_rows(split, count) do
    Enum.map(0..(count - 1), fn index ->
      Imp.example(
        id: "#{split}-#{index}",
        claim: "Alpha relation #{split} #{index}",
        supporting_facts: [%{"key" => "Gamma#{rem(index, 4) + 1}"}]
      )
      |> Imp.with_inputs(:claim)
    end)
  end

  defp static_task_lm do
    Imp.LM.Static.new(
      handler: fn messages, _opts ->
        prompt = Enum.map_join(messages, "\n", &to_string(&1.content))

        cond do
          String.contains?(prompt, "`summary`") and String.contains?(prompt, "`context`") ->
            %{
              reasoning: "evidence",
              summary: if(String.contains?(prompt, "Improved."), do: "Gamma3", else: "Alpha2")
            }

          String.contains?(prompt, "`summary`") ->
            %{
              reasoning: "evidence",
              summary: if(String.contains?(prompt, "Improved."), do: "Gamma1", else: "Alpha1")
            }

          String.contains?(prompt, "`summary_2`") ->
            query =
              cond do
                String.contains?(prompt, "Improved.") and String.contains?(prompt, "Gamma3") ->
                  "Gamma3 Gamma4"

                String.contains?(prompt, "Improved.") ->
                  "Gamma4"

                String.contains?(prompt, "Gamma3") ->
                  "Gamma3"

                true ->
                  "Beta3"
              end

            %{reasoning: "bridge", query: query}

          true ->
            query =
              cond do
                String.contains?(prompt, "Improved.") and String.contains?(prompt, "Gamma1") ->
                  "Gamma1 Gamma2"

                String.contains?(prompt, "Improved.") ->
                  "Gamma2"

                String.contains?(prompt, "Gamma1") ->
                  "Gamma1"

                true ->
                  "Beta2"
              end

            %{reasoning: "bridge", query: query}
        end
      end
    )
  end

  defp provider_disabled_optimizer(metric, seed) do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    reflection_lm =
      Imp.LM.Static.new(
        handler: fn _messages, _opts ->
          call = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
          if call <= 4, do: "```Improved.```", else: "```Worse.```"
        end
      )

    envelope = GEPA.v014_budget_envelope(4, 1, 30)

    optimizer =
      GEPA.new(metric,
        execution_profile: :gepa_v0_1_4,
        reflection_record_mode: :gepa_v0_1_4,
        reflection_lm: reflection_lm,
        component_feedback: Imp.BenchmarkTruth.HoverFeedback.callbacks(),
        module_selector: :round_robin,
        use_merge: false,
        minibatch_size: 1,
        generations: 5,
        max_metric_calls: 30,
        max_reflection_calls: envelope.max_reflection_calls,
        seed: seed,
        max_concurrency: 1
      )

    {optimizer, counter}
  end

  defp provider_disabled_metric do
    fn _example, prediction ->
      prediction
      |> Imp.Prediction.get(:retrieved_docs, [])
      |> Enum.map(fn passage -> passage |> String.split(" | ", parts: 2) |> hd() end)
      |> MapSet.new()
      |> MapSet.intersection(MapSet.new(Enum.map(1..4, &"Gamma#{&1}")))
      |> MapSet.size()
      |> Kernel./(5)
    end
  end

  defp static_retriever do
    fn query, _opts ->
      docs =
        Regex.scan(~r/Gamma[1-5]/, query)
        |> List.flatten()
        |> Enum.uniq()
        |> Enum.map(&%{title: &1, text: "evidence"})
        |> case do
          [] -> [%{title: "Alpha", text: "one"}]
          matches -> matches
        end

      {:ok, docs}
    end
  end

  defp fresh_service!(artifact_path, receipt_path) do
    code = """
    Code.require_file("examples/deployment/lib/imp_deployment/support_pipeline.ex")
    Code.require_file("examples/deployment/lib/imp_deployment/callbacks.ex")
    Code.require_file("examples/deployment/lib/imp_deployment/workflow.ex")
    Code.require_file("examples/deployment/lib/imp_deployment/program_server.ex")
    lm = Imp.LM.Static.new(handler: fn messages, _opts ->
      prompt = Enum.map_join(messages, "\\n", &to_string(&1.content))
      cond do
        String.contains?(prompt, "`summary`") and String.contains?(prompt, "`context`") -> %{reasoning: "evidence", summary: if(String.contains?(prompt, "Improved."), do: "Gamma3", else: "Alpha2")}
        String.contains?(prompt, "`summary`") -> %{reasoning: "evidence", summary: if(String.contains?(prompt, "Improved."), do: "Gamma1", else: "Alpha1")}
        String.contains?(prompt, "`summary_2`") ->
          query = cond do
            String.contains?(prompt, "Improved.") and String.contains?(prompt, "Gamma3") -> "Gamma3 Gamma4"
            String.contains?(prompt, "Improved.") -> "Gamma4"
            String.contains?(prompt, "Gamma3") -> "Gamma3"
            true -> "Beta3"
          end
          %{reasoning: "bridge", query: query}
        true ->
          query = cond do
            String.contains?(prompt, "Improved.") and String.contains?(prompt, "Gamma1") -> "Gamma1 Gamma2"
            String.contains?(prompt, "Improved.") -> "Gamma2"
            String.contains?(prompt, "Gamma1") -> "Gamma1"
            true -> "Beta2"
          end
          %{reasoning: "bridge", query: query}
      end
    end)
    retriever = fn query, _opts ->
      docs = Regex.scan(~r/Gamma[1-5]/, query) |> List.flatten() |> Enum.uniq() |> Enum.map(&%{title: &1, text: "evidence"})
      docs = if docs == [], do: [%{title: "Alpha", text: "one"}], else: docs
      {:ok, docs}
    end
    baseline = Imp.BenchmarkTruth.HoverMultiHop.from_retriever(lm, retriever)
    artifact = Imp.Optimizer.Artifact.read!(#{inspect(artifact_path)})
    program = Imp.Optimizer.Artifact.apply(artifact, baseline)
    supervisor = Module.concat([ImpHoverProbe, TaskSupervisor])
    {:ok, _} = Task.Supervisor.start_link(name: supervisor)
    {:ok, server} = ImpDeployment.ProgramServer.start_link(program: program, lm: lm, task_supervisor: supervisor, name: nil)
    results = 1..4 |> Enum.map(fn i -> Task.async(fn -> ImpDeployment.ProgramServer.call(server, %{claim: "Alpha relation fresh \#{i}"}, 5_000) end) end) |> Task.await_many(10_000)
    payload = %{calls: length(results), all_ok: Enum.all?(results, &match?({:ok, _}, &1))}
    File.write!(#{inspect(receipt_path)}, Jason.encode!(payload))
    """

    case System.cmd("mix", ["run", "--no-compile", "--no-deps-check", "-e", code],
           env: [
             {"MIX_ENV", "test"},
             {"OPENAI_API_KEY", ""},
             {"OPENROUTER_API_KEY", ""},
             {"ANTHROPIC_API_KEY", ""}
           ],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      {output, status} -> raise "fresh HoVer service failed (#{status}): #{output}"
    end
  end

  defp proposal_components(candidates) do
    candidates
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [left, right] ->
      left_params = left["parameters"]
      right_params = right["parameters"]

      left_params
      |> Map.keys()
      |> Enum.filter(&(left_params[&1] != right_params[&1]))
      |> case do
        [component] -> component
        components -> Enum.join(Enum.sort(components), "+")
      end
    end)
  end

  defp file_sha256(path) do
    path |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
  end

  defp line_count(path) do
    path |> File.stream!([], :line) |> Enum.count()
  end

  defp verify_git!(root, expected) do
    case System.cmd("git", ["-C", root, "rev-parse", "HEAD"], stderr_to_stdout: true) do
      {head, 0} ->
        if String.trim(head) == expected,
          do: :ok,
          else: raise(ArgumentError, "authority mismatch for #{root}: #{String.trim(head)}")

      {head, _} ->
        raise ArgumentError, "authority mismatch for #{root}: #{String.trim(head)}"
    end
  end

  defp verify_files!(root, files) do
    Enum.each(files, fn {relative, expected} ->
      path = Path.join(root, relative)

      actual =
        path |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

      unless actual == expected, do: raise(ArgumentError, "authority file mismatch: #{path}")
    end)
  end
end
