defmodule Imp.Error do
  @moduledoc """
  General Imp exception.

  Most Imp runtime APIs return `{:ok, value}` or `{:error, reason}` tuples so
  callers can supervise and retry explicitly. This base exception exists for
  boundary code that must raise while still carrying a structured `:reason`.
  """

  defexception [:message, :reason]
end

defmodule Imp.LMError do
  @moduledoc """
  Language-model provider error.

  `%Imp.LMError{}` is useful when an LM boundary needs exception semantics but
  still wants to expose whether the failure is worth retrying. Tuple-returning
  APIs normally surface provider failures as `{:error, reason}`.
  """

  defexception [:message, :reason, retryable: false]
end

defmodule Imp.AdapterParseError do
  @moduledoc """
  Adapter parse failure with retry feedback.

  Adapters return this struct when provider output could not be shaped into the
  requested signature. Predictive modules use the `:message` as corrective
  feedback for retry loops and preserve `:reason` for diagnostics.
  """

  defexception [:message, :reason]
end

defmodule Imp.ContextWindowExceededError do
  @moduledoc """
  Context-window overflow error.

  Imp tries to keep context management explicit: callers can choose smaller
  demos, retrieval limits, or recursive control instead of letting a provider
  reject oversized requests late in the workflow.
  """

  defexception [:message, :reason]
end

defmodule Imp.Errors do
  @moduledoc """
  Helpers for Imp exception structs.

  These helpers keep retry policy checks out of provider-specific code.
  """

  @doc """
  Returns whether an exception represents a retryable LM failure.

      iex> Imp.Errors.retryable?(%Imp.LMError{retryable: true})
      true

      iex> Imp.Errors.retryable?(%Imp.AdapterParseError{})
      false

  """
  def retryable?(%Imp.LMError{retryable: retryable}), do: retryable
  def retryable?(_), do: false
end
