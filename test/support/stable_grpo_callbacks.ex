defmodule Imp.Test.StableGRPOCallbacks do
  @moduledoc false

  def reward(_example, _prediction, %{"value" => value}), do: value

  def exact_answer(expected, prediction, %{"field" => field}) do
    key = String.to_existing_atom(field)
    if Imp.get(expected, key) == Imp.get(prediction, key), do: 1.0, else: 0.0
  end

  def validate(_program, _dataset, _context, %{"result" => "ok"}), do: :ok
end
