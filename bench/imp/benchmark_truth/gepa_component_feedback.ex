defmodule Imp.BenchmarkTruth.GepaComponentFeedback do
  @moduledoc false

  alias Imp.BenchmarkTruth.{HotpotFeedback, HoverFeedback, IFBenchFeedback}

  def callbacks!(%{"program" => "HotpotMultiHop"}, program, _metric) do
    validate!(program, HotpotFeedback.callbacks())
  end

  def callbacks!(%{"program" => "IFBenchCoT2StageProgram"}, program, metric) do
    validate!(program, IFBenchFeedback.callbacks(metric))
  end

  def callbacks!(%{"program" => "HoverMultiHop"}, program, _metric) do
    case HoverFeedback.callbacks_for(program) do
      {:ok, callbacks} -> callbacks
      {:error, reason} -> raise ArgumentError, "invalid HoVer feedback graph: #{inspect(reason)}"
    end
  end

  def callbacks!(_spec, _program, _metric), do: %{}

  def callbacks!(%{"family" => family}, program, _feedback_metric, gepa_metric)
      when family in ["AIMEBench", "LiveBenchMathBench", "Papillon"] do
    callbacks =
      Map.new(Imp.ProgramParameters.predictors(program), fn %{name: name} ->
        {name,
         fn context ->
           result =
             gepa_metric.(context.example, context.program_output, context.trace)
             |> Imp.Metrics.normalize_result()

           result.feedback ||
             raise ArgumentError, "#{family} source GEPA metric returned no feedback text"
         end}
      end)

    validate!(program, callbacks)
  end

  def callbacks!(spec, program, feedback_metric, _gepa_metric),
    do: callbacks!(spec, program, feedback_metric)

  def identity(callbacks) do
    %{
      "contract" => "Imp.Optimizer.GEPA.ComponentFeedback/v1",
      "components" => callbacks |> Map.keys() |> Enum.map(&Atom.to_string/1) |> Enum.sort(),
      "strict" => true
    }
  end

  defp validate!(program, callbacks) do
    actual = program |> Imp.ProgramParameters.predictors() |> Enum.map(& &1.name) |> MapSet.new()
    configured = callbacks |> Map.keys() |> MapSet.new()

    unless actual == configured do
      raise ArgumentError,
            "component feedback does not cover the program graph: predictors=#{inspect(actual)} callbacks=#{inspect(configured)}"
    end

    callbacks
  end
end
