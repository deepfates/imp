defmodule LocalOptimizeAnythingRetryPolicy.Atomic do
  def write!(path, value) do
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

defmodule LocalOptimizeAnythingRetryPolicy.Task do
  @seed %{
    "base_ms" => 500,
    "cap_ms" => 8_000,
    "honor_server_hint" => false,
    "jitter_ms" => 0,
    "reject_non_retryable" => true,
    "urgent_attempt_limit" => -1
  }

  @train [
    {"train-reject", 3, false, false, 0, 2, -1},
    {"train-hint", 2, true, false, 1_200, 1, 1_200},
    {"train-cap", 1, true, false, 12_000, 0, 8_000},
    {"train-urgent", 0, true, true, 0, 3, 0},
    {"train-zero", 0, true, false, 0, 0, 500},
    {"train-one", 1, true, false, 0, 2, 1_000},
    {"train-two", 2, true, false, 0, 1, 2_000},
    {"train-three", 3, true, false, 0, 3, 4_000}
  ]
  @selection [
    {"selection-urgent-one", 1, true, true, 0, 0, 0},
    {"selection-urgent-expired", 2, true, true, 0, 2, 2_000},
    {"selection-hint-precedence", 0, true, true, 725, 3, 725},
    {"selection-late", 4, true, false, 0, 3, 8_000},
    {"selection-hint-cap", 0, true, false, 9_500, 1, 8_000},
    {"selection-reject", 0, false, true, 900, 0, -1}
  ]
  @test [
    {"test-hint", 5, true, false, 640, 2, 640},
    {"test-urgent-new", 0, true, true, 0, 1, 0},
    {"test-one-jitter", 1, true, false, 0, 3, 1_000},
    {"test-three", 3, true, false, 0, 0, 4_000},
    {"test-cap", 5, true, false, 0, 2, 8_000},
    {"test-reject-hint", 2, false, false, 600, 3, -1}
  ]

  def seed, do: @seed
  def train, do: Enum.map(@train, &row/1)
  def selection, do: Enum.map(@selection, &row/1)
  def test, do: Enum.map(@test, &row/1)

  def evaluate(candidate, row) when is_map(candidate) and is_map(row) do
    with :ok <- validate(candidate),
         actual <- apply_policy(candidate, row) do
      exact = actual == row.expected
      distance = abs(actual - row.expected)
      proximity = max(0.0, 1.0 - distance / 8_001)
      score = if exact, do: 1.0, else: 0.2 * proximity

      {score,
       %{
         id: row.id,
         expected: row.expected,
         actual: actual,
         exact: exact,
         feedback: feedback(candidate, row, actual)
       }}
    else
      {:error, reason} -> {0.0, %{id: row.id, error: reason, feedback: reason}}
    end
  end

  def evaluate(_candidate, row), do: {0.0, %{id: row.id, error: "candidate must be a map"}}

  defp validate(candidate) do
    if candidate == Map.take(candidate, Map.keys(@seed)) and
         Map.keys(candidate) == Map.keys(@seed) and
         is_integer(candidate["base_ms"]) and candidate["base_ms"] > 0 and
         is_integer(candidate["cap_ms"]) and candidate["cap_ms"] > 0 and
         is_integer(candidate["jitter_ms"]) and candidate["jitter_ms"] >= 0 and
         is_integer(candidate["urgent_attempt_limit"]) and
         is_boolean(candidate["honor_server_hint"]) and
         is_boolean(candidate["reject_non_retryable"]) do
      :ok
    else
      {:error, "preserve the exact typed retry-policy schema and positive bounds"}
    end
  end

  defp apply_policy(candidate, row) do
    cond do
      candidate["reject_non_retryable"] and not row.retryable ->
        -1

      candidate["honor_server_hint"] and row.retry_after_ms > 0 ->
        min(candidate["cap_ms"], row.retry_after_ms)

      row.urgent and row.attempt <= candidate["urgent_attempt_limit"] ->
        0

      true ->
        delay = candidate["base_ms"] * Integer.pow(2, row.attempt)
        min(candidate["cap_ms"], delay + candidate["jitter_ms"] * row.jitter_slot)
    end
  end

  defp feedback(candidate, row, actual) do
    cond do
      actual == row.expected ->
        "correct behavior for #{row.id}"

      row.retry_after_ms > 0 and not candidate["honor_server_hint"] ->
        "server retry-after hints must take precedence for #{row.id}"

      row.urgent and row.attempt <= 1 and candidate["urgent_attempt_limit"] < row.attempt ->
        "urgent attempts zero and one must retry immediately for #{row.id}"

      true ->
        "expected #{row.expected}ms but policy returned #{actual}ms for #{row.id}"
    end
  end

  defp row({id, attempt, retryable, urgent, hint, jitter, expected}) do
    %{
      id: id,
      attempt: attempt,
      retryable: retryable,
      urgent: urgent,
      retry_after_ms: hint,
      jitter_slot: jitter,
      expected: expected
    }
  end
end

defmodule LocalOptimizeAnythingRetryPolicy.ObservedLM do
  defstruct [:inner, :owner]

  def generate(lm, messages, opts) do
    send(lm.owner, {:proposal_call, messages})
    Imp.LM.generate(lm.inner, messages, opts)
  end

  def response_format_capability(%__MODULE__{inner: inner}),
    do: Imp.LM.response_format_capability(inner)
end

defmodule LocalOptimizeAnythingRetryPolicy.Runner do
  alias Imp.Optimize.Anything
  alias Imp.Optimize.Anything.{Config, Result}
  alias LocalOptimizeAnythingRetryPolicy.{Atomic, ObservedLM, Task}

  @model "phi4:latest"
  @digest "ac896e5b8b34a1f4efa7b14d7520725140d5512484457fab45d2a4ea14c69dba"
  @treatment_id "local-oa-retry-policy-typed-round-robin-v1"

  def run do
    cond do
      System.get_env("IMP_OA_FRESH") == "1" -> fresh()
      System.get_env("IMP_OA_SELECTED_ONLY") == "1" -> selected_only()
      true -> parent()
    end
  end

  defp parent do
    paths = paths!()
    require_new_output!(paths.output)
    run_parent(paths)
  end

  defp run_parent(paths) do
    verify_model!()

    result =
      Anything.run(Task.seed(), &Task.evaluate/2,
        dataset: Task.train(),
        valset: Task.selection(),
        objective:
          "Produce correct bounded retry delays: reject non-retryable work, honor server hints, retry urgent attempts zero and one immediately, then use capped exponential backoff.",
        background:
          "The artifact is a complete typed configuration. Every field is behaviorally evaluated; strict shape alone earns no reward.",
        config:
          Config.new(
            engine: [
              max_candidate_proposals: 6,
              seed: 29,
              raise_on_exception: false,
              parallel: false,
              max_workers: 1,
              cache_evaluation: false,
              acceptance_criterion: :strict_improvement
            ],
            reflection: [
              reflection_lm: proposal_lm(),
              module_selector: :round_robin,
              structured_response_format: :required
            ]
          )
      )

    selected = Result.best_candidate(result)
    selected_path = Path.join(paths.output, "selected-artifact.json")
    result_path = Path.join(paths.output, "optimizer-result.json")
    Atomic.write!(result_path, Result.to_map(result))
    Atomic.write!(selected_path, selected)

    proposal_calls = collect_proposal_calls([])
    optimization = optimization_stage(result, selected, proposal_calls)
    Atomic.write!(Path.join(paths.output, "01-optimization.json"), optimization)
    require_optimization!(optimization)

    baseline_test = evaluate_stage(Task.seed(), Task.test())
    selected_test = evaluate_stage(selected, Task.test())
    test_stage = %{baseline: baseline_test, selected: selected_test}
    Atomic.write!(Path.join(paths.output, "02-untouched-test.json"), test_stage)

    fresh_path = Path.join(paths.output, "03-fresh-test.json")
    {output, status} = fresh_process(paths, selected_path, fresh_path)
    if status != 0, do: raise("fresh OS BEAM failed: #{output}")
    fresh = fresh_path |> File.read!() |> Jason.decode!()

    unless fresh["reproduction_sha256"] == selected_test.reproduction_sha256,
      do: raise("fresh selected retry behavior differs")

    summary = %{
      status: "complete",
      treatment_id: @treatment_id,
      scope: "one local mixed-type Optimize Anything retry-policy lifecycle",
      split_sizes: %{train: 8, selection: 6, untouched_test: 6},
      model: @model,
      model_digest: @digest,
      proposal_calls: proposal_calls,
      baseline_selection_score: optimization.baseline_score,
      selected_selection_score: optimization.selected_score,
      selected: optimization.selected,
      untouched_test: %{
        baseline: Map.take(baseline_test, [:score, :exact]),
        selected: Map.take(selected_test, [:score, :exact])
      },
      fresh_byte_identical: true,
      claim_boundary:
        "One task/model mixed-type optimization and fresh artifact lifecycle; not general Optimize Anything effectiveness, schema-v2 evidence, parity, or BEAM superiority."
    }

    Atomic.write!(Path.join(paths.output, "result.json"), summary)
    IO.puts(Jason.encode!(summary, pretty: true))
  rescue
    error ->
      Atomic.write!(Path.join(paths.output, "failure.json"), %{
        status: "stopped",
        error: Exception.format(:error, error, __STACKTRACE__)
      })

      reraise error, __STACKTRACE__
  end

  defp fresh do
    selected = System.fetch_env!("IMP_OA_ARTIFACT") |> File.read!() |> Jason.decode!()
    stage = evaluate_stage(selected, Task.test())
    Atomic.write!(System.fetch_env!("IMP_OA_FRESH_OUTPUT"), stage)
  end

  defp selected_only do
    paths = paths!()

    optimization =
      paths.output |> Path.join("01-optimization.json") |> File.read!() |> Jason.decode!()

    require_optimization!(optimization)

    selected_path = Path.join(paths.output, "selected-artifact.json")
    selected = selected_path |> File.read!() |> Jason.decode!()
    baseline_test = evaluate_stage(Task.seed(), Task.test())
    selected_test = evaluate_stage(selected, Task.test())

    Atomic.write!(Path.join(paths.output, "02-untouched-test.json"), %{
      baseline: baseline_test,
      selected: selected_test
    })

    fresh_path = Path.join(paths.output, "03-fresh-test.json")
    {output, status} = fresh_process(paths, selected_path, fresh_path)
    if status != 0, do: raise("fresh OS BEAM failed: #{output}")
    fresh = fresh_path |> File.read!() |> Jason.decode!()

    unless fresh["reproduction_sha256"] == selected_test.reproduction_sha256,
      do: raise("fresh selected retry behavior differs")

    summary = %{
      status: "complete_with_rejected_proposal",
      scope: "one local mixed-type Optimize Anything retry-policy lifecycle",
      split_sizes: %{train: 8, selection: 6, untouched_test: 6},
      model: @model,
      model_digest: @digest,
      proposal_calls: optimization["proposal_calls"],
      baseline_selection_score: optimization["baseline_score"],
      selected_selection_score: optimization["selected_score"],
      selected: optimization["selected"],
      untouched_test: %{
        baseline: Map.take(baseline_test, [:score, :exact]),
        selected: Map.take(selected_test, [:score, :exact])
      },
      fresh_byte_identical: true,
      claim_boundary:
        "One task/model strict proposal-rejection and fresh artifact lifecycle; no admitted mutation and not general Optimize Anything effectiveness, schema-v2 evidence, parity, or BEAM superiority."
    }

    Atomic.write!(Path.join(paths.output, "result.json"), summary)
    IO.puts(Jason.encode!(summary, pretty: true))
  rescue
    error ->
      paths = paths!()

      Atomic.write!(Path.join(paths.output, "continuation-failure.json"), %{
        status: "stopped",
        error: Exception.format(:error, error, __STACKTRACE__)
      })

      reraise error, __STACKTRACE__
  end

  defp proposal_lm do
    %ObservedLM{
      owner: self(),
      inner:
        Imp.req_llm("ollama:" <> @model,
          cache: false,
          temperature: 0,
          max_tokens: 512,
          max_retries: 0,
          timeout: 120_000,
          req_http_options: [retry: false, max_retries: 0]
        )
    }
  end

  defp optimization_stage(result, selected, proposal_calls) do
    baseline_score = hd(result.validation_scores)
    selected_score = Enum.max(result.validation_scores)

    %{
      status: "complete",
      candidate_count: length(result.candidates),
      baseline_score: baseline_score,
      selected_score: selected_score,
      selected: if(selected == Task.seed(), do: "baseline", else: "mutated"),
      selected_artifact: selected,
      proposal_calls: proposal_calls,
      rejected: Imp.Optimizer.Report.json_safe(result.rejected),
      result: Result.to_map(result)
    }
  end

  defp require_optimization!(stage) do
    proposal_calls = Map.get(stage, :proposal_calls, Map.get(stage, "proposal_calls"))
    candidate_count = Map.get(stage, :candidate_count, Map.get(stage, "candidate_count"))
    rejected = Map.get(stage, :rejected, Map.get(stage, "rejected", []))

    unless is_integer(proposal_calls) and proposal_calls > 0 and candidate_count >= 1 and
             (candidate_count > 1 or rejected != []),
           do:
             raise(
               "Optimize Anything did not execute the frozen component proposals: #{inspect(stage)}"
             )
  end

  defp evaluate_stage(candidate, rows) do
    results =
      Enum.map(rows, fn row ->
        {score, info} = Task.evaluate(candidate, row)

        %{
          id: row.id,
          score: score,
          expected: row.expected,
          actual: info[:actual],
          error: info[:error]
        }
      end)

    %{
      rows: results,
      score: Enum.sum(Enum.map(results, & &1.score)) / length(results),
      exact: Enum.count(results, &(&1.score == 1.0)),
      reproduction_sha256: sha256(Enum.map(results, &Map.take(&1, [:id, :actual, :error])))
    }
  end

  defp collect_proposal_calls(calls) do
    receive do
      {:proposal_call, _messages} -> collect_proposal_calls([:call | calls])
    after
      0 -> length(calls)
    end
  end

  defp verify_model! do
    models = Req.get!("http://127.0.0.1:11434/api/tags", retry: false).body["models"]

    unless Enum.any?(models, &(&1["name"] == @model and &1["digest"] == @digest)),
      do: raise("pinned local model is absent or changed")
  end

  defp fresh_process(paths, artifact_path, output_path) do
    System.cmd("mix", ["run", "--no-compile", "--no-deps-check", __ENV__.file],
      cd: paths.imp,
      env: [
        {"MIX_ENV", "dev"},
        {"IMP_PATH", paths.imp},
        {"IMP_OA_OUTPUT", paths.output},
        {"IMP_OA_FRESH", "1"},
        {"IMP_OA_ARTIFACT", artifact_path},
        {"IMP_OA_FRESH_OUTPUT", output_path}
      ],
      stderr_to_stdout: true
    )
  end

  defp paths! do
    imp = System.get_env("IMP_PATH", Path.expand("../..", __DIR__)) |> Path.expand()

    %{
      imp: imp,
      output:
        System.get_env(
          "IMP_OA_OUTPUT",
          "/Users/deepfates/.cache/imp/optimize-anything/#{@treatment_id}"
        )
        |> Path.expand()
    }
  end

  defp require_new_output!(path) do
    case File.ls(path) do
      {:error, :enoent} -> :ok
      {:ok, []} -> :ok
      {:ok, _entries} -> raise("IMP_OA_OUTPUT must be a new empty directory")
      {:error, reason} -> raise("cannot inspect IMP_OA_OUTPUT: #{inspect(reason)}")
    end
  end

  defp sha256(value),
    do:
      value |> Jason.encode!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
end

cond do
  System.get_env("IMP_OA_DEFINE_ONLY") == "1" ->
    :ok

  System.get_env("IMP_88SN_MODE") ->
    Code.require_file("usefulness.exs", __DIR__)
    LocalOptimizeAnythingRetryPolicy.Usefulness.run()

  true ->
    LocalOptimizeAnythingRetryPolicy.Runner.run()
end
