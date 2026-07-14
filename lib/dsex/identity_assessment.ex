defmodule DSEx.IdentityAssessment do
  @moduledoc false

  alias DSEx.Clients.ReqLLM, as: ReqLLMClient
  alias DSEx.{IdentityCheckpoint, IdentityEvaluation}

  @runner_version 1
  @default_batch_size 8
  @default_concurrency 3
  @default_timeout 120_000
  @default_max_tokens 8_000
  @default_checkpoint_every 10
  @max_reasoning_chars 4_000
  @atlas_refs [
    "identity/atlas.json#assessment-axes",
    "identity/atlas.json#product-boundary"
  ]
  @secret_option_keys ~w(api_key authorization headers access_token auth token test_pid)a
  @reserved_call_option_keys ~w(identity_schema identity_req_llm_module req_module)a

  @type profile :: %{
          required(:id) => String.t(),
          required(:model) => String.t(),
          optional(:name) => String.t(),
          optional(:options) => keyword()
        }

  @type run_input :: %{
          required(:registry) => [map()],
          required(:atlas) => map(),
          optional(:enrichments) => [map()],
          optional(:flags) => [map()],
          optional(:collisions) => [map()],
          optional(:assessments) => [map()]
        }

  @doc """
  Runs or plans model assessments over in-memory identity artifacts.

  Profiles are maps with `:id`, `:model`, and optional `:name` and `:options`.
  Tests may inject an `:assessor` function of arity two. It receives the
  normalized profile and a request containing `:messages`, `:schema`, and
  `:candidate_ids` and must return `{:ok, response}` or `{:error, reason}`.
  """
  @spec run(run_input(), keyword()) :: map()
  def run(input, opts \\ []) when is_map(input) and is_list(opts) do
    config = run_config!(opts)
    context = build_context!(input, config)
    work = build_work(context, config)
    plan = Enum.map(work, &work_plan/1)

    base = %{
      "mode" => if(config.dry_run?, do: "plan", else: "live"),
      "assessment_kind" => "model_assessment_not_user_research",
      "runner_version" => @runner_version,
      "atlas_version" => context.atlas["atlas_version"],
      "atlas_digest" => context.atlas_digest,
      "profiles" => Enum.map(context.profiles, &profile_report/1),
      "plan" => plan,
      "input" => context.input_report
    }

    if config.dry_run? do
      Map.put(base, "summary", summary(context, work, nil))
    else
      execute(base, context, work, config)
    end
  end

  @doc """
  Loads JSON/JSONL artifacts, runs assessments, and atomically checkpoints
  append-only assessment and run/error ledgers.
  """
  @spec run_files!(keyword()) :: map()
  def run_files!(opts \\ []) when is_list(opts) do
    paths = file_paths!(opts)
    ensure_distinct_paths!(paths)

    {assessments, assessment_body} = load_jsonl_with_body!(paths.out, optional: true)
    {_run_events, run_body} = load_jsonl_with_body!(paths.runs_out, optional: true)

    input = %{
      registry: IdentityEvaluation.load_jsonl!(paths.registry),
      enrichments: load_many_jsonl!(paths.enrichments),
      flags: load_many_jsonl!(paths.flags),
      collisions: load_many_jsonl!(paths.collisions),
      assessments: assessments,
      atlas: paths.atlas |> File.read!() |> Jason.decode!()
    }

    checkpoint = fn records, events ->
      checkpoint_files!(paths, assessment_body, run_body, records, events)
    end

    run_opts =
      opts
      |> Keyword.drop([
        :registry,
        :enrichments,
        :flags,
        :collisions,
        :atlas,
        :out,
        :runs_out
      ])
      |> Keyword.put(:checkpoint, checkpoint)

    run(input, run_opts)
  end

  defp execute(base, context, work, config) do
    started_at = now_iso8601()
    run_id = run_id(started_at, context, config)

    started_event = %{
      "event_type" => "identity_assessment_run_started",
      "run_id" => run_id,
      "occurred_at" => started_at,
      "assessment_kind" => "model_assessment_not_user_research",
      "runner_version" => @runner_version,
      "atlas_digest" => context.atlas_digest,
      "profiles" => Enum.map(context.profiles, &profile_report/1),
      "planned_batches" => length(work),
      "planned_records" => Enum.sum(Enum.map(work, &length(&1.candidates)))
    }

    state = %{
      record_batches: [],
      failures: [],
      events: [started_event],
      attempted_batches: 0,
      succeeded_batches: 0,
      failed_batches: 0,
      succeeded_records: 0,
      failed_records: 0
    }

    checkpoint!(config, state)

    stream =
      Task.async_stream(work, &assess_work(&1, config),
        max_concurrency: config.concurrency,
        ordered: true,
        timeout: config.timeout,
        on_timeout: :kill_task
      )

    state =
      work
      |> Stream.zip(stream)
      |> Stream.with_index(1)
      |> Enum.reduce(state, fn {{unit, result}, index}, acc ->
        next = consume_result(acc, unit, result, run_id)

        if rem(index, config.checkpoint_every) == 0 do
          checkpoint!(config, next)
        end

        next
      end)

    completed_at = now_iso8601()
    final_summary = summary(context, work, state)

    completed_event = %{
      "event_type" => "identity_assessment_run_completed",
      "run_id" => run_id,
      "occurred_at" => completed_at,
      "summary" => final_summary
    }

    state = %{state | events: [completed_event | state.events]}
    checkpoint!(config, state)

    base
    |> Map.put("run_id", run_id)
    |> Map.put("started_at", started_at)
    |> Map.put("completed_at", completed_at)
    |> Map.put("summary", final_summary)
    |> Map.put("records", flatten_batches(state.record_batches))
    |> Map.put("failures", Enum.reverse(state.failures))
  end

  defp assess_work(unit, config) do
    request = assessment_request(unit, config)

    with {:ok, response} <- invoke_assessor(unit.profile, request, config),
         {:ok, returned} <- parse_response(response),
         {:ok, assessments} <- validate_response(returned, unit) do
      assessed_at = now_iso8601()

      records =
        Enum.map(assessments, fn assessment ->
          candidate = Map.fetch!(unit.candidates_by_id, assessment["candidate_id"])
          assessment_record(assessment, candidate, unit.profile, assessed_at)
        end)

      {:ok, Enum.sort_by(records, & &1["candidate_id"])}
    else
      {:error, reason} -> {:error, normalize_failure(reason, response_excerpt(reason))}
    end
  rescue
    error -> {:error, exception_failure(:error, error, __STACKTRACE__)}
  catch
    kind, reason -> {:error, exception_failure(kind, reason, __STACKTRACE__)}
  end

  defp invoke_assessor(profile, request, %{assessor: assessor}) when is_function(assessor, 2) do
    normalize_assessor_result(assessor.(profile, request))
  end

  defp invoke_assessor(profile, request, config) do
    lm =
      ReqLLMClient.new(profile.model,
        req_module: DSEx.IdentityAssessment.ReqLLMTransport
      )

    call_opts =
      profile.options
      |> Keyword.drop(@reserved_call_option_keys)
      |> Keyword.put(:timeout, config.timeout)
      |> Keyword.put(:max_tokens, config.max_tokens)
      |> Keyword.put(:cache, false)
      |> Keyword.put(:identity_schema, request.schema)
      |> Keyword.put(:identity_req_llm_module, config.req_llm_module)

    lm
    |> ReqLLMClient.generate(request.messages, call_opts)
    |> normalize_assessor_result()
  end

  defp normalize_assessor_result({:ok, _response} = result), do: result
  defp normalize_assessor_result({:error, reason}), do: {:error, transport_failure(reason)}

  defp normalize_assessor_result(other) do
    {:error,
     %{
       "kind" => "invalid_assessor_result",
       "message" => "assessor returned #{inspect_limited(other)}"
     }}
  end

  defp consume_result(state, unit, {:ok, {:ok, records}}, run_id) do
    event = %{
      "event_type" => "identity_assessment_batch_completed",
      "run_id" => run_id,
      "occurred_at" => now_iso8601(),
      "profile_id" => unit.profile.id,
      "model" => unit.profile.model,
      "candidate_ids" => Enum.map(unit.candidates, & &1["candidate_id"]),
      "assessment_ids" => Enum.map(records, & &1["id"])
    }

    %{
      state
      | record_batches: [records | state.record_batches],
        events: [event | state.events],
        attempted_batches: state.attempted_batches + 1,
        succeeded_batches: state.succeeded_batches + 1,
        succeeded_records: state.succeeded_records + length(records)
    }
  end

  defp consume_result(state, unit, {:ok, {:error, failure}}, run_id) do
    record_failure(state, unit, failure, run_id)
  end

  defp consume_result(state, unit, {:exit, reason}, run_id) do
    failure = %{
      "kind" => if(reason == :timeout, do: "timeout", else: "task_exit"),
      "message" => inspect_limited(reason)
    }

    record_failure(state, unit, failure, run_id)
  end

  defp record_failure(state, unit, failure, run_id) do
    event = %{
      "event_type" => "identity_assessment_batch_failed",
      "run_id" => run_id,
      "occurred_at" => now_iso8601(),
      "profile_id" => unit.profile.id,
      "model" => unit.profile.model,
      "candidate_ids" => Enum.map(unit.candidates, & &1["candidate_id"]),
      "failure" => failure
    }

    %{
      state
      | failures: [event | state.failures],
        events: [event | state.events],
        attempted_batches: state.attempted_batches + 1,
        failed_batches: state.failed_batches + 1,
        failed_records: state.failed_records + length(unit.candidates)
    }
  end

  defp summary(context, work, nil) do
    %{
      "candidate_entities" => length(context.candidates),
      "profiles" => length(context.profiles),
      "expected_records" => length(context.candidates) * length(context.profiles),
      "existing_complete_records" => context.skipped,
      "pending_records" => Enum.sum(Enum.map(work, &length(&1.candidates))),
      "planned_batches" => length(work),
      "attempted_batches" => 0,
      "succeeded_batches" => 0,
      "failed_batches" => 0,
      "succeeded_records" => 0,
      "failed_records" => 0,
      "complete_records_after_run" => context.skipped
    }
  end

  defp summary(context, work, state) do
    %{
      "candidate_entities" => length(context.candidates),
      "profiles" => length(context.profiles),
      "expected_records" => length(context.candidates) * length(context.profiles),
      "existing_complete_records" => context.skipped,
      "pending_records" => Enum.sum(Enum.map(work, &length(&1.candidates))),
      "planned_batches" => length(work),
      "attempted_batches" => state.attempted_batches,
      "succeeded_batches" => state.succeeded_batches,
      "failed_batches" => state.failed_batches,
      "succeeded_records" => state.succeeded_records,
      "failed_records" => state.failed_records,
      "complete_records_after_run" => context.skipped + state.succeeded_records
    }
  end

  defp build_context!(input, config) do
    registry = fetch_list!(input, :registry)
    atlas = fetch_map!(input, :atlas)
    enrichments = active_records(optional_list!(input, :enrichments))
    flags = active_records(optional_list!(input, :flags))
    collisions = current_collisions(optional_list!(input, :collisions))
    existing = optional_list!(input, :assessments)
    profiles = normalize_profiles!(config.profiles)
    {axis_ids, atlas_digest} = atlas_identity!(atlas)

    all_candidates =
      registry
      |> candidate_contexts(atlas, enrichments, flags, collisions)
      |> Enum.map(&Map.put(&1, "evidence_digest", stable_digest(&1)))

    all_candidate_ids = MapSet.new(all_candidates, & &1["candidate_id"])

    candidates =
      all_candidates
      |> select_candidates!(config.candidate_ids, config.limit)
      |> Enum.map(fn candidate ->
        assessment_ids =
          Map.new(profiles, fn profile ->
            {profile.id,
             assessment_id(
               candidate["candidate_id"],
               candidate["evidence_digest"],
               profile,
               atlas_digest
             )}
          end)

        Map.put(candidate, "assessment_ids", assessment_ids)
      end)

    ensure_unique_existing_ids!(existing)
    {completed, skipped} = completed_pairs!(existing, candidates, profiles, axis_ids)

    %{
      registry: registry,
      atlas: atlas,
      axis_ids: axis_ids,
      atlas_digest: atlas_digest,
      candidates: candidates,
      profiles: profiles,
      completed: completed,
      skipped: skipped,
      input_report: %{
        "registry_events" => length(registry),
        "active_enrichments" => length(enrichments),
        "active_flags" => length(flags),
        "current_collision_checks" => length(collisions),
        "existing_assessments" => length(existing),
        "registry_candidate_entities" => length(all_candidates),
        "selected_candidate_entities" => length(candidates),
        "orphan_enrichments" => orphan_count(enrichments, all_candidate_ids),
        "orphan_flags" => orphan_count(flags, all_candidate_ids),
        "orphan_collision_checks" => orphan_count(collisions, all_candidate_ids)
      }
    }
  end

  defp candidate_contexts(registry, atlas, enrichments, flags, collisions) do
    entities = IdentityEvaluation.candidate_entities(registry)

    if map_size(entities) == 0 do
      raise ArgumentError, "registry contains no candidate_observed events"
    end

    observations =
      registry
      |> Enum.filter(&(&1["event_type"] == "candidate_observed"))
      |> Enum.group_by(& &1["candidate_id"])

    evidence = %{
      enrichments: Enum.group_by(enrichments, & &1["candidate_id"]),
      flags: Enum.group_by(flags, & &1["candidate_id"]),
      collisions: Enum.group_by(collisions, & &1["candidate_id"])
    }

    lookups = %{
      territories: index_atlas(atlas, "territories"),
      strategies: index_atlas(atlas, "lexical_strategies"),
      audiences: index_atlas(atlas, "audiences"),
      architectures: index_atlas(atlas, "brand_architectures")
    }

    entities
    |> Enum.map(fn {candidate_id, entity} ->
      unless is_binary(candidate_id) and String.match?(candidate_id, ~r/^cand-[a-f0-9]{16}$/) do
        raise ArgumentError, "invalid registry candidate_id: #{inspect(candidate_id)}"
      end

      candidate_observations = Map.get(observations, candidate_id, [])
      enrichments_for_candidate = Map.get(evidence.enrichments, candidate_id, [])
      flags_for_candidate = Map.get(evidence.flags, candidate_id, [])
      collisions_for_candidate = Map.get(evidence.collisions, candidate_id, [])

      audience_ids = observation_ids(candidate_observations, "audience_lenses")
      architecture_ids = observation_ids(candidate_observations, "architecture_lenses")

      evidence_refs =
        @atlas_refs ++
          evidence_ids(candidate_observations, "occurrence_id") ++
          evidence_ids(enrichments_for_candidate, "id") ++
          evidence_ids(flags_for_candidate, "id") ++
          evidence_ids(collisions_for_candidate, "id")

      %{
        "candidate_id" => candidate_id,
        "display" => entity["display"],
        "normalized" => entity["normalized"],
        "surfaces" => entity["surfaces"],
        "run_ids" => entity["run_ids"],
        "wildcard" => entity["wildcard"],
        "territories" => resolved_atlas(entity["territories"], lookups.territories),
        "strategies" => resolved_atlas(entity["strategies"], lookups.strategies),
        "audiences" => resolved_atlas(audience_ids, lookups.audiences),
        "architectures" => resolved_atlas(architecture_ids, lookups.architectures),
        "observations" => Enum.map(candidate_observations, &observation_payload/1),
        "enrichments" => enrichments_for_candidate,
        "flags" => Enum.map(flags_for_candidate, &flag_payload/1),
        "collision_checks" => Enum.map(collisions_for_candidate, &collision_payload/1),
        "allowed_evidence_refs" => evidence_refs |> Enum.uniq() |> Enum.sort()
      }
    end)
    |> Enum.sort_by(& &1["candidate_id"])
  end

  defp build_work(context, config) do
    candidates_by_id = Map.new(context.candidates, &{&1["candidate_id"], &1})

    context.profiles
    |> Enum.flat_map(fn profile ->
      pending =
        Enum.reject(context.candidates, fn candidate ->
          MapSet.member?(context.completed, {profile.id, candidate["candidate_id"]})
        end)

      pending
      |> Enum.chunk_every(config.batch_size)
      |> Enum.map(fn candidates ->
        %{
          profile: profile,
          candidates: candidates,
          candidates_by_id: candidates_by_id,
          atlas: atlas_prompt(context.atlas),
          axis_ids: context.axis_ids
        }
      end)
    end)
  end

  defp assessment_request(unit, config) do
    schema = response_schema(unit.candidates, unit.axis_ids)

    payload = %{
      "assessment_kind" => "model_assessment_not_user_research",
      "instructions" => [
        "Return one assessment for every supplied candidate and no others.",
        "Score every atlas axis from 0 to 5; higher is always more favorable.",
        "Assess the evidence supplied. Do not present these model judgments as user research.",
        "Start each concise reasoning string with the candidate's exact display surface.",
        "Keep each reasoning string under #{@max_reasoning_chars} characters.",
        "Use only that candidate's allowed_evidence_refs, and cite at least one.",
        "Do not rank, select, rename, merge, or suppress candidates."
      ],
      "atlas" => unit.atlas,
      "candidates" => Enum.map(unit.candidates, &prompt_candidate/1)
    }

    %{
      schema: schema,
      candidate_ids: Enum.map(unit.candidates, & &1["candidate_id"]),
      messages: [
        %{
          role: :system,
          content:
            "You are a critical identity assessor for an Elixir/BEAM language-model programming project. Produce evidence-bounded model assessments, not claims of user research."
        },
        %{role: :user, content: Jason.encode!(payload)}
      ],
      timeout: config.timeout
    }
  end

  defp response_schema(candidates, axis_ids) do
    score_properties =
      Map.new(axis_ids, &{&1, %{"type" => "number", "minimum" => 0, "maximum" => 5}})

    assessment = %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["candidate_id", "scores", "confidence", "reasoning", "evidence_refs"],
      "properties" => %{
        "candidate_id" => %{
          "type" => "string",
          "enum" => Enum.map(candidates, & &1["candidate_id"])
        },
        "scores" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => axis_ids,
          "properties" => score_properties
        },
        "confidence" => %{"type" => "number", "minimum" => 0, "maximum" => 1},
        "reasoning" => %{
          "type" => "string",
          "minLength" => 1,
          "maxLength" => @max_reasoning_chars
        },
        "evidence_refs" => %{
          "type" => "array",
          "minItems" => 1,
          "items" => %{"type" => "string"}
        }
      }
    }

    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["assessments"],
      "properties" => %{
        "assessments" => %{
          "type" => "array",
          "minItems" => length(candidates),
          "maxItems" => length(candidates),
          "items" => assessment
        }
      }
    }
  end

  defp parse_response(response) do
    with {:ok, output} <- DSEx.LM.Result.output(response) do
      output
      |> unwrap_response()
      |> decode_response()
    end
  end

  defp unwrap_response(%{tool_calls: [call]}), do: unwrap_tool_call(call)
  defp unwrap_response(%{"tool_calls" => [call]}), do: unwrap_tool_call(call)
  defp unwrap_response(response), do: response

  defp unwrap_tool_call(%{arguments: arguments}), do: unwrap_response(arguments)
  defp unwrap_tool_call(%{"arguments" => arguments}), do: unwrap_response(arguments)
  defp unwrap_tool_call(call), do: call

  defp decode_response(response) when is_map(response) do
    {:ok, response |> stringify_keys() |> decode_nested_assessments()}
  end

  defp decode_response(response) when is_list(response) do
    {:ok, %{"assessments" => stringify_keys(response)}}
  end

  defp decode_response(response) when is_binary(response) do
    response
    |> json_text_candidates()
    |> Enum.reduce_while({:error, invalid_json_failure(response)}, fn text, _acc ->
      case Jason.decode(text) do
        {:ok, decoded} -> {:halt, decode_response(decoded)}
        {:error, _error} -> {:cont, {:error, invalid_json_failure(response)}}
      end
    end)
  end

  defp decode_response(response) do
    {:error,
     %{
       "kind" => "invalid_response_type",
       "message" => "expected a structured object or JSON text, got #{inspect_limited(response)}"
     }}
  end

  defp decode_nested_assessments(%{"assessments" => assessments} = response)
       when is_binary(assessments) do
    case Jason.decode(assessments) do
      {:ok, decoded} when is_list(decoded) ->
        Map.put(response, "assessments", stringify_keys(decoded))

      _ ->
        response
    end
  end

  defp decode_nested_assessments(response), do: response

  defp json_text_candidates(text) do
    trimmed = String.trim(text)

    fenced =
      case Regex.run(~r/\A```(?:json)?\s*(.*?)\s*```\z/s, trimmed, capture: :all_but_first) do
        [body] -> [body]
        _ -> []
      end

    embedded =
      case Regex.run(~r/(\{.*\}|\[.*\])/s, trimmed, capture: :all_but_first) do
        [body] -> [body]
        _ -> []
      end

    [trimmed | fenced ++ embedded] |> Enum.reject(&(&1 == "")) |> Enum.uniq()
  end

  defp validate_response(%{"assessments" => assessments} = response, unit)
       when is_list(assessments) do
    errors =
      []
      |> maybe_error(
        Map.keys(response) != ["assessments"],
        "response object must contain only assessments"
      )
      |> Kernel.++(validate_candidate_set(assessments, unit))
      |> Kernel.++(Enum.flat_map(assessments, &validate_assessment(&1, unit)))

    if errors == [] do
      {:ok, Enum.map(assessments, &canonical_assessment/1)}
    else
      {:error, validation_failure(errors, response)}
    end
  end

  defp validate_response(response, _unit) do
    {:error,
     validation_failure(["response must be an object containing an assessments array"], response)}
  end

  defp validate_candidate_set(assessments, unit) do
    expected = Enum.map(unit.candidates, & &1["candidate_id"])
    returned = Enum.map(assessments, &if(is_map(&1), do: &1["candidate_id"], else: nil))

    []
    |> maybe_error(length(returned) != length(expected), "assessment count does not match batch")
    |> maybe_error(
      Enum.sort(returned) != Enum.sort(expected),
      "candidate IDs must exactly match the requested batch"
    )
    |> maybe_error(length(Enum.uniq(returned)) != length(returned), "duplicate candidate IDs")
  end

  defp validate_assessment(assessment, unit) when is_map(assessment) do
    candidate_id = assessment["candidate_id"]
    candidate = Map.get(unit.candidates_by_id, candidate_id)
    scores = assessment["scores"]
    confidence = assessment["confidence"]
    reasoning = assessment["reasoning"]
    refs = assessment["evidence_refs"]

    score_keys = if is_map(scores), do: Map.keys(scores), else: []
    allowed_refs = if candidate, do: candidate["allowed_evidence_refs"], else: []

    []
    |> maybe_error(
      Map.keys(assessment) |> Enum.sort() !=
        ~w(candidate_id confidence evidence_refs reasoning scores),
      "#{candidate_id || "<missing>"}: unexpected or missing assessment fields"
    )
    |> maybe_error(is_nil(candidate), "unknown candidate ID #{inspect(candidate_id)}")
    |> maybe_error(not is_map(scores), "#{candidate_id}: scores must be an object")
    |> maybe_error(
      Enum.sort(score_keys) != Enum.sort(unit.axis_ids),
      "#{candidate_id}: scores must contain the exact atlas axis set"
    )
    |> maybe_error(not valid_scores?(scores), "#{candidate_id}: every score must be in 0..5")
    |> maybe_error(
      not valid_range?(confidence, 0, 1),
      "#{candidate_id}: confidence must be in 0..1"
    )
    |> maybe_error(
      not concise_reasoning?(reasoning),
      "#{candidate_id}: reasoning must contain 1..#{@max_reasoning_chars} characters"
    )
    |> maybe_error(
      candidate && not mentions_surface?(reasoning, candidate["display"]),
      "#{candidate_id}: reasoning must mention the exact display surface"
    )
    |> maybe_error(not valid_refs?(refs), "#{candidate_id}: evidence_refs must be unique strings")
    |> maybe_error(refs == [], "#{candidate_id}: at least one evidence_ref is required")
    |> maybe_error(
      is_list(refs) and Enum.any?(refs, &(&1 not in allowed_refs)),
      "#{candidate_id}: evidence_refs contain values outside allowed_evidence_refs"
    )
  end

  defp validate_assessment(value, _unit),
    do: ["assessment entries must be objects, got #{inspect_limited(value)}"]

  defp canonical_assessment(assessment) do
    %{
      "candidate_id" => assessment["candidate_id"],
      "scores" => assessment["scores"],
      "confidence" => assessment["confidence"] / 1,
      "reasoning" => String.trim(assessment["reasoning"]),
      "evidence_refs" => assessment["evidence_refs"] |> Enum.uniq() |> Enum.sort()
    }
  end

  defp assessment_record(assessment, candidate, profile, assessed_at) do
    %{
      "id" => candidate["assessment_ids"][profile.id],
      "candidate_id" => candidate["candidate_id"],
      "assessed_at" => assessed_at,
      "assessor" => %{
        "kind" => "model",
        "name" => "Model assessment: #{profile.name}",
        "profile_id" => profile.id,
        "profile_digest" => profile.digest,
        "provider" => profile.provider,
        "model" => profile.model,
        "requested_model" => profile.requested_model,
        "evidence_digest" => candidate["evidence_digest"],
        "transport" => "DSEx.Clients.ReqLLM via ReqLLM"
      },
      "context" => %{},
      "scores" => assessment["scores"],
      "confidence" => assessment["confidence"],
      "reasoning" => assessment["reasoning"],
      "evidence_refs" => assessment["evidence_refs"],
      "supersedes" => nil
    }
  end

  defp completed_pairs!(existing, candidates, profiles, axis_ids) do
    expected =
      for candidate <- candidates, profile <- profiles, into: %{} do
        id = candidate["assessment_ids"][profile.id]
        {id, {profile, candidate}}
      end

    Enum.reduce(existing, {MapSet.new(), 0}, fn record, acc ->
      consume_existing_record(record, Map.get(expected, record["id"]), axis_ids, acc)
    end)
  end

  defp consume_existing_record(_record, nil, _axis_ids, acc), do: acc

  defp consume_existing_record(record, {profile, candidate}, axis_ids, {completed, count}) do
    if complete_record?(record, profile, candidate, axis_ids) do
      {MapSet.put(completed, {profile.id, candidate["candidate_id"]}), count + 1}
    else
      raise ArgumentError,
            "existing assessment #{record["id"]} conflicts with its deterministic ID but is incomplete"
    end
  end

  defp complete_record?(record, profile, candidate, axis_ids) do
    assessor = record["assessor"] || %{}
    scores = record["scores"]

    Enum.all?([
      complete_record_identity?(record, candidate),
      complete_record_assessor?(assessor, profile, candidate),
      complete_record_scores?(scores, axis_ids),
      complete_record_judgment?(record, candidate),
      Map.has_key?(record, "supersedes") and is_nil(record["supersedes"])
    ])
  end

  defp complete_record_identity?(record, candidate) do
    record["candidate_id"] == candidate["candidate_id"] and
      valid_iso8601?(record["assessed_at"]) and is_map(record["context"])
  end

  defp complete_record_assessor?(assessor, profile, candidate) do
    assessor["kind"] == "model" and assessor["profile_id"] == profile.id and
      assessor["profile_digest"] == profile.digest and assessor["model"] == profile.model and
      assessor["evidence_digest"] == candidate["evidence_digest"]
  end

  defp complete_record_scores?(scores, axis_ids) do
    is_map(scores) and Enum.sort(Map.keys(scores)) == Enum.sort(axis_ids) and
      valid_scores?(scores)
  end

  defp complete_record_judgment?(record, candidate) do
    refs = record["evidence_refs"]

    valid_range?(record["confidence"], 0, 1) and
      concise_reasoning?(record["reasoning"]) and
      mentions_surface?(record["reasoning"], candidate["display"]) and valid_refs?(refs) and
      refs != [] and Enum.all?(refs, &(&1 in candidate["allowed_evidence_refs"]))
  end

  defp run_config!(opts) do
    unless Keyword.keyword?(opts), do: raise(ArgumentError, "options must be a keyword list")

    profiles = Keyword.get(opts, :profiles, [])

    batch_size =
      positive_integer!(Keyword.get(opts, :batch_size, @default_batch_size), :batch_size)

    concurrency =
      positive_integer!(Keyword.get(opts, :concurrency, @default_concurrency), :concurrency)

    timeout = positive_integer!(Keyword.get(opts, :timeout, @default_timeout), :timeout)

    max_tokens =
      positive_integer!(Keyword.get(opts, :max_tokens, @default_max_tokens), :max_tokens)

    checkpoint_every =
      positive_integer!(
        Keyword.get(opts, :checkpoint_every, @default_checkpoint_every),
        :checkpoint_every
      )

    assessor = Keyword.get(opts, :assessor)

    if assessor && not is_function(assessor, 2),
      do: raise(ArgumentError, ":assessor must have arity 2")

    req_llm_module = Keyword.get(opts, :req_llm_module, ReqLLM)

    unless is_atom(req_llm_module) do
      raise ArgumentError, ":req_llm_module must be a module atom"
    end

    checkpoint = Keyword.get(opts, :checkpoint)

    if checkpoint && not is_function(checkpoint, 2) do
      raise ArgumentError, ":checkpoint must have arity 2"
    end

    candidate_ids =
      opts
      |> Keyword.get(:candidate_ids, [])
      |> List.wrap()
      |> Enum.map(&to_string/1)
      |> Enum.uniq()

    limit = optional_positive_integer!(Keyword.get(opts, :limit), :limit)

    %{
      profiles: profiles,
      batch_size: batch_size,
      concurrency: concurrency,
      timeout: timeout,
      max_tokens: max_tokens,
      checkpoint_every: checkpoint_every,
      assessor: assessor,
      req_llm_module: req_llm_module,
      checkpoint: checkpoint,
      candidate_ids: candidate_ids,
      limit: limit,
      dry_run?: Keyword.get(opts, :dry_run, false) or Keyword.get(opts, :plan, false)
    }
  end

  defp normalize_profiles!(profiles) when is_list(profiles) and profiles != [] do
    normalized = Enum.map(profiles, &normalize_profile!/1)

    duplicate_ids = duplicate_values(normalized, & &1.id)

    if duplicate_ids != [],
      do: raise(ArgumentError, "duplicate profile IDs: #{Enum.join(duplicate_ids, ", ")}")

    normalized |> Enum.sort_by(& &1.id)
  end

  defp normalize_profiles!(_profiles),
    do: raise(ArgumentError, "at least one assessor profile is required")

  defp normalize_profile!(profile) when is_map(profile) do
    id = fetch_profile_value(profile, :id)
    requested_model = fetch_profile_value(profile, :model)
    name = fetch_profile_value(profile, :name) || id
    options = fetch_profile_value(profile, :options) || []

    validate_profile_id!(id)
    validate_profile_text!(requested_model, "profile #{id} must have a non-empty model spec")
    validate_profile_text!(name, "profile #{id} must have a non-empty name")
    validate_profile_options!(id, options)

    model = normalize_model_spec(requested_model)
    provider = model |> String.split(":", parts: 2) |> hd()
    options = provider_options(options, provider)
    digest = profile_digest(id, model, options)

    %{
      id: id,
      name: name,
      requested_model: requested_model,
      model: model,
      provider: provider,
      digest: digest,
      options: options
    }
  end

  defp normalize_profile!(profile),
    do: raise(ArgumentError, "profiles must be maps, got: #{inspect(profile)}")

  defp validate_profile_id!(id) do
    unless is_binary(id) and String.match?(id, ~r/^[a-z0-9][a-z0-9_-]*$/) do
      raise ArgumentError, "profile id must match [a-z0-9][a-z0-9_-]*, got: #{inspect(id)}"
    end
  end

  defp validate_profile_text!(value, message) do
    unless is_binary(value) and String.trim(value) != "", do: raise(ArgumentError, message)
  end

  defp validate_profile_options!(id, options) do
    unless Keyword.keyword?(options) do
      raise ArgumentError, "profile #{id} options must be a keyword list"
    end
  end

  # Accept the provider/family:model spelling used by some model catalogs while
  # passing ReqLLM its canonical provider:model form.
  defp normalize_model_spec("google/gemini:" <> model), do: "google:" <> model
  defp normalize_model_spec(model), do: model

  defp provider_options(options, "google") do
    case {Keyword.has_key?(options, :api_key), System.get_env("GEMINI_API_KEY")} do
      {false, key} when is_binary(key) and key != "" -> Keyword.put(options, :api_key, key)
      _ -> options
    end
  end

  defp provider_options(options, _provider), do: options

  defp profile_digest(id, model, options) do
    safe_options =
      options
      |> Keyword.drop(@secret_option_keys ++ @reserved_call_option_keys)
      |> Enum.sort()
      |> Enum.map(fn {key, value} -> {key, stable_term(value)} end)

    stable_digest({@runner_version, id, model, safe_options})
  end

  defp atlas_identity!(atlas) do
    axes = atlas["assessment_axes"]

    unless is_list(axes) and axes != [] do
      raise ArgumentError, "atlas assessment_axes must be a non-empty array"
    end

    axis_ids = Enum.map(axes, & &1["id"])

    if Enum.any?(axis_ids, &(not is_binary(&1) or &1 == "")) do
      raise ArgumentError, "every atlas assessment axis must have a non-empty id"
    end

    duplicates = duplicate_values(axis_ids, & &1)

    if duplicates != [],
      do: raise(ArgumentError, "duplicate atlas axes: #{Enum.join(duplicates, ", ")}")

    digest_input = {
      @runner_version,
      atlas["atlas_version"],
      atlas["product_boundary"],
      Enum.map(axes, &Map.take(&1, ["id", "label", "question"]))
    }

    {axis_ids, stable_digest(digest_input)}
  end

  defp assessment_id(candidate_id, evidence_digest, profile, atlas_digest) do
    digest =
      stable_digest(
        {@runner_version, candidate_id, evidence_digest, profile.digest, atlas_digest}
      )

    "assessment-model-" <> binary_part(digest, 0, 24)
  end

  defp select_candidates!(candidates, [], nil), do: candidates
  defp select_candidates!(candidates, [], limit), do: Enum.take(candidates, limit)

  defp select_candidates!(candidates, requested, limit) do
    known = MapSet.new(candidates, & &1["candidate_id"])
    unknown = Enum.reject(requested, &MapSet.member?(known, &1))

    if unknown != [] do
      raise ArgumentError, "unknown candidate IDs: #{Enum.join(unknown, ", ")}"
    end

    selected = Enum.filter(candidates, &(&1["candidate_id"] in requested))
    if limit, do: Enum.take(selected, limit), else: selected
  end

  defp atlas_prompt(atlas) do
    %{
      "atlas_version" => atlas["atlas_version"],
      "product_boundary" => atlas["product_boundary"],
      "assessment_axes" => atlas["assessment_axes"]
    }
  end

  defp prompt_candidate(candidate) do
    Map.drop(candidate, ["assessment_ids", "evidence_digest"])
  end

  defp observation_payload(event) do
    candidate = event["candidate"] || %{}

    %{
      "occurrence_id" => event["occurrence_id"],
      "run_id" => event["run_id"],
      "surface" => event["surface"],
      "ordinal" => event["ordinal"],
      "rationale" => candidate["rationale"],
      "pronunciation" => candidate["pronunciation"],
      "grammar" => candidate["grammar"],
      "etymology" => candidate["etymology"],
      "known_concerns" => candidate["known_concerns"] || [],
      "notes" => candidate["notes"] || []
    }
  end

  defp flag_payload(flag) do
    Map.take(flag, [
      "id",
      "kind",
      "severity",
      "status",
      "scope",
      "summary",
      "confidence",
      "evidence_refs"
    ])
  end

  defp collision_payload(check) do
    Map.take(check, [
      "id",
      "checked_at",
      "source",
      "query",
      "status",
      "claim_basis",
      "confidence",
      "summary"
    ])
  end

  defp active_records(records) do
    superseded =
      records
      |> Enum.map(& &1["supersedes"])
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    Enum.reject(records, &MapSet.member?(superseded, &1["id"]))
  end

  defp current_collisions(records) do
    records
    |> Enum.group_by(&{&1["candidate_id"], &1["source"], &1["query"]})
    |> Enum.map(fn {_key, attempts} ->
      Enum.max_by(attempts, &{&1["attempt"] || 0, &1["checked_at"] || "", &1["id"] || ""})
    end)
    |> Enum.sort_by(&{&1["candidate_id"] || "", &1["source"] || "", &1["query"] || ""})
  end

  defp index_atlas(atlas, key) do
    atlas |> Map.get(key, []) |> Map.new(&{&1["id"], &1})
  end

  defp resolved_atlas(ids, lookup) do
    ids
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(&Map.get(lookup, &1, %{"id" => &1, "missing_from_atlas" => true}))
  end

  defp observation_ids(observations, key) do
    observations
    |> Enum.flat_map(&(get_in(&1, ["candidate", key]) || []))
    |> Enum.uniq()
  end

  defp evidence_ids(records, key) do
    records |> Enum.map(& &1[key]) |> Enum.filter(&(is_binary(&1) and &1 != ""))
  end

  defp orphan_count(records, candidate_ids) do
    Enum.count(records, &(not MapSet.member?(candidate_ids, &1["candidate_id"])))
  end

  defp ensure_unique_existing_ids!(records) do
    duplicates =
      records
      |> Enum.map(& &1["id"])
      |> Enum.reject(&is_nil/1)
      |> duplicate_values(& &1)

    if duplicates != [] do
      raise ArgumentError, "duplicate existing assessment IDs: #{Enum.join(duplicates, ", ")}"
    end
  end

  defp work_plan(unit) do
    %{
      "profile_id" => unit.profile.id,
      "model" => unit.profile.model,
      "candidate_ids" => Enum.map(unit.candidates, & &1["candidate_id"])
    }
  end

  defp profile_report(profile) do
    %{
      "id" => profile.id,
      "name" => profile.name,
      "provider" => profile.provider,
      "model" => profile.model,
      "requested_model" => profile.requested_model,
      "profile_digest" => profile.digest
    }
  end

  defp checkpoint!(%{checkpoint: checkpoint}, state) when is_function(checkpoint, 2) do
    checkpoint.(flatten_batches(state.record_batches), Enum.reverse(state.events))
  end

  defp checkpoint!(_config, _state), do: :ok

  defp flatten_batches(batches), do: batches |> Enum.reverse() |> List.flatten()

  defp file_paths!(opts) do
    out = Keyword.get(opts, :out, "identity/assessments.jsonl")

    %{
      registry: Keyword.get(opts, :registry, "identity/registry.jsonl"),
      enrichments: path_list(Keyword.get(opts, :enrichments, ["identity/enrichments.jsonl"])),
      flags: path_list(Keyword.get(opts, :flags, ["identity/flags.jsonl"])),
      collisions:
        path_list(
          Keyword.get(opts, :collisions, [
            "identity/research/package-collision-checks.jsonl"
          ])
        ),
      atlas: Keyword.get(opts, :atlas, "identity/atlas.json"),
      out: out,
      runs_out: Keyword.get(opts, :runs_out, default_runs_out(out))
    }
  end

  defp path_list(paths), do: paths |> List.wrap() |> Enum.map(&to_string/1) |> Enum.uniq()

  defp default_runs_out(out) do
    Path.join(Path.dirname(out), "assessment-runs.jsonl")
  end

  defp ensure_distinct_paths!(paths) do
    inputs = [paths.registry, paths.atlas | paths.enrichments ++ paths.flags ++ paths.collisions]
    outputs = [paths.out, paths.runs_out]
    expanded_outputs = Enum.map(outputs, &Path.expand/1)

    if length(Enum.uniq(expanded_outputs)) != length(expanded_outputs) do
      raise ArgumentError, "assessment output and run ledger paths must be distinct"
    end

    overlap =
      inputs
      |> Enum.map(&Path.expand/1)
      |> Enum.filter(&(&1 in expanded_outputs))
      |> Enum.uniq()

    if overlap != [] do
      raise ArgumentError, "assessment outputs overlap inputs: #{Enum.join(overlap, ", ")}"
    end
  end

  defp load_many_jsonl!(paths) do
    Enum.flat_map(paths, &IdentityEvaluation.load_jsonl!(&1, optional: true))
  end

  defp load_jsonl_with_body!(path, opts) do
    records = IdentityEvaluation.load_jsonl!(path, opts)
    body = if File.exists?(path), do: File.read!(path), else: ""
    {records, body}
  end

  defp checkpoint_files!(paths, assessment_body, run_body, records, events) do
    if records != [] do
      IdentityCheckpoint.write_atomic!(paths.out, append_jsonl(assessment_body, records))
    end

    if events != [] do
      IdentityCheckpoint.write_atomic!(paths.runs_out, append_jsonl(run_body, events))
    end
  end

  defp append_jsonl(body, []), do: body

  defp append_jsonl(body, records) do
    prefix = if body == "" or String.ends_with?(body, "\n"), do: body, else: body <> "\n"
    prefix <> Enum.map_join(records, "\n", &Jason.encode!/1) <> "\n"
  end

  defp fetch_list!(input, key) do
    value = Map.get(input, key, Map.get(input, Atom.to_string(key)))
    if is_list(value), do: value, else: raise(ArgumentError, "#{key} must be a list")
  end

  defp optional_list!(input, key) do
    value = Map.get(input, key, Map.get(input, Atom.to_string(key), []))
    if is_list(value), do: value, else: raise(ArgumentError, "#{key} must be a list")
  end

  defp fetch_map!(input, key) do
    value = Map.get(input, key, Map.get(input, Atom.to_string(key)))
    if is_map(value), do: value, else: raise(ArgumentError, "#{key} must be a map")
  end

  defp fetch_profile_value(profile, key) do
    Map.get(profile, key, Map.get(profile, Atom.to_string(key)))
  end

  defp valid_scores?(scores) when is_map(scores) do
    Enum.all?(scores, fn {_axis, score} -> valid_range?(score, 0, 5) end)
  end

  defp valid_scores?(_scores), do: false

  defp valid_range?(value, minimum, maximum) do
    is_number(value) and value >= minimum and value <= maximum
  end

  defp concise_reasoning?(value) when is_binary(value) do
    length = value |> String.trim() |> String.length()
    length >= 1 and length <= @max_reasoning_chars
  end

  defp concise_reasoning?(_value), do: false

  defp mentions_surface?(reasoning, surface)
       when is_binary(reasoning) and is_binary(surface) do
    reasoning |> String.downcase() |> String.contains?(String.downcase(surface))
  end

  defp mentions_surface?(_reasoning, _surface), do: false

  defp valid_refs?(refs) when is_list(refs) do
    Enum.all?(refs, &(is_binary(&1) and String.trim(&1) != "")) and
      length(refs) == length(Enum.uniq(refs))
  end

  defp valid_refs?(_refs), do: false

  defp valid_iso8601?(value) when is_binary(value),
    do: match?({:ok, _, _}, DateTime.from_iso8601(value))

  defp valid_iso8601?(_value), do: false

  defp maybe_error(errors, true, message), do: errors ++ [message]
  defp maybe_error(errors, false, _message), do: errors

  defp validation_failure(errors, response) do
    %{
      "kind" => "invalid_model_assessment",
      "message" => Enum.join(Enum.uniq(errors), "; "),
      "response_sha256" => response_digest(response),
      "response_excerpt" => response_excerpt(response)
    }
  end

  defp invalid_json_failure(response) do
    %{
      "kind" => "invalid_json",
      "message" => "model response did not contain a decodable JSON value",
      "response_sha256" => response_digest(response),
      "response_excerpt" => response_excerpt(response)
    }
  end

  defp transport_failure(%{__exception__: true} = reason) do
    failure = %{
      "kind" => "transport_error",
      "message" => reason |> Exception.message() |> String.slice(0, 2_000)
    }

    case Map.get(reason, :status) do
      status when is_integer(status) -> Map.put(failure, "status", status)
      _status -> failure
    end
  end

  defp transport_failure(reason) do
    %{"kind" => "transport_error", "message" => inspect_limited(reason)}
  end

  defp normalize_failure(reason, _excerpt) when is_map(reason), do: stringify_keys(reason)
  defp normalize_failure(reason, _excerpt), do: transport_failure(reason)

  defp exception_failure(kind, reason, stacktrace) do
    %{
      "kind" => "assessor_exception",
      "message" => Exception.format(kind, reason, stacktrace) |> String.slice(0, 2_000)
    }
  end

  defp response_digest(response) do
    response |> inspect_limited(50_000) |> stable_digest()
  end

  defp response_excerpt(response),
    do: response |> inspect_limited(1_000) |> String.slice(0, 1_000)

  defp stringify_keys(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), stringify_keys(nested)} end)
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp stable_term(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: value

  defp stable_term(value) when is_atom(value), do: Atom.to_string(value)
  defp stable_term(value) when is_list(value), do: Enum.map(value, &stable_term/1)

  defp stable_term(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested} -> {to_string(key), stable_term(nested)} end)
    |> Enum.sort()
  end

  defp stable_term(value), do: inspect_limited(value)

  defp stable_digest(value) do
    value
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp duplicate_values(values, mapper) do
    values
    |> Enum.frequencies_by(mapper)
    |> Enum.filter(fn {_value, count} -> count > 1 end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  defp positive_integer!(value, _key) when is_integer(value) and value > 0, do: value

  defp positive_integer!(value, key) do
    raise ArgumentError, "#{key} must be a positive integer, got: #{inspect(value)}"
  end

  defp optional_positive_integer!(nil, _key), do: nil
  defp optional_positive_integer!(value, key), do: positive_integer!(value, key)

  defp run_id(started_at, context, config) do
    digest =
      stable_digest({
        started_at,
        context.atlas_digest,
        Enum.map(context.profiles, & &1.digest),
        Enum.map(context.candidates, & &1["candidate_id"]),
        config.batch_size,
        config.concurrency,
        :crypto.strong_rand_bytes(16)
      })

    "identity-assessment-run-" <> binary_part(digest, 0, 20)
  end

  defp now_iso8601 do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  defp inspect_limited(value, limit \\ 300) do
    inspect(value, pretty: false, limit: 50, printable_limit: limit)
  end
end

defmodule DSEx.IdentityAssessment.ReqLLMTransport do
  @moduledoc false

  def generate_text(model, messages, opts) do
    {schema, opts} = Keyword.pop!(opts, :identity_schema)
    {req_llm_module, opts} = Keyword.pop(opts, :identity_req_llm_module, ReqLLM)
    req_llm_module.generate_object(model, messages, schema, opts)
  end
end
