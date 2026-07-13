defmodule DSExDeployment.Callbacks do
  def registry do
    DSEx.Saving.Registry.new(quality_metric: &quality_metric/2)
  end

  def quality_metric(_example, prediction) do
    prediction
    |> DSEx.get(:answer, "")
    |> then(&(&1 != ""))
  end
end
