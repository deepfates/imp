Application.ensure_all_started(:imp)

defmodule Banking77GEPA.Router do
  @behaviour Imp.Module
  defstruct [:analyze_intent, :classify_route]

  def new do
    %__MODULE__{
      analyze_intent:
        Imp.predict(
          Imp.signature("utterance -> evidence", "Summarize the banking request for routing."),
          adapter: Imp.Adapter.Chat,
          config: [cache: false, json_fallback: false]
        ),
      classify_route:
        Imp.predict(
          Imp.signature(
            "utterance, evidence -> route: enum[R17,R42,R68,R93]",
            "Choose exactly one opaque route code."
          ),
          adapter: Imp.Adapter.Chat,
          config: [cache: false, json_fallback: false]
        )
    }
  end

  def optimizer_predictors(router),
    do: [analyze_intent: router.analyze_intent, classify_route: router.classify_route]

  def update_optimizer_predictor(router, :analyze_intent, update),
    do: %{router | analyze_intent: update.(router.analyze_intent)}

  def update_optimizer_predictor(router, :classify_route, update),
    do: %{router | classify_route: update.(router.classify_route)}

  @impl true
  def call(router, inputs) do
    utterance = Map.get(Map.new(inputs), :utterance, Map.get(Map.new(inputs), "utterance"))

    with true <- is_binary(utterance) || {:error, {:missing_input_fields, [:utterance]}},
         {:ok, analysis} <- Imp.call(router.analyze_intent, %{utterance: utterance}),
         evidence <- Imp.get(analysis, :evidence),
         {:ok, prediction} <-
           Imp.call(router.classify_route, %{utterance: utterance, evidence: evidence}) do
      {:ok, prediction}
    end
  end
end

defmodule Banking77GEPA do
  alias Banking77GEPA.Router
  alias Imp.Experiment.{Data, Result}
  alias Imp.Optimizer.{Artifact, GEPA}
  alias ImpDeployment.ProgramServer

  @dataset "../../benchmarks/data/grpo-usefulness-banking77-v1.json"
  @dataset_sha "2dc52c1b06002f44e03986d675cd05f078d4690fe3ee0a41be27c00c7135afb1"
  @task_model "openrouter:openai/gpt-5.4-mini"
  @optimizer_model "openrouter:anthropic/claude-sonnet-4.6"
  @output "../../benchmarks/results/banking77-gepa-product-example"

  def run do
    if System.get_env("IMP_BANKING77_GEPA_FRESH") == "1", do: fresh(), else: optimize()
  end

  # Two task calls per program evaluation: 64 GEPA metric calls, two 8-row
  # selection passes, selected and baseline 40-row tests, then four fresh probes.
  def transport_caps do
    %{task: 2 * (64 + 8 + 8 + 40 + 40 + 4), optimizer: 2}
  end

  defp optimize do
    data = data!()
    IO.inspect(transport_caps(), label: "Conservative transport caps")
    catalog!()
    task_lm = lm(:task)
    optimizer_lm = lm(:optimizer)

    traced =
      Imp.Observability.trace(fn ->
        Imp.context([lm: task_lm], fn ->
          Imp.Experiment.check(
            Router.new(),
            GEPA.new(&metric/2,
              reflection_lm: optimizer_lm,
              generations: 1,
              module_selector: :all,
              minibatch_size: 4,
              seed: 1,
              use_merge: false,
              max_concurrency: 1,
              max_metric_calls: 64,
              max_full_evaluations: 3,
              max_reflection_calls: 2
            ),
            data,
            &metric/2,
            artifact_id: "banking77-gepa-selected",
            evaluation_options: [max_concurrency: 1, max_errors: 0, timeout: 120_000]
          )
        end)
      end)

    case traced.result do
      {:ok, result} -> finish(result, data, task_lm, traced.events)
      {:error, failure} -> raise "Experiment.check stopped: #{inspect(failure)}"
    end
  end

  defp finish(result, data, task_lm, events) do
    output = output!()
    result_path = Path.join(output, "experiment-result.json")
    artifact_path = Path.join(output, "selected-artifact.json")
    :ok = Result.write!(result, result_path)
    :ok = Artifact.write!(result.artifact, artifact_path)

    baseline =
      Imp.context([lm: task_lm], fn ->
        Imp.evaluate(Router.new(), data.test, &metric/2,
          max_concurrency: 1,
          max_errors: 0,
          timeout: 120_000
        )
      end)

    ensure_routes!(result.test.rows ++ baseline.rows, "OpenAI")
    attempts = Enum.count(events, &match?({[:imp, :lm, :transport, :attempt], _, _}, &1))

    IO.inspect(
      %{
        selected: result.selected,
        selection: [result.baseline_selection.score, result.optimized_selection.score],
        untouched: [baseline.score, result.test.score],
        experiment_transport_attempts: attempts
      },
      label: "Banking77 GEPA example"
    )

    fresh!(result_path, artifact_path)
  end

  defp fresh do
    result_path = System.fetch_env!("IMP_BANKING77_GEPA_RESULT")
    artifact_path = System.fetch_env!("IMP_BANKING77_GEPA_ARTIFACT")
    stored = Result.read!(result_path)
    artifact = Artifact.read!(artifact_path)
    true = stored["payload"]["artifact"] == artifact
    {:ok, tasks} = Task.Supervisor.start_link()

    try do
      {:ok, server} =
        ProgramServer.start_link(
          name: nil,
          program: Router.new(),
          lm: lm(:task),
          task_supervisor: tasks
        )

      :ok = ProgramServer.reload_parameters(server, artifact_path)

      results =
        [
          "My card transfer was rejected",
          "I do not recognize this cash withdrawal",
          "Why was I charged twice?",
          "I need to change a beneficiary"
        ]
        |> Task.async_stream(&ProgramServer.call(server, %{utterance: &1}, 120_000),
          ordered: true,
          max_concurrency: 4,
          timeout: 120_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      true = Enum.all?(results, &match?({:ok, _}, &1))
      IO.puts("fresh OS service passed with four concurrent two-stage calls")
    after
      Supervisor.stop(tasks)
    end
  end

  defp fresh!(result_path, artifact_path) do
    env = [
      {"IMP_BANKING77_GEPA_FRESH", "1"},
      {"IMP_BANKING77_GEPA_RESULT", result_path},
      {"IMP_BANKING77_GEPA_ARTIFACT", artifact_path},
      {"OPENROUTER_API_KEY", System.fetch_env!("OPENROUTER_API_KEY")}
    ]

    {output, status} =
      System.cmd("mix", ["run", "--no-start", __ENV__.file],
        cd: __DIR__,
        env: env,
        stderr_to_stdout: true
      )

    if status != 0, do: raise("fresh OS service failed: #{output}")
  end

  defp data! do
    path = Path.expand(@dataset, __DIR__)
    true = sha256(path) == @dataset_sha
    rows = path |> File.read!() |> Jason.decode!()

    Data.new(
      train: examples(rows["train"]),
      selection: examples(rows["validation"]),
      test: examples(rows["held_out"]),
      id: :source_id
    )
  end

  defp examples(rows) do
    Enum.map(rows, fn row ->
      Imp.example(source_id: row["id"], utterance: row["utterance"], route: row["route"])
      |> Imp.with_inputs(:utterance)
    end)
  end

  defp metric(example, prediction), do: Imp.get(example, :route) == Imp.get(prediction, :route)

  defp lm(role) do
    {model, provider, max_tokens, max_price, extra} =
      case role do
        :task ->
          {@task_model, "openai", 256, %{prompt: 0.75, completion: 4.5, request: 0}, [seed: 1]}

        :optimizer ->
          {@optimizer_model, "anthropic", 1024, %{prompt: 3, completion: 15, request: 0},
           [temperature: 1]}
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
            max_price: max_price
          },
          openrouter_usage: %{include: true}
        ],
        req_http_options: [retry: false, max_retries: 0]
      ] ++ extra
    )
  end

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

  defp ensure_routes!(rows, provider) do
    unless Enum.all?(rows, fn row ->
             case row.prediction do
               %Imp.Prediction{metadata: %{req_llm: %{provider_meta: meta}}} ->
                 to_string(meta[:provider] || meta["provider"]) == provider

               _ ->
                 false
             end
           end),
           do: raise("task response route identity drift")
  end

  defp output!, do: @output |> Path.expand(__DIR__) |> tap(&File.mkdir_p!/1)

  defp sha256(path),
    do: path |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
end

Banking77GEPA.run()
