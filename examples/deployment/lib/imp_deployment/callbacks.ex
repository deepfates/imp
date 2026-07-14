defmodule ImpDeployment.Callbacks do
  def registry do
    Imp.Saving.Registry.new(quality_metric: &quality_metric/2)
  end

  def quality_metric(_example, prediction) do
    prediction
    |> Imp.get(:answer, "")
    |> then(&(&1 != ""))
  end
end
