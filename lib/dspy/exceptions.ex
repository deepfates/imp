defmodule DSPy.Error do
  defexception [:message, :reason]
end

defmodule DSPy.LMError do
  defexception [:message, :reason, retryable: false]
end

defmodule DSPy.AdapterParseError do
  defexception [:message, :reason]
end

defmodule DSPy.ContextWindowExceededError do
  defexception [:message, :reason]
end

defmodule DSPy.Errors do
  @moduledoc "Exception helpers."

  def retryable?(%DSPy.LMError{retryable: retryable}), do: retryable
  def retryable?(_), do: false
end
