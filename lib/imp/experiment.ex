defmodule Imp.Experiment do
  @moduledoc """
  One public, fail-closed optimize/select/test lifecycle.

  `check/5` evaluates the baseline and optimized programs on selection data,
  chooses the higher score (retaining baseline on a tie), and only then evaluates
  the selected program on untouched test data. The returned artifact contains
  both parameter snapshots and can be applied to a freshly reconstructed trusted
  program with `Imp.Optimizer.Artifact.apply/4`. Set
  `compare_baseline_on_test: true` to evaluate the baseline on the same ordered
  test rows after the selected artifact has been built and applied.

  Evaluation failures remain ordered `failure_score` diagnostic rows while the
  configured error budget has not been exhausted. `max_errors: 0` (the
  Experiment default) stops on the first ordinary failure, a positive finite
  budget stops when that many failures have occurred, and `:infinity` retains
  every ordinary failure. Operational-safety failures always escape
  immediately.

  For a noisy model, set `evaluation_options: [repetitions: n,
  aggregation: :mean]` to repeat each outer selection and test evaluation over
  the same ordered rows. Use `repetitions: [selection: n, test: m]` when the
  selection decision and final test estimate require different repeat counts.
  The default is one pass. Repetitions change only the family-independent
  Experiment admission and reporting boundary; an optimizer's internal
  candidate evaluations remain under that optimizer's own documented policy.

  A result describes this program, metric, data split, and run configuration.
  Repeat the lifecycle across representative tasks and conditions before
  generalizing an optimizer's effectiveness.
  """

  alias Imp.Experiment.{Bootstrap, Data, Result}
  alias Imp.Optimizer.{Artifact, Report}

  @doc "Runs the canonical train → selection → selected-only test lifecycle."
  @spec check(struct(), struct(), Data.t(), function(), keyword()) ::
          {:ok, Result.t()} | {:error, map()}
  def check(program, optimizer, data, metric, opts \\ [])

  def check(program, optimizer, %Data{} = data, metric, opts)
      when is_struct(program) and is_struct(optimizer) and is_function(metric) and is_list(opts) do
    unless Keyword.keyword?(opts), do: invalid_options!(opts)

    {optimizer_opts, evaluation_opts, bootstrap_opts, artifact_id, declared_config,
     metric_identity, compare_baseline_on_test?, budget} =
      split_options!(opts)

    config = %{
      optimizer_module: optimizer.__struct__,
      optimizer_options: Imp.Optimizer.Report.json_safe(optimizer_opts),
      evaluation_options: Imp.Optimizer.Report.json_safe(evaluation_opts),
      compare_baseline_on_test: compare_baseline_on_test?,
      artifact_id: artifact_id,
      declared: declared_config,
      metric: metric_identity
    }

    try do
      case prevalidate_optimizer(optimizer, optimizer_opts) do
        :ok ->
          :ok

        {:error, reason} ->
          raise Imp.Experiment.StageError, stage: :optimizer_validation, reason: reason
      end

      provenance = stage!(:bootstrap, fn -> Bootstrap.capture!(data, config, bootstrap_opts) end)

      {baseline, baseline_repetitions} =
        evaluate!(
          :baseline_selection,
          program,
          data.selection,
          data.ids.selection,
          metric,
          evaluation_opts
        )

      with {:ok, optimized} <-
             stage!(:optimize, fn -> optimize(program, optimizer, data, optimizer_opts) end) do
        {optimized_result, optimized_repetitions} =
          evaluate!(
            :optimized_selection,
            optimized,
            data.selection,
            data.ids.selection,
            metric,
            evaluation_opts
          )

        selected = select(baseline, optimized_result)

        artifact_provenance = put_budget_snapshot(provenance, budget, "through_selection")

        artifact =
          stage!(:artifact, fn ->
            build_artifact(
              program,
              baseline,
              optimized,
              optimized_result,
              selected,
              artifact_id,
              artifact_provenance
            )
          end)

        selected_program =
          stage!(:artifact_application, fn -> Artifact.apply(artifact, program) end)

        {baseline_test, baseline_test_repetitions} =
          if compare_baseline_on_test? do
            evaluate!(
              :baseline_test,
              program,
              data.test,
              data.ids.test,
              metric,
              evaluation_opts
            )
          else
            {nil, nil}
          end

        {test, test_repetitions} =
          evaluate!(
            :test,
            selected_program,
            data.test,
            data.ids.test,
            metric,
            evaluation_opts
          )

        {:ok,
         %Result{
           status: :completed,
           selected: selected,
           program: selected_program,
           artifact: artifact,
           baseline_selection: baseline,
           optimized_selection: optimized_result,
           baseline_test: baseline_test,
           test: test,
           provenance: put_budget_snapshot(provenance, budget, "final"),
           repetition_summary:
             repetition_summary(
               evaluation_opts,
               data,
               baseline_repetitions,
               optimized_repetitions,
               baseline_test_repetitions,
               test_repetitions
             )
         }}
      else
        {:error, reason} -> {:error, %{stage: :optimize, reason: public_reason(reason)}}
      end
    rescue
      error in Imp.OperationalSafetyError ->
        reraise error, __STACKTRACE__

      error in Imp.Experiment.StageError ->
        {:error,
         %{
           stage: error.stage,
           reason: public_reason(error.reason),
           exception: error.__struct__
         }}

      error ->
        {:error,
         %{
           stage: failure_stage(error),
           reason: Exception.message(error),
           exception: error.__struct__
         }}
    catch
      kind, reason -> {:error, %{stage: :runtime, reason: {kind, reason}}}
    end
  end

  def check(program, optimizer, data, metric, opts) do
    raise ArgumentError,
          "Imp.Experiment.check/5 requires program, optimizer, Data, metric function, and keyword options; got: #{inspect({program, optimizer, data, metric, opts})}"
  end

  defp optimize(program, optimizer, data, invocation) do
    with {:ok, capabilities} <- Imp.Optimizer.capabilities(optimizer) do
      case capabilities.datasets.validation do
        :unsupported when invocation == [] -> Imp.optimize(program, optimizer, data.train)
        :unsupported -> Imp.optimize(program, optimizer, data.train, invocation)
        _ -> Imp.optimize(program, optimizer, data.train, data.selection, invocation)
      end
    end
  end

  defp evaluate!(stage, program, rows, row_ids, metric, opts) do
    repetitions = repetition_count(opts, stage)
    evaluate_opts = Keyword.drop(opts, [:repetitions, :aggregation])

    results =
      Enum.map(1..repetitions, fn repetition ->
        try do
          stage!(stage, fn ->
            result = Imp.evaluate(program, rows, metric, evaluate_opts)

            unless is_number(result.score) do
              raise Imp.Experiment.StageError,
                stage: stage,
                reason: {:non_numeric_score, result.score}
            end

            result
          end)
        rescue
          error in Imp.EvaluationCancelledError ->
            reraise Imp.Experiment.StageError.exception(
                      stage: stage,
                      reason: evaluation_cancelled(stage, repetition, error, row_ids)
                    ),
                    __STACKTRACE__
        end
      end)

    {aggregate_evaluations(results), repetition_runs(results)}
  end

  defp aggregate_evaluations([result]), do: result

  defp aggregate_evaluations(results) do
    %Imp.Evaluate.Result{
      score: results |> Enum.map(& &1.score) |> average(),
      rows: tagged_entries(results, :rows),
      errors: tagged_entries(results, :errors)
    }
  end

  defp tagged_entries(results, field) do
    results
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {result, repetition} ->
      result
      |> Map.fetch!(field)
      |> Enum.map(&Map.put(&1, :repetition, repetition))
    end)
  end

  defp repetition_runs(results) do
    results
    |> Enum.with_index(1)
    |> Enum.map(fn {evaluation, index} -> %{index: index, evaluation: evaluation} end)
  end

  defp repetition_summary(opts, data, baseline, optimized, baseline_test, test) do
    case repetition_counts(opts) do
      %{selection: repetitions, test: repetitions} ->
        uniform_repetition_summary(
          repetitions,
          data,
          baseline,
          optimized,
          baseline_test,
          test
        )

      counts ->
        staged_repetition_summary(counts, data, baseline, optimized, baseline_test, test)
    end
  end

  defp uniform_repetition_summary(
         repetitions,
         data,
         baseline,
         optimized,
         baseline_test,
         test
       ) do
    if repetitions == 1 do
      nil
    else
      selection_rows = length(data.selection) * repetitions
      test_rows = length(data.test) * repetitions

      opportunities = %{
        baseline_selection: selection_rows,
        optimized_selection: selection_rows,
        test: test_rows
      }

      opportunities =
        if baseline_test,
          do: Map.put(opportunities, :baseline_test, test_rows),
          else: opportunities

      %{
        count: repetitions,
        aggregation: :mean,
        outer_row_evaluations: %{
          stages: opportunities,
          total: opportunities |> Map.values() |> Enum.sum()
        },
        stages: %{
          baseline_selection: stage_repetitions(baseline),
          optimized_selection: stage_repetitions(optimized),
          baseline_test: stage_repetitions(baseline_test),
          test: stage_repetitions(test)
        },
        paired_deltas: %{
          selection: paired_deltas(baseline, optimized),
          test: paired_deltas(baseline_test, test)
        }
      }
    end
  end

  defp staged_repetition_summary(counts, data, baseline, optimized, baseline_test, test) do
    selection_rows = length(data.selection) * counts.selection
    test_rows = length(data.test) * counts.test

    opportunities = %{
      baseline_selection: selection_rows,
      optimized_selection: selection_rows,
      test: test_rows
    }

    opportunities =
      if baseline_test,
        do: Map.put(opportunities, :baseline_test, test_rows),
        else: opportunities

    %{
      counts: counts,
      aggregation: :mean,
      outer_row_evaluations: %{
        stages: opportunities,
        total: opportunities |> Map.values() |> Enum.sum()
      },
      stages: %{
        baseline_selection: stage_repetitions(baseline),
        optimized_selection: stage_repetitions(optimized),
        baseline_test: stage_repetitions(baseline_test),
        test: stage_repetitions(test)
      },
      paired_deltas: %{
        selection: paired_deltas(baseline, optimized),
        test: paired_deltas(baseline_test, test)
      }
    }
  end

  defp stage_repetitions(nil), do: nil

  defp stage_repetitions(runs) do
    %{aggregate_score: runs |> Enum.map(& &1.evaluation.score) |> average(), runs: runs}
  end

  defp paired_deltas(nil, _right), do: nil

  defp paired_deltas(left, right) do
    left
    |> Enum.zip(right)
    |> Enum.map(fn {left_run, right_run} ->
      right_run.evaluation.score - left_run.evaluation.score
    end)
  end

  defp average(values), do: Enum.sum(values) / length(values)

  defp select(baseline, optimized_result) do
    if optimized_result.score > baseline.score,
      do: :optimized,
      else: :baseline
  end

  defp build_artifact(
         program,
         baseline,
         optimized,
         optimized_result,
         selected,
         artifact_id,
         provenance
       ) do
    baseline_candidate = Artifact.parameter_candidate("baseline", program, score: baseline.score)
    optimized_report = Report.fetch(optimized)

    if is_nil(optimized_report) do
      raise Imp.Experiment.StageError,
        stage: :artifact,
        reason: :optimized_program_missing_report
    end

    optimized_candidate =
      Artifact.parameter_candidate(artifact_id, optimized,
        score: optimized_result.score,
        report: optimized_report
      )

    {champion, challengers} =
      if selected == :optimized,
        do: {optimized_candidate, [baseline_candidate]},
        else: {baseline_candidate, [optimized_candidate]}

    Artifact.new(champion, challengers, provenance: provenance)
  end

  defp split_options!(opts) do
    public = [
      :artifact_id,
      :bootstrap,
      :optimizer_options,
      :evaluation_options,
      :config,
      :metric_identity,
      :compare_baseline_on_test,
      :budget
    ]

    unknown = Keyword.keys(opts) -- public

    if unknown != [],
      do: raise(ArgumentError, "unknown Imp.Experiment.check options: #{inspect(unknown)}")

    optimizer_opts = Keyword.get(opts, :optimizer_options, [])

    evaluation_opts =
      opts
      |> Keyword.get(:evaluation_options, [])
      |> Keyword.put_new(:max_errors, 0)

    bootstrap_opts = Keyword.get(opts, :bootstrap, [])
    artifact_id = Keyword.get(opts, :artifact_id, "optimized")
    declared_config = Keyword.get(opts, :config, %{})
    metric_identity = Keyword.get(opts, :metric_identity)
    compare_baseline_on_test? = Keyword.get(opts, :compare_baseline_on_test, false)
    budget = Keyword.get(opts, :budget)

    unless Keyword.keyword?(optimizer_opts),
      do: raise(ArgumentError, ":optimizer_options must be a keyword list")

    unless Keyword.keyword?(evaluation_opts),
      do: raise(ArgumentError, ":evaluation_options must be a keyword list")

    unknown_evaluation = Keyword.keys(evaluation_opts) -- evaluation_keys()

    if unknown_evaluation != [],
      do: raise(ArgumentError, "unknown :evaluation_options: #{inspect(unknown_evaluation)}")

    validate_repetitions!(Keyword.get(evaluation_opts, :repetitions, 1))

    aggregation = Keyword.get(evaluation_opts, :aggregation, :mean)

    unless aggregation == :mean,
      do: raise(ArgumentError, ":evaluation_options :aggregation only supports :mean")

    unless Keyword.keyword?(bootstrap_opts),
      do: raise(ArgumentError, ":bootstrap must be a keyword list")

    unless is_binary(artifact_id) and artifact_id != "",
      do: raise(ArgumentError, ":artifact_id must be a non-empty string")

    unless is_map(declared_config), do: raise(ArgumentError, ":config must be a map")

    unless is_nil(metric_identity) or
             (is_map(metric_identity) and map_size(metric_identity) > 0) or
             (is_binary(metric_identity) and metric_identity != "") do
      raise ArgumentError, ":metric_identity must be nil, a non-empty map, or a string"
    end

    unless is_boolean(compare_baseline_on_test?),
      do: raise(ArgumentError, ":compare_baseline_on_test must be boolean")

    unless is_nil(budget) or is_pid(budget),
      do: raise(ArgumentError, ":budget must be an Imp.Optimizer.Budget pid or nil")

    {optimizer_opts, evaluation_opts, bootstrap_opts, artifact_id, declared_config,
     metric_identity, compare_baseline_on_test?, budget}
  end

  defp put_budget_snapshot(provenance, nil, _stage), do: provenance

  defp put_budget_snapshot(provenance, budget, stage) do
    Map.put(provenance, :optimizer_budget, %{
      stage: stage,
      snapshot: Imp.Optimizer.Budget.snapshot(budget)
    })
  end

  defp evaluation_keys,
    do: [:failure_score, :max_concurrency, :max_errors, :timeout, :repetitions, :aggregation]

  defp validate_repetitions!(repetitions) when is_integer(repetitions) and repetitions > 0,
    do: :ok

  defp validate_repetitions!(repetitions) when is_list(repetitions) do
    valid? =
      if Keyword.keyword?(repetitions) do
        keys = Keyword.keys(repetitions)

        length(keys) == 2 and Enum.sort(keys) == [:selection, :test] and
          Enum.all?(repetitions, fn {_stage, count} ->
            is_integer(count) and count > 0
          end)
      else
        false
      end

    unless valid? do
      invalid_repetitions!()
    end

    :ok
  end

  defp validate_repetitions!(_repetitions), do: invalid_repetitions!()

  defp invalid_repetitions! do
    raise ArgumentError,
          ":evaluation_options :repetitions must be a positive integer or exactly [selection: positive_integer, test: positive_integer]"
  end

  defp repetition_count(opts, stage) do
    counts = repetition_counts(opts)

    if stage in [:baseline_selection, :optimized_selection],
      do: counts.selection,
      else: counts.test
  end

  defp repetition_counts(opts) do
    case Keyword.get(opts, :repetitions, 1) do
      repetitions when is_integer(repetitions) ->
        %{selection: repetitions, test: repetitions}

      repetitions when is_list(repetitions) ->
        %{
          selection: Keyword.fetch!(repetitions, :selection),
          test: Keyword.fetch!(repetitions, :test)
        }
    end
  end

  defp prevalidate_optimizer(optimizer, opts) do
    case Imp.Optimizer.validate_invocation_options(optimizer, opts) do
      :ok -> :ok
      :deferred -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp stage!(stage, fun) do
    fun.()
  rescue
    error in [Imp.Experiment.StageError, Imp.EvaluationCancelledError, Imp.OperationalSafetyError] ->
      reraise error, __STACKTRACE__

    error ->
      raise Imp.Experiment.StageError, stage: stage, reason: Exception.message(error)
  catch
    kind, reason -> raise Imp.Experiment.StageError, stage: stage, reason: {kind, reason}
  end

  defp failure_stage(%Imp.Experiment.StageError{stage: stage}), do: stage
  defp failure_stage(_error), do: :bootstrap

  defp evaluation_cancelled(stage, repetition, error, row_ids) do
    failures =
      Enum.map(error.errors, fn failure ->
        index = Map.get(failure, :index, Map.get(failure, "index"))
        reason = Map.get(failure, :reason, Map.get(failure, "reason", :unknown))

        %{
          stage: stage,
          index: index,
          identity_sha256: row_identity(row_ids, index),
          reason: public_reason(reason)
        }
      end)

    %{
      kind: :evaluation_cancelled,
      repetition: repetition,
      max_errors: error.max_errors,
      completed_rows: length(error.rows),
      failures: failures
    }
  end

  defp row_identity(row_ids, index) when is_integer(index) and index >= 0 do
    case Enum.fetch(row_ids, index) do
      {:ok, identity} -> Data.digest(identity)
      :error -> nil
    end
  end

  defp row_identity(_row_ids, _index), do: nil

  defp public_reason(reason), do: Imp.Redaction.redact(reason)

  defp invalid_options!(opts),
    do:
      raise(
        ArgumentError,
        "Imp.Experiment.check options must be a keyword list, got: #{inspect(opts)}"
      )
end
