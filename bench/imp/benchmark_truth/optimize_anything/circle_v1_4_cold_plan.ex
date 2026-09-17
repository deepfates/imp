defmodule Imp.BenchmarkTruth.OptimizeAnything.CircleV14ColdPlan do
  @moduledoc false

  alias Imp.Optimize.Anything
  alias Imp.Optimize.Anything.Config

  @authority_commit "6388548aac5de93ed3e581de20cc943bb3bee3fe"
  @dspy_commit "29448ae12756abdd14bd8796c819247ebb83673c"
  @seed_code_sha256 "f8c1a8826cbc5bbbf40a5881c6cbaa71ba2db34fe5f4de8c7123d94ac60ee7de"
  @source_sha256 %{
    "main.py" => "96ace3c62513c1e14fcf07a20da021ab6428cc0b662565d09bd3812344032686",
    "utils.py" => "6c269ad8568d9060bb9d11372fa0f35a4e0aae5fdb380bc5ba6a57511464824b",
    "llms.py" => "536c35e27e8e6d7c996bb330ce72acba0d58634715c637009d0ae32d2300c04e",
    "requirements.txt" => "e2cdbc3bd3627798ac752d0d38b077bd26202f713b352bb4d1691b25e93db12a"
  }

  def design do
    %{
      condition: "imp-88sn-circle-v1.4-cold-provider-free-probe",
      authority: %{optimize_anything: @authority_commit, dspy: @dspy_commit},
      source_sha256: @source_sha256,
      seed_code_sha256: @seed_code_sha256,
      n: 26,
      model: "openai/gpt-5.1",
      released_config: %{
        timeout_seconds: 600,
        semantic_max_metric_calls: 150,
        parallel: true,
        cache_evaluation: true,
        frontier_type: :objective,
        max_refinements: 1
      },
      exercised_probe: %{
        timeout_seconds: 30,
        semantic_max_metric_calls: 1,
        parallel: false,
        max_candidate_proposals: 0,
        status: :readiness_only
      },
      exercised_opportunity: %{
        imp: %{logical_metric_calls: 1, exact_evaluator_executions: 2, refiner_lm_calls: 1},
        upstream: %{logical_metric_calls: 1, exact_evaluator_executions: 1, refiner_lm_calls: 1},
        upstream_cache_effect:
          "identical refined code collapsed the second exact evaluation, so upstream exposes no second current_best input in this probe"
      },
      state: "cold seed/current_best; released 133-call warm state is separate evidence",
      boundaries: %{
        evaluator: "pinned Python subprocess; current_best reconstructed as a (26,3) ndarray",
        imp: "ordinary Imp.Optimize.Anything.run/3 and schema-3 value Artifact",
        upstream: "ordinary gepa.optimize_anything.optimize_anything entry",
        trusted_consumer: "fresh OS loads value then invokes the pinned evaluator"
      },
      accounting_note:
        "the pinned OA engine and Imp charge refiner attempts differently; no five-seed ceiling is claimed until a task-owned exact-config planner derives each engine's loop-boundary overshoot"
    }
  end

  def exact_evaluate!(candidate, opts \\ []) when is_map(candidate) do
    root = Keyword.get(opts, :authority_root, "tmp/optimize-anything-upstream")
    dspy_root = Keyword.get(opts, :dspy_root, "tmp/dspy-3.2.1")

    payload = %{
      "code" => Map.fetch!(candidate, "code"),
      "timeout" => Keyword.get(opts, :timeout, 30),
      "current_best_solution" => Keyword.get(opts, :current_best_solution)
    }

    args = [
      "run",
      "--project",
      root,
      "--with",
      "numpy",
      "--with",
      "scipy",
      "--with-editable",
      dspy_root,
      "python",
      "scripts/circle_v1_4_probe.py",
      "--authority-root",
      root,
      "--dspy-root",
      dspy_root,
      "--mode",
      "evaluate",
      "--payload-json",
      Jason.encode!(payload)
    ]

    env = [{"PYTHONPATH", Enum.join([Path.join(root, "src"), dspy_root], ":")}]

    case System.cmd("uv", args, env: env, stderr_to_stdout: true) do
      {output, 0} ->
        result = output |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()

        if result["success"],
          do: result,
          else: raise("Circle evaluator failed: #{result["error"]}")

      {output, status} ->
        raise "Circle evaluator process failed (#{status}): #{String.trim(output)}"
    end
  end

  def imp_probe!(opts \\ []) do
    identity = identity!(opts)
    objective = identity["objective"]
    background = identity["background"]

    seed = %{
      "code" => identity["seed_code"],
      "refiner_prompt" => identity["refiner_prompt"]
    }

    {:ok, state} = Agent.start_link(fn -> %{best: nil, score: :negative_infinity, trace: []} end)

    evaluator = fn candidate ->
      current = Agent.get(state, & &1.best)
      result = exact_evaluate!(candidate, Keyword.put(opts, :current_best_solution, current))

      Agent.update(state, fn prior ->
        better? = prior.score == :negative_infinity or result["score"] > prior.score

        %{
          best: if(better?, do: result["circles"], else: prior.best),
          score: if(better?, do: result["score"], else: prior.score),
          trace:
            prior.trace ++
              [
                %{
                  input_sha256: result["current_best_input_sha256"],
                  output_sha256: result["circles_sha256"]
                }
              ]
        }
      end)

      {result["score"], %{"circles" => result["circles"], "code_sha256" => result["code_sha256"]}}
    end

    lm =
      Imp.LM.Static.new(
        handler: fn _messages, _lm_opts -> Jason.encode!(Map.take(seed, ["code"])) end
      )

    result =
      Anything.run(seed, evaluator,
        objective: objective,
        background: background,
        config:
          Config.new(
            engine: [
              max_metric_calls: 1,
              max_candidate_proposals: 0,
              parallel: false,
              max_workers: 1,
              cache_evaluation: true,
              frontier_type: :objective,
              track_best_outputs: true
            ],
            reflection: [reflection_lm: lm],
            refiner: [refiner_lm: lm, max_refinements: 1]
          )
      )

    artifact =
      Anything.to_artifact(result, provenance: %{"authority_commit" => @authority_commit})

    trace = Agent.get(state, & &1.trace)
    Agent.stop(state)

    %{result: result, artifact: artifact, evaluator_calls: length(trace), evaluator_trace: trace}
  end

  def identity!(opts \\ []) do
    root = Keyword.get(opts, :authority_root, "tmp/optimize-anything-upstream")
    dspy_root = Keyword.get(opts, :dspy_root, "tmp/dspy-3.2.1")
    env = [{"PYTHONPATH", Enum.join([Path.join(root, "src"), dspy_root], ":")}]

    args = [
      "run",
      "--project",
      root,
      "--with",
      "numpy",
      "--with",
      "scipy",
      "--with-editable",
      dspy_root,
      "python",
      "scripts/circle_v1_4_probe.py",
      "--authority-root",
      root,
      "--dspy-root",
      dspy_root,
      "--mode",
      "identity"
    ]

    case System.cmd("uv", args, env: env, stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> List.last()
        |> Jason.decode!()
        |> validate_identity!()

      {output, status} ->
        raise "Circle identity process failed (#{status}): #{String.trim(output)}"
    end
  end

  def upstream_probe!(opts \\ []) do
    root = Keyword.get(opts, :authority_root, "tmp/optimize-anything-upstream")
    dspy_root = Keyword.get(opts, :dspy_root, "tmp/dspy-3.2.1")
    env = [{"PYTHONPATH", Enum.join([Path.join(root, "src"), dspy_root], ":")}]

    args = [
      "run",
      "--project",
      root,
      "--with",
      "numpy",
      "--with",
      "scipy",
      "--with-editable",
      dspy_root,
      "python",
      "scripts/circle_v1_4_probe.py",
      "--authority-root",
      root,
      "--dspy-root",
      dspy_root,
      "--mode",
      "upstream-probe"
    ]

    case System.cmd("uv", args, env: env, stderr_to_stdout: true) do
      {output, 0} -> output |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()
      {output, status} -> raise "Circle upstream probe failed (#{status}): #{String.trim(output)}"
    end
  end

  defp validate_identity!(identity) do
    authority = Map.fetch!(identity, "authority")

    unless authority["commit"] == @authority_commit and
             authority["dspy_commit"] == @dspy_commit and
             authority["source_sha256"] == @source_sha256 and
             identity["seed_code_sha256"] == @seed_code_sha256 do
      raise ArgumentError, "Circle pinned source identity mismatch"
    end

    identity
  end
end
