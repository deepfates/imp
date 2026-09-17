defmodule Imp.BenchmarkTruth.OptimizeAnything.SchedulingHeuristic do
  @moduledoc false

  @max_candidate_bytes 4_096
  @weight_limit 10.0
  @candidate_keys MapSet.new(["version", "priority", "assignment"])
  @priority_keys MapSet.new(["processing", "due_date", "importance"])
  @assignments ["least_loaded", "earliest_finish", "cost_aware", "capability_aware"]
  @objective_weights %{
    "makespan" => 0.30,
    "weighted_tardiness" => 0.45,
    "load_fairness" => 0.15,
    "resource_cost" => 0.10
  }

  @baseline Jason.encode!(%{
              "version" => 1,
              "priority" => %{
                "processing" => 0.0,
                "due_date" => 0.0,
                "importance" => 0.0
              },
              "assignment" => "least_loaded"
            })

  @comparator Jason.encode!(%{
                "version" => 1,
                "priority" => %{
                  "processing" => 0.0,
                  "due_date" => 0.0,
                  "importance" => 0.0
                },
                "assignment" => "capability_aware"
              })

  @trainset (
              resource = fn id, speed, cost_rate, setup ->
                %{"id" => id, "speed" => speed, "cost_rate" => cost_rate, "setup" => setup}
              end

              job = fn id, work, due, importance, class, eligible_resources ->
                %{
                  "id" => id,
                  "work" => work,
                  "due" => due,
                  "importance" => importance,
                  "class" => class,
                  "eligible_resources" => eligible_resources
                }
              end

              [
                %{
                  "id" => "train-mixed-deadlines",
                  "resources" => [
                    resource.("fast", 2.0, 1.4, %{"gpu" => 1}),
                    resource.("steady", 1.0, 0.8, %{"batch" => 1})
                  ],
                  "jobs" => [
                    job.("bulk-a", 9, 16, 1, "batch", :all),
                    job.("urgent-a", 3, 4, 5, "gpu", :all),
                    job.("bulk-b", 8, 18, 1, "batch", :all),
                    job.("urgent-b", 2, 5, 4, "gpu", :all),
                    job.("standard", 5, 11, 2, "general", :all)
                  ]
                },
                %{
                  "id" => "train-cost-and-setup",
                  "resources" => [
                    resource.("premium", 2.5, 2.0, %{"precision" => 2}),
                    resource.("economy", 1.0, 0.55, %{"bulk" => 1}),
                    resource.("flex", 1.4, 1.0, %{})
                  ],
                  "jobs" => [
                    job.("long-bulk", 12, 20, 1, "bulk", :all),
                    job.("precision-1", 4, 6, 5, "precision", :all),
                    job.("short-bulk", 3, 9, 2, "bulk", :all),
                    job.("precision-2", 5, 10, 4, "precision", :all),
                    job.("routine", 6, 15, 2, "general", :all)
                  ]
                },
                %{
                  "id" => "train-eligibility",
                  "resources" => [
                    resource.("cpu-a", 1.0, 0.7, %{}),
                    resource.("cpu-b", 1.2, 0.9, %{}),
                    resource.("accelerator", 3.0, 2.4, %{"accelerated" => 0})
                  ],
                  "jobs" => [
                    job.("background", 10, 22, 1, "general", :all),
                    job.("accelerated-urgent", 7, 5, 5, "accelerated", ["accelerator"]),
                    job.("cpu-urgent", 3, 6, 4, "general", ["cpu-a", "cpu-b"]),
                    job.("accelerated-later", 9, 14, 2, "accelerated", ["accelerator"]),
                    job.("cpu-batch", 8, 18, 1, "general", ["cpu-a", "cpu-b"])
                  ]
                }
              ]
            )

  @valset (
            resource = fn id, speed, cost_rate, setup ->
              %{"id" => id, "speed" => speed, "cost_rate" => cost_rate, "setup" => setup}
            end

            job = fn id, work, due, importance, class, eligible_resources ->
              %{
                "id" => id,
                "work" => work,
                "due" => due,
                "importance" => importance,
                "class" => class,
                "eligible_resources" => eligible_resources
              }
            end

            [
              %{
                "id" => "val-unseen-scale",
                "resources" => [
                  resource.("rapid", 2.2, 1.8, %{"critical" => 1}),
                  resource.("base-a", 1.0, 0.65, %{}),
                  resource.("base-b", 1.1, 0.75, %{"bulk" => 1})
                ],
                "jobs" => [
                  job.("large-first", 14, 25, 1, "bulk", :all),
                  job.("critical-a", 4, 6, 5, "critical", :all),
                  job.("routine-a", 5, 13, 2, "general", :all),
                  job.("critical-b", 3, 7, 4, "critical", :all),
                  job.("large-second", 11, 23, 1, "bulk", :all),
                  job.("routine-b", 4, 12, 3, "general", :all)
                ]
              },
              %{
                "id" => "val-capability-bottleneck",
                "resources" => [
                  resource.("specialist", 2.8, 2.2, %{"special" => 2}),
                  resource.("general-a", 1.0, 0.7, %{}),
                  resource.("general-b", 1.3, 0.95, %{})
                ],
                "jobs" => [
                  job.("general-long", 13, 24, 1, "general", :all),
                  job.("special-hot", 6, 7, 5, "special", ["specialist"]),
                  job.("general-hot", 3, 6, 4, "general", ["general-a", "general-b"]),
                  job.("special-cold", 10, 20, 1, "special", ["specialist"]),
                  job.("general-medium", 7, 15, 2, "general", :all)
                ]
              }
            ]
          )

  @testset (
             resource = fn id, speed, cost_rate, setup ->
               %{"id" => id, "speed" => speed, "cost_rate" => cost_rate, "setup" => setup}
             end

             job = fn id, work, due, importance, class, eligible_resources ->
               %{
                 "id" => id,
                 "work" => work,
                 "due" => due,
                 "importance" => importance,
                 "class" => class,
                 "eligible_resources" => eligible_resources
               }
             end

             [
               %{
                 "id" => "test-unseen-workload",
                 "resources" => [
                   resource.("rapid", 2.4, 1.9, %{"critical" => 1}),
                   resource.("base-a", 1.0, 0.65, %{}),
                   resource.("base-b", 1.2, 0.8, %{"bulk" => 1})
                 ],
                 "jobs" => [
                   job.("bulk-large", 15, 27, 1, "bulk", :all),
                   job.("critical-first", 5, 7, 5, "critical", :all),
                   job.("routine-first", 6, 15, 2, "general", :all),
                   job.("critical-second", 4, 8, 4, "critical", :all),
                   job.("bulk-second", 10, 23, 1, "bulk", :all),
                   job.("routine-second", 5, 14, 3, "general", :all)
                 ]
               },
               %{
                 "id" => "test-heterogeneous-fleet",
                 "resources" => [
                   resource.("specialist", 2.6, 2.0, %{"precision" => 1}),
                   resource.("steady", 1.15, 0.75, %{}),
                   resource.("economy", 0.9, 0.5, %{"bulk" => 1})
                 ],
                 "jobs" => [
                   job.("bulk-long", 13, 26, 1, "bulk", :all),
                   job.("precision-hot", 5, 7, 5, "precision", ["specialist"]),
                   job.("routine-hot", 3, 6, 4, "general", ["steady", "economy"]),
                   job.("precision-later", 8, 18, 2, "precision", ["specialist"]),
                   job.("bulk-short", 5, 14, 2, "bulk", :all)
                 ]
               }
             ]
           )

  def id, do: "optimize_anything_scheduling_heuristic_v1"

  def artifact_class, do: "scheduling_heuristic"

  def baseline, do: @baseline

  def comparator, do: @comparator

  def trainset, do: normalize_dataset(@trainset)

  def valset, do: normalize_dataset(@valset)

  def testset, do: normalize_dataset(@testset)

  def metadata do
    %{
      "schema_version" => 1,
      "deterministic" => true,
      "candidate_format" => "strict_json",
      "candidate_byte_limit" => @max_candidate_bytes,
      "objective" =>
        "Improve makespan, weighted tardiness, load fairness, and resource cost on scheduling instances while preserving the strict heuristic schema.",
      "candidate_contract" => %{
        "exact_top_level_keys" => @candidate_keys |> MapSet.to_list() |> Enum.sort(),
        "version" => 1,
        "priority_exact_keys" => @priority_keys |> MapSet.to_list() |> Enum.sort(),
        "priority_weight_range" => [0.0, @weight_limit],
        "assignment_values" => @assignments,
        "search_guidance" =>
          "Run assignment-only ablations before tuning weights. On iterations 1 through 4, respectively test earliest_finish, cost_aware, capability_aware, and least_loaded while preserving every current priority weight exactly. Only later iterations may tune one priority weight at a time when diagnostics justify it.",
        "requirement" => "Return one complete strict JSON object with no unknown fields."
      },
      "weight_range" => [0.0, @weight_limit],
      "assignments" => @assignments,
      "objective_weights" => @objective_weights,
      "train_instances" => length(@trainset),
      "selection_instances" => length(@valset),
      "test_instances" => length(@testset),
      "higher_is_better" => true,
      "score_range" => [0.0, 1.0]
    }
  end

  def evaluate(candidate_text, example) do
    with {:ok, candidate} <- parse_candidate(candidate_text),
         :ok <- validate_example(example),
         {:ok, result} <- schedule(candidate, example) do
      {result["score"], result}
    else
      {:error, reason} ->
        {0.0,
         %{
           "status" => "invalid",
           "error" => reason,
           "instance_id" => instance_id(example),
           "objective_subscores" => zero_subscores(),
           "action" => "Return a bounded version-1 JSON heuristic matching metadata/0."
         }}
    end
  end

  defp parse_candidate(text) when not is_binary(text), do: {:error, "candidate must be text"}

  defp parse_candidate(text) when byte_size(text) > @max_candidate_bytes,
    do: {:error, "candidate exceeds #{@max_candidate_bytes}-byte limit"}

  defp parse_candidate(text) do
    with {:ok, value} <- Jason.decode(text),
         :ok <- exact_keys(value, @candidate_keys, "candidate"),
         :ok <- ensure(value["version"] == 1, "version must equal 1"),
         :ok <- exact_keys(value["priority"], @priority_keys, "priority"),
         {:ok, weights} <- validate_weights(value["priority"]),
         :ok <-
           ensure(value["assignment"] in @assignments, "assignment is not supported") do
      {:ok, %{"priority" => weights, "assignment" => value["assignment"]}}
    else
      {:error, %Jason.DecodeError{}} -> {:error, "candidate is not valid JSON"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp exact_keys(value, expected, context) when is_map(value) do
    actual = value |> Map.keys() |> MapSet.new()

    if MapSet.equal?(actual, expected),
      do: :ok,
      else: {:error, "#{context} has missing or unknown fields"}
  end

  defp exact_keys(_value, _expected, context), do: {:error, "#{context} must be an object"}

  defp validate_weights(weights) do
    Enum.reduce_while(@priority_keys, {:ok, %{}}, fn key, {:ok, valid} ->
      value = weights[key]

      if is_number(value) and value >= 0 and value <= @weight_limit do
        {:cont, {:ok, Map.put(valid, key, value / 1)}}
      else
        {:halt, {:error, "priority.#{key} must be between 0 and #{@weight_limit}"}}
      end
    end)
  end

  defp validate_example(%{"id" => id, "jobs" => jobs, "resources" => resources})
       when is_binary(id) and is_list(jobs) and jobs != [] and is_list(resources) and
              resources != [] do
    resource_ids = MapSet.new(resources, & &1["id"])

    ensure(
      valid_resources?(resources, resource_ids) and valid_jobs?(jobs, resource_ids),
      "example does not satisfy the scheduling schema"
    )
  end

  defp validate_example(_example), do: {:error, "example does not satisfy the scheduling schema"}

  defp valid_resources?(resources, resource_ids) do
    Enum.all?(resources, &valid_resource?/1) and MapSet.size(resource_ids) == length(resources)
  end

  defp valid_resource?(resource) do
    is_binary(resource["id"]) and positive_number?(resource["speed"]) and
      positive_number?(resource["cost_rate"]) and is_map(resource["setup"])
  end

  defp valid_jobs?(jobs, resource_ids),
    do: Enum.all?(jobs, &valid_job?(&1, resource_ids))

  defp valid_job?(job, resource_ids) do
    eligible = job["eligible_resources"]

    valid_job_fields?(job) and is_list(eligible) and eligible != [] and
      Enum.all?(eligible, &MapSet.member?(resource_ids, &1))
  end

  defp valid_job_fields?(job) do
    is_binary(job["id"]) and positive_number?(job["work"]) and
      positive_number?(job["due"]) and positive_number?(job["importance"]) and
      is_binary(job["class"])
  end

  defp schedule(candidate, example) do
    resources = example["resources"]
    indexed_jobs = Enum.with_index(example["jobs"])
    ordered_jobs = Enum.sort_by(indexed_jobs, &dispatch_key(&1, candidate, resources))
    initial = Map.new(resources, &{&1["id"], %{available: 0.0, busy: 0.0, cost: 0.0}})

    reserved_resources =
      example["jobs"]
      |> Enum.filter(&(length(&1["eligible_resources"]) == 1))
      |> Enum.map(&hd(&1["eligible_resources"]))
      |> MapSet.new()

    {assignments, state} =
      Enum.map_reduce(ordered_jobs, initial, fn {job, _index}, resource_state ->
        resource =
          choose_resource(
            job,
            resources,
            resource_state,
            candidate["assignment"],
            reserved_resources
          )

        current = resource_state[resource["id"]]
        duration = duration(job, resource)
        finish = current.available + duration
        cost = duration * resource["cost_rate"]

        assignment = %{
          "job_id" => job["id"],
          "resource_id" => resource["id"],
          "start" => round_metric(current.available),
          "finish" => round_metric(finish),
          "duration" => round_metric(duration),
          "due" => job["due"],
          "tardiness" => round_metric(max(finish - job["due"], 0.0)),
          "importance" => job["importance"],
          "cost" => round_metric(cost)
        }

        updated = %{available: finish, busy: current.busy + duration, cost: current.cost + cost}
        {assignment, Map.put(resource_state, resource["id"], updated)}
      end)

    {:ok, score_result(example, assignments, state)}
  end

  defp dispatch_key({job, index}, candidate, resources) do
    weights = candidate["priority"]
    fastest = job |> eligible_resources(resources) |> Enum.map(&duration(job, &1)) |> Enum.min()

    priority =
      weights["processing"] * fastest + weights["due_date"] * job["due"] -
        weights["importance"] * job["importance"]

    {priority, index}
  end

  defp choose_resource(job, resources, state, policy, reserved_resources) do
    job
    |> eligible_resources(resources)
    |> Enum.min_by(fn resource ->
      resource_key(job, resource, state[resource["id"]], policy, reserved_resources)
    end)
  end

  defp resource_key(_job, resource, current, "least_loaded", _reserved_resources),
    do: {current.available, resource["id"]}

  defp resource_key(job, resource, current, "earliest_finish", _reserved_resources),
    do: {current.available + duration(job, resource), resource["cost_rate"], resource["id"]}

  defp resource_key(job, resource, current, "cost_aware", _reserved_resources) do
    runtime = duration(job, resource)
    {current.available + runtime + runtime * resource["cost_rate"] * 0.35, resource["id"]}
  end

  defp resource_key(job, resource, current, "capability_aware", reserved_resources) do
    specialization_penalty =
      if length(job["eligible_resources"]) > 1 and
           MapSet.member?(reserved_resources, resource["id"]),
         do: 1_000.0,
         else: 0.0

    {specialization_penalty + current.available + duration(job, resource), resource["cost_rate"],
     resource["id"]}
  end

  defp eligible_resources(job, resources) do
    allowed = MapSet.new(job["eligible_resources"])
    Enum.filter(resources, &MapSet.member?(allowed, &1["id"]))
  end

  defp duration(job, resource) do
    job["work"] / resource["speed"] + Map.get(resource["setup"], job["class"], 0)
  end

  defp score_result(example, assignments, state) do
    makespan = assignments |> Enum.map(& &1["finish"]) |> Enum.max()

    weighted_tardiness =
      assignments
      |> Enum.map(&(&1["tardiness"] * &1["importance"]))
      |> Enum.sum()

    loads = Enum.map(state, fn {_id, resource} -> resource.busy end)
    total_cost = assignments |> Enum.map(& &1["cost"]) |> Enum.sum()
    total_work = example["jobs"] |> Enum.map(& &1["work"]) |> Enum.sum()
    total_importance = example["jobs"] |> Enum.map(& &1["importance"]) |> Enum.sum()
    fastest_speed = example["resources"] |> Enum.map(& &1["speed"]) |> Enum.max()
    cheapest_rate = example["resources"] |> Enum.map(& &1["cost_rate"]) |> Enum.min()
    total_speed = example["resources"] |> Enum.map(& &1["speed"]) |> Enum.sum()
    lower_makespan = total_work / total_speed
    tardiness_scale = total_importance * Enum.max_by(example["jobs"], & &1["due"])["due"]
    cost_floor = total_work / fastest_speed * cheapest_rate

    subscores = %{
      "makespan" => clamp(lower_makespan / makespan),
      "weighted_tardiness" => clamp(1.0 / (1.0 + weighted_tardiness / tardiness_scale)),
      "load_fairness" => clamp(1.0 - (Enum.max(loads) - Enum.min(loads)) / makespan),
      "resource_cost" => clamp(cost_floor / total_cost)
    }

    score =
      @objective_weights
      |> Enum.map(fn {name, weight} -> subscores[name] * weight end)
      |> Enum.sum()

    %{
      "status" => "ok",
      "instance_id" => example["id"],
      "score" => round_metric(score),
      "objective_subscores" =>
        Map.new(subscores, fn {key, value} -> {key, round_metric(value)} end),
      "metrics" => %{
        "makespan" => round_metric(makespan),
        "weighted_tardiness" => round_metric(weighted_tardiness),
        "load_spread" => round_metric(Enum.max(loads) - Enum.min(loads)),
        "resource_cost" => round_metric(total_cost)
      },
      "dispatch_order" => Enum.map(assignments, & &1["job_id"]),
      "resource_loads" =>
        Map.new(state, fn {id, resource} -> {id, round_metric(resource.busy)} end),
      "late_jobs" => Enum.count(assignments, &(&1["tardiness"] > 0)),
      "schedule" => assignments
    }
  end

  defp ensure(true, _message), do: :ok
  defp ensure(false, message), do: {:error, message}

  defp positive_number?(value), do: is_number(value) and value > 0
  defp clamp(value), do: value |> max(0.0) |> min(1.0)
  defp round_metric(value), do: Float.round(value / 1, 6)

  defp zero_subscores,
    do: Map.new(@objective_weights, fn {name, _weight} -> {name, 0.0} end)

  defp instance_id(%{"id" => id}) when is_binary(id), do: id
  defp instance_id(_example), do: nil

  defp normalize_dataset(dataset) do
    Enum.map(dataset, fn example ->
      resource_ids = Enum.map(example["resources"], & &1["id"])
      Map.update!(example, "jobs", &normalize_jobs(&1, resource_ids))
    end)
  end

  defp normalize_jobs(jobs, resource_ids) do
    Enum.map(jobs, fn
      %{"eligible_resources" => :all} = job ->
        Map.put(job, "eligible_resources", resource_ids)

      job ->
        job
    end)
  end
end
