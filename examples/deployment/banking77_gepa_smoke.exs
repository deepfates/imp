Application.ensure_all_started(:imp)

defmodule Banking77GEPASmoke.Router do
  @behaviour Imp.Module
  defstruct [:analyze_intent, :classify_route]

  def new do
    %__MODULE__{
      analyze_intent:
        Imp.predict(
          Imp.signature(
            "utterance -> evidence",
            "Summarize the customer's banking request as concise evidence for a route classifier."
          ),
          adapter: Imp.Adapter.Chat,
          config: [cache: false, json_fallback: false]
        ),
      classify_route:
        Imp.predict(
          Imp.signature(
            "utterance, evidence -> route: enum[R17,R42,R68,R93]",
            "Choose exactly one opaque route code from the utterance and evidence."
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
  def call(router, inputs) when is_map(inputs) or is_list(inputs) do
    inputs = Map.new(inputs)
    utterance = Map.get(inputs, :utterance, Map.get(inputs, "utterance"))

    with true <- is_binary(utterance) || {:error, {:missing_input_fields, [:utterance]}},
         {:ok, analysis} <- Imp.call(router.analyze_intent, %{utterance: utterance}),
         evidence <- Imp.Prediction.fetch!(analysis, :evidence),
         {:ok, prediction} <-
           Imp.call(router.classify_route, %{utterance: utterance, evidence: evidence}) do
      {:ok, prediction}
    end
  end

  def call(_router, inputs), do: {:error, {:invalid_router_inputs, inputs}}
end

defmodule Banking77GEPASmoke.Ledger do
  def start_link(config, mode) do
    ceilings = config["execution"]["call_ceilings"]

    caps =
      case mode do
        :parent ->
          %{
            task: ceilings["experiment_task"] + ceilings["baseline_test_task"],
            optimizer: ceilings["optimizer_total"]
          }

        :fresh ->
          %{task: ceilings["fresh_service_task"], optimizer: 0}
      end

    rates = config["execution"]["reservation_usd"]

    Agent.start_link(fn ->
      %{
        caps: caps,
        counts: %{task: 0, optimizer: 0},
        responses: 0,
        transports: [],
        actual_cost: 0.0,
        reserved_cost: 0.0,
        rates: %{task: rates["task_per_call"], optimizer: rates["optimizer_per_call"]}
      }
    end)
  end

  def reserve!(pid, role) do
    Agent.get_and_update(pid, fn state ->
      count = state.counts[role] + 1
      reserved = state.reserved_cost + state.rates[role]

      if count > state.caps[role] do
        error =
          Imp.OperationalSafetyError.exception(
            kind: :budget,
            reason: :call_ceiling,
            message: "#{role} call ceiling exceeded"
          )

        {{:error, error}, state}
      else
        {:ok, %{state | counts: Map.put(state.counts, role, count), reserved_cost: reserved}}
      end
    end)
    |> case do
      :ok -> :ok
      {:error, error} -> raise error
    end
  end

  def response!(pid, cost) when is_number(cost) and cost >= 0 do
    Agent.get_and_update(pid, fn state ->
      actual = state.actual_cost + cost

      if actual > state.reserved_cost + 1.0e-6 do
        error =
          Imp.OperationalSafetyError.exception(
            kind: :cost,
            reason: :actual_exceeds_reservation,
            message: "reported provider cost exceeds reserved cost"
          )

        {{:error, error}, state}
      else
        {:ok, %{state | responses: state.responses + 1, actual_cost: actual}}
      end
    end)
    |> case do
      :ok -> :ok
      {:error, error} -> raise error
    end
  end

  def transport(pid, measurements, metadata),
    do:
      Agent.update(
        pid,
        &%{&1 | transports: &1.transports ++ [%{measurements: measurements, metadata: metadata}]}
      )

  def snapshot(pid), do: Agent.get(pid, & &1)

  def assert_complete!(pid) do
    state = snapshot(pid)
    logical = state.counts.task + state.counts.optimizer

    unless state.responses == logical and length(state.transports) == logical and
             Enum.all?(state.transports, fn entry ->
               value(entry.measurements, :count) == 1 and value(entry.metadata, :retry) == false
             end) do
      raise "logical/response/single-transport ledger mismatch: #{inspect(state)}"
    end

    state
  end

  defp value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end

defmodule Banking77GEPASmoke.GuardedLM do
  defstruct [:inner, :ledger, :role, :expected]

  def generate(lm, messages, opts) do
    Banking77GEPASmoke.Ledger.reserve!(lm.ledger, lm.role)

    case Imp.LM.generate(lm.inner, messages, opts) do
      {:ok, _} = result ->
        validate!(lm, result)
        result

      {:error, %Imp.OperationalSafetyError{}} = error ->
        error

      {:error, reason} ->
        {:error,
         Imp.OperationalSafetyError.exception(
           kind: :transport,
           reason: reason,
           message: "provider transport failed"
         )}

      other ->
        {:error,
         Imp.OperationalSafetyError.exception(
           kind: :transport,
           reason: other,
           message: "invalid provider response envelope"
         )}
    end
  rescue
    error in Imp.OperationalSafetyError -> {:error, error}
  end

  def response_format_capability(%__MODULE__{inner: inner}),
    do: Imp.LM.response_format_capability(inner)

  defp validate!(lm, result) do
    {:ok, value} = result
    {:ok, _output, metadata} = Imp.LM.Result.split(value)
    req = value(metadata, :req_llm) || raise_safety(:route, :missing_metadata)
    usage = value(req, :usage) || %{}
    provider = value(req, :provider_meta) || %{}
    model = value(req, :model)
    route = value(provider, :provider)
    gateway = value(req, :provider)
    input = value(usage, :input_tokens) || value(usage, :prompt_tokens)
    output = value(usage, :output_tokens) || value(usage, :completion_tokens)
    cost = scalar_cost(usage)
    content = value(req, :content)
    finish = value(req, :finish_reason)

    valid? =
      model in [lm.expected["logical"], lm.expected["imp"]] and
        String.downcase(to_string(route)) == String.downcase(lm.expected["endpoint_provider"]) and
        gateway == "openrouter" and is_integer(input) and input <= lm.expected["max_input_tokens"] and
        is_integer(output) and output <= lm.expected["max_tokens"] and is_binary(content) and
        (is_binary(finish) or is_atom(finish)) and is_number(cost) and cost >= 0

    unless valid?,
      do:
        raise_safety(
          :route,
          {:response_identity_or_usage_drift,
           %{
             model: model,
             route: route,
             gateway: gateway,
             input: input,
             output: output,
             finish: finish,
             cost: cost
           }}
        )

    Banking77GEPASmoke.Ledger.response!(lm.ledger, cost)
  end

  defp scalar_cost(usage) do
    Enum.find_value(["cost", :cost, "total_cost", :total_cost], fn key ->
      case Map.get(usage, key) do
        number when is_number(number) -> number
        _ -> nil
      end
    end) || raise_safety(:cost, :missing_cost)
  end

  defp value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp raise_safety(kind, reason),
    do:
      raise(Imp.OperationalSafetyError,
        kind: kind,
        reason: reason,
        message: "provider response guard failed"
      )
end

defmodule Banking77GEPASmoke.Runner do
  alias Banking77GEPASmoke.{GuardedLM, Ledger, Router}
  alias Imp.Experiment.{Data, Result}
  alias Imp.Optimizer.{Artifact, GEPA}
  alias ImpDeployment.ProgramServer

  @config Path.expand("banking77_gepa_smoke.json", __DIR__)

  def run do
    if System.get_env("IMP_BANKING77_SMOKE_FRESH") == "1" do
      fresh()
    else
      parent()
    end
  rescue
    error ->
      write_json!(Path.join(output_dir!(), "smoke-stop.json"), %{
        status: "stopped",
        error: Exception.format(:error, error, __STACKTRACE__),
        calls: stopped_ledger()
      })

      reraise error, __STACKTRACE__
  end

  def validate_contract! do
    config = load_config!()
    calls = config["execution"]["call_ceilings"]
    usd = config["execution"]["reservation_usd"]

    true =
      calls["task_total"] ==
        calls["experiment_task"] + calls["baseline_test_task"] + calls["fresh_service_task"]

    true = calls["transport_total"] == calls["task_total"] + calls["optimizer_total"]

    calculated =
      calls["task_total"] * usd["task_per_call"] +
        calls["optimizer_total"] * usd["optimizer_per_call"]

    true = abs(usd["new_maximum"] - calculated) < 1.0e-12

    true =
      abs(
        usd["aggregate_worst_case"] -
          (usd["prior_workshop_bound"] + usd["new_maximum"])
      ) < 1.0e-12

    true = config["execution"]["data_collection"] == "deny"
    true = config["execution"]["fallbacks"] == false
    true = config["execution"]["retry"] == false
    true = config["execution"]["max_retries"] == 0
    true = config["seed"] == 0
    :ok
  end

  defp parent do
    :ok = validate_contract!()
    config = load_config!()
    output = output_dir!()
    data = load_data!(config)
    catalog = validate_catalog!(config)
    {ledger, telemetry} = ledger!(config, :parent)
    Process.put(:banking77_smoke_ledger, ledger)

    try do
      task_lm = guarded_lm(config, "task", ledger)
      optimizer_lm = guarded_lm(config, "optimizer", ledger)
      baseline = Router.new()
      {:ok, metric_rows} = Agent.start_link(fn -> [] end)
      metric = tracked_metric(metric_rows)
      optimizer = optimizer(config, optimizer_lm, metric)

      checked =
        Imp.context([lm: task_lm], fn ->
          {:ok, result} =
            Imp.Experiment.check(baseline, optimizer, data, metric,
              artifact_id: config["id"] <> "-selected",
              config: public_config(config),
              metric_identity: "exact opaque route accuracy",
              evaluation_options: [max_concurrency: 1, max_errors: 0, timeout: 120_000]
            )

          result
        end)

      result_path = Path.join(output, "experiment-result.json")
      artifact_path = Path.join(output, "selected-artifact.json")
      :ok = Result.write!(checked, result_path)
      :ok = Artifact.write!(checked.artifact, artifact_path)

      baseline_test = Imp.context([lm: task_lm], fn -> evaluate(baseline, data.test) end)
      selected_test = selected_test(metric_rows, data.ids.test)
      parent_ledger = Ledger.assert_complete!(ledger)
      summary_path = Path.join(output, "smoke-summary.json")

      write_json!(summary_path, %{
        status: "parent_complete",
        catalog: catalog,
        selected: checked.selected,
        selection: %{
          baseline: checked.baseline_selection.score,
          optimized: checked.optimized_selection.score
        },
        test: %{baseline: baseline_test, selected: selected_test},
        outcome_passed:
          checked.selected == :optimized and selected_test.accuracy > baseline_test.accuracy and
            selected_test.macro_f1 >= baseline_test.macro_f1,
        calls: ledger_json(parent_ledger),
        result_path: Path.basename(result_path),
        artifact_path: Path.basename(artifact_path)
      })

      fresh!(output, result_path, artifact_path)
      IO.puts("Banking77 GEPA smoke completed; see #{summary_path}")
    after
      :telemetry.detach(telemetry)
    end
  end

  defp fresh do
    :ok = validate_contract!()
    config = load_config!()
    output = output_dir!()
    result_path = System.fetch_env!("IMP_BANKING77_SMOKE_RESULT")
    artifact_path = System.fetch_env!("IMP_BANKING77_SMOKE_ARTIFACT")
    stored = Result.read!(result_path)
    artifact = Artifact.read!(artifact_path)
    true = stored["payload"]["artifact"] == artifact
    catalog = validate_catalog!(config)
    {ledger, telemetry} = ledger!(config, :fresh)
    Process.put(:banking77_smoke_ledger, ledger)
    {:ok, tasks} = Task.Supervisor.start_link()

    try do
      task_lm = guarded_lm(config, "task", ledger)

      {:ok, server} =
        ProgramServer.start_link(
          name: nil,
          program: Router.new(),
          lm: task_lm,
          task_supervisor: tasks
        )

      :ok = ProgramServer.reload_parameters(server, artifact_path)

      predictions =
        [
          "My card transfer was rejected",
          "I do not recognize this cash withdrawal",
          "Why was I charged twice for my card payment?",
          "I need to change the beneficiary on a transfer"
        ]
        |> Enum.map(fn utterance ->
          Task.async(fn -> ProgramServer.call(server, %{utterance: utterance}, 120_000) end)
        end)
        |> Task.await_many(120_000)

      unless Enum.all?(predictions, &match?({:ok, _}, &1)),
        do: raise("fresh service returned an error")

      fresh_ledger = Ledger.assert_complete!(ledger)

      write_json!(Path.join(output, "fresh-service.json"), %{
        status: "complete",
        catalog: catalog,
        selected: stored["payload"]["selected"],
        artifact_sha256: sha256_file(artifact_path),
        ordered_predictions: Imp.Optimizer.Report.json_safe(predictions),
        calls: ledger_json(fresh_ledger)
      })
    after
      :telemetry.detach(telemetry)
      Supervisor.stop(tasks)
    end
  end

  defp fresh!(output, result_path, artifact_path) do
    env = [
      {"IMP_BANKING77_SMOKE_FRESH", "1"},
      {"IMP_BANKING77_SMOKE_OUTPUT", output},
      {"IMP_BANKING77_SMOKE_RESULT", result_path},
      {"IMP_BANKING77_SMOKE_ARTIFACT", artifact_path},
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

  defp load_config!, do: @config |> File.read!() |> Jason.decode!()

  defp load_data!(config) do
    path = Path.expand(config["dataset"]["path"], __DIR__)
    unless sha256_file(path) == config["dataset"]["sha256"], do: raise("dataset digest drift")
    source = path |> File.read!() |> Jason.decode!()
    counts = config["dataset"]["splits"]
    true = length(source["train"]) == counts["train"]
    true = length(source["validation"]) == counts["selection"]
    true = length(source["held_out"]) == counts["test"]

    Data.new(
      train: examples(source["train"]),
      selection: examples(source["validation"]),
      test: examples(source["held_out"]),
      id: :source_id
    )
  end

  defp examples(rows) do
    Enum.map(rows, fn row ->
      Imp.Example.new(%{source_id: row["id"], utterance: row["utterance"], route: row["route"]})
      |> Imp.Example.with_inputs([:utterance])
    end)
  end

  defp tracked_metric(agent) do
    fn example, prediction ->
      expected = Imp.get(example, :route)
      predicted = Imp.get(prediction, :route)

      Agent.update(agent, fn rows ->
        [
          %{
            source_id: Imp.get(example, :source_id),
            expected: expected,
            predicted: predicted,
            error: false
          }
          | rows
        ]
      end)

      expected == predicted
    end
  end

  defp selected_test(agent, ids) do
    wanted = MapSet.new(ids)

    rows =
      agent
      |> Agent.get(&Enum.reverse/1)
      |> Enum.filter(&MapSet.member?(wanted, &1.source_id))

    unless length(rows) == length(ids), do: raise("selected test metric cardinality drift")
    aggregate(rows)
  end

  defp evaluate(program, rows) do
    rows =
      Enum.map(rows, fn example ->
        result = Imp.call(program, %{utterance: Imp.get(example, :utterance)})

        predicted =
          case result do
            {:ok, prediction} -> Imp.get(prediction, :route)
            _ -> nil
          end

        %{
          expected: Imp.get(example, :route),
          predicted: predicted,
          error: not match?({:ok, _}, result)
        }
      end)

    aggregate(rows)
  end

  defp aggregate(rows) when is_list(rows) do
    routes = ~w(R17 R42 R68 R93)
    accuracy = Enum.count(rows, &(&1.expected == &1.predicted)) / length(rows)
    macro = Enum.sum(Enum.map(routes, &f1(rows, &1))) / length(routes)
    %{accuracy: accuracy, macro_f1: macro, errors: Enum.count(rows, & &1.error)}
  end

  defp f1(rows, route) do
    tp = Enum.count(rows, &(&1.expected == route and &1.predicted == route))
    fp = Enum.count(rows, &(&1.expected != route and &1.predicted == route))
    fn_ = Enum.count(rows, &(&1.expected == route and &1.predicted != route))
    if 2 * tp + fp + fn_ == 0, do: 0.0, else: 2 * tp / (2 * tp + fp + fn_)
  end

  defp optimizer(config, optimizer_lm, metric) do
    opts = config["optimizer"]

    GEPA.new(metric,
      reflection_lm: optimizer_lm,
      generations: opts["generations"],
      module_selector: :all,
      minibatch_size: opts["minibatch_size"],
      seed: config["seed"],
      use_merge: false,
      max_concurrency: 1,
      timeout: 120_000,
      proposal_timeout: 120_000,
      max_metric_calls: opts["max_metric_calls"],
      max_full_evaluations: opts["max_full_evaluations"],
      max_reflection_calls: opts["max_reflection_calls"],
      raise_on_exception: false
    )
  end

  defp guarded_lm(config, role, ledger) do
    model = config["models"][role]
    request = config["execution"]["request"][role]

    provider = %{
      only: [model["provider_tag"]],
      order: [model["provider_tag"]],
      allow_fallbacks: false,
      require_parameters: true,
      data_collection: "deny",
      max_price: %{
        prompt: String.to_float(model["prompt_per_token"]) * 1_000_000,
        completion: String.to_float(model["completion_per_token"]) * 1_000_000,
        request: 0
      }
    }

    opts = [
      api_key: System.fetch_env!("OPENROUTER_API_KEY"),
      cache: false,
      max_tokens: request["max_tokens"],
      max_retries: 0,
      timeout: 120_000,
      provider_options: [openrouter_provider: provider, openrouter_usage: %{include: true}],
      req_http_options: [retry: false, max_retries: 0]
    ]

    opts =
      if request["temperature"],
        do: Keyword.put(opts, :temperature, request["temperature"]),
        else: Keyword.put(opts, :seed, config["seed"])

    %GuardedLM{
      inner: Imp.req_llm(model["imp"], opts),
      ledger: ledger,
      role: String.to_existing_atom(role),
      expected: Map.merge(model, request)
    }
  end

  defp ledger!(config, mode) do
    {:ok, ledger} = Ledger.start_link(config, mode)
    id = {__MODULE__, self(), mode}

    :ok =
      :telemetry.attach(
        id,
        [:imp, :lm, :transport, :attempt],
        fn _, measurements, metadata, pid -> Ledger.transport(pid, measurements, metadata) end,
        ledger
      )

    {ledger, id}
  end

  defp validate_catalog!(config) do
    Map.new(~w(task optimizer), fn role ->
      model = config["models"][role]
      url = "https://openrouter.ai/api/v1/models/#{model["logical"]}/endpoints"
      body = Req.get!(url, retry: false, max_retries: 0).body
      endpoints = get_in(body, ["data", "endpoints"]) || []

      params =
        if role == "task",
          do: ~w(max_tokens seed response_format),
          else: ~w(max_tokens temperature)

      endpoint =
        Enum.find(endpoints, fn item ->
          item["provider_name"] == model["endpoint_provider"] and
            item["tag"] == model["provider_tag"] and
            price(item, "prompt") == String.to_float(model["prompt_per_token"]) and
            price(item, "completion") == String.to_float(model["completion_per_token"]) and
            Enum.all?(params, &(&1 in (item["supported_parameters"] || [])))
        end) || raise("no exact first-party #{role} route satisfies price and parameter contract")

      {role,
       %{
         url: url,
         route: endpoint["provider_name"],
         tag: endpoint["tag"],
         pricing: endpoint["pricing"],
         supported_parameters: endpoint["supported_parameters"]
       }}
    end)
  end

  defp price(endpoint, kind), do: endpoint |> get_in(["pricing", kind]) |> String.to_float()

  defp public_config(config),
    do: Map.take(config, ~w(id schema_version seed dataset optimizer execution outcome))

  defp output_dir!,
    do:
      System.get_env(
        "IMP_BANKING77_SMOKE_OUTPUT",
        Path.expand("../../tmp/banking77-gepa-product-smoke-v1", __DIR__)
      )
      |> Path.expand(__DIR__)
      |> tap(&File.mkdir_p!/1)

  defp ledger_json(state),
    do: %{
      logical: state.counts,
      responses: state.responses,
      transports: length(state.transports),
      reserved_cost: state.reserved_cost,
      actual_cost: state.actual_cost
    }

  defp stopped_ledger do
    case Process.get(:banking77_smoke_ledger) do
      pid when is_pid(pid) ->
        if Process.alive?(pid),
          do: ledger_json(Ledger.snapshot(pid)),
          else: empty_ledger()

      _ ->
        empty_ledger()
    end
  end

  defp empty_ledger,
    do: %{
      logical: %{task: 0, optimizer: 0},
      responses: 0,
      transports: 0,
      reserved_cost: 0.0,
      actual_cost: 0.0
    }

  defp sha256_file(path),
    do: path |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

  defp write_json!(path, value) do
    tmp = path <> ".tmp-#{System.unique_integer([:positive])}"

    try do
      {:ok, io} = File.open(tmp, [:write, :exclusive])
      :ok = File.chmod(tmp, 0o600)
      IO.binwrite(io, Jason.encode!(value, pretty: true) <> "\n")
      :ok = :file.sync(io)
      File.close(io)
      File.rename!(tmp, path)
    after
      File.rm(tmp)
    end
  end
end

if System.get_env("IMP_BANKING77_SMOKE_VALIDATE_ONLY") == "1" do
  :ok = Banking77GEPASmoke.Runner.validate_contract!()
  IO.puts("Banking77 GEPA smoke contract is internally consistent")
else
  Banking77GEPASmoke.Runner.run()
end
