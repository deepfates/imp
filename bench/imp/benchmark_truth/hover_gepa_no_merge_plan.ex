defmodule Imp.BenchmarkTruth.HoverGepaNoMergePlan do
  @moduledoc false

  alias Imp.Optimizer.GEPA

  @gepa_artifact_commit "cbefbc1aa0f43dd39874ec4bf42211365dbda42e"
  @dspy_commit "29448ae12756abdd14bd8796c819247ebb83673c"
  @gepa_commit "8b0ce6cd99a234f6b74daf37558a2ac0ce18f975"
  @historical_task_model "openai:gpt-4.1-mini-2025-04-14"
  @candidate_model "deepseek/deepseek-v4-flash-0731"
  @candidate_endpoint_model "deepseek/deepseek-v4-flash-20260731"
  @candidate_endpoint_tag "siliconflow/fp8"
  @candidate_endpoint_name "SiliconFlow | deepseek/deepseek-v4-flash-20260731"
  @candidate_provider "SiliconFlow"
  @reflection_model "anthropic/claude-sonnet-5"
  @reflection_endpoint_model "anthropic/claude-sonnet-5-20260630"
  @reflection_endpoint_tag "google-vertex/global"
  @reflection_endpoint_name "Google | anthropic/claude-sonnet-5-20260630"
  @reflection_provider "Google"
  @task_input_price_per_million 0.14
  @task_output_price_per_million 0.28
  @reflection_input_price_per_million 2.0
  @reflection_output_price_per_million 10.0
  @task_output_byte_cap 32_768
  @reflection_output_byte_cap 65_536
  @feedback_byte_cap 16_384
  @task_guard %{
    max_input_bytes: 131_072,
    reservation_tokens: 131_072,
    max_output_tokens: 2_048,
    max_output_bytes: @task_output_byte_cap
  }
  @reflection_guard %{
    max_input_bytes: 655_360,
    reservation_tokens: 655_360,
    max_output_tokens: 8_192,
    max_output_bytes: @reflection_output_byte_cap,
    enforcement: :candidate_request_serializers_exercised
  }
  @task_concurrency 1
  @reflection_concurrency 1
  @seeds [2_026_080_201, 2_026_080_202, 2_026_080_203]
  @train_size 150
  @selection_size 300
  @test_size 300
  @stages 4
  @repetitions 3
  @semantic_metric_calls 4_500
  @minibatch_size 3
  @service_calls_per_seed 4

  @split_sha256 %{
    train: "448048cc80de7982b344ef3c8767816164eeabe3d2a1ad4f776245e3dff39370",
    selection: "052fdda83d8e7fff83c7f4db67cd1a2a8cb66047e6cd68ecfe14310dcbf93602",
    test: "cf1b51ca6ed32c21355a954624d88b396d3e963585549cea68308b519c5a8807"
  }

  @released_split_sha256 %{
    train: "448048cc80de7982b344ef3c8767816164eeabe3d2a1ad4f776245e3dff39370",
    selection: "b342dbaaa4516e55b7f4f7ac046828c2201952e69de5b97751173238674a74a7",
    test: "cf1b51ca6ed32c21355a954624d88b396d3e963585549cea68308b519c5a8807"
  }

  @removed_duplicate_sha256 "ef899c595acd9714480791fe7d15e929dab4799308e0c67bab5756a16a141c17"
  @replacement_sha256 "00213c2cde2b65017097d21be6a77fe2a46ba6f053227a677b148130da1e2e5c"

  @corpus_sha256 "c006527c7c600f85ed594afa36d2a34d0598996405f560474227738342463724"
  @index_build_instance_sha256 "d8ef9ed4d833c0f9b67ed33784864ff316ec3cfbf1ffca7b0cf2c2190f9f0548"
  @fingerprint_sha256 "2662ef6b6a4f8f80b9d348992f14ca04d3007c84b13252825dc38a55ace22099"
  @dependency_lock_sha256 "8fb251bc1fedd7ca9664b6128470e43eba4e5b784ad0c4aede6168782d5f53d4"
  @runtime_entries [:imp, :dspy]

  @retrieval_build_tuple %{
    repository: "dspy/cache",
    revision: "ef6a5e72a98b47cef31574a400fea8fe149559a3",
    archive_bytes: 608_448_121,
    archive_sha256: "744183e61af986bde9b25c880b59c1502618a8b673671e189cbc0ee684fceb42",
    corpus_bytes: 1_780_742_620,
    corpus_rows: 5_233_330,
    corpus_sha256: @corpus_sha256,
    python: "3.12.8",
    bm25s: "0.2.12",
    numpy: "2.5.1",
    pystemmer: "pystemmer 2.2.0.3",
    k1: 0.9,
    b: 0.4,
    method: "lucene",
    idf_method: "lucene",
    stopwords: "en",
    stemmer: "english",
    platform: "Darwin 25.5.0 arm64",
    dependency_lock_sha256: @dependency_lock_sha256
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

    nominal_task_total =
      nominal_task_per_runtime_seed * 2 * length(@seeds) +
        @service_calls_per_seed * @stages * length(@seeds)

    legal_task_total =
      legal_task_per_runtime_seed * 2 * length(@seeds) +
        @service_calls_per_seed * @stages * length(@seeds)

    nominal_reflections = envelope.max_iterations * 2 * length(@seeds)
    legal_reflections = envelope.max_reflection_calls * 2 * length(@seeds)

    %{
      condition: "imp-88sn-hover-gepa-no-merge-current-model-v2",
      status: :readiness_only,
      target_claim: "adapted current-source matched-information/opportunity noninferiority",
      excluded_claims: ["paper replication", "runtime parity", "GEPA-with-merge"],
      authorities: %{
        gepa_artifact: @gepa_artifact_commit,
        dspy: @dspy_commit,
        gepa: @gepa_commit
      },
      historical_artifact: %{
        task_model: @historical_task_model,
        treatment_status: :provenance_only
      },
      current_treatment: %{
        status: :provider_free_candidate,
        applies_to: @runtime_entries,
        task_model: @candidate_model,
        reflection_model: @reflection_model,
        same_route_for_task_and_reflection: false,
        task_route: candidate_route(:task),
        reflection_route: candidate_route(:reflection),
        concurrency: %{
          status: :matched_serial_within_lane,
          imp_optimizer: @task_concurrency,
          upstream_threads: 1,
          outer_evaluation: 1,
          reflection: @reflection_concurrency,
          result_order: :source_row_order,
          independent_lane_parallelism: :separate_processes_only_not_implemented,
          rationale:
            "the pinned Imp profile is serial; DSPy num_threads=1 matches it and both retain source-row order"
        },
        policies: %{
          task: %{
            temperature: 1.0,
            top_p: 1.0,
            reasoning: :disabled,
            max_output_tokens: @task_guard.max_output_tokens,
            max_output_bytes: @task_guard.max_output_bytes,
            request_seed: nil
          },
          reflection: %{
            temperature: :omitted,
            verbosity: :omitted,
            reasoning_effort: :high,
            max_output_tokens: @reflection_guard.max_output_tokens,
            max_output_bytes: @reflection_guard.max_output_bytes,
            request_seed: nil
          }
        },
        guards: %{task: @task_guard, reflection: @reflection_guard},
        excluded_claims: [
          "ratified treatment",
          "exact GEPA algorithm parity",
          "renderer parity",
          "provider execution"
        ],
        matched_contract: %{
          rows: :exact,
          information: :same,
          optimizer_opportunity: :same,
          generation_policies: :provider_disabled_both_serializers_exercised,
          renderer: :runtime_native,
          result_order: :source_row_order
        },
        readiness: %{
          imp_provider_disabled_lifecycle: :exercised,
          dspy_provider_disabled_lifecycle: :exercised_repository_only_entry,
          imp_live_request_serialization: :provider_disabled_wire_exercised,
          dspy_live_request_serialization: :provider_disabled_wire_exercised,
          exact_route_cost_calibration: :pending,
          provider_authority: false
        }
      },
      seeds: @seeds,
      rows: %{train: @train_size, selection: @selection_size, test: @test_size},
      split_sha256: @split_sha256,
      split_policy: %{
        kind: :released_split_with_content_identity_overlap_removed,
        released_split_sha256: @released_split_sha256,
        removed_duplicate_sha256: @removed_duplicate_sha256,
        replacement_sha256: @replacement_sha256,
        output_blind: true
      },
      retrieval: %{
        authority_scope: :condition_build_instance_receipt,
        planned_runtime_entries: @runtime_entries,
        corpus_sha256: @corpus_sha256,
        index_build_instance_tree_sha256: @index_build_instance_sha256,
        frozen_claim_retrieval_fingerprint_sha256: @fingerprint_sha256,
        fingerprint_rows: 450,
        build_tuple: @retrieval_build_tuple,
        excluded_claims: ["universal rebuild identity", "cross-build semantic equivalence"]
      },
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
        nominal_total: nominal_task_total,
        legal_total: legal_task_total,
        logical_reflections_all_runtimes_seeds: nominal_reflections,
        legal_reflection_transports_all_runtimes_seeds: legal_reflections
      },
      reservation: %{
        accounting: :full_price_byte_as_token_planning_ceiling,
        framing: :included_in_request_byte_guards,
        nominal_usd: reservation_usd(nominal_task_total, nominal_reflections),
        legal_usd: reservation_usd(legal_task_total, legal_reflections),
        prospective_spend_cap: :pending_train_only_calibration,
        caveat:
          "planning ceiling, not a prospective spend cap; both provider-disabled request serializers exercise the per-request byte guards, while live distribution and spend calibration remain pending and provider prompt-cache tariff is never assumed"
      }
    }
  end

  def candidate_provider_preferences(role) when role in [:task, :reflection] do
    route = candidate_route(role)

    %{
      only: [route.endpoint_tag],
      order: [route.endpoint_tag],
      allow_fallbacks: false,
      require_parameters: true,
      data_collection: "deny",
      zdr: true,
      max_price: %{
        prompt: route.input_price_per_million,
        completion: route.output_price_per_million
      }
    }
  end

  def provider_disabled_request_serialization!(role) when role in [:task, :reflection] do
    owner = self()
    route = candidate_route(role)
    guard = if role == :task, do: @task_guard, else: @reflection_guard
    requested_model = if role == :task, do: @candidate_model, else: @reflection_model

    adapter = fn request ->
      body = request.body |> IO.iodata_to_binary() |> Jason.decode!()
      headers = Map.new(request.headers, fn {key, values} -> {String.downcase(key), values} end)
      messages = Jason.encode!(Map.fetch!(body, "messages"))

      if byte_size(messages) > guard.max_input_bytes do
        raise Imp.OperationalSafetyError,
          kind: :budget,
          message: "serialized HoVer #{role} request exceeds the candidate byte guard",
          reason: %{actual_bytes: byte_size(messages), max_bytes: guard.max_input_bytes}
      end

      send(owner, {:hover_serialized_request, role, body, headers, messages})

      response = %{
        "id" => "provider-disabled-#{role}",
        "object" => "chat.completion",
        "model" => route.endpoint_model,
        "provider" => route.provider,
        "choices" => [
          %{
            "index" => 0,
            "message" => %{"role" => "assistant", "content" => "provider-disabled"},
            "finish_reason" => "stop"
          }
        ],
        "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2}
      }

      {request, Req.Response.new(status: 200, body: response)}
    end

    role_options =
      case role do
        :task ->
          [
            temperature: 1.0,
            top_p: 1.0,
            reasoning_effort: :none,
            openrouter_reasoning_wire: :nested
          ]

        :reflection ->
          [reasoning_effort: :high, openrouter_reasoning_wire: :nested]
      end

    lm =
      Imp.req_llm(
        %{
          provider: :openrouter,
          id: requested_model,
          model: requested_model,
          base_url: "https://openrouter.ai/api/v1"
        },
        [
          api_key: "provider-disabled",
          cache: false,
          max_tokens: guard.max_output_tokens,
          max_retries: 0,
          input_envelope: [
            max_bytes: guard.max_input_bytes,
            reservation_tokens: guard.reservation_tokens
          ],
          provider_options: [
            openrouter_provider: candidate_provider_preferences(role),
            openrouter_usage: %{include: true}
          ],
          req_http_options: [
            adapter: adapter,
            headers: [
              {"X-OpenRouter-Metadata", "enabled"},
              {"X-OpenRouter-Cache", "false"}
            ],
            retry: false,
            max_retries: 0
          ]
        ] ++ role_options
      )

    {:ok, _response} =
      Imp.Clients.ReqLLM.generate(
        lm,
        [%{role: :user, content: "provider-disabled #{role} serializer assertion"}],
        []
      )

    receive do
      {:hover_serialized_request, ^role, body, headers, messages} ->
        %{
          role: role,
          body: body,
          headers: headers,
          rendered_messages_bytes: byte_size(messages),
          rendered_messages_sha256: sha256(messages),
          max_input_bytes: guard.max_input_bytes
        }
    after
      1_000 -> raise "HoVer #{role} serializer did not reach the provider-disabled transport"
    end
  end

  def validate_candidate_catalog!(task_catalog, task_zdr, reflection_catalog, reflection_zdr)
      when is_map(task_catalog) and is_map(task_zdr) and is_map(reflection_catalog) and
             is_map(reflection_zdr) do
    model = task_catalog["data"] || task_catalog[:data]

    unless is_map(model) and model["id"] == @candidate_model do
      raise ArgumentError, "HoVer candidate model catalog identity drift"
    end

    reflector = reflection_catalog["data"] || reflection_catalog[:data]

    unless is_map(reflector) and reflector["id"] == @reflection_model do
      raise ArgumentError, "HoVer reflection model catalog identity drift"
    end

    task_endpoint = exact_endpoint!(:task, model["endpoints"], "task model catalog")
    _task_zdr_endpoint = exact_endpoint!(:task, task_zdr["data"], "task ZDR catalog")

    reflection_endpoint =
      exact_endpoint!(:reflection, reflector["endpoints"], "reflection model catalog")

    _reflection_zdr_endpoint =
      exact_endpoint!(:reflection, reflection_zdr["data"], "reflection ZDR catalog")

    %{task: task_endpoint, reflection: reflection_endpoint}
  end

  def validate_candidate_catalog!(_task_catalog, _task_zdr, _reflection_catalog, _reflection_zdr),
    do: raise(ArgumentError, "HoVer candidate catalogs are malformed")

  defp candidate_route(role) do
    identity =
      case role do
        :task ->
          {@candidate_endpoint_tag, @candidate_endpoint_name, @candidate_endpoint_model,
           @candidate_provider, "fp8", @task_input_price_per_million,
           @task_output_price_per_million}

        :reflection ->
          {@reflection_endpoint_tag, @reflection_endpoint_name, @reflection_endpoint_model,
           @reflection_provider, "unknown", @reflection_input_price_per_million,
           @reflection_output_price_per_million}
      end

    {tag, name, model, provider, quantization, input_price, output_price} = identity

    %{
      endpoint_tag: tag,
      endpoint_name: name,
      endpoint_model: model,
      provider: provider,
      quantization: quantization,
      zdr: true,
      data_collection: "deny",
      allow_fallbacks: false,
      require_parameters: true,
      response_cache: false,
      provider_prompt_cache: :reported_only,
      retries: 0,
      input_price_per_million: input_price,
      output_price_per_million: output_price
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
      max_concurrency: @task_concurrency
    )
  end

  def optimizer(_metric, _reflection_lm, seed) do
    raise ArgumentError, "unfrozen HoVer seed: #{inspect(seed)}"
  end

  def materialization_options(root) when is_binary(root) do
    root = Path.expand(root)

    retrieval = %{
      "kind" => "bm25s_wiki_abstracts_2017",
      "corpus_path" => Path.join(root, "retrieval/extracted/wiki.abstracts.2017.jsonl"),
      "index_path" => Path.join(root, "retrieval/index/bm25s_retriever"),
      "corpus_checksum" => "sha256:" <> @corpus_sha256,
      "index_checksum" => "sha256:" <> @index_build_instance_sha256
    }

    [
      data_root: Path.join(root, "export-disjoint-v1/hoverBench"),
      receipt_path: Path.join(root, "materialization.json"),
      split_receipt_path: Path.join(root, "export-disjoint-v1/families.json"),
      dependency_lock_path: Path.join(root, "dependency-lock.txt"),
      fingerprint_path:
        Path.join(
          root,
          "retrieval/frozen-disjoint-claim-retrieval-fingerprint.jsonl"
        ),
      runtime_retrievals: %{imp: retrieval, dspy: retrieval}
    ]
  end

  def data!(materialization_root) when is_binary(materialization_root) do
    opts = materialization_options(materialization_root)
    %{data_ready: true} = data_readiness(opts)
    data_root = Keyword.fetch!(opts, :data_root)

    Imp.Experiment.Data.new(
      train: Imp.Datasets.jsonl(Path.join(data_root, "train.jsonl"), [:claim]),
      selection: Imp.Datasets.jsonl(Path.join(data_root, "dev.jsonl"), [:claim]),
      test: Imp.Datasets.jsonl(Path.join(data_root, "test.jsonl"), [:claim])
    )
  end

  def metric(example, prediction) do
    gold =
      example
      |> Imp.Example.get(:supporting_facts, [])
      |> Enum.map(&Map.get(&1, "key", Map.get(&1, :key)))
      |> Enum.map(&Imp.Metrics.normalize_text/1)
      |> MapSet.new()

    found =
      prediction
      |> Imp.Prediction.get(:retrieved_docs, [])
      |> Enum.map(fn passage -> passage |> String.split(" | ", parts: 2) |> hd() end)
      |> Enum.map(&Imp.Metrics.normalize_text/1)
      |> MapSet.new()

    MapSet.subset?(gold, found)
  end

  def source_exact_retrieval_probe!(materialization_root, opts \\ []) do
    materialization = materialization_options(materialization_root)
    %{data_ready: true} = data_readiness(materialization)
    retrieval = materialization |> Keyword.fetch!(:runtime_retrievals) |> Map.fetch!(:imp)
    data_root = Keyword.fetch!(materialization, :data_root)
    fingerprint_path = Keyword.fetch!(materialization, :fingerprint_path)
    gepa_root = Keyword.get(opts, :gepa_root, "tmp/gepa-artifact")

    python =
      Keyword.get(
        opts,
        :python,
        Path.join(Path.expand(materialization_root), ".venv/bin/python")
      )

    {:ok, server} =
      Imp.BenchmarkTruth.HoverBM25.UpstreamPython.start_link(retrieval,
        python: python,
        gepa_root: gepa_root,
        startup_timeout: Keyword.get(opts, :startup_timeout, 240_000)
      )

    try do
      row = data_root |> Path.join("train.jsonl") |> first_jsonl!()
      expected = fingerprint_path |> first_jsonl!() |> Map.fetch!("titles")

      retriever =
        Imp.BenchmarkTruth.HoverBM25.UpstreamPython.new(retrieval,
          python: python,
          gepa_root: gepa_root,
          server: server,
          k: 24
        )

      query_count = Keyword.get(opts, :queries, 16)

      results =
        Enum.map(1..query_count, fn _index ->
          {:ok, result} =
            Imp.BenchmarkTruth.HoverBM25.UpstreamPython.search(retriever, row["claim"])

          result
        end)

      first = hd(results)
      titles = Enum.map(first, &(String.split(&1, " | ", parts: 2) |> hd()))

      unless Enum.all?(results, &(&1 == first)) and titles == expected do
        raise "resident HoVer retrieval differs from its exact frozen fingerprint"
      end

      %{
        queries: query_count,
        top_k: 24,
        repeat_exact: true,
        fingerprint_exact: true,
        implementation: "resident_upstream_python_bm25s"
      }
    after
      GenServer.stop(server)
    end
  end

  def train_only_reflection_census!(materialization_root, opts \\ []) do
    materialization = materialization_options(materialization_root)
    data_root = Keyword.fetch!(materialization, :data_root)
    train_path = Path.join(data_root, "train.jsonl")
    retrieval = materialization |> Keyword.fetch!(:runtime_retrievals) |> Map.fetch!(:imp)

    unless line_count(train_path) == @train_size and
             file_sha256(train_path) == @split_sha256.train do
      raise ArgumentError, "HoVer reflection census train rows do not match the frozen source"
    end

    verify_build_receipt!(Keyword.fetch!(materialization, :receipt_path))

    unless file_sha256(Keyword.fetch!(materialization, :dependency_lock_path)) ==
             @dependency_lock_sha256 do
      raise ArgumentError, "HoVer reflection census dependency lock does not match"
    end

    verify_retrieval!(retrieval)

    python =
      Keyword.get(
        opts,
        :python,
        Path.join(Path.expand(materialization_root), ".venv/bin/python")
      )

    {:ok, server} =
      Imp.BenchmarkTruth.HoverBM25.UpstreamPython.start_link(retrieval,
        python: python,
        gepa_root: Keyword.get(opts, :gepa_root, "tmp/gepa-artifact"),
        startup_timeout: Keyword.get(opts, :startup_timeout, 240_000)
      )

    try do
      retriever =
        Imp.BenchmarkTruth.HoverBM25.UpstreamPython.new(retrieval,
          python: python,
          gepa_root: Keyword.get(opts, :gepa_root, "tmp/gepa-artifact"),
          server: server,
          k: 24
        )

      rows = Imp.Datasets.jsonl(train_path, [:claim])
      program = Imp.BenchmarkTruth.HoverMultiHop.from_retriever(static_task_lm(), retriever)
      {optimizer, recorder} = provider_disabled_optimizer(&metric/2, hd(@seeds))

      try do
        {_compiled, _report} =
          GEPA.compile_with_report(optimizer, program, rows, Enum.take(rows, 4))

        recorder
        |> Agent.get(& &1.prompts)
        |> reflection_prompt_census!(:authenticated_train_three_row_four_stage_traces)
        |> Map.put(:train_rows_available, length(rows))
        |> Map.put(:train_rows_sha256, @split_sha256.train)
        |> Map.put(:selection_or_test_loaded, false)
        |> Map.put(:retrieval_tree_sha256, @index_build_instance_sha256)
      after
        Agent.stop(recorder)
      end
    after
      GenServer.stop(server)
    end
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
    runtime_retrievals = Keyword.get(opts, :runtime_retrievals)
    receipt_path = Keyword.get(opts, :receipt_path)
    split_receipt_path = Keyword.get(opts, :split_receipt_path)
    dependency_lock_path = Keyword.get(opts, :dependency_lock_path)
    fingerprint_path = Keyword.get(opts, :fingerprint_path)

    if is_binary(data_root) and is_map(runtime_retrievals) and is_binary(receipt_path) and
         is_binary(split_receipt_path) and is_binary(dependency_lock_path) and
         is_binary(fingerprint_path) do
      verify_materialized!(
        data_root,
        runtime_retrievals,
        receipt_path,
        split_receipt_path,
        dependency_lock_path,
        fingerprint_path
      )

      %{
        data_ready: true,
        data_root: Path.expand(data_root),
        runtime_entries: @runtime_entries,
        index_authority_scope: :condition_build_instance_receipt
      }
    else
      %{
        data_ready: false,
        reason:
          "condition-specific row, split-lineage, build-receipt, dependency-lock, runtime-path, and retrieval-fingerprint evidence is required"
      }
    end
  end

  def verify_materialized!(
        data_root,
        runtime_retrievals,
        receipt_path,
        split_receipt_path,
        dependency_lock_path,
        fingerprint_path
      )
      when is_binary(data_root) and is_map(runtime_retrievals) do
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

    verify_identity_disjoint!(data_root)
    verify_split_receipt!(split_receipt_path)

    unless Enum.sort(Map.keys(runtime_retrievals)) == Enum.sort(@runtime_entries) do
      raise ArgumentError, "HoVer retrieval paths must be supplied for Imp and DSPy"
    end

    verify_build_receipt!(receipt_path)

    unless file_sha256(dependency_lock_path) == @dependency_lock_sha256 do
      raise ArgumentError, "HoVer retrieval dependency lock does not match the build receipt"
    end

    verify_fingerprint!(fingerprint_path)

    Enum.each(@runtime_entries, fn runtime ->
      verify_retrieval!(Map.fetch!(runtime_retrievals, runtime))
    end)
  end

  def verify_retrieval!(retrieval) when is_map(retrieval) do
    expected = %{
      "corpus_checksum" => "sha256:" <> @corpus_sha256,
      "index_checksum" => "sha256:" <> @index_build_instance_sha256
    }

    unless Map.take(retrieval, Map.keys(expected)) == expected do
      raise ArgumentError, "HoVer retrieval identity does not match the frozen source"
    end

    Imp.BenchmarkTruth.HoverBM25.verify_source!(retrieval)
  end

  defp verify_build_receipt!(path) do
    receipt = path |> File.read!() |> Jason.decode!()
    build = get_in(receipt, ["retrieval", "build"])
    extraction = get_in(receipt, ["retrieval", "extraction"])
    archive = get_in(receipt, ["retrieval", "archive"])

    expected = @retrieval_build_tuple

    actual = %{
      repository: get_in(receipt, ["retrieval", "repository"]),
      revision: get_in(receipt, ["retrieval", "revision"]),
      archive_bytes: archive["bytes"],
      archive_sha256: archive["sha256"],
      corpus_bytes:
        get_in(extraction, ["authenticated_members"])
        |> Enum.find_value(fn member -> member["extracted"] && member["bytes"] end),
      corpus_rows: extraction["corpus_rows"],
      corpus_sha256: extraction["corpus_sha256"],
      python: build["python"],
      bm25s: get_in(build, ["parameters", "bm25s"]),
      numpy: build["numpy"],
      pystemmer: build["parameters"]["stemmer"] |> String.split("/") |> hd(),
      k1: get_in(build, ["parameters", "k1"]),
      b: get_in(build, ["parameters", "b"]),
      method: get_in(build, ["parameters", "method"]),
      idf_method: get_in(build, ["parameters", "idf_method"]),
      stopwords: get_in(build, ["parameters", "stopwords"]),
      stemmer: build["parameters"]["stemmer"] |> String.split("/") |> List.last(),
      platform: build["platform"],
      dependency_lock_sha256: build["dependency_lock_sha256"]
    }

    unless actual == expected and build["actual_tree_sha256"] == @index_build_instance_sha256 do
      raise ArgumentError, "HoVer retrieval build receipt does not match this condition"
    end
  end

  defp verify_split_receipt!(path) do
    receipt = path |> File.read!() |> Jason.decode!()

    family =
      case receipt["families"] do
        [%{"family" => "hoverBench"} = family] -> family
        _other -> raise ArgumentError, "HoVer split receipt must contain exactly hoverBench"
      end

    expected_checksums = %{
      "train" => "sha256:" <> @split_sha256.train,
      "dev" => "sha256:" <> @split_sha256.selection,
      "test" => "sha256:" <> @split_sha256.test
    }

    lineage = family["split_lineage"] || %{}

    valid? =
      family["split_policy"] ==
        "released_split_with_content_identity_overlap_removed" and
        family["split_checksums"] == expected_checksums and
        get_in(lineage, ["released_split_sha256", "dev"]) ==
          @released_split_sha256.selection and
        get_in(lineage, ["skipped", "dev"]) == [
          %{
            "content_sha256" => @removed_duplicate_sha256,
            "released_position" => 57
          }
        ] and
        get_in(lineage, ["replacements", "dev"]) == [
          %{
            "content_sha256" => @replacement_sha256,
            "source_pool_position" => 1_101
          }
        ]

    unless valid? do
      raise ArgumentError, "HoVer identity-disjoint split receipt does not match this condition"
    end
  end

  defp verify_identity_disjoint!(data_root) do
    identities =
      for split <- ~w(train dev test),
          line <- Path.join(data_root, "#{split}.jsonl") |> File.stream!() do
        line
        |> Jason.decode!()
        |> Imp.Optimizer.Report.encode_term()
        |> Imp.Experiment.Data.digest()
      end

    unless length(identities) == MapSet.size(MapSet.new(identities)) do
      raise ArgumentError, "HoVer train, selection, and test rows are not content-disjoint"
    end
  end

  defp verify_fingerprint!(path) do
    unless file_sha256(path) == @fingerprint_sha256 do
      raise ArgumentError,
            "HoVer frozen-claim retrieval fingerprint does not match this condition"
    end

    records = path |> File.stream!() |> Enum.map(&Jason.decode!/1)

    expected_positions =
      Enum.map(0..(@train_size - 1), &{"train", &1}) ++
        Enum.map(0..(@selection_size - 1), &{"dev", &1})

    actual_positions = Enum.map(records, &{&1["split"], &1["split_position"]})

    valid? =
      actual_positions == expected_positions and
        Enum.all?(records, fn record ->
          Map.keys(record) |> Enum.sort() ==
            ~w(claim_sha256 doc_ids row_sha256 split split_position titles) and
            length(record["doc_ids"]) == 24 and length(record["titles"]) == 24
        end)

    unless valid? do
      raise ArgumentError, "HoVer frozen-claim retrieval fingerprint shape is invalid"
    end
  end

  def provider_disabled_lifecycle!(root, seed) when seed in @seeds do
    File.mkdir_p!(root)
    program = provider_disabled_program()
    metric = provider_disabled_metric()
    data = provider_disabled_data()
    {optimizer, reflection_recorder} = provider_disabled_optimizer(metric, seed)
    artifact_path = Path.join(root, "artifact-#{seed}.json")
    result_path = Path.join(root, "result-#{seed}.json")
    receipt_path = Path.join(root, "fresh-#{seed}.json")

    {result, reflection_records} =
      try do
        {:ok, result} =
          Imp.Experiment.check(program, optimizer, data, metric,
            artifact_id: "hover-no-merge-#{seed}",
            compare_baseline_on_test: true,
            evaluation_options: [repetitions: @repetitions, aggregation: :mean, max_errors: 0],
            config: %{condition: design().condition, seed: seed}
          )

        {result, Agent.get(reflection_recorder, & &1.prompts)}
      after
        Agent.stop(reflection_recorder)
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
      reflection_prompt_census: reflection_prompt_census!(reflection_records),
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
    {:ok, recorder} = Agent.start_link(fn -> %{calls: 0, prompts: []} end)

    reflection_lm =
      Imp.LM.Static.new(
        handler: fn messages, _opts ->
          rendered = canonical_messages(messages)

          call =
            Agent.get_and_update(recorder, fn state ->
              call = state.calls + 1
              prompt = %{call: call, bytes: byte_size(rendered), sha256: sha256(rendered)}
              {call, %{state | calls: call, prompts: state.prompts ++ [prompt]}}
            end)

          if call <= 4, do: "```Improved.```", else: "```Worse.```"
        end
      )

    envelope = GEPA.v014_budget_envelope(4, 3, 50)

    optimizer =
      GEPA.new(metric,
        execution_profile: :gepa_v0_1_4,
        reflection_record_mode: :gepa_v0_1_4,
        reflection_lm: reflection_lm,
        component_feedback: Imp.BenchmarkTruth.HoverFeedback.callbacks(),
        module_selector: :round_robin,
        use_merge: false,
        minibatch_size: 3,
        generations: 5,
        max_metric_calls: 50,
        max_reflection_calls: envelope.max_reflection_calls,
        seed: seed,
        max_concurrency: 1
      )

    {optimizer, recorder}
  end

  defp reflection_prompt_census!(records, scope \\ :compact_three_row_four_stage_traces) do
    bytes = records |> Enum.map(& &1.bytes) |> Enum.sort()
    max_bytes = Enum.max(bytes)
    planning_bytes = synthetic_reflection_planning_bytes()

    if max_bytes > @reflection_guard.max_input_bytes do
      raise Imp.OperationalSafetyError,
        kind: :budget,
        message:
          "observed provider-free HoVer reflection prompt exceeds the candidate byte guard",
        reason: %{
          observed_max_bytes: max_bytes,
          guard_bytes: @reflection_guard.max_input_bytes
        }
    end

    %{
      scope: scope,
      serialization: :canonical_role_content_json_v1,
      count: length(bytes),
      bytes: bytes,
      observed_provider_free: %{
        p50_bytes: nearest_rank(bytes, 0.50),
        p95_bytes: nearest_rank(bytes, 0.95),
        max_bytes: max_bytes,
        live_distribution_claim: false
      },
      synthetic_planning_case: %{
        rendered_bytes: planning_bytes,
        records: 3,
        per_record_input_bytes: @task_guard.max_input_bytes,
        per_record_output_bytes: @task_output_byte_cap,
        per_record_feedback_bytes: @feedback_byte_cap,
        candidate_instruction_bytes: @reflection_output_byte_cap
      },
      guard_bytes: @reflection_guard.max_input_bytes,
      context_tokens: 1_000_000,
      max_output_tokens: @reflection_guard.max_output_tokens,
      guard_status: :candidate_pending_real_request_builders,
      context_safety_proven: false,
      prompts: records
    }
  end

  defp synthetic_reflection_planning_bytes do
    record = %{
      "Inputs" => %{"bounded_task_input" => String.duplicate("i", @task_guard.max_input_bytes)},
      "Generated Outputs" => %{
        "bounded_task_output" => String.duplicate("o", @task_output_byte_cap)
      },
      "Feedback" => String.duplicate("f", @feedback_byte_cap)
    }

    @reflection_output_byte_cap
    |> then(&String.duplicate("c", &1))
    |> Imp.Optimizer.GEPA.InstructionProposal.messages(
      List.duplicate(record, 3),
      nil,
      :gepa_v0_1_4,
      %{
        "Inputs" => ["bounded_task_input"],
        "Generated Outputs" => ["bounded_task_output"]
      }
    )
    |> canonical_messages()
    |> byte_size()
  end

  defp nearest_rank(sorted, probability) do
    Enum.at(sorted, max(ceil(length(sorted) * probability) - 1, 0))
  end

  defp canonical_messages(messages) do
    messages
    |> Enum.map(fn message ->
      %{
        "content" => Map.fetch!(message, :content),
        "role" => message |> Map.fetch!(:role) |> to_string()
      }
    end)
    |> Imp.Training.ChatDataset.canonical_json()
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

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp line_count(path) do
    path |> File.stream!([], :line) |> Enum.count()
  end

  defp first_jsonl!(path) do
    path |> File.stream!() |> Enum.at(0) |> Jason.decode!()
  end

  defp reservation_usd(task_calls, reflection_calls) do
    task =
      task_calls *
        (@task_guard.reservation_tokens / 1_000_000 * @task_input_price_per_million +
           @task_guard.max_output_tokens / 1_000_000 * @task_output_price_per_million)

    reflection =
      reflection_calls *
        (@reflection_guard.reservation_tokens / 1_000_000 *
           @reflection_input_price_per_million +
           @reflection_guard.max_output_tokens / 1_000_000 *
             @reflection_output_price_per_million)

    task + reflection
  end

  defp exact_endpoint!(:task, endpoints, label) when is_list(endpoints) do
    matches = Enum.filter(endpoints, &(&1["tag"] == @candidate_endpoint_tag))

    case matches do
      [endpoint] ->
        required = ~w(reasoning temperature top_p max_tokens)
        supported = endpoint["supported_parameters"] || []

        valid? =
          endpoint["name"] == @candidate_endpoint_name and
            endpoint["model_id"] == @candidate_model and
            endpoint["provider_name"] == @candidate_provider and
            endpoint["quantization"] == "fp8" and endpoint["status"] == 0 and
            endpoint["supports_implicit_caching"] == false and
            get_in(endpoint, ["pricing", "prompt"]) == "0.00000014" and
            get_in(endpoint, ["pricing", "completion"]) == "0.00000028" and
            Enum.all?(required, &(&1 in supported))

        unless valid?, do: raise(ArgumentError, "HoVer candidate #{label} endpoint drift")
        endpoint

      _other ->
        raise ArgumentError, "HoVer candidate #{label} must contain one exact endpoint"
    end
  end

  defp exact_endpoint!(:reflection, endpoints, label) when is_list(endpoints) do
    matches = Enum.filter(endpoints, &(&1["tag"] == @reflection_endpoint_tag))

    case matches do
      [endpoint] ->
        required = ~w(reasoning reasoning_effort max_tokens)
        supported = endpoint["supported_parameters"] || []

        valid? =
          endpoint["name"] == @reflection_endpoint_name and
            endpoint["model_id"] == @reflection_model and
            endpoint["provider_name"] == @reflection_provider and
            endpoint["status"] == 0 and endpoint["supports_implicit_caching"] == false and
            endpoint["context_length"] == 1_000_000 and
            get_in(endpoint, ["pricing", "prompt"]) == "0.000002" and
            get_in(endpoint, ["pricing", "completion"]) == "0.00001" and
            "temperature" not in supported and
            Enum.all?(required, &(&1 in supported))

        unless valid?, do: raise(ArgumentError, "HoVer candidate #{label} endpoint drift")
        endpoint

      _other ->
        raise ArgumentError, "HoVer candidate #{label} must contain one exact endpoint"
    end
  end

  defp exact_endpoint!(_role, _endpoints, label),
    do: raise(ArgumentError, "HoVer candidate #{label} endpoint list is malformed")

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
