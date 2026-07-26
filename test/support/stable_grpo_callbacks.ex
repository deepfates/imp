defmodule Imp.Test.StableGRPOCallbacks do
  @moduledoc false

  def reward(_example, _prediction, %{"value" => value}), do: value

  def exact_answer(expected, prediction, %{"field" => field}) do
    key = String.to_existing_atom(field)
    if Imp.get(expected, key) == Imp.get(prediction, key), do: 1.0, else: 0.0
  end

  def validate(_program, _dataset, _context, %{"result" => "ok"}), do: :ok
end

defmodule Imp.Test.ControlledRouteLM do
  @moduledoc false
  @behaviour Imp.LM
  defstruct [:model]

  @routes ["R17", "R42", "R68", "R93"]

  @impl true
  def generate(_messages, opts) do
    {:ok, %{route: Enum.fetch!(@routes, Keyword.fetch!(opts, :rollout_id))}}
  end
end
