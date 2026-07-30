defmodule MatchedGepaMiproIFBenchV3.CallBudget do
  @moduledoc false
  @keys ~w(task_logical optimizer_logical total_logical transports)

  def zero,
    do: %{
      "task_logical" => 0,
      "optimizer_logical" => 0,
      "total_logical" => 0,
      "transports" => 0
    }

  def reserve!(counts, ceiling, role) when role in [:task, :optimizer] do
    unless Map.keys(counts) |> Enum.sort() == Enum.sort(@keys) and
             Map.keys(ceiling) |> Enum.sort() == Enum.sort(@keys),
           do: raise(ArgumentError, "call budget shape drift")

    role_key = "#{role}_logical"

    projected =
      counts
      |> Map.update!(role_key, &(&1 + 1))
      |> Map.update!("total_logical", &(&1 + 1))
      |> Map.update!("transports", &(&1 + 1))

    case Enum.find(projected, fn {name, count} -> count > Map.fetch!(ceiling, name) end) do
      nil ->
        projected

      {name, count} ->
        raise "call budget refused #{role} before dispatch: #{name}=#{count} ceiling=#{ceiling[name]}"
    end
  end
end
