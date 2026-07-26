defmodule LocalOptimizeAnythingProviderFree.Atomic do
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

defmodule LocalOptimizeAnythingProviderFree.RetryController do
  @seed %{"enabled" => false, "max_attempts" => 1, "base_delay_ms" => 1_000}
  @target %{"enabled" => true, "max_attempts" => 3, "base_delay_ms" => 250}

  @train [
    %{id: "retry-train-1", split: :train, attempt: 0, retryable: true, expected: "retry:250"},
    %{id: "retry-train-2", split: :train, attempt: 2, retryable: true, expected: "retry:750"},
    %{id: "retry-train-3", split: :train, attempt: 0, retryable: false, expected: "drop"}
  ]
  @selection [
    %{
      id: "retry-select-1",
      split: :selection,
      attempt: 1,
      retryable: true,
      expected: "retry:500"
    },
    %{id: "retry-select-2", split: :selection, attempt: 3, retryable: true, expected: "escalate"}
  ]
  @test [
    %{id: "retry-test-1", split: :test, attempt: 0, retryable: false, expected: "drop"},
    %{id: "retry-test-2", split: :test, attempt: 2, retryable: true, expected: "retry:750"},
    %{id: "retry-test-3", split: :test, attempt: 4, retryable: true, expected: "escalate"}
  ]

  def id, do: "retry-controller"
  def seed, do: @seed
  def target, do: @target
  def train, do: @train
  def selection, do: @selection
  def test, do: @test

  def execute(artifact, row) do
    cond do
      not artifact["enabled"] -> "manual"
      not row.retryable -> "drop"
      row.attempt >= artifact["max_attempts"] -> "escalate"
      true -> "retry:#{artifact["base_delay_ms"] * (row.attempt + 1)}"
    end
  end

  def evaluate(artifact, row) do
    actual = execute(artifact, row)
    {if(actual == row.expected, do: 1.0, else: 0.0), %{actual: actual, expected: row.expected}}
  end
end

defmodule LocalOptimizeAnythingProviderFree.JobScheduler do
  @seed %{"ordering" => "fifo", "reserve_specialist" => false, "batch_size" => 1}
  @target %{"ordering" => "earliest_due", "reserve_specialist" => true, "batch_size" => 2}

  @train (
           job = fn id, due, kind -> %{id: id, due: due, kind: kind} end

           [
             %{
               id: "schedule-train-1",
               split: :train,
               jobs: [
                 job.("general-old", 9, "general"),
                 job.("special", 5, "special"),
                 job.("general-hot", 2, "general")
               ],
               expected: %{
                 order: ["special", "general-hot", "general-old"],
                 batches: [["special", "general-hot"], ["general-old"]]
               }
             },
             %{
               id: "schedule-train-2",
               split: :train,
               jobs: [
                 job.("routine", 8, "general"),
                 job.("gpu", 7, "special"),
                 job.("urgent", 3, "general")
               ],
               expected: %{
                 order: ["gpu", "urgent", "routine"],
                 batches: [["gpu", "urgent"], ["routine"]]
               }
             }
           ]
         )
  @selection (
               job = fn id, due, kind -> %{id: id, due: due, kind: kind} end

               [
                 %{
                   id: "schedule-select-1",
                   split: :selection,
                   jobs: [
                     job.("later", 12, "general"),
                     job.("precision", 6, "special"),
                     job.("soon", 4, "general")
                   ],
                   expected: %{
                     order: ["precision", "soon", "later"],
                     batches: [["precision", "soon"], ["later"]]
                   }
                 },
                 %{
                   id: "schedule-select-2",
                   split: :selection,
                   jobs: [
                     job.("first", 10, "general"),
                     job.("accelerated", 8, "special"),
                     job.("second", 5, "general")
                   ],
                   expected: %{
                     order: ["accelerated", "second", "first"],
                     batches: [["accelerated", "second"], ["first"]]
                   }
                 }
               ]
             )
  @test (
          job = fn id, due, kind -> %{id: id, due: due, kind: kind} end

          [
            %{
              id: "schedule-test-1",
              split: :test,
              jobs: [
                job.("bulk", 20, "general"),
                job.("critical", 9, "special"),
                job.("standard", 7, "general")
              ],
              expected: %{
                order: ["critical", "standard", "bulk"],
                batches: [["critical", "standard"], ["bulk"]]
              }
            },
            %{
              id: "schedule-test-2",
              split: :test,
              jobs: [
                job.("alpha", 14, "general"),
                job.("beta", 4, "general"),
                job.("gamma", 11, "special")
              ],
              expected: %{
                order: ["gamma", "beta", "alpha"],
                batches: [["gamma", "beta"], ["alpha"]]
              }
            }
          ]
        )

  def id, do: "job-scheduler"
  def seed, do: @seed
  def target, do: @target
  def train, do: @train
  def selection, do: @selection
  def test, do: @test

  def execute(artifact, row) do
    jobs =
      case artifact["ordering"] do
        "earliest_due" -> Enum.sort_by(row.jobs, & &1.due)
        "fifo" -> row.jobs
      end

    jobs =
      if artifact["reserve_specialist"] do
        Enum.sort_by(jobs, &if(&1.kind == "special", do: 0, else: 1))
      else
        jobs
      end

    order = Enum.map(jobs, & &1.id)
    %{order: order, batches: Enum.chunk_every(order, artifact["batch_size"])}
  end

  def evaluate(artifact, row) do
    actual = execute(artifact, row)

    matches =
      Enum.zip(actual.order, row.expected.order)
      |> Enum.count(fn {left, right} -> left == right end)

    order_score = matches / length(row.expected.order)
    batch_score = if actual.batches == row.expected.batches, do: 1.0, else: 0.0
    {0.8 * order_score + 0.2 * batch_score, %{actual: actual, expected: row.expected}}
  end
end

defmodule LocalOptimizeAnythingProviderFree.TargetStrategy do
  @behaviour Imp.Optimize.Anything.StructuredStrategy

  @impl true
  def propose(candidate, dataset, components, %{"target" => target}) do
    unless is_map(candidate) and is_map(dataset) and is_list(components),
      do: raise("strategy did not receive native OA values")

    {:ok, target, %{"proposal" => "deterministic-domain-candidate"}}
  end
end

defmodule LocalOptimizeAnythingProviderFree.InvalidStrategy do
  @behaviour Imp.Optimize.Anything.StructuredStrategy

  @impl true
  def propose(candidate, _dataset, _components, %{"mode" => "partial"}),
    do: Map.delete(candidate, "max_attempts")

  def propose(candidate, _dataset, _components, %{"mode" => "unselected"}),
    do: %{candidate | "reserve_specialist" => true, "batch_size" => 2}
end

defmodule LocalOptimizeAnythingProviderFree.Runner do
  alias Imp.Optimize.Anything
  alias Imp.Optimize.Anything.{Config, Result, StructuredStrategy}

  alias LocalOptimizeAnythingProviderFree.{
    Atomic,
    InvalidStrategy,
    JobScheduler,
    RetryController,
    TargetStrategy
  }

  @domains [RetryController, JobScheduler]

  def run do
    if System.get_env("IMP_OA_PROVIDER_FREE_FRESH") == "1", do: fresh(), else: parent()
  end

  defp parent do
    output = output!()
    require_empty!(output)

    summaries = Enum.map(@domains, &optimize_domain(&1, output))
    Atomic.write!(Path.join(output, "summary.json"), %{status: "complete", domains: summaries})

    code_paths =
      :code.get_path()
      |> Enum.map(&List.to_string/1)
      |> Enum.flat_map(&["-pa", &1])

    {fresh_output, status} =
      System.cmd(System.find_executable("elixir"), code_paths ++ [__ENV__.file],
        env: [
          {"IMP_OA_PROVIDER_FREE_FRESH", "1"},
          {"IMP_OA_PROVIDER_FREE_OUTPUT", output}
        ],
        stderr_to_stdout: true
      )

    if status != 0, do: raise("fresh consumer failed: #{fresh_output}")

    fresh = output |> Path.join("fresh.json") |> File.read!() |> Jason.decode!()

    Enum.each(summaries, fn summary ->
      unless get_in(fresh, [summary.id, "sha256"]) == summary.test_sha256,
        do: raise("fresh #{summary.id} behavior changed")
    end)

    Atomic.write!(Path.join(output, "complete.json"), %{
      status: "complete",
      domains: summaries,
      fresh_process_byte_identical: true,
      claim_boundary:
        "Two deterministic Imp-native structured OA applications; not pinned text-map parity, model-backed proposal quality, or general effectiveness."
    })

    IO.puts("provider-free Optimize Anything applications completed in #{output}")
  end

  defp optimize_domain(domain, output) do
    id = domain.id()
    directory = Path.join(output, id)
    {:ok, calls} = Agent.start_link(fn -> [] end)

    try do
      evaluator = fn artifact, row ->
        Agent.update(calls, &[{row.split, row.id} | &1])
        domain.evaluate(artifact, row)
      end

      strategy =
        StructuredStrategy.new(TargetStrategy,
          id: "#{id}/target-v1",
          config: %{"target" => domain.target()}
        )

      config =
        Config.new(
          engine: [max_candidate_proposals: 1, seed: 37, cache_evaluation: false],
          reflection: [module_selector: :all, structured_strategy: strategy]
        )

      checkpoint =
        try do
          Anything.run(domain.seed(), evaluator,
            dataset: domain.train(),
            valset: domain.selection(),
            evaluator_identity: %{id: "#{id}-score", version: 1},
            config: config,
            checkpoint_fn: fn checkpoint ->
              if checkpoint["iteration"] == 1,
                do: throw({:checkpoint, checkpoint}),
                else: :ok
            end
          )

          raise "#{id} did not emit the expected resumable checkpoint"
        catch
          {:checkpoint, checkpoint} -> checkpoint
        end

      Atomic.write!(Path.join(directory, "checkpoint.json"), checkpoint)
      calls_before_resume = Agent.get(calls, &length/1)

      result =
        Anything.run(domain.seed(), evaluator,
          dataset: domain.train(),
          valset: domain.selection(),
          evaluator_identity: %{id: "#{id}-score", version: 1},
          config: config,
          resume_state: checkpoint
        )

      unless Agent.get(calls, &length/1) == calls_before_resume,
        do: raise("#{id} resume duplicated sealed evaluation")

      selected = Result.best_candidate(result)
      unless selected == domain.target(), do: raise("#{id} did not select the improved artifact")
      unless domain.seed() != selected, do: raise("#{id} mutated its input artifact")

      calls_before_test = Agent.get(calls, & &1)

      if Enum.any?(calls_before_test, fn {split, _id} -> split == :test end),
        do: raise("#{id} opened untouched test during optimization")

      test = evaluate_test(domain, selected)

      persisted =
        result |> Result.to_map() |> Jason.encode!() |> Jason.decode!() |> Result.from_map()

      unless Result.best_candidate(persisted) == selected,
        do: raise("#{id} result round-trip changed")

      Atomic.write!(Path.join(directory, "result.json"), Result.to_map(result))
      Atomic.write!(Path.join(directory, "selected.json"), selected)
      Atomic.write!(Path.join(directory, "test.json"), test)

      invalid = invalid_run(domain)
      Atomic.write!(Path.join(directory, "invalid-proposal.json"), invalid)

      %{
        id: id,
        baseline_selection_score: hd(result.validation_scores),
        selected_selection_score: Enum.max(result.validation_scores),
        test_score: test.score,
        test_sha256: test.sha256,
        resume_duplicated_calls: false,
        invalid_proposal_rejected: invalid.rejected
      }
    after
      Agent.stop(calls)
    end
  end

  defp invalid_run(RetryController = domain) do
    strategy =
      StructuredStrategy.new(InvalidStrategy,
        id: "retry-invalid/v1",
        config: %{"mode" => "partial"}
      )

    rejected_result(domain, strategy, :all)
  end

  defp invalid_run(JobScheduler = domain) do
    strategy =
      StructuredStrategy.new(InvalidStrategy,
        id: "schedule-invalid/v1",
        config: %{"mode" => "unselected"}
      )

    rejected_result(domain, strategy, :round_robin)
  end

  defp rejected_result(domain, strategy, selector) do
    result =
      Anything.run(domain.seed(), &domain.evaluate/2,
        dataset: domain.train(),
        valset: domain.selection(),
        evaluator_identity: %{id: "#{domain.id()}-invalid-score", version: 1},
        config:
          Config.new(
            engine: [max_candidate_proposals: 1, raise_on_exception: false],
            reflection: [module_selector: selector, structured_strategy: strategy]
          )
      )

    %{
      rejected: Result.best_candidate(result) == domain.seed() and result.rejected != [],
      selected_seed: Result.best_candidate(result) == domain.seed(),
      reason: inspect(result.rejected)
    }
  end

  defp fresh do
    output = output!()

    results =
      Map.new(@domains, fn domain ->
        selected_file =
          output
          |> Path.join(domain.id())
          |> Path.join("selected.json")
          |> File.read!()
          |> Jason.decode!()

        persisted_result =
          output
          |> Path.join(domain.id())
          |> Path.join("result.json")
          |> File.read!()
          |> Jason.decode!()
          |> Result.from_map()

        selected = Result.best_candidate(persisted_result)

        unless selected == selected_file,
          do: raise("#{domain.id()} fresh result and selected artifact disagree")

        test = evaluate_test(domain, selected)
        {domain.id(), %{"rows" => test.rows, "score" => test.score, "sha256" => test.sha256}}
      end)

    Atomic.write!(Path.join(output, "fresh.json"), results)
  end

  defp evaluate_test(domain, artifact) do
    rows =
      Enum.map(domain.test(), fn row ->
        {score, details} = domain.evaluate(artifact, row)
        %{id: row.id, score: score, actual: details.actual, expected: details.expected}
      end)

    %{rows: rows, score: mean(Enum.map(rows, & &1.score)), sha256: sha256(rows)}
  end

  defp mean(values), do: Enum.sum(values) / length(values)

  defp sha256(value),
    do:
      value
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

  defp output!,
    do:
      System.get_env("IMP_OA_PROVIDER_FREE_OUTPUT", Path.expand("tmp/provider-free", __DIR__))
      |> Path.expand()

  defp require_empty!(path) do
    case File.ls(path) do
      {:error, :enoent} -> :ok
      {:ok, []} -> :ok
      {:ok, _} -> raise("IMP_OA_PROVIDER_FREE_OUTPUT must be empty")
      {:error, reason} -> raise("cannot inspect output: #{inspect(reason)}")
    end
  end
end

unless System.get_env("IMP_OA_PROVIDER_FREE_DEFINE_ONLY") == "1",
  do: LocalOptimizeAnythingProviderFree.Runner.run()
