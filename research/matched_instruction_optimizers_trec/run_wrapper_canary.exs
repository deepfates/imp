System.put_env("IMP_MATCHED_TREC_LOAD_ONLY", "1")
Code.require_file("run_imp.exs", __DIR__)
System.delete_env("IMP_MATCHED_TREC_LOAD_ONLY")

defmodule MatchedTRECImp.WrapperCanary do
  alias Imp.Optimizer.GEPA.InstructionProposal
  alias Imp.Optimizer.Report
  alias MatchedInstructionOptimizersTREC.{Contract, ResponseEvidence}
  alias MatchedTRECImp.{ObservedLM, Observer}

  @manifest Path.expand("contract.json", __DIR__)
  @output Path.expand(
            "../../tmp/matched_instruction_optimizers_trec/wrapper-canary-014a7fc.json",
            __DIR__
          )
  @seed 2_026_072_602
  @arm "wrapper_canary_014a7fc"
  @ceiling %{
    "task_logical" => 1,
    "optimizer_logical" => 1,
    "total_logical" => 2,
    "transports" => 2
  }

  def run do
    manifest = Contract.load_optimization!(@manifest)
    {:ok, observer} = Observer.start_link(manifest)
    :ok = Observer.register_budget(observer, @seed, @arm, @ceiling)
    Observer.phase(observer, %{seed: @seed, arm: @arm, phase: "synthetic_wrapper_canary"})
    telemetry_id = {__MODULE__, self()}

    :ok =
      :telemetry.attach(
        telemetry_id,
        [:imp, :lm, :transport, :attempt],
        fn _event, measurements, metadata, target ->
          Observer.transport(target, measurements, metadata)
        end,
        observer
      )

    try do
      task = observed(remote_lm(manifest, "task", @seed), observer, :task, manifest)
      optimizer = observed(remote_lm(manifest, "optimizer", nil), observer, :optimizer, manifest)

      task_result =
        Imp.LM.generate(task, [
          %{
            role: :system,
            content:
              "Engineering wrapper canary. Reply with exactly the three-line marker envelope requested by the user."
          },
          %{
            role: :user,
            content:
              "Synthetic public input: gravity is a concept. Reply exactly:\n[[ ## route ## ]]\nK11\n[[ ## completed ## ]]"
          }
        ])

      {:ok, task_output} = Imp.LM.Result.unwrap(task_result)
      {:ok, "K11"} = Contract.parse_route(task_output)
      task_evidence = ResponseEvidence.from_result!(task_result)

      optimizer_result =
        Imp.LM.generate(optimizer, [
          %{
            role: :user,
            content:
              "Synthetic public engineering canary. Return this instruction inside one markdown code fence and nothing else: Route concepts to K11 and concrete entities to K47."
          }
        ])

      {:ok, optimizer_output} = Imp.LM.Result.unwrap(optimizer_result)

      unless is_binary(optimizer_output) and String.contains?(optimizer_output, "```") do
        raise "optimizer canary response lacked the required fenced instruction"
      end

      {:ok, optimizer_instruction} = InstructionProposal.normalize(optimizer_output)
      optimizer_evidence = ResponseEvidence.from_result!(optimizer_result)
      snapshot = Observer.snapshot(observer)

      unless length(snapshot.messages) == 2 and length(snapshot.responses) == 2 and
               length(snapshot.transports) == 2 do
        raise "wrapper canary did not produce exactly two logical calls and transports"
      end

      budget = Map.fetch!(snapshot.call_budgets, {@seed, @arm})

      unless budget.counts == @ceiling do
        raise "wrapper canary call ceiling drift: #{inspect(budget.counts)}"
      end

      result = %{
        schema_version: 1,
        name: @arm,
        status: "complete",
        scientific_treatment: false,
        synthetic_public_input: true,
        source_commit: source_commit!(),
        ceiling: @ceiling,
        counts: budget.counts,
        actual_cost: snapshot.actual_cost,
        usd_reserved: snapshot.usd_reserved,
        task: evidence(task_evidence, %{parsed_route: "K11"}),
        optimizer: evidence(optimizer_evidence, %{normalized_instruction: optimizer_instruction})
      }

      atomic_write!(@output, result)
      IO.puts(Jason.encode!(result, pretty: true))
    rescue
      error ->
        snapshot = Observer.snapshot(observer)

        atomic_write!(@output, %{
          schema_version: 1,
          name: @arm,
          status: "stopped",
          scientific_treatment: false,
          synthetic_public_input: true,
          source_commit: source_commit!(),
          ceiling: @ceiling,
          snapshot: Report.encode_term(snapshot),
          error: Exception.format(:error, error, __STACKTRACE__)
        })

        reraise error, __STACKTRACE__
    after
      :telemetry.detach(telemetry_id)
    end
  end

  defp remote_lm(manifest, role, seed) do
    model = manifest["models"][role]
    request = manifest["execution"]["request"][role]
    route = manifest["execution"]["openrouter"]

    guard = %{
      only: route["#{role}_only"],
      order: route["#{role}_order"],
      allow_fallbacks: false,
      require_parameters: true,
      data_collection: "deny",
      max_price: route["#{role}_max_price_per_million"]
    }

    opts = [
      api_key: System.fetch_env!("OPENROUTER_API_KEY"),
      cache: false,
      max_tokens: request["max_tokens"],
      max_retries: 0,
      timeout: 120_000,
      provider_options: [openrouter_provider: guard, openrouter_usage: %{include: true}],
      req_http_options: [retry: false, max_retries: 0]
    ]

    opts =
      if is_nil(request["temperature"]),
        do: opts,
        else: Keyword.put(opts, :temperature, request["temperature"])

    opts = if is_nil(seed), do: opts, else: Keyword.put(opts, :seed, seed)
    Imp.req_llm(model["imp"], opts)
  end

  defp observed(inner, observer, role, manifest) do
    role_name = Atom.to_string(role)
    request = manifest["execution"]["request"][role_name]

    expected =
      manifest["models"][role_name]
      |> Map.put("max_input_tokens", request["max_input_tokens"])
      |> Map.put("max_output_tokens", request["max_tokens"])

    %ObservedLM{
      inner: inner,
      observer: observer,
      role: role,
      seed: @seed,
      arm: @arm,
      max_input_tokens: request["max_input_tokens"],
      expected_model: expected
    }
  end

  defp evidence(response, parsed) do
    Map.merge(
      %{
        model: response.model,
        route: response.route,
        gateway: response.gateway,
        service_tier: response.service_tier,
        input_tokens: response.input_tokens,
        output_tokens: response.output_tokens,
        finish_reason: response.finish_reason,
        content: response.content,
        gateway_reported_cost: response.gateway_reported_cost,
        adapter_computed_cost: response.computed_cost
      },
      parsed
    )
  end

  defp source_commit! do
    {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: Path.expand("../..", __DIR__))
    String.trim(sha)
  end

  defp atomic_write!(path, value) do
    File.mkdir_p!(Path.dirname(path))
    temporary = path <> ".tmp-#{System.unique_integer([:positive])}"

    try do
      File.write!(temporary, Jason.encode!(value, pretty: true) <> "\n", [:sync])
      File.rename!(temporary, path)
    after
      File.rm(temporary)
    end
  end
end

MatchedTRECImp.WrapperCanary.run()
