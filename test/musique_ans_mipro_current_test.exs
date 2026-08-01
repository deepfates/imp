defmodule Imp.BenchmarkTruth.MusiqueAnsMiproCurrentTest do
  use ExUnit.Case, async: false

  alias Imp.BenchmarkTruth.MusiqueAnsMiproCurrent, as: Plan
  alias Imp.Optimizer.{MIPROv2, Report}

  test "frozen receipt and exact opportunity planner remain internally coherent" do
    receipt = Plan.receipt!()
    assert length(receipt["splits"]["train"]) == 700
    assert length(receipt["splits"]["selection"]) == 300
    assert MapSet.disjoint?(ids(receipt, "train"), ids(receipt, "selection"))
    plan = Plan.call_plan()
    assert plan.per_runtime_seed == %{task: 46_412, proposer: 47}
    assert plan.study == %{task: 278_472, proposer: 282}
    assert plan.task.fresh_service == 8
    assert Float.round(plan.reservation.total_usd, 8) == 2_192.04012144
    assert plan.reservation.accounting == :full_price_byte_as_token_planning_arithmetic
    assert plan.reservation.owner_spend_authority == :not_granted
    assert plan.reservation.current_catalog_revalidation_required
    refute plan.reservation.provider_prompt_cache_discount_assumed
    refute plan.executable

    assert plan.remaining_evidence == [
             :pinned_upstream_complete_census_exact_route_single_transport_and_pretransport_guards,
             :task_owned_wire_framing_and_dynamic_output_guard_wiring_including_bootstrap_demos,
             :current_catalog_revalidation_and_owner_spend_cap
           ]

    assert Plan.status() == :provider_free_readiness_in_progress

    assert Plan.acceptance() == %{
             aggregate: :mean,
             artifact_required: true,
             component_floors: %{mean_answer_f1_lift: 0.0, mean_support_f1_lift: 0.0},
             evidence_scope:
               :official_source_row_disjoint_treatment_unseen_semantic_overlap_disclosed,
             fresh_service_calls_per_seed: 4,
             minimum_mean_lift: 0.05,
             minimum_positive_seeds: 2,
             primary: :mean_answer_support_f1,
             reporting: %{
               every_seed_and_component: true,
               joint_metric_scope: :adapted_not_official,
               parameter_identical_baseline_causal_lift: 0.0,
               per_hop: [:answer_f1, :support_f1, :joint_adapted, :exact_match],
               prohibited_claims: [:broad_mipro_effectiveness, :modeled_tpe_causation]
             },
             secondary: :exact_match,
             seed_count: 3
           }
  end

  test "real ReqLLM JSON and pinned DSPy JSONAdapter preserve actual two-stage wires" do
    owner = self()

    adapter = fn request ->
      body = request.body |> IO.iodata_to_binary() |> Jason.decode!()
      send(owner, {:wire, body})
      selector? = Jason.encode!(body) =~ "ordered_paragraph_idxs"

      content =
        if selector?,
          do: Jason.encode!(%{ordered_paragraph_idxs: [2, 0, 1, 3, 4, 5, 6]}),
          else: Jason.encode!(%{answer: "Gamma", support_positions: [1, 2]})

      response = %{
        "id" => "json-loopback",
        "object" => "chat.completion",
        "model" => "provider-disabled",
        "choices" => [
          %{
            "index" => 0,
            "message" => %{"role" => "assistant", "content" => content},
            "finish_reason" => "stop"
          }
        ],
        "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2}
      }

      {request, Req.Response.new(status: 200, body: response)}
    end

    lm =
      Imp.req_llm(
        %{
          provider: :openrouter,
          id: "provider-disabled",
          model: "provider-disabled",
          base_url: "http://127.0.0.1:1/v1"
        },
        api_key: "none",
        cache: false,
        max_retries: 0,
        req_http_options: [adapter: adapter, retry: false, max_retries: 0]
      )

    assert {:ok, prediction} = Imp.call(Plan.program(lm), inputs())
    assert Imp.get(prediction, :support_idxs) == [0, 1]
    imp_wires = for _ <- 1..2, do: receive(do: ({:wire, body} -> body))
    assert Enum.all?(imp_wires, &(get_in(&1, ["response_format", "type"]) == "json_object"))

    imp_answerer =
      imp_wires |> Enum.at(1) |> get_in(["messages"]) |> List.last() |> Map.fetch!("content")

    {output, 0} =
      System.cmd(
        Path.expand("tmp/dspy-parity-venv/bin/python"),
        [
          "scripts/musique_ans_product_fit_upstream.py",
          "--json-request-proof",
          "--dspy-root",
          "tmp/dspy-3.2.1"
        ],
        stderr_to_stdout: true
      )

    upstream = output |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()

    expected = upstream["answerer_input"]
    assert Enum.map(expected, & &1["idx"]) == [2, 0, 1, 3, 4, 5, 6]

    offsets =
      Enum.map(expected, fn item ->
        {offset, _} = :binary.match(imp_answerer, inspect(item))
        offset
      end)

    assert offsets == Enum.sort(offsets)

    assert Enum.all?(
             upstream["requests"],
             &(get_in(&1, ["body", "response_format", "type"]) == "json_object")
           )
  end

  test "frozen task and proposer routes reach the real ReqLLM serializer" do
    owner = self()

    adapter = fn request ->
      body = request.body |> IO.iodata_to_binary() |> Jason.decode!()
      send(owner, {:route_wire, body, request.headers})

      response = %{
        "id" => "route-loopback",
        "object" => "chat.completion",
        "model" => body["model"],
        "choices" => [
          %{
            "index" => 0,
            "message" => %{"role" => "assistant", "content" => "{}"},
            "finish_reason" => "stop"
          }
        ],
        "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2}
      }

      {request, Req.Response.new(status: 200, body: response)}
    end

    for role <- [:task, :proposer] do
      lm =
        Plan.route_lm(role,
          api_key: "provider-disabled",
          req_http_options: [adapter: adapter, retry: false, max_retries: 0]
        )

      generation_options =
        if role == :task, do: [response_format: %{type: "json_object"}], else: []

      assert {:ok, _} =
               Imp.Clients.ReqLLM.generate(
                 lm,
                 [%{role: :user, content: "route proof"}],
                 generation_options
               )

      assert_receive {:route_wire, body, headers}
      expected = Plan.routes()[role]
      assert body["model"] == expected.model
      assert body["max_tokens"] == expected.max_tokens
      assert get_in(body, ["provider", "only"]) == [expected.provider]
      assert get_in(body, ["provider", "order"]) == [expected.provider]
      assert get_in(body, ["provider", "allow_fallbacks"]) == false
      assert get_in(body, ["provider", "data_collection"]) == "deny"

      if role == :task,
        do: assert(body["response_format"] == %{"type" => "json_object"}),
        else: refute(Map.has_key?(body, "response_format"))

      header_names = Enum.map(headers, fn {name, _} -> String.downcase(name) end)
      assert "x-openrouter-cache" in header_names
      assert "x-openrouter-metadata" in header_names

      if role == :task do
        assert body["temperature"] == 1.0
        assert body["top_p"] == 1.0
      else
        refute Map.has_key?(body, "temperature")
        refute Map.has_key?(body, "top_p")
      end
    end

    assert Plan.prompt_guards().task.max_input_bytes == 52_744
    assert Plan.prompt_guards().proposer.max_input_bytes == 149_443

    assert Plan.adapter_semantics().imp_task == %{
             adapter: Imp.Adapter.JSON,
             json_fallback: false,
             json_repair: false
           }

    assert Plan.adapter_semantics().dspy_task.json_repair
    refute Plan.adapter_semantics().dspy_task.chat_formatted_retry_on_adapter_error
    assert Plan.adapter_semantics().dspy_task.structured_schema_to_json_object_fallback
    assert Plan.adapter_semantics().dspy_task.exact_route_single_transport == :unverified

    json_adapter = File.read!("tmp/dspy-3.2.1/dspy/adapters/json_adapter.py")
    chat_adapter = File.read!("tmp/dspy-3.2.1/dspy/adapters/chat_adapter.py")
    assert json_adapter =~ "json_repair.loads"
    assert json_adapter =~ "falling back to JSON mode"
    assert chat_adapter =~ "isinstance(self, JSONAdapter)"

    assert Plan.admit_dynamic_value!(:instruction, String.duplicate("x", 8_192)) |> byte_size() ==
             8_192

    assert_raise Imp.OperationalSafetyError, ~r/dynamic-value byte guard/, fn ->
      Plan.admit_dynamic_value!(:dataset_summary, String.duplicate("x", 8_193))
    end
  end

  @tag :evidence_infrastructure
  test "receipt replays exact official rows and discloses only exact-question exclusion" do
    data = Plan.data!(data_root!())
    assert {length(data.train), length(data.selection), length(data.test)} == {700, 300, 2_417}
    receipt = Plan.receipt!()

    assert receipt["overlap_disclosure"]["safety"] ==
             "exact normalized composed-question identity only"

    assert "primitive single-hop overlap" in receipt["overlap_disclosure"]["not_excluded"]

    {output, 0} =
      System.cmd(
        "python3",
        [
          "scripts/musique_ans_product_fit_upstream.py",
          "--verify-receipt",
          "--data-root",
          data_root!(),
          "--receipt",
          Plan.receipt_path()
        ],
        stderr_to_stdout: true
      )

    replay = output |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()
    assert replay["derivation_replayed"]

    assert replay["receipt_sha256"] ==
             "df91cf92c123bdaab3dca9943dd0d47188498d4d99488bad9bc215ecd66d7b36"
  end

  @tag :evidence_infrastructure
  test "exact accepted pinned Optuna minibatch configuration is admitted without work" do
    upstream = File.read!("tmp/dspy-3.2.1/dspy/teleprompt/mipro_optimizer_v2.py")
    assert upstream =~ "minibatch: bool = True"
    assert upstream =~ "minibatch_size: int = 35"
    assert upstream =~ "minibatch_full_eval_steps: int = 5"
    lm = Imp.LM.Static.new(handler: fn _, _ -> flunk("constructor performed LM work") end)

    optimizer = Plan.optimizer(lm, lm, hd(Plan.seeds()))
    assert optimizer.config.minibatch
    assert optimizer.config.search_fidelity == :dspy_3_2_1_optuna_4_9_0
  end

  @tag :evidence_infrastructure
  test "exact frozen setup censes every proposer call and actual pinned demo arms" do
    data = Plan.data!(data_root!())

    frozen_answers =
      Enum.map(data.train ++ data.selection, fn ex ->
        {Imp.Example.get(ex, :question), ex}
      end)
      |> Enum.sort_by(fn {question, _ex} -> -byte_size(question) end)

    task_lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          current = messages |> List.last() |> Map.fetch!(:content)

          {_question, ex} =
            Enum.find(frozen_answers, fn {question, _ex} ->
              String.contains?(current, question)
            end) || raise("provider-disabled bootstrap question did not match frozen train data")

          paragraphs = Imp.Example.get(ex, :paragraphs)
          support = Imp.Example.get(ex, :support_idxs)
          ranking = (support ++ Enum.map(paragraphs, & &1["idx"])) |> Enum.uniq() |> Enum.take(7)

          %{
            ordered_paragraph_idxs: ranking,
            answer: Imp.Example.get(ex, :answer),
            support_positions:
              ranking
              |> Enum.with_index()
              |> Enum.filter(fn {idx, _position} -> idx in support end)
              |> Enum.map(&elem(&1, 1))
          }
        end
      )

    calls =
      start_supervised!(
        {Agent, fn -> [] end},
        id: {:musique_proposer_calls, System.unique_integer([:positive])}
      )

    prompt_lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          Agent.update(calls, &(&1 ++ [messages]))

          %{
            observations: "provider-disabled observations",
            summary: "provider-disabled summary",
            program_description: "provider-disabled program",
            module_description: "provider-disabled module",
            proposed_instruction: "provider-disabled instruction"
          }
        end
      )

    compiled =
      Plan.optimizer(task_lm, prompt_lm, hd(Plan.seeds()))
      |> MIPROv2.compile(Plan.program(task_lm), data.train, data.selection, max_trials: 0)

    report = Report.fetch(compiled)

    artifacts =
      report.metadata.resume_state["payload"]["artifacts"]
      |> Report.decode_term()

    proposer_census = calls |> Agent.get(& &1) |> Plan.proposer_prompt_census!()

    assert proposer_census == %{
             calls: 47,
             max_bytes: 124_867,
             min_bytes: 1_198,
             ordered_sha256: "fb8bc5068c17d1dccc907280c9a650efd165a04ac4fae6326f8772394e4952e6",
             p50_bytes: 30_777,
             p95_bytes: 111_395
           }

    task_census = Plan.task_prompt_census!(data_root!(), artifacts.search_demos)
    assert task_census.source == :actual_pinned_search_demo_arms
    assert task_census.dev_labels_used == false
    assert task_census.selector_demo_arm_sizes == [0, 2, 2, 2, 2, 2]
    assert task_census.answerer_demo_arm_sizes == [0, 2, 2, 2, 2, 2]
    assert task_census.selector_max_bytes == 44_552
    assert task_census.answerer_max_bytes == 21_994
    assert task_census.selector_guard_bytes == 52_744
    assert task_census.answerer_guard_bytes == 30_186
    assert task_census.selector_guard_bytes > task_census.selector_max_bytes
    assert task_census.answerer_guard_bytes > task_census.answerer_max_bytes
  end

  @tag :evidence_infrastructure
  test "reduced modeled MIPRO selects, persists, and serves four calls in a fresh OS" do
    task_lm = reduced_task_lm()

    prompt_lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          rendered = Enum.map_join(messages, "\n", & &1.content)

          cond do
            rendered =~ "`proposed_instruction`" ->
              %{proposed_instruction: "candidate instruction"}

            rendered =~ "`summary`" ->
              %{summary: "Every row asks for Gamma and its two supporting paragraphs."}

            true ->
              %{observations: "Rank the decisive paragraphs and answer Gamma."}
          end
        end
      )

    rows =
      Enum.map(0..7, fn index ->
        Imp.example(
          id: "reduced-#{index}",
          question: "Who won reduced row #{index}?",
          paragraphs: inputs().paragraphs,
          answer: "Gamma",
          support_idxs: [0, 1]
        )
        |> Imp.with_inputs([:question, :paragraphs])
      end)

    data =
      Imp.Experiment.Data.new(
        train: Enum.take(rows, 4),
        selection: Enum.slice(rows, 4, 2),
        test: Enum.slice(rows, 6, 2),
        id: :id
      )

    optimizer =
      MIPROv2.new(&Plan.metric/2,
        auto: nil,
        num_candidates: 3,
        num_trials: 11,
        startup_trials: 10,
        max_bootstrapped_demos: 0,
        max_labeled_demos: 0,
        minibatch: true,
        minibatch_size: 1,
        minibatch_full_eval_steps: 5,
        proposer_fidelity: :dspy_3_2_1,
        search_fidelity: :dspy_3_2_1_optuna_4_9_0,
        program_aware_proposer: false,
        data_aware_proposer: true,
        tip_aware_proposer: true,
        fewshot_aware_proposer: false,
        view_data_batch_size: 10,
        prompt_lm: prompt_lm,
        task_lm: task_lm,
        metric_identity: %{
          "id" => "musique-reduced-provider-disabled",
          "version" => 1,
          "config" => %{}
        },
        max_errors: 10,
        max_concurrency: 1,
        seed: 9
      )

    assert {:ok, result} =
             Imp.Experiment.check(
               Plan.program(task_lm),
               optimizer,
               data,
               &Plan.metric/2,
               artifact_id: "musique-reduced-provider-disabled",
               compare_baseline_on_test: true,
               evaluation_options: [
                 repetitions: 1,
                 aggregation: :mean,
                 max_errors: 10,
                 failure_score: 0.0,
                 max_concurrency: 1
               ]
             )

    assert result.selected == :optimized
    assert result.optimized_selection.score > result.baseline_selection.score
    assert result.test.score == 1.0
    assert result.baseline_test.score == 0.0

    assert Report.fetch(result.program).metadata["sampler"] ==
             "optuna_4_9_0_multivariate_categorical_tpe"

    source_instructions =
      Plan.program(task_lm)
      |> Imp.ProgramParameters.predictors()
      |> Map.new(&{&1.name, &1.predictor.signature.instructions})

    assert Enum.all?(Imp.ProgramParameters.predictors(result.program), fn item ->
             item.predictor.signature.instructions != source_instructions[item.name]
           end)

    root = Path.join(System.tmp_dir!(), "musique-reduced-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    artifact = Path.join(root, "artifact.json")
    receipt = Path.join(root, "fresh.json")
    :ok = Imp.Optimizer.Artifact.write!(result.artifact, artifact)

    code = """
    Code.require_file("examples/deployment/lib/imp_deployment/program_server.ex")
    lm = #{reduced_task_lm_source()}
    source = Imp.BenchmarkTruth.MusiqueAnsMiproCurrent.program(lm)
    selected = Imp.Optimizer.Artifact.apply(Imp.Optimizer.Artifact.read!(#{inspect(artifact)}), source)
    {:ok, supervisor} = Task.Supervisor.start_link()
    {:ok, server} = ImpDeployment.ProgramServer.start_link(program: selected, lm: lm, task_supervisor: supervisor,
      executor: fn program, _lm, inputs -> Imp.call(program, inputs) end, name: nil)
    results =
      0..3
      |> Task.async_stream(fn index ->
        ImpDeployment.ProgramServer.call(server, %{question: "Who won fresh row \#{index}?", paragraphs: #{inspect(inputs().paragraphs)}}, 5_000)
      end, ordered: true, max_concurrency: 4, timeout: 10_000)
      |> Enum.map(fn {:ok, {:ok, prediction}} -> Imp.Prediction.to_map(prediction) end)
    File.write!(#{inspect(receipt)}, Jason.encode!(results))
    """

    assert {_output, 0} =
             System.cmd("mix", ["run", "--no-compile", "--no-deps-check", "-e", code],
               env: [{"MIX_ENV", "test"}],
               stderr_to_stdout: true
             )

    assert receipt |> File.read!() |> Jason.decode!() ==
             List.duplicate(%{"answer" => "Gamma", "support_idxs" => [0, 1]}, 4)
  end

  @tag :evidence_infrastructure
  test "pinned DSPy reduced MIPRO selects optimized state and serves four calls fresh" do
    {output, 0} =
      System.cmd(
        Path.expand("tmp/dspy-parity-venv/bin/python"),
        [
          "scripts/musique_ans_product_fit_upstream.py",
          "--mipro-readiness",
          "--dspy-root",
          "tmp/dspy-3.2.1"
        ],
        env: [{"PYTHONPATH", Path.expand("tmp/dspy-3.2.1")}],
        stderr_to_stdout: false
      )

    readiness = output |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()
    assert readiness["dspy_commit"] == "29448ae12756abdd14bd8796c819247ebb83673c"
    assert readiness["reduced_execution"]
    refute readiness["full_opportunity_claimed"]
    assert readiness["requested_objective_trials"] == 11
    assert readiness["adjusted_log_slots"] == 15
    assert readiness["inserted_full_evaluations"] == 3
    assert readiness["selected"] == "optimized"
    assert readiness["baseline_selection"] == 0.0
    assert readiness["optimized_selection"] == 1.0

    assert readiness["selected_instructions"] == %{
             "answerer" => "candidate instruction",
             "selector" => "candidate instruction"
           }

    assert byte_size(readiness["state_sha256"]) == 64

    assert readiness["fresh_predictions"] ==
             List.duplicate(%{"answer" => "Gamma", "support_idxs" => [0, 1]}, 4)
  end

  defp ids(receipt, split), do: receipt["splits"][split] |> Enum.map(& &1["id"]) |> MapSet.new()

  defp data_root! do
    System.get_env("MUSIQUE_DATA_ROOT") ||
      File.read!("/tmp/musique-current-data-dir") |> String.trim() |> Path.join("data")
  end

  defp inputs do
    paragraphs =
      [
        %{"idx" => 0, "title" => "Bridge", "text" => "The winner was Gamma."},
        %{"idx" => 1, "title" => "Final", "text" => "Gamma received the prize."},
        %{"idx" => 2, "title" => "Noise", "text" => "Delta attended."}
      ] ++
        Enum.map(3..7, &%{"idx" => &1, "title" => "Noise #{&1}", "text" => "Noise."})

    %{question: "Who won?", paragraphs: paragraphs}
  end

  defp reduced_task_lm do
    Imp.LM.Static.new(
      handler: fn messages, _opts ->
        rendered = Enum.map_join(messages, "\n", & &1.content)
        candidate? = rendered =~ "candidate instruction"

        if rendered =~ "`ordered_paragraph_idxs`" do
          %{
            ordered_paragraph_idxs:
              if(candidate?, do: [2, 0, 1, 3, 4, 5, 6], else: [2, 3, 4, 5, 6, 7, 0])
          }
        else
          if candidate?,
            do: %{answer: "Gamma", support_positions: [1, 2]},
            else: %{answer: "Delta", support_positions: []}
        end
      end
    )
  end

  defp reduced_task_lm_source do
    """
    Imp.LM.Static.new(handler: fn messages, _opts ->
      rendered = Enum.map_join(messages, "\\n", & &1.content)
      candidate? = rendered =~ "candidate instruction"
      if rendered =~ "`ordered_paragraph_idxs`" do
        %{ordered_paragraph_idxs: if(candidate?, do: [2, 0, 1, 3, 4, 5, 6], else: [2, 3, 4, 5, 6, 7, 0])}
      else
        if candidate?, do: %{answer: "Gamma", support_positions: [1, 2]}, else: %{answer: "Delta", support_positions: []}
      end
    end)
    """
  end
end
