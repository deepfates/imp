defmodule DSEx.Error do
  defexception [:message, :reason]
end

defmodule DSEx.LMError do
  defexception [:message, :reason, retryable: false]
end

defmodule DSEx.AdapterParseError do
  defexception [:message, :reason]
end

defmodule DSEx.ContextWindowExceededError do
  defexception [:message, :reason]
end

defmodule DSEx.Errors do
  @moduledoc "Exception helpers."

  def retryable?(%DSEx.LMError{retryable: retryable}), do: retryable
  def retryable?(_), do: false
end
