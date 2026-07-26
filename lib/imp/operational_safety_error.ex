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
end
