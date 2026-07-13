defmodule DSEx.BenchmarkTruth.GepaComponentFeedback do
  @moduledoc false

  alias DSEx.BenchmarkTruth.{HotpotFeedback, HoverFeedback, IFBenchFeedback}

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

  def identity(callbacks) do
    %{
      "contract" => "DSEx.Optimizer.GEPA.ComponentFeedback/v1",
      "components" => callbacks |> Map.keys() |> Enum.map(&Atom.to_string/1) |> Enum.sort(),
      "strict" => true
    }
  end

  defp validate!(program, callbacks) do
    actual = program |> DSEx.ProgramParameters.predictors() |> Enum.map(& &1.name) |> MapSet.new()
    configured = callbacks |> Map.keys() |> MapSet.new()

    unless actual == configured do
      raise ArgumentError,
            "component feedback does not cover the program graph: predictors=#{inspect(actual)} callbacks=#{inspect(configured)}"
    end

    callbacks
  end
end
