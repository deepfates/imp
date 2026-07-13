defmodule DSEx.Optimizer.BootstrapFewShot do
  @moduledoc """
  Compile a predictor by selecting successful demonstrations from a trainset.

  `BootstrapFewShot` runs the current program over each training example and
  keeps trajectories whose predictions pass the metric. Generated outputs from
  those trajectories become demos for each named predictor in the compiled
  program.

  Compilation also attaches a `DSEx.Optimizer.Report` so you can inspect which
  examples were selected, which were rejected, and which failed because of a
  program or metric error.
  """

  defstruct [:metric, max_bootstrapped_demos: 4]

  @option_schema [
    max_bootstrapped_demos: [type: :non_neg_integer, default: 4]
  ]

  def new(metric, opts \\ []) do
    DSEx.FunctionContract.validate!(
      metric,
      [2, 3],
      "DSEx.Optimizer.BootstrapFewShot.new/2",
      "metric"
    )

    opts = DSEx.Options.validate!(opts, @option_schema, "DSEx.Optimizer.BootstrapFewShot.new/2")

    %__MODULE__{
      metric: metric,
      max_bootstrapped_demos: opts[:max_bootstrapped_demos]
    }
  end

  def compile(%__MODULE__{} = optimizer, program, trainset) do
    {demos_by_name, selected_count, candidates, errors} =
      case materialize_trainset(trainset) do
        {:ok, examples} ->
          trajectories =
            DSEx.Optimizer.TrajectoryRunner.run(program, examples, optimizer.metric,
              runtime: :evaluation
            )

          {selected, candidates} =
            select_trajectories(trajectories, optimizer.max_bootstrapped_demos)

          names = Enum.map(DSEx.ProgramParameters.predictors(program), & &1.name)
          demos_by_name = DSEx.Optimizer.DemoCandidates.extract_bootstrapped(selected, names)

          {demos_by_name, length(selected), candidates, trajectory_errors(trajectories)}

        {:error, error} ->
          {%{}, 0, [], [%{stage: :trainset, reason: error_message(error)}]}
      end

    compiled = if trainset_error?(errors), do: program, else: put_demos(program, demos_by_name)

    report =
      DSEx.Optimizer.Report.new(%{
        optimizer: :bootstrap_few_shot,
        best_score: average_score(candidates),
        candidate_count: length(candidates),
        candidates: candidates,
        errors: errors,
        metadata: %{
          selected_count: selected_count,
          predictor_demo_counts:
            Map.new(demos_by_name, fn {name, demos} -> {name, length(demos)} end),
          max_bootstrapped_demos: optimizer.max_bootstrapped_demos,
          trainset_size: length(candidates),
          trajectory_substrate: DSEx.Optimizer.Trajectory,
          status: report_status(errors)
        }
      })

    attach_report(compiled, report)
  end

  defp materialize_trainset(trainset) do
    {:ok, Enum.to_list(trainset)}
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp select_trajectories(trajectories, limit) do
    {selected, candidates, _count} =
      Enum.reduce(trajectories, {[], [], 0}, fn trajectory, {selected, candidates, count} ->
        passed? = is_nil(trajectory.error) and trajectory.score != 0
        selected? = passed? and count < limit

        candidate = %{
          index: trajectory.index,
          score: trajectory.score,
          passed?: passed?,
          selected?: selected?,
          feedback: trajectory.feedback
        }

        if selected? do
          {[trajectory | selected], [candidate | candidates], count + 1}
        else
          {selected, [candidate | candidates], count}
        end
      end)

    {Enum.reverse(selected), Enum.reverse(candidates)}
  end

  defp trajectory_errors(trajectories) do
    trajectories
    |> Enum.reject(&is_nil(&1.error))
    |> Enum.map(fn
      %{index: index, error: {:metric_error, reason}} ->
        %{index: index, stage: :metric, reason: error_message(reason)}

      %{index: index, error: reason} ->
        %{index: index, stage: :program_call, reason: error_message(reason)}
    end)
  end

  defp report_status([]), do: :ok
  defp report_status(errors) when is_list(errors), do: :with_errors

  defp trainset_error?(errors), do: Enum.any?(errors, &(&1.stage == :trainset))

  defp put_demos(program, demos_by_name) do
    Enum.reduce(demos_by_name, program, fn {name, demos}, compiled ->
      DSEx.ProgramParameters.put_demos(compiled, name, demos)
    end)
  end

  defp attach_report(program, report) do
    case DSEx.ProgramAccess.predict(program) do
      nil ->
        Enum.reduce(DSEx.ProgramParameters.predictors(program), program, fn %{name: name}, acc ->
          DSEx.ProgramParameters.update_predictor(acc, name, fn predictor ->
            DSEx.Optimizer.Report.attach(predictor, report)
          end)
        end)

      _predictor ->
        DSEx.Optimizer.Report.attach(program, report)
    end
  end

  defp average_score([]), do: 0.0

  defp average_score(candidates) do
    candidates
    |> Enum.map(& &1.score)
    |> Enum.sum()
    |> Kernel./(length(candidates))
  end

  defp error_message(%_{} = exception), do: Exception.message(exception)
  defp error_message(error) when is_binary(error), do: error
  defp error_message(error), do: inspect(error)
end
