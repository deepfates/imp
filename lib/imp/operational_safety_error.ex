defmodule Imp.OperationalSafetyError do
  @moduledoc """
  Marks a fail-closed operational error from a guarded LM or program call.

  Ordinary model, task, and adapter failures may be scored by an evaluator or
  optimizer. Budget, route, cost, transport, and explicit cancellation guards
  must instead remain fatal across optimization boundaries. A guard inside a
  normalized Imp callback should return `{:error, exception}`; a guard outside
  that boundary may raise the exception directly.
  """

  @kinds [:budget, :route, :cost, :transport, :cancellation]
  defexception [:message, :kind, :reason]

  def exception(opts) do
    kind = Keyword.fetch!(opts, :kind)

    unless kind in @kinds do
      raise ArgumentError, "unsupported operational safety kind: #{inspect(kind)}"
    end

    reason = Keyword.get(opts, :reason)
    message = Keyword.get(opts, :message, "operational #{kind} guard failed")
    %__MODULE__{kind: kind, reason: reason, message: message}
  end

  @doc false
  def find(%__MODULE__{} = error), do: error

  def find(%_{} = struct), do: struct |> Map.from_struct() |> find()

  def find(map) when is_map(map) do
    Enum.find_value(map, fn {_key, value} -> find(value) end)
  end

  def find(list) when is_list(list), do: Enum.find_value(list, &find/1)
  def find(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> Enum.find_value(&find/1)
  def find(_value), do: nil

  @doc false
  def raise_if_present!(value) do
    case find(value) do
      %__MODULE__{} = error -> raise error
      nil -> :ok
    end
  end
end
