defmodule Imp.Experiment.StageError do
  @moduledoc false
  defexception [:stage, :reason]
  def message(error), do: "experiment #{error.stage} failed: #{inspect(error.reason)}"
end
