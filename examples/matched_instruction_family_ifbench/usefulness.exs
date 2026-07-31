Application.ensure_all_started(:imp)

unless Code.ensure_loaded?(ImpDeployment.ProgramServer) do
  Code.require_file("../deployment/lib/imp_deployment/support_pipeline.ex", __DIR__)
  Code.require_file("../deployment/lib/imp_deployment/workflow.ex", __DIR__)
  Code.require_file("../deployment/lib/imp_deployment/callbacks.ex", __DIR__)
  Code.require_file("../deployment/lib/imp_deployment/program_server.ex", __DIR__)
end

defmodule MatchedInstructionFamilyIFBench.Usefulness do
  alias Imp.BenchmarkTruth.{GepaMetrics, IFBenchFeedback, IFBenchTwoStage}
  alias Imp.Experiment.{Data, Result}
  alias Imp.Optimizer.{Artifact, GEPA}

  @seeds [2_026_072_705, 2_026_072_706, 2_026_072_707]
  @task_model "openrouter:openai/gpt-5.4-mini"
  @optimizer_model "openrouter:anthropic/claude-sonnet-4.6"
  @split_sha %{
    train: "8d80f329bbab37a44fe2e2ea0ea8c7e69eeb976d8a8e51af5bcd4547b4221197",
    selection: "f0c2d8e808e4783e496ecf189ead61fde4a1e80373ff85f3ea801883f68c7468",
    test: "49779533faa842decda93a1221ce7bae615af82403e33e380ab69d2abc84610d"
  }

  def run do
    data = data!()

    case System.get_env("IMP_88SN_MODE", "disabled") do
      "disabled" -> disabled!(data)
      "preflight" -> catalog!()
      "live" -> Enum.each(@seeds, &live_seed(&1, data))
      "fresh" -> fresh!()
      mode -> raise "unknown IMP_88SN_MODE #{inspect(mode)}"
    end
  end

  defp disabled!(data) do
    envelope = GEPA.v014_budget_envelope(length(data.selection), 8, 80)
    true = envelope == %{max_metric_calls: 120, max_reflection_calls: 12, max_iterations: 6}
    _optimizer = optimizer(hd(@seeds), disabled_lm(), metric())
    _program = IFBenchTwoStage.new(disabled_lm())

    IO.puts(
      Jason.encode!(%{
        status: "provider_disabled",
        seeds: @seeds,
        split_counts: %{train: 16, selection: 32, test: 64},
        split_sha256: @split_sha,
        per_seed_imp_ceiling: %{task: 632, optimizer: 12},
        provider_authority_used: false
      })
    )
  end

  defp live_seed(seed, data) do
    seed_dir = Path.join(output_root!(), Integer.to_string(seed))
    refuse_existing!(seed_dir)
    File.mkdir_p!(seed_dir)
    metric = metric()
    task_lm = remote_lm(:task, seed)
    program = IFBenchTwoStage.new(task_lm)

    traced =
      Imp.Observability.trace(fn ->
        Imp.Experiment.check(
          program,
          optimizer(seed, remote_lm(:optimizer, nil), metric),
          data,
          metric,
          artifact_id: "ifbench-gepa-#{seed}",
          compare_baseline_on_test: true,
          evaluation_options: [max_concurrency: 1, max_errors: 0, timeout: 120_000],
          config: %{
            condition: "imp-88sn-ifbench",
            seed: seed,
            task_model: @task_model,
            optimizer_model: @optimizer_model,
            execution_profile: "gepa_v0_1_4",
            split_sha256: @split_sha
          },
          metric_identity: "IFBench.ifbench_metric.metric"
        )
      end)

    result = require_completed!(traced.result)
    result_path = Path.join(seed_dir, "result.json")
    artifact_path = Path.join(seed_dir, "selected-artifact.json")
    :ok = Result.write!(result, result_path, include_rows: true)
    :ok = Artifact.write!(result.artifact, artifact_path)
    _ = Result.read!(result_path)
    _ = Artifact.read!(artifact_path)

    IO.puts(
      Jason.encode!(%{
        seed: seed,
        selected: result.selected,
        result_path: result_path,
        artifact_path: artifact_path,
        baseline_selection: result.baseline_selection.score,
        optimized_selection: result.optimized_selection.score,
        baseline_test: result.baseline_test.score,
        selected_test: result.test.score,
        trace: Imp.Optimizer.Report.json_safe(traced.events)
      })
    )

    fresh_process!(seed, artifact_path, result_path)
  end

  defp fresh! do
    artifact_path = System.fetch_env!("IMP_88SN_ARTIFACT")
    result_path = System.fetch_env!("IMP_88SN_RESULT")
    seed = System.fetch_env!("IMP_88SN_SEED") |> String.to_integer()
    artifact = Artifact.read!(artifact_path)
    result = Result.read!(result_path)
    true = result["payload"]["artifact"] == artifact
    task_lm = remote_lm(:task, seed)
    {:ok, supervisor} = Task.Supervisor.start_link()

    {:ok, server} =
      ImpDeployment.ProgramServer.start_link(
        name: nil,
        program: IFBenchTwoStage.new(task_lm),
        lm: task_lm,
        task_supervisor: supervisor
      )

    :ok = ImpDeployment.ProgramServer.reload_parameters(server, artifact_path)

    probes = [
      "Answer in exactly one sentence: name one benefit of testing software.",
      "Give exactly two bullet points about careful measurement.",
      "Reply with the single word READY in uppercase.",
      "Write one sentence containing the word reproducible exactly once."
    ]

    outputs =
      Task.async_stream(probes, &ImpDeployment.ProgramServer.call(server, %{prompt: &1}, 120_000),
        ordered: true,
        max_concurrency: 4,
        timeout: 120_000
      )
      |> Enum.map(fn {:ok, {:ok, prediction}} -> Imp.Prediction.fetch!(prediction, :response) end)

    true = length(outputs) == 4
    GenServer.stop(server)
    Supervisor.stop(supervisor)

    IO.puts(
      Jason.encode!(%{
        fresh: true,
        seed: seed,
        candidate: Artifact.inspect(artifact).champion_id,
        outputs: outputs
      })
    )
  end

  defp fresh_process!(seed, artifact_path, result_path) do
    {output, status} =
      System.cmd("mix", ["run", "--no-compile", "--no-deps-check", __ENV__.file],
        cd: Path.expand("../..", __DIR__),
        env: [
          {"IMP_88SN_MODE", "fresh"},
          {"IMP_88SN_SEED", Integer.to_string(seed)},
          {"IMP_88SN_ARTIFACT", artifact_path},
          {"IMP_88SN_RESULT", result_path}
        ],
        stderr_to_stdout: true
      )

    if status != 0, do: raise("IFBench seed #{seed} fresh process failed: #{output}")
    IO.write(output)
  end

  defp optimizer(seed, reflection_lm, metric) do
    GEPA.new(metric,
      execution_profile: :gepa_v0_1_4,
      reflection_lm: reflection_lm,
      generations: 6,
      minibatch_size: 8,
      seed: seed,
      candidate_selection_strategy: :pareto,
      module_selector: :round_robin,
      acceptance_policy: :strict_improvement,
      selection_strategy: :all_improvements,
      use_merge: false,
      reflection_record_mode: :gepa_v0_1_4,
      component_feedback: IFBenchFeedback.callbacks(metric),
      max_concurrency: 1,
      timeout: 120_000,
      proposal_timeout: 120_000,
      raise_on_exception: true,
      max_metric_calls: 80,
      max_reflection_calls: 12
    )
  end

  defp metric do
    GepaMetrics.metric_with_feedback(%{"upstream_metric" => "IFBench.ifbench_metric.metric"},
      upstream_descriptions: true,
      gepa_root: Path.expand("../../tmp/gepa-artifact", __DIR__),
      python: Path.expand("../../tmp/ifbench-parity-venv/bin/python", __DIR__)
    )
  end

  defp data! do
    paths = %{
      train: Path.join(__DIR__, "data/train.jsonl"),
      selection: Path.join(__DIR__, "data/selection.jsonl"),
      test: Path.join(__DIR__, "data/held_out.jsonl")
    }

    Enum.each(paths, fn {split, path} -> true = file_sha256(path) == @split_sha[split] end)
    rows = Map.new(paths, fn {split, path} -> {split, load_rows(path, split != :test)} end)
    true = Enum.map([:train, :selection, :test], &length(rows[&1])) == [16, 32, 64]
    Data.new(train: rows.train, selection: rows.selection, test: rows.test, id: :source_id)
  end

  defp load_rows(path, feedback_allowed?) do
    path
    |> File.stream!()
    |> Enum.map(fn line ->
      row = Jason.decode!(line)

      row
      |> Map.take(["source_id", "prompt", "instruction_id_list", "kwargs"])
      |> Map.put("feedback_allowed", feedback_allowed?)
      |> Imp.Example.new()
      |> Imp.Example.with_inputs([:prompt])
    end)
  end

  defp remote_lm(role, seed) do
    {model, provider, max_tokens, temperature, price} =
      case role do
        :task ->
          {@task_model, "openai", 2048, nil, %{prompt: 0.75, completion: 4.5, request: 0}}

        :optimizer ->
          {@optimizer_model, "anthropic", 1024, 1, %{prompt: 3, completion: 15, request: 0}}
      end

    opts = [
      api_key: System.fetch_env!("OPENROUTER_API_KEY"),
      cache: false,
      max_tokens: max_tokens,
      max_retries: 0,
      timeout: 120_000,
      provider_options: [
        openrouter_provider: %{
          only: [provider],
          order: [provider],
          allow_fallbacks: false,
          require_parameters: true,
          data_collection: "deny",
          max_price: price
        },
        openrouter_usage: %{include: true}
      ],
      req_http_options: [retry: false, max_retries: 0]
    ]

    opts = if is_nil(seed), do: opts, else: Keyword.put(opts, :seed, seed)
    opts = if is_nil(temperature), do: opts, else: Keyword.put(opts, :temperature, temperature)
    Imp.req_llm(model, opts)
  end

  defp disabled_lm,
    do:
      Imp.LM.Static.new(
        handler: fn _messages, _opts -> raise "provider-disabled LM was called" end
      )

  defp catalog! do
    checks = [
      {"openai/gpt-5.4-mini", "OpenAI", 0.00000075, 0.0000045},
      {"anthropic/claude-sonnet-4.6", "Anthropic", 0.000003, 0.000015}
    ]

    Enum.each(checks, fn {model, provider, prompt, completion} ->
      body =
        Req.get!("https://openrouter.ai/api/v1/models/#{model}/endpoints",
          retry: false,
          max_retries: 0
        ).body

      true =
        Enum.any?(body["data"]["endpoints"], fn endpoint ->
          endpoint["provider_name"] == provider and
            String.to_float(endpoint["pricing"]["prompt"]) == prompt and
            String.to_float(endpoint["pricing"]["completion"]) == completion
        end)
    end)

    IO.puts("IFBench route/privacy/price preflight passed")
  end

  defp require_completed!({:ok, %Result{} = result}), do: result
  defp require_completed!({:error, failure}), do: raise("experiment failed: #{inspect(failure)}")

  defp output_root!,
    do:
      System.get_env("IMP_88SN_OUTPUT", Path.join(System.tmp_dir!(), "imp-88sn-ifbench"))
      |> Path.expand()

  defp refuse_existing!(path),
    do: if(File.exists?(path), do: raise("output already exists: #{path}"))

  defp file_sha256(path),
    do: path |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
end

MatchedInstructionFamilyIFBench.Usefulness.run()
