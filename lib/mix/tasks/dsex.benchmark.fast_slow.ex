defmodule Mix.Tasks.Dsex.Benchmark.FastSlow do
  @moduledoc """
  Run the deterministic Fast-Slow protocol campaign.

      mix dsex.benchmark.fast_slow --out benchmarks/results/fast-slow-protocol.json

  This campaign verifies orchestration and recovery behavior. Its held-out
  quality measurements are synthetic and are not provider or research evidence.
  """

  use Mix.Task

  alias DSEx.Optimizer.GEPA.EvaluationCache.Codec
  alias DSEx.Training.FastSlow.{Checkpoint, Config, Runner, State}
  alias Mix.Tasks.Dsex.Benchmark.FastSlow.Backend

  @shortdoc "Run deterministic Fast-Slow protocol evidence"
  @default_out "benchmarks/results/fast-slow-protocol.json"
  @modes ~w(prompt_only slow_only combined)

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, argv, invalid} = OptionParser.parse(args, strict: [out: :string])

    if argv != [] or invalid != [],
      do: Mix.raise("invalid arguments: #{inspect(argv ++ invalid)}")

    artifact = build_artifact()
    path = Keyword.get(opts, :out, @default_out)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Codec.canonical_json!(artifact) <> "\n")

    Mix.shell().info("Fast-Slow protocol campaign: #{path}")

    unless artifact["summary"]["all_protocol_claims_verified"],
      do: Mix.raise("Fast-Slow protocol campaign failed; inspect #{path}")
  end

  @doc false
  def build_artifact do
    rows = Enum.map(@modes, &run_mode/1)

    artifact = %{
      "schema_version" => 1,
      "artifact_type" => "dsex_fast_slow_protocol_campaign",
      "evidence_class" => "deterministic_provider_neutral_protocol",
      "quality_scope" => %{
        "label" => "synthetic_protocol_behavior",
        "research_effectiveness" => false,
        "provider_effectiveness" => false,
        "warning" =>
          "Held-out scores exercise protocol wiring only and must not be cited as Fast-Slow research or provider effectiveness."
      },
      "contract" => %{
        "algorithm" => "Learning, Fast and Slow Algorithm 1",
        "t" => 2,
        "k" => 2,
        "g" => 4,
        "cycles" => 1,
        "rollouts_per_prompt_per_question" => 2,
        "required_order" => ["prefetch", "gepa", "rollouts", "slow_update"],
        "failure_plan" =>
          "definitive failure before applying slow update 1, then checkpoint reload and replay"
      },
      "dataset" => dataset_provenance(),
      "provenance" => %{
        "runner" => inspect(Runner),
        "backend" => inspect(Backend),
        "paper" => "https://arxiv.org/abs/2605.12484v2",
        "official_blog" =>
          "https://gepa-ai.github.io/gepa/blog/2026/05/11/learning-fast-and-slow/",
        "source_revision" => git_sha(),
        "command" => "mix dsex.benchmark.fast_slow --out <path>",
        "deterministic" => true,
        "external_provider_calls" => 0
      },
      "rows" => rows,
      "summary" => summarize(rows)
    }

    Map.put(artifact, "artifact_sha256", Codec.digest(artifact))
  end

  defp run_mode(mode) do
    config = config(mode)
    initial = State.new!(config, %{"bias" => -2, "artifact" => "theta-0"}, ["seed"])
    context = Backend.context(mode)

    {:error, {:planned_definitive_failure, 1}, failed, failed_context} =
      Runner.run(initial, Backend, context)

    state_checkpoint = config |> Checkpoint.dump(failed) |> json_round_trip()
    context_checkpoint = failed_context |> Runner.dump_context!(failed) |> json_round_trip()
    restored_state = Checkpoint.load!(state_checkpoint, config)
    restored_context = Runner.load_context!(context_checkpoint, restored_state)
    before_resume = counts(restored_context.backend)

    {:ok, final, final_context} = Runner.run(restored_state, Backend, restored_context)

    events = final_context.backend["events"]
    slow_events = Enum.filter(events, &(&1["kind"] == "slow_update"))
    successful_slow = Enum.reject(slow_events, & &1["planned_failure"])
    population_digests = Enum.map(successful_slow, & &1["population_digest"])
    allocation = Enum.map(successful_slow, & &1["prompt_indices"])
    theta_lineage = Enum.map(final.theta_lineage, &theta_row/1)
    final_counts = counts(final_context.backend)

    resume = %{
      "planned_failure" => %{
        "kind" => "slow_update",
        "slow_step" => 1,
        "definitive_not_applied" => true
      },
      "checkpoint_schema_version" => state_checkpoint["schema_version"],
      "state_payload_sha256" => state_checkpoint["payload_sha256"],
      "context_digest" => context_checkpoint["digest"],
      "pending_retryable_intents" => map_size(failed.pending_operations),
      "rollouts_before_resume" => before_resume["rollout"],
      "rollouts_after_resume" => final_counts["rollout"],
      "rollouts_repeated_on_resume" => final_counts["rollout"] - before_resume["rollout"],
      "replayed_definitive_slow_update" =>
        final_counts["slow_update"] - before_resume["slow_update"],
      "completed" => final.stage == :terminal and final.terminal.reason == :completed
    }

    claims = %{
      "exact_event_order" => exact_order?(events),
      "exact_t_slow_updates" => length(successful_slow) == config.t,
      "exact_k_population" => length(final.prompt_population.candidates) == config.k,
      "exact_g_allocation" => allocation == List.duplicate([0, 0, 1, 1], config.t),
      "population_fixed_across_t" => length(Enum.uniq(population_digests)) == 1,
      "theta_lineage_rebound_each_step" => valid_theta_lineage?(theta_lineage, successful_slow),
      "checkpoint_round_trip_exact" =>
        restored_state == failed and
          Runner.dump_context!(restored_context, restored_state) == context_checkpoint,
      "resume_avoids_rollout_repetition" => resume["rollouts_repeated_on_resume"] == 0,
      "definitive_failure_replayed_once" => resume["replayed_definitive_slow_update"] == 1,
      "held_out_isolation" => split_overlap() == []
    }

    %{
      "mode" => mode,
      "active_components" => active_components(mode),
      "control_semantics" => control_semantics(mode),
      "quality" => held_out_quality(final),
      "operation_counts" => Map.merge(final_counts, learning_counts(mode, final_counts)),
      "cost" => %{
        "currency" => "USD",
        "external_provider_cost" => 0.0,
        "provider_calls" => 0,
        "synthetic_backend_operations" => Enum.sum(Map.values(final_counts))
      },
      "event_trace" => events,
      "prompt_population" => %{
        "revision" => final.prompt_population.revision,
        "digest" => final.prompt_population.digest,
        "candidates" => final.prompt_population.candidates,
        "digests_seen_by_successful_slow_updates" => population_digests
      },
      "theta_lineage" => theta_lineage,
      "resume" => resume,
      "claims" => claims,
      "all_claims_verified" => Enum.all?(claims, fn {_claim, verified} -> verified end)
    }
  end

  defp config(mode) do
    Config.new!(
      program_topology: %{"predictors" => ["deterministic_binary_classifier"]},
      models: %{"behavior" => "provider-neutral", "reflection" => "provider-neutral"},
      dataset_digests: %{
        "train" => Codec.digest(Backend.training_data()),
        "held_out" => Codec.digest(held_out_data())
      },
      verifier_version: "synthetic-independent-rule-v1",
      adapter_version: "fast-slow-protocol-backend-v1",
      t: 2,
      k: 2,
      g: 4,
      max_cycles: 1,
      reuse_rollouts: false,
      optimizer_config: %{"mode" => mode},
      provider_config: %{"kind" => "deterministic", "external" => false},
      sampling_config: %{"temperature" => 0.0, "seed" => 73}
    )
  end

  defp held_out_quality(final) do
    theta = Enum.find(final.theta_lineage, &(&1.id == final.current_theta_id)).payload
    prompt = hd(final.prompt_population.candidates)

    predictions =
      Enum.map(held_out_data(), fn example ->
        prediction = Backend.predict(prompt, theta, example)
        %{"id" => example["id"], "prediction" => prediction, "label" => example["label"]}
      end)

    correct = Enum.count(predictions, &(&1["prediction"] == &1["label"]))

    %{
      "label" => "synthetic_protocol_behavior",
      "metric" => "held_out_accuracy",
      "correct" => correct,
      "total" => length(predictions),
      "value" => correct / length(predictions),
      "predictions" => predictions,
      "optimizer_received_held_out_examples" => false,
      "evaluation_uses_training_callback_reward" => false
    }
  end

  defp held_out_data do
    [
      %{"id" => "held-0", "x1" => 3, "x2" => -2, "label" => 1},
      %{"id" => "held-1", "x1" => -3, "x2" => 2, "label" => 0},
      %{"id" => "held-2", "x1" => 1, "x2" => -1, "label" => 1},
      %{"id" => "held-3", "x1" => -1, "x2" => 1, "label" => 1},
      %{"id" => "held-4", "x1" => 2, "x2" => 2, "label" => 1},
      %{"id" => "held-5", "x1" => -2, "x2" => -1, "label" => 0}
    ]
  end

  defp dataset_provenance do
    %{
      "task" => "binary classification where label = 1 iff x1 + x2 >= 0",
      "train_digest" => Codec.digest(Backend.training_data()),
      "held_out_digest" => Codec.digest(held_out_data()),
      "train_examples" => length(Backend.training_data()),
      "held_out_examples" => length(held_out_data()),
      "split_overlap" => split_overlap(),
      "held_out_location" => "campaign evaluator only",
      "optimizer_callback_access" => ["train"]
    }
  end

  defp exact_order?(events) do
    Enum.map(events, & &1["kind"]) ==
      [
        "prefetch",
        "gepa",
        "rollout",
        "rollout",
        "rollout",
        "rollout",
        "slow_update",
        "rollout",
        "rollout",
        "rollout",
        "rollout",
        "slow_update",
        "slow_update"
      ]
  end

  defp valid_theta_lineage?([initial, first, second], [first_slow, second_slow]) do
    is_nil(initial["parent_id"]) and first["parent_id"] == initial["id"] and
      second["parent_id"] == first["id"] and first_slow["theta_id"] == initial["id"] and
      second_slow["theta_id"] == first["id"] and first_slow["result_theta_id"] == first["id"] and
      second_slow["result_theta_id"] == second["id"]
  end

  defp valid_theta_lineage?(_, _), do: false

  defp theta_row(theta) do
    %{
      "id" => theta.id,
      "parent_id" => theta.parent_id,
      "digest" => theta.digest,
      "cycle" => theta.cycle,
      "payload" => theta.payload
    }
  end

  defp counts(context) do
    Map.merge(
      %{
        "prefetch" => 0,
        "gepa" => 0,
        "rollout" => 0,
        "slow_update" => 0,
        "trainer_step" => 0
      },
      context["counts"]
    )
  end

  defp active_components("prompt_only"),
    do: %{"prompt_adaptation" => true, "slow_learning" => false}

  defp active_components("slow_only"),
    do: %{"prompt_adaptation" => false, "slow_learning" => true}

  defp active_components("combined"),
    do: %{"prompt_adaptation" => true, "slow_learning" => true}

  defp control_semantics("prompt_only"),
    do:
      "Runner slow-update calls are protocol no-ops; theta artifacts are rebound without parameter learning."

  defp control_semantics("slow_only"),
    do: "Runner GEPA phase installs a fixed control population and performs no prompt search."

  defp control_semantics("combined"),
    do: "Both prompt adaptation and slow parameter updates are active."

  defp learning_counts(mode, counts) do
    %{
      "active_prompt_optimizations" => if(mode == "slow_only", do: 0, else: counts["gepa"]),
      "active_slow_updates" => if(mode == "prompt_only", do: 0, else: 2),
      "definitive_failed_slow_attempts" => counts["slow_update"] - 2
    }
  end

  defp summarize(rows) do
    quality = Map.new(rows, &{&1["mode"], get_in(&1, ["quality", "value"])})

    %{
      "rows" => length(rows),
      "matched_modes" => Enum.map(rows, & &1["mode"]),
      "all_protocol_claims_verified" => Enum.all?(rows, & &1["all_claims_verified"]),
      "research_effectiveness_claimed" => false,
      "provider_effectiveness_claimed" => false,
      "quality_label" => "synthetic_protocol_behavior",
      "quality_comparison" => %{
        "values" => quality,
        "combined_gt_prompt_only" => quality["combined"] > quality["prompt_only"],
        "combined_gt_slow_only" => quality["combined"] > quality["slow_only"],
        "interpretation" => "Synthetic held-out protocol behavior only"
      }
    }
  end

  defp split_overlap do
    training_ids = Backend.training_data() |> Enum.map(& &1["id"]) |> MapSet.new()
    held_out_ids = held_out_data() |> Enum.map(& &1["id"]) |> MapSet.new()
    training_ids |> MapSet.intersection(held_out_ids) |> MapSet.to_list() |> Enum.sort()
  end

  defp json_round_trip(value), do: value |> Jason.encode!() |> Jason.decode!()

  defp git_sha do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> "unavailable"
    end
  end

  defmodule Backend do
    @moduledoc false

    @behaviour DSEx.Training.FastSlow.Backend

    alias DSEx.Training.FastSlow.{Config, DatasetState}

    @doc false
    def context(mode) do
      session =
        DSEx.Clients.ReinforcementSession.new(%{
          id: "fast-slow-protocol-session",
          provider: "deterministic_protocol",
          model: "theta-0",
          current_model: "theta-0",
          pending_batch_ids: []
        })

      %{
        "mode" => mode,
        "events" => [],
        "counts" => %{},
        "failed_once" => false,
        "session" => Config.json_safe!(Map.from_struct(session))
      }
    end

    @doc false
    def training_data do
      [
        %{"id" => "train-0", "x1" => 2, "x2" => 2, "label" => 1},
        %{"id" => "train-1", "x1" => 3, "x2" => -2, "label" => 1}
      ]
    end

    @doc false
    def predict(prompt, theta, example) do
      bias = theta["bias"]

      value =
        case prompt do
          "sum_features" -> example["x1"] + example["x2"] + bias
          "difference_features" -> example["x1"] - example["x2"] + bias
          "first_feature" -> example["x1"] + bias
          "second_feature" -> example["x2"] + bias
        end

      if value >= 0, do: 1, else: 0
    end

    @impl true
    def prefetch(state, count, intent, context) do
      examples = Enum.slice(training_data(), state.dataset.cursor, count)

      batches =
        Enum.with_index(examples, state.dataset.cursor)
        |> Enum.map(fn {example, index} ->
          problem = Map.put(example, "dataset_indices", [index])
          %{"id" => "train-batch-#{index}", "problems" => [problem]}
        end)

      dataset = DatasetState.new!(state.dataset.cursor + count, 0, %{"seed" => 73})

      event = %{
        "kind" => "prefetch",
        "intent_id" => intent.id,
        "batch_ids" => Enum.map(batches, & &1["id"]),
        "count" => count
      }

      {:ok, batches, dataset, record(context, event)}
    end

    @impl true
    def validate_prefetch_progression(state, batches, dataset, _context) do
      if dataset.cursor == state.dataset.cursor + length(batches),
        do: :ok,
        else: {:error, :non_contiguous_protocol_fixture}
    end

    @impl true
    def optimize_fast(state, batches, intent, context) do
      candidates = candidates(context["mode"])
      candidate_ids = Enum.map(candidates, &Config.digest/1)
      theta = current_theta(state)

      instance_scores =
        Map.new(batches, fn batch ->
          [problem] = batch["problems"]

          scores =
            candidates
            |> Enum.zip(candidate_ids)
            |> Map.new(fn {candidate, id} ->
              score =
                if predict(candidate, theta, problem) == problem["label"], do: 1.0, else: 0.0

              {id, score}
            end)

          {problem["id"], scores}
        end)

      instance_frontier =
        Map.new(instance_scores, fn {problem_id, scores} ->
          best = scores |> Map.values() |> Enum.max()
          winners = for {id, score} <- scores, score == best, do: id
          {problem_id, winners}
        end)

      result = %{
        candidates: candidates,
        candidate_ids: candidate_ids,
        instance_scores: instance_scores,
        instance_frontier: instance_frontier,
        cached_trajectories: []
      }

      event = %{
        "kind" => "gepa",
        "intent_id" => intent.id,
        "theta_id" => state.current_theta_id,
        "candidate_ids" => candidate_ids,
        "active" => context["mode"] != "slow_only"
      }

      {:ok, result, record(context, event)}
    end

    @impl true
    def generate_rollout(state, slot, intent, context) do
      theta = current_theta(state)
      prediction = predict(slot.prompt, theta, slot.problem)
      score = if prediction == slot.problem["label"], do: 1.0, else: 0.0

      result = %{
        output: %{"prediction" => prediction},
        score: score,
        behavior_logprobs: [-0.25 - slot.member_index / 100],
        response_token_ids: [500 + prediction],
        response_mask: [1],
        metrics: %{"synthetic" => true}
      }

      event = %{
        "kind" => "rollout",
        "intent_id" => intent.id,
        "slow_step" => slot.slow_step,
        "member_index" => slot.member_index,
        "prompt_index" => slot.prompt_index,
        "theta_id" => state.current_theta_id
      }

      {:ok, result, record(context, event)}
    end

    @impl true
    def update_slow(state, batch, groups, intent, context) do
      [group] = groups

      event = %{
        "kind" => "slow_update",
        "intent_id" => intent.id,
        "slow_step" => state.slow_step,
        "batch_id" => batch["id"],
        "theta_id" => state.current_theta_id,
        "population_digest" => state.prompt_population.digest,
        "prompt_indices" => Enum.map(group.members, & &1["prompt_index"]),
        "behavior_policy_ids" => Enum.map(group.members, & &1["behavior_policy_id"]),
        "planned_failure" => state.slow_step == 1 and not context["failed_once"]
      }

      context = record(context, event)

      if event["planned_failure"] do
        {:error, {:planned_definitive_failure, 1}, Map.put(context, "failed_once", true)}
      else
        theta = current_theta(state)
        {artifact, context} = apply_slow_update(context, groups, intent, theta)
        bias = if context["mode"] == "prompt_only", do: theta["bias"], else: theta["bias"] + 1

        payload = %{
          "bias" => bias,
          "artifact" => artifact,
          "parent_theta_id" => state.current_theta_id,
          "training_batch" => batch["id"]
        }

        result_theta_id =
          DSEx.Training.FastSlow.Theta.new!(state.cycle, payload, state.current_theta_id).id

        context = update_last_event(context, "result_theta_id", result_theta_id)
        {:ok, payload, context}
      end
    end

    @impl true
    def replay_safe?(intent, context) do
      intent.kind == "fast_slow.slow_update" and context["failed_once"] == true
    end

    defp apply_slow_update(%{"mode" => "prompt_only"} = context, _groups, _intent, theta),
      do: {theta["artifact"], context}

    defp apply_slow_update(context, groups, intent, _theta) do
      session = DSEx.Clients.ReinforcementSession.new(context["session"])

      provider_groups =
        Enum.map(groups, fn group ->
          %{"batch_id" => group.id, "group" => group.members}
        end)

      {:ok, updated} =
        DSEx.Clients.Trainer.reinforcement_step(
          Mix.Tasks.Dsex.Benchmark.FastSlow.Backend.ProtocolTrainer,
          session,
          provider_groups,
          objective: :cispo,
          operation_id: intent.id
        )

      context =
        context
        |> Map.put("session", Config.json_safe!(Map.from_struct(updated)))
        |> update_in(["counts", "trainer_step"], &((&1 || 0) + 1))

      {updated.current_model, context}
    end

    defp candidates("slow_only"), do: ["first_feature", "second_feature"]
    defp candidates(_mode), do: ["sum_features", "difference_features"]

    defp current_theta(state) do
      state.theta_lineage |> Enum.find(&(&1.id == state.current_theta_id)) |> Map.fetch!(:payload)
    end

    defp record(context, event) do
      event = Map.put(event, "sequence", length(context["events"]))

      context
      |> Map.update!("events", &(&1 ++ [event]))
      |> update_in(["counts", event["kind"]], &((&1 || 0) + 1))
    end

    defp update_last_event(context, key, value) do
      update_in(context, ["events"], fn events ->
        List.update_at(events, -1, &Map.put(&1, key, value))
      end)
    end

    defmodule ProtocolTrainer do
      @moduledoc false
      @behaviour DSEx.Clients.Trainer

      @impl true
      def supported_methods, do: [:grpo]

      @impl true
      def reinforcement_step(session, groups, opts) do
        operation_id = Keyword.fetch!(opts, :operation_id)
        objective = Keyword.fetch!(opts, :objective)
        step = length(session.fulfilled_batch_ids) + 1

        {:ok,
         %{
           session
           | current_model: "protocol-cispo-theta-#{step}",
             metadata: %{
               "last_operation_id" => operation_id,
               "objective" => Atom.to_string(objective),
               "group_count" => length(groups)
             }
         }}
      end
    end
  end
end
