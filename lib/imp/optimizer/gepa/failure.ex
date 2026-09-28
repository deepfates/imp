defmodule Imp.Optimizer.GEPA.Failure do
  @moduledoc false

  # A proposal failure as GEPA records it in rejections, history, pending
  # proposal slots and ComBee reports. It is redacted when recorded, since a
  # checkpoint holds it as it is, and it is built from strings and Imp's own
  # atoms, apart from a thrown or exit term, so a checkpoint reads back in a
  # VM that has not loaded the module that raised. An exception keeps its
  # module's name and its message: `{:proposal_exception, "MyApp.Error",
  # message}`. A throw or exit keeps its term: `{:proposal_throw, term}`,
  # `{:proposal_exit, term}`. The tag names the stage that failed.

  @doc false
  def record(stage, :error, %{__exception__: true} = exception) do
    {tag(stage, :exception), inspect(exception.__struct__),
     exception |> Exception.message() |> Imp.Redaction.redact()}
  end

  def record(stage, :error, reason),
    do: record(stage, :error, Exception.normalize(:error, reason, []))

  def record(stage, kind, reason) when kind in [:throw, :exit],
    do: {tag(stage, kind), Imp.Redaction.redact(reason)}

  @doc false
  # A worker failure carried with its stacktrace, made into the recorded shape.
  def serializable({:combee_first_level_failed, index, reason}),
    do: {:combee_first_level_failed, index, serializable(reason)}

  def serializable({:combee_final_aggregation_failed, reason}),
    do: {:combee_final_aggregation_failed, serializable(reason)}

  def serializable({:proposal_exception, exception, _stacktrace}) when is_exception(exception),
    do: record(:proposal, :error, exception)

  def serializable({:reflection_strategy_exception, exception, _stacktrace})
      when is_exception(exception),
      do: record(:reflection_strategy, :error, exception)

  def serializable({:reflection_batch_exception, exception, _stacktrace})
      when is_exception(exception),
      do: record(:reflection_batch, :error, exception)

  def serializable({:evaluation_exception, exception, _stacktrace}) when is_exception(exception),
    do: record(:evaluation, :error, exception)

  def serializable({:proposal_throw, kind, reason, _stacktrace}),
    do: record(:proposal, kind, reason)

  def serializable({:reflection_strategy_throw, kind, reason, _stacktrace}),
    do: record(:reflection_strategy, kind, reason)

  def serializable({:reflection_batch_throw, kind, reason, _stacktrace}),
    do: record(:reflection_batch, kind, reason)

  def serializable({:evaluation_throw, kind, reason, _stacktrace}),
    do: record(:evaluation, kind, reason)

  def serializable(reason), do: Imp.Redaction.redact(reason)

  defp tag(:proposal, :exception), do: :proposal_exception
  defp tag(:proposal, :throw), do: :proposal_throw
  defp tag(:proposal, :exit), do: :proposal_exit
  defp tag(:reflection_strategy, :exception), do: :reflection_strategy_exception
  defp tag(:reflection_strategy, :throw), do: :reflection_strategy_throw
  defp tag(:reflection_strategy, :exit), do: :reflection_strategy_exit
  defp tag(:reflection_batch, :exception), do: :reflection_batch_exception
  defp tag(:reflection_batch, :throw), do: :reflection_batch_throw
  defp tag(:reflection_batch, :exit), do: :reflection_batch_exit
  defp tag(:evaluation, :exception), do: :evaluation_exception
  defp tag(:evaluation, :throw), do: :evaluation_throw
  defp tag(:evaluation, :exit), do: :evaluation_exit
  defp tag(:reflective_dataset, :exception), do: :reflective_dataset_exception
  defp tag(:reflective_dataset, :throw), do: :reflective_dataset_throw
  defp tag(:reflective_dataset, :exit), do: :reflective_dataset_exit
  defp tag(:worker, :exception), do: :exception
  defp tag(:worker, kind), do: kind
end
