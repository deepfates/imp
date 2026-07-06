defmodule Dachshund.Error do
  defexception [:message, :reason]
end

defmodule Dachshund.LMError do
  defexception [:message, :reason, retryable: false]
end

defmodule Dachshund.AdapterParseError do
  defexception [:message, :reason]
end

defmodule Dachshund.ContextWindowExceededError do
  defexception [:message, :reason]
end

defmodule Dachshund.Errors do
  @moduledoc "Exception helpers."

  def retryable?(%Dachshund.LMError{retryable: retryable}), do: retryable
  def retryable?(_), do: false
end
