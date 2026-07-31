defmodule Imp.BenchmarkTruth.OptimizeAnything.V14Readiness do
  @moduledoc false

  alias Imp.Optimize.Anything.Result

  @repository "https://github.com/gepa-ai/optimize-anything-artifact"
  @commit "6388548aac5de93ed3e581de20cc943bb3bee3fe"
  @license_sha256 "10c47467a961feb40adf3294fe27dd9cba79d4d1b7cf27173b1c34586d4126c3"
  @default_authority_root "tmp/optimize-anything-upstream"
  @circle_root "acm_cais_artifact_evaluation/domains/circle_packing"
  @gskill_root "acm_cais_artifact_evaluation/domains/gskill"

  @circle_files %{
    "main.py" => "96ace3c62513c1e14fcf07a20da021ab6428cc0b662565d09bd3812344032686",
    "utils.py" => "6c269ad8568d9060bb9d11372fa0f35a4e0aae5fdb380bc5ba6a57511464824b",
    "llms.py" => "536c35e27e8e6d7c996bb330ce72acba0d58634715c637009d0ae32d2300c04e",
    "requirements.txt" => "e2cdbc3bd3627798ac752d0d38b077bd26202f713b352bb4d1691b25e93db12a",
    "logs/state_tracker_logs.json" =>
      "39d051b1fdbb9ea67405d2490b2587f10a49a3bdff1ecba5d582f6a449fce02f",
    "logs/gepa_state.bin" => "ca0ec9aef9e77e02b6947e54134054b198b4c8a2228be8ab439c4977e020b06d",
    "logs/generated_best_outputs_valset/task_0/iter_0_prog_0.json" =>
      "70c35cf389779a858e7994001bb1baf89ad899822ef03c8d7b159d185ecc2229",
    "logs/generated_best_outputs_valset/task_0/iter_75_prog_25.json" =>
      "801782fab88f6e633eec1ae251cea8a2f0d3d3f3b809acd694b95440149f3985"
  }

  @gskill_files %{
    "README.md" => "3b1aff869b3cd5ffb6026349c3a074faa6d5c444cd9bc69c49b9af879f7b6276",
    "offline_runs/README.md" =>
      "47fbdffa1b335a9c2ee4176f81e69647e62e0fa9dccd34320a244b7354abbee5",
    "gskill/train_optimize_anything.py" =>
      "91c9750500fb733a24ea634bfab849bf3bc6130e2b8d138d25e5afe5d7d4b43f",
    "offline_runs/gepa_skills_training/run_blevesearch_20260131_131944_d7b877/config.json" =>
      "6850abc9204d2f44d3125cb2486bb5c3edcca67fb518ea735f9063abec277e18",
    "offline_runs/gepa_skills_training/run_blevesearch_20260131_131944_d7b877/summary.json" =>
      "99617812f40950c79e40496722bb570319ca5ef6df89239027b43076d9265fdd",
    "offline_runs/gepa_skills_training/run_pallets_20260131_152447_4347c2/config.json" =>
      "8f392d97c374fc2c46c301afdbc025fd79d5877334a511bc17b2e28cf1660916",
    "offline_runs/gepa_skills_training/run_pallets_20260131_152447_4347c2/summary.json" =>
      "a316a733bfa1a42050b9f53ff3707506a1b6ecabcc333f4c410a258ea947a5a1"
  }

  @seed_score 0.9797642169962063
  @retained_score 2.635983362593453
  @seed_code_sha256 "f8c1a8826cbc5bbbf40a5881c6cbaa71ba2db34fe5f4de8c7123d94ac60ee7de"
  @retained_code_sha256 "8bdcda4325bf33ef860d326e28d798ca6e0438bbf385df43ec38adc72cbfb301"
  @retained_prompt_sha256 "61d77cd30eb813c8147fec1ec413368b15163c8c048ba5ff020581e6b679c381"
  @retained_incumbent_sha256 "3e03d4291d66a81988b204bc935f8a289826c475a6e5a0e510974b121433ce1b"
  @retained_solution_sha256 "8f23421330641dbb7a7d323be1e2cb6c0e99ffc023316863063400335e60aa26"

  @gskill_required_paths [
    ["dataset", "revision"],
    ["dataset", "file_hashes"],
    ["repositories", "blevesearch__bleve", "repository"],
    ["repositories", "blevesearch__bleve", "repository_commit"],
    ["repositories", "blevesearch__bleve", "base_commit"],
    ["repositories", "pallets__jinja", "repository"],
    ["repositories", "pallets__jinja", "repository_commit"],
    ["repositories", "pallets__jinja", "base_commit"],
    ["docker_image_digests"],
    ["dependency_locks"],
    ["platform", "os"],
    ["platform", "architecture"],
    ["models", "task"],
    ["models", "reflection"],
    ["seed"],
    ["opportunity", "blevesearch__bleve", "requested_metric_calls"],
    ["opportunity", "blevesearch__bleve", "completed_metric_calls"],
    ["opportunity", "blevesearch__bleve", "proposer"],
    ["opportunity", "pallets__jinja", "requested_metric_calls"],
    ["opportunity", "pallets__jinja", "completed_metric_calls"],
    ["opportunity", "pallets__jinja", "proposer"]
  ]

  @doc "Verifies and projects the released warm Circle state into an Imp OA Result."
  def circle_retained_state!(opts \\ []) do
    root = authority_root(opts)
    verify_authority!(root)
    verify_hashes!(root, @circle_root, @circle_files)

    main = File.read!(Path.join([root, @circle_root, "main.py"]))
    verify_circle_configuration!(main)

    logs = read_json!(Path.join([root, @circle_root, "logs/state_tracker_logs.json"]))
    verify_circle_trajectory!(logs)
    seed = hd(logs)
    retained = List.last(logs)

    best_output =
      read_json!(
        Path.join([
          root,
          @circle_root,
          "logs/generated_best_outputs_valset/task_0/iter_75_prog_25.json"
        ])
      )

    verify_retained_output!(retained, best_output)
    seed_value = circle_value(seed, "released-seed")
    retained_value = circle_value(retained, "released-warm-retained-best")
    seed_evaluation = evaluate_circle_value!(seed_value)
    retained_evaluation = evaluate_circle_value!(retained_value)
    assert_close!(seed_evaluation.score, @seed_score, "deterministic seed geometry score")

    assert_close!(
      retained_evaluation.score,
      @retained_score,
      "deterministic retained geometry score"
    )

    result = %Result{
      candidates: [seed_value, retained_value],
      parents: [[], []],
      validation_scores: [seed_evaluation.score, retained_evaluation.score],
      validation_subscores: [
        %{"circle_packing_26" => seed_evaluation.score},
        %{"circle_packing_26" => retained_evaluation.score}
      ],
      candidate_side_information: [seed_evaluation, retained_evaluation],
      best_outputs_valset: retained_value,
      instance_frontier: %{"circle_packing_26" => [1]},
      objective_scores: [
        %{"sum_radii" => seed_evaluation.score},
        %{"sum_radii" => retained_evaluation.score}
      ],
      objective_frontier: %{"sum_radii" => [1]},
      discovery_evaluation_counts: [1, 114],
      total_metric_calls: 133,
      full_evaluations: 133,
      reflection_calls: nil,
      mode: "released-v1.4-warm-state-projection",
      run_dir: nil,
      seed: 0,
      stop_reason: "retained checkpoint stopped after 133 of 150 allowed metric calls",
      rejected: [],
      history: trajectory_history(logs),
      checkpoint: %{
        "authority_commit" => @commit,
        "gepa_state_sha256" => @circle_files["logs/gepa_state.bin"],
        "source_state_kind" => "warm-resumed-retained-state",
        "candidate_lineage" => "not reconstructable from the retained tracker log",
        "complete_population" => "not reconstructable from the retained tracker log",
        "reflection_calls" => "not reconstructable from the retained tracker log"
      }
    }

    artifact =
      Imp.Optimize.Anything.to_artifact(result,
        provenance: %{
          "authority_repository" => @repository,
          "authority_commit" => @commit,
          "domain" => "circle_packing_26",
          "retained_state" => "warm-resumed",
          "trajectory_metric_calls" => 133,
          "configured_max_metric_calls" => 150,
          "model" => "openai/gpt-5.1",
          "evaluator_timeout_seconds" => 600,
          "gepa_state_sha256" => @circle_files["logs/gepa_state.bin"],
          "candidate_lineage" => "not reconstructable from the retained tracker log",
          "complete_population" => "not reconstructable from the retained tracker log"
        }
      )

    %{
      authority: authority_identity(),
      result: result,
      artifact: artifact,
      seed: seed_evaluation,
      retained: retained_evaluation,
      limitations: [
        "the selected value is a projection of a warm retained upstream state, not a cold Imp optimization",
        "the deterministic replay validates the retained geometry; it does not rerun the evolved Python solver",
        "candidate lineage and the complete candidate population are not reconstructable from the retained tracker log",
        "the retained tracker does not expose an exact reflection-call count"
      ]
    }
  end

  @doc "Validates a retained Circle value without executing its Python code."
  def evaluate_circle_value!(%{
        "kind" => "circle_packing_retained_state",
        "n" => 26,
        "solution" => circles,
        "solution_json" => solution_json,
        "code" => code,
        "refiner_prompt" => prompt,
        "incumbent_json" => incumbent_json
      })
      when is_list(circles) and is_binary(solution_json) and is_binary(code) and
             is_binary(prompt) and is_binary(incumbent_json) do
    unless Jason.decode!(solution_json) == circles do
      raise ArgumentError, "Circle retained solution and source JSON disagree"
    end

    unless length(circles) == 26 and Enum.all?(circles, &valid_circle?/1) do
      raise ArgumentError,
            "Circle retained value must contain exactly 26 finite [x, y, radius] rows"
    end

    boundary_violations =
      circles
      |> Enum.with_index()
      |> Enum.filter(fn {[x, y, radius], _index} ->
        radius < 0 or x - radius < -1.0e-6 or x + radius > 1.0 + 1.0e-6 or
          y - radius < -1.0e-6 or y + radius > 1.0 + 1.0e-6
      end)
      |> Enum.map(&elem(&1, 1))

    overlaps =
      for {left, left_index} <- Enum.with_index(circles),
          {right, right_index} <- Enum.with_index(circles),
          right_index > left_index,
          overlap?(left, right),
          do: [left_index, right_index]

    score = Enum.reduce(circles, 0.0, fn [_x, _y, radius], total -> total + radius end)

    if boundary_violations != [] or overlaps != [] do
      raise ArgumentError,
            "invalid retained Circle geometry: boundary=#{inspect(boundary_violations)} overlaps=#{inspect(overlaps)}"
    end

    %{
      score: score,
      circle_count: 26,
      boundary_violations: [],
      overlaps: [],
      solution_sha256: checksum(solution_json),
      code_sha256: checksum(code),
      refiner_prompt_sha256: checksum(prompt),
      incumbent_sha256: checksum(incumbent_json)
    }
  end

  def evaluate_circle_value!(value) do
    raise ArgumentError, "invalid retained Circle value: #{inspect(value)}"
  end

  @doc "Verifies the released gskill files and rejects their incomplete reproduction identity."
  def gskill_release_readiness(opts \\ []) do
    root = authority_root(opts)
    verify_authority!(root)
    verify_hashes!(root, @gskill_root, @gskill_files)
    observation = released_gskill_observation!(root)

    case audit_gskill_identity(observation) do
      {:error, missing} ->
        {:error,
         %{
           authority: authority_identity(),
           reason: "released gskill evidence cannot support exact artifact reproduction",
           missing: missing,
           observed: observation
         }}

      {:ok, _identity} ->
        raise "released gskill evidence unexpectedly satisfied exact reproduction identity"
    end
  end

  @doc "Checks whether a future gskill replication has a complete, explicit identity."
  def audit_gskill_identity(identity) when is_map(identity) do
    missing =
      Enum.flat_map(@gskill_required_paths, fn path ->
        if present?(get_in(identity, path)), do: [], else: [Enum.join(path, ".")]
      end) ++ split_identity_errors(identity)

    if missing == [], do: {:ok, identity}, else: {:error, Enum.uniq(missing)}
  end

  def audit_gskill_identity(_identity), do: {:error, ["identity"]}

  defp authority_root(opts),
    do: opts |> Keyword.get(:authority_root, @default_authority_root) |> Path.expand()

  defp authority_identity,
    do: %{
      "repository" => @repository,
      "tag" => "v1.4",
      "commit" => @commit,
      "license" => "MIT",
      "license_sha256" => @license_sha256
    }

  defp verify_authority!(root) do
    case System.cmd("git", ["-C", root, "rev-parse", "HEAD"], stderr_to_stdout: true) do
      {output, 0} ->
        if String.trim(output) != @commit,
          do: raise("Optimize Anything authority commit mismatch: #{String.trim(output)}")

      {output, status} ->
        raise "cannot authenticate Optimize Anything authority (git #{status}): #{String.trim(output)}"
    end

    license_hash = root |> Path.join("LICENSE") |> File.read!() |> checksum()

    unless license_hash == @license_sha256,
      do: raise("Optimize Anything authority license hash mismatch: #{license_hash}")
  end

  defp verify_hashes!(root, prefix, hashes) do
    Enum.each(hashes, fn {relative, expected} ->
      path = Path.join([root, prefix, relative])

      unless File.regular?(path),
        do: raise("pinned Optimize Anything source is missing: #{path}")

      actual = path |> File.read!() |> checksum()

      unless actual == expected,
        do: raise("pinned Optimize Anything source hash mismatch for #{relative}: #{actual}")
    end)
  end

  defp verify_circle_configuration!(main) do
    required = [
      ~s(LLM_MODEL = "openai/gpt-5.1"),
      "TIMEOUT = 600",
      ~s|parser.add_argument("--max-metric-calls", type=int, default=150)|,
      "cache_evaluation=True",
      ~s(frontier_type="objective"),
      "refiner=RefinerConfig()",
      "Optimize circle packing code to maximize sum of circle radii within a unit square for N={NUM_CIRCLES} circles."
    ]

    missing = Enum.reject(required, &String.contains?(main, &1))
    if missing != [], do: raise("released Circle configuration drifted: #{inspect(missing)}")
  end

  defp verify_circle_trajectory!(logs) do
    unless is_list(logs) and length(logs) == 133 do
      raise "released Circle tracker must contain 133 ordered metric-call entries"
    end

    calls = Enum.map(logs, & &1["metric_calls"])

    unless calls == Enum.to_list(1..133),
      do: raise("released Circle tracker metric-call order is not 1..133")

    seed = hd(logs)
    retained = List.last(logs)

    assert_equal!(seed["best_score"], @seed_score, "released Circle seed score")
    assert_equal!(retained["best_score"], @retained_score, "released Circle retained score")
    assert_equal!(checksum(seed["best_artifact_code"]), @seed_code_sha256, "seed code hash")

    assert_equal!(
      checksum(retained["best_artifact_refined_code"]),
      @retained_code_sha256,
      "retained code hash"
    )

    assert_equal!(
      checksum(retained["best_artifact_refiner_prompt"]),
      @retained_prompt_sha256,
      "retained refiner prompt hash"
    )

    assert_equal!(
      checksum(retained["best_artifact_arg_current_best_solution"]),
      @retained_incumbent_sha256,
      "retained incumbent hash"
    )

    assert_equal!(
      checksum(retained["best_solution"]),
      @retained_solution_sha256,
      "retained solution hash"
    )

    unless Enum.find_index(logs, &(&1["best_score"] == @retained_score)) == 113,
      do: raise("released Circle retained best was not first observed at metric call 114")
  end

  defp verify_retained_output!(retained, output) do
    assert_equal!(output["best_score"], retained["best_score"], "retained output score")
    assert_equal!(output["best_code"], retained["best_artifact_refined_code"], "retained code")

    assert_equal!(
      output["best_circles"],
      Jason.decode!(retained["best_solution"]),
      "retained circles"
    )
  end

  defp circle_value(entry, identity) do
    code = entry["best_artifact_refined_code"] || entry["best_artifact_code"]
    prompt = entry["best_artifact_refiner_prompt"] || ""
    incumbent = entry["best_artifact_arg_current_best_solution"]

    %{
      "kind" => "circle_packing_retained_state",
      "identity" => identity,
      "n" => 26,
      "code" => code,
      "refiner_prompt" => prompt,
      "incumbent_json" => incumbent || "null",
      "incumbent" => if(incumbent, do: Jason.decode!(incumbent), else: nil),
      "solution_json" => entry["best_solution"],
      "solution" => Jason.decode!(entry["best_solution"]),
      "recorded_score" => entry["best_score"],
      "metric_call" => entry["metric_calls"]
    }
  end

  defp trajectory_history(logs) do
    Enum.map(logs, fn entry ->
      %{
        "metric_call" => entry["metric_calls"],
        "best_score" => entry["best_score"],
        "best_solution_sha256" => checksum(entry["best_solution"] || "null"),
        "best_code_sha256" =>
          checksum(entry["best_artifact_refined_code"] || entry["best_artifact_code"] || "none")
      }
    end)
  end

  defp released_gskill_observation!(root) do
    training = File.read!(Path.join([root, @gskill_root, "gskill/train_optimize_anything.py"]))

    unless String.contains?(
             training,
             ~s|load_dataset("SWE-bench/SWE-smith", split="train")|
           ) and not String.contains?(training, "revision=") do
      raise "released gskill loader no longer has the pinned unrevisioned dataset behavior"
    end

    bleve = gskill_run!(root, "run_blevesearch_20260131_131944_d7b877")
    jinja = gskill_run!(root, "run_pallets_20260131_152447_4347c2")

    assert_gskill_run!(bleve, "blevesearch__bleve", "loop", 300, 300, 0.19, 0.85)
    assert_gskill_run!(jinja, "pallets__jinja", "batch", 300, 307, 0.38, 0.59)

    %{
      "dataset" => %{
        "name" => "SWE-bench/SWE-smith",
        "split" => "train",
        "revision" => nil,
        "file_hashes" => nil
      },
      "splits" => %{
        "train" => %{"count" => 200},
        "selection" => %{"count" => 50},
        "test" => %{"count" => 100}
      },
      "repositories" => %{
        "blevesearch__bleve" => %{
          "repository" => "https://github.com/blevesearch/bleve",
          "repository_commit" => nil,
          "base_commit" => nil
        },
        "pallets__jinja" => %{
          "repository" => "https://github.com/pallets/jinja",
          "repository_commit" => nil,
          "base_commit" => nil
        }
      },
      "docker_image_digests" => nil,
      "dependency_locks" => nil,
      "platform" => %{"os" => nil, "architecture" => nil},
      "models" => %{"task" => "gpt-5-mini", "reflection" => "gpt-5.2-pro"},
      "seed" => 42,
      "opportunity" => %{
        "blevesearch__bleve" => %{
          "requested_metric_calls" => 300,
          "completed_metric_calls" => 300,
          "proposer" => "loop",
          "resumed" => true
        },
        "pallets__jinja" => %{
          "requested_metric_calls" => 300,
          "completed_metric_calls" => 307,
          "proposer" => "batch",
          "resumed" => false
        }
      },
      "released_scores" => %{
        "blevesearch__bleve" => %{"baseline" => 0.19, "selected" => 0.85},
        "pallets__jinja" => %{"baseline" => 0.38, "selected" => 0.59}
      },
      "default_600_call_protocol" => "pygments__pygments",
      "five_seed_status" => "new robustness design, not released v1.4 behavior"
    }
  end

  defp gskill_run!(root, name) do
    run_root =
      Path.join([
        root,
        @gskill_root,
        "offline_runs/gepa_skills_training",
        name
      ])

    %{
      "config" => read_json!(Path.join(run_root, "config.json")),
      "summary" => read_json!(Path.join(run_root, "summary.json"))
    }
  end

  defp assert_gskill_run!(run, repo, proposer, requested, completed, baseline, selected) do
    config = run["config"]
    extra = run["summary"]["extra_info"]

    expected = %{
      "repo" => repo,
      "model" => "gpt-5-mini",
      "reflection_model" => "gpt-5.2-pro",
      "train_size" => 200,
      "val_size" => 50,
      "test_size" => 100,
      "max_metric_calls" => requested,
      "workers" => 16,
      "seed" => 42,
      "proposer" => proposer
    }

    Enum.each(expected, fn {key, value} ->
      assert_equal!(config[key], value, "gskill #{repo} #{key}")
    end)

    assert_equal!(extra["total_metric_calls"], completed, "gskill #{repo} completed calls")
    assert_equal!(extra["baseline_test_score"], baseline, "gskill #{repo} baseline")
    assert_equal!(extra["optimized_test_score"], selected, "gskill #{repo} selected")
  end

  defp split_identity_errors(identity) do
    [{"train", 200}, {"selection", 50}, {"test", 100}]
    |> Enum.flat_map(fn {name, count} ->
      split = get_in(identity, ["splits", name]) || %{}
      ids = split["ordered_task_ids"]
      hashes = split["ordered_task_hashes"]

      []
      |> maybe_missing(
        is_list(ids) and length(ids) == count,
        "splits.#{name}.ordered_task_ids[#{count}]"
      )
      |> maybe_missing(
        is_list(hashes) and length(hashes) == count,
        "splits.#{name}.ordered_task_hashes[#{count}]"
      )
    end)
  end

  defp maybe_missing(errors, true, _label), do: errors
  defp maybe_missing(errors, false, label), do: errors ++ [label]

  defp present?(value) when is_binary(value), do: value != ""
  defp present?(value) when is_map(value), do: map_size(value) > 0
  defp present?(value) when is_list(value), do: value != []
  defp present?(value) when is_integer(value) or is_float(value), do: true
  defp present?(_value), do: false

  defp valid_circle?([x, y, radius]),
    do: Enum.all?([x, y, radius], &(is_number(&1) and finite?(&1)))

  defp valid_circle?(_circle), do: false

  defp finite?(number) when is_integer(number), do: true
  defp finite?(number) when is_float(number), do: number == number and abs(number) < 1.0e308

  defp overlap?([x1, y1, r1], [x2, y2, r2]) do
    distance = :math.sqrt(:math.pow(x1 - x2, 2) + :math.pow(y1 - y2, 2))
    distance < r1 + r2 - 1.0e-6
  end

  defp read_json!(path), do: path |> File.read!() |> Jason.decode!()

  defp checksum(value) when is_binary(value),
    do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp assert_equal!(actual, expected, label) do
    unless actual == expected,
      do: raise("#{label} mismatch: expected #{inspect(expected)}, got #{inspect(actual)}")
  end

  defp assert_close!(actual, expected, label) do
    unless abs(actual - expected) <= 1.0e-12,
      do: raise("#{label} mismatch: expected #{inspect(expected)}, got #{inspect(actual)}")
  end
end
