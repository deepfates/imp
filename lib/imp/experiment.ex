defmodule Imp.Experiment do
  @moduledoc """
  One public, fail-closed optimize/select/test lifecycle.

  `check/5` evaluates the baseline and optimized programs on selection data,
  chooses the higher score (retaining baseline on a tie), and only then evaluates
  the selected program on untouched test data. The returned artifact contains
  both parameter snapshots and can be applied to a freshly reconstructed trusted
  program with `Imp.Optimizer.Artifact.apply/4`.

  This boundary is for ordinary product checks and bounded scientific runs. It
  does not turn a single result into a general optimizer-effectiveness claim.
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
     metric_identity} =
      split_options!(opts)

    config = %{
      optimizer_module: optimizer.__struct__,
      optimizer_options: Imp.Optimizer.Report.json_safe(optimizer_opts),
      evaluation_options: Imp.Optimizer.Report.json_safe(evaluation_opts),
      artifact_id: artifact_id,
      declared: declared_config,
      metric: metric_identity
    }

    try do
      provenance = stage!(:bootstrap, fn -> Bootstrap.capture!(data, config, bootstrap_opts) end)

      baseline =
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
        optimized_result =
          evaluate!(
            :optimized_selection,
            optimized,
            data.selection,
            data.ids.selection,
            metric,
            evaluation_opts
          )

        selected = select(baseline, optimized_result)

        artifact =
          stage!(:artifact, fn ->
            build_artifact(
              program,
              baseline,
              optimized,
              optimized_result,
              selected,
              artifact_id,
              provenance
            )
          end)

        selected_program =
          stage!(:artifact_application, fn -> Artifact.apply(artifact, program) end)

        test =
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
           test: test,
           provenance: provenance
         }}
      else
        {:error, reason} -> {:error, %{stage: :optimize, reason: reason}}
      end
    rescue
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
    stage!(stage, fn ->
      result = Imp.evaluate(program, rows, metric, opts)

      if result.errors != [] do
        raise Imp.Experiment.StageError, stage: stage, reason: {:evaluation_errors, result.errors}
      end

      unless is_number(result.score) do
        raise Imp.Experiment.StageError, stage: stage, reason: {:non_numeric_score, result.score}
      end

      result
    end)
  rescue
    error in Imp.EvaluationCancelledError ->
      reraise Imp.Experiment.StageError.exception(
                stage: stage,
                reason: evaluation_cancelled(stage, error, row_ids)
              ),
              __STACKTRACE__
  end

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
      :metric_identity
    ]

    unknown = Keyword.keys(opts) -- public

    if unknown != [],
      do: raise(ArgumentError, "unknown Imp.Experiment.check options: #{inspect(unknown)}")

    optimizer_opts = Keyword.get(opts, :optimizer_options, [])
    evaluation_opts = Keyword.get(opts, :evaluation_options, [])
    bootstrap_opts = Keyword.get(opts, :bootstrap, [])
    artifact_id = Keyword.get(opts, :artifact_id, "optimized")
    declared_config = Keyword.get(opts, :config, %{})
    metric_identity = Keyword.get(opts, :metric_identity)

    unless Keyword.keyword?(optimizer_opts),
      do: raise(ArgumentError, ":optimizer_options must be a keyword list")

    unless Keyword.keyword?(evaluation_opts),
      do: raise(ArgumentError, ":evaluation_options must be a keyword list")

    unknown_evaluation = Keyword.keys(evaluation_opts) -- evaluation_keys()

    if unknown_evaluation != [],
      do: raise(ArgumentError, "unknown :evaluation_options: #{inspect(unknown_evaluation)}")

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

    {optimizer_opts, evaluation_opts, bootstrap_opts, artifact_id, declared_config,
     metric_identity}
  end

  defp evaluation_keys, do: [:max_concurrency, :max_errors, :timeout]

  defp stage!(stage, fun) do
    fun.()
  rescue
    error in [Imp.Experiment.StageError] -> reraise error, __STACKTRACE__
    error in [Imp.EvaluationCancelledError] -> reraise error, __STACKTRACE__
    error -> raise Imp.Experiment.StageError, stage: stage, reason: Exception.message(error)
  catch
    kind, reason -> raise Imp.Experiment.StageError, stage: stage, reason: {kind, reason}
  end

  defp failure_stage(%Imp.Experiment.StageError{stage: stage}), do: stage
  defp failure_stage(_error), do: :bootstrap

  defp evaluation_cancelled(stage, error, row_ids) do
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
