Application.ensure_all_started(:imp)

defmodule Banking77MIPRO do
  alias Imp.Experiment.{Data, Result}
  alias Imp.Optimizer.{Artifact, MIPROv2}
  alias ImpDeployment.{Banking77Pipeline, ProgramServer}

  @condition "imp-88sn-banking77-mipro-confirmatory-v1"
  @dataset_condition @condition
  @dataset "data/banking77-mipro-confirmatory-v1.json"
  @dataset_sha "6550e65edf66353af54d74daa48778a98d747052cb85ad05a64a9ad5e3680e86"
  @task_model "openrouter:openai/gpt-5.4-mini"
  @optimizer_model "openrouter:anthropic/claude-sonnet-4.6"
  @seeds [2_026_073_101, 2_026_073_102, 2_026_073_103]
  @routes ~w(R15 R16 R27 R32 R38 R45 R53 R70)

  @analysis_instruction """
  Extract the banking intent evidence needed for routing. Identify the payment
  or transfer state, whether the customer recognizes it, fees, and the requested
  action. Do not choose a route; provide concise evidence for the router.
  """

  @routing_instruction """
  Choose exactly one route from the evidence and original utterance:
  R15 card payment fee charged; R16 card payment not recognized;
  R27 declined transfer; R32 exchange rate; R38 get a physical card;
  R45 pending card payment; R53 reverted card payment;
  R70 verify source of funds.
  """

  def run do
    case System.get_env("IMP_BANKING77_MIPRO_MODE", "disabled") do
      "disabled" -> provider_disabled!()
      "live" -> optimize!()
      "fresh" -> fresh!()
      mode -> raise "unknown IMP_BANKING77_MIPRO_MODE: #{inspect(mode)}"
    end
  end

  def program do
    Banking77Pipeline.new(
      routes: @routes,
      analysis_instruction: @analysis_instruction,
      routing_instruction: @routing_instruction
    )
  end

  def metric(example, prediction), do: Imp.get(example, :route) == Imp.get(prediction, :route)

  def seeds, do: @seeds

  def transport_caps do
    %{
      per_seed: %{
        baseline_selection: 144,
        bootstrap: 48,
        internal_baseline: 48,
        categorical_trials: 720,
        optimized_selection: 144,
        baseline_and_selected_test: 576,
        fresh_service: 8,
        task: 1_688,
        optimizer: 10
      },
      stage: %{task: 5_064, optimizer: 30},
      reservation_usd: 38.393856
    }
  end

  def optimizer(task_lm, prompt_lm, seed) when seed in @seeds do
    MIPROv2.new(&metric/2,
      auto: nil,
      num_candidates: 3,
      num_trials: 15,
      max_bootstrapped_demos: 2,
      max_labeled_demos: 2,
      prompt_lm: prompt_lm,
      task_lm: task_lm,
      startup_trials: 10,
      minibatch: false,
      proposer_fidelity: :dspy_3_2_1,
      search_fidelity: :dspy_3_2_1_optuna_4_9_0,
      program_aware_proposer: false,
      data_aware_proposer: true,
      tip_aware_proposer: true,
      fewshot_aware_proposer: true,
      view_data_batch_size: 10,
      max_concurrency: 1,
      max_errors: 10,
      timeout: 120_000,
      seed: seed
    )
  end

  def data! do
    path = Path.expand(@dataset, __DIR__)
    true = sha256(File.read!(path)) == @dataset_sha
    payload = path |> File.read!() |> Jason.decode!()

    true = payload["condition_id"] == @dataset_condition

    true =
      payload["digests"] == %{
        "train" => "sha256:ae934e51f39eadf632b93a7715294acd601d23c693f5f5f119adb5584448cfa9",
        "selection" => "sha256:aa5cdb1b33e1ad06c1905505f4b23ff01a741c4f0000d855a4545488ff70f1ea",
        "test" => "sha256:09f9850284f4ce70dd18c3e0dd77c6c18eead80b27ccb375c96a178b3b7f9f99"
      }

    Data.new(
      train: examples(payload["train"]),
      selection: examples(payload["selection"]),
      test: examples(payload["test"]),
      id: :source_id
    )
  end

  defp provider_disabled! do
    data = data!()
    predictors = Enum.map(Imp.ProgramParameters.predictors(program()), &to_string(&1.name))
    true = predictors == ["analyze_intent", "classify_route"]

    receipt = %{
      status: "provider_disabled",
      condition: @condition,
      provider_authority_used: false,
      seeds: @seeds,
      rows: %{
        train: length(data.train),
        selection: length(data.selection),
        test: length(data.test)
      },
      predictors: predictors,
      optimizer: %{
        instruction_candidates: 3,
        categorical_trials: 15,
        startup_trials: 10,
        startup_random_trials: 9,
        modeled_trials: 6,
        max_bootstrapped_demos: 2,
        max_labeled_demos: 2,
        max_errors: 10,
        outer_repetitions: 3,
        outer_aggregation: "mean",
        internal_objectives: "single_pass"
      },
      call_caps: transport_caps(),
      uses_ifbench_bridge: false
    }

    IO.puts(Jason.encode!(receipt))
  end

  defp optimize! do
    seed = live_seed!()
    output = output!(seed)
    catalog!()
    task_lm = lm(:task, seed)
    prompt_lm = lm(:optimizer, seed)

    result =
      Imp.context([lm: task_lm], fn ->
        Imp.Experiment.check(
          program(),
          optimizer(task_lm, prompt_lm, seed),
          data!(),
          &metric/2,
          artifact_id: "#{@condition}-#{seed}-selected",
          metric_identity: %{"kind" => "exact_route_accuracy", "version" => 1},
          compare_baseline_on_test: true,
          config: %{
            "condition" => @condition,
            "seed" => seed,
            "dataset_sha256" => @dataset_sha,
            "task_model" => @task_model,
            "optimizer_model" => @optimizer_model,
            "outer_repetitions" => 3,
            "outer_aggregation" => "mean",
            "internal_objectives" => "single_pass",
            "transport_caps" => transport_caps()
          },
          evaluation_options: [
            max_concurrency: 1,
            max_errors: 10,
            timeout: 120_000,
            repetitions: 3,
            aggregation: :mean
          ]
        )
      end)

    case result do
      {:ok, completed} ->
        result_path = Path.join(output, "experiment-result.json")
        artifact_path = Path.join(output, "selected-artifact.json")
        :ok = Result.write!(completed, result_path, include_rows: true)
        :ok = Artifact.write!(completed.artifact, artifact_path)
        stored = Result.read!(result_path)
        true = stored["payload"]["artifact"] == Artifact.read!(artifact_path)

        fresh_process!(seed, result_path, artifact_path)

        IO.inspect(
          %{
            seed: seed,
            selected: completed.selected,
            selection: [completed.baseline_selection.score, completed.optimized_selection.score],
            held_out: [completed.baseline_test.score, completed.test.score],
            result: result_path,
            artifact: artifact_path
          },
          label: "Banking77 MIPRO confirmatory replication"
        )

      {:error, failure} ->
        raise "Experiment.check stopped: #{inspect(failure)}"
    end
  end

  defp fresh! do
    result_path = System.fetch_env!("IMP_BANKING77_MIPRO_RESULT")
    artifact_path = System.fetch_env!("IMP_BANKING77_MIPRO_ARTIFACT")
    stored = Result.read!(result_path)
    artifact = Artifact.read!(artifact_path)
    true = stored["payload"]["artifact"] == artifact
    {:ok, tasks} = Task.Supervisor.start_link()

    try do
      {:ok, server} =
        ProgramServer.start_link(
          name: nil,
          program: program(),
          lm: lm(:task, live_seed!()),
          task_supervisor: tasks
        )

      :ok = ProgramServer.reload_parameters(server, artifact_path)

      results =
        [
          "Why did this card payment include an extra fee?",
          "I do not recognize a payment on my card.",
          "My card payment is still pending.",
          "How do I verify where my funds came from?"
        ]
        |> Task.async_stream(&ProgramServer.call(server, %{utterance: &1}, 120_000),
          ordered: true,
          max_concurrency: 4,
          timeout: 120_000
        )
        |> Enum.map(fn {:ok, value} -> value end)

      true = Enum.all?(results, &match?({:ok, _}, &1))
      IO.puts("fresh OS service passed with four concurrent two-stage calls")
    after
      Supervisor.stop(tasks)
    end
  end

  defp fresh_process!(seed, result_path, artifact_path) do
    env = [
      {"IMP_BANKING77_MIPRO_MODE", "fresh"},
      {"IMP_BANKING77_MIPRO_SEED", Integer.to_string(seed)},
      {"IMP_BANKING77_MIPRO_RESULT", result_path},
      {"IMP_BANKING77_MIPRO_ARTIFACT", artifact_path},
      {"OPENROUTER_API_KEY", System.fetch_env!("OPENROUTER_API_KEY")}
    ]

    {text, status} =
      System.cmd("mix", ["run", "--no-start", __ENV__.file],
        cd: __DIR__,
        env: env,
        stderr_to_stdout: true
      )

    if status != 0, do: raise("fresh OS service failed: #{text}")
  end

  defp examples(rows) do
    Enum.map(rows, fn row ->
      Imp.example(source_id: row["source_id"], utterance: row["utterance"], route: row["route"])
      |> Imp.with_inputs(:utterance)
    end)
  end

  defp live_seed! do
    seed = System.fetch_env!("IMP_BANKING77_MIPRO_SEED") |> String.to_integer()
    if seed in @seeds, do: seed, else: raise("seed is not frozen: #{seed}")
  end

  defp output!(seed) do
    root = System.fetch_env!("IMP_BANKING77_MIPRO_OUTPUT") |> Path.expand()
    output = Path.join(root, Integer.to_string(seed))

    if File.exists?(output) and File.ls!(output) != [],
      do: raise("seed output must be new and empty: #{output}")

    File.mkdir_p!(output)
    output
  end

  defp lm(role, seed) do
    {model, provider, max_tokens, extra} =
      case role do
        :task -> {@task_model, "openai", 256, [seed: seed]}
        :optimizer -> {@optimizer_model, "anthropic", 1024, [temperature: 1]}
      end

    Imp.req_llm(
      model,
      [
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
            max_price: price(role)
          },
          openrouter_usage: %{include: true}
        ],
        req_http_options: [retry: false, max_retries: 0]
      ] ++ extra
    )
  end

  defp price(:task), do: %{prompt: 0.75, completion: 4.5, request: 0}
  defp price(:optimizer), do: %{prompt: 3, completion: 15, request: 0}

  defp catalog! do
    for {model, provider, prompt, completion} <- [
          {"openai/gpt-5.4-mini", "OpenAI", 0.00000075, 0.0000045},
          {"anthropic/claude-sonnet-4.6", "Anthropic", 0.000003, 0.000015}
        ] do
      body = Req.get!("https://openrouter.ai/api/v1/models/#{model}/endpoints", retry: false).body

      unless Enum.any?(body["data"]["endpoints"], fn endpoint ->
               endpoint["provider_name"] == provider and
                 String.to_float(endpoint["pricing"]["prompt"]) == prompt and
                 String.to_float(endpoint["pricing"]["completion"]) == completion
             end),
             do: raise("exact route or price unavailable for #{model}")
    end
  end

  defp sha256(bytes),
    do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end

unless System.get_env("IMP_BANKING77_MIPRO_DEFINE_ONLY") == "1" do
  Banking77MIPRO.run()
end
