defmodule Imp.Error do
  @moduledoc """
  Raised by a function whose name ends in `!` when the call ran and failed.

  `:reason` is the term the non-raising form of the same function returns as
  `{:error, reason}`, so a caller that rescues it can act on the same classes
  as one that matches the tuple. A call that could never have run, such as one
  given the wrong kind of argument, raises `ArgumentError` instead.
  """

  defexception [:message, :reason]

  @type t :: %__MODULE__{message: String.t(), reason: term()}
end

defmodule Imp.LMError do
  @moduledoc """
  A language-model request the provider did not answer with a completion.

  `Imp.Clients.ReqLLM` returns `{:error, %Imp.LMError{}}` for every failed
  request: an HTTP error status, an error the provider relayed inside a
  successful response, a connection that failed, and an exception raised
  inside the provider library. A caller decides what to do from three fields
  without matching the provider library's own terms:

    * `:status` — the HTTP status the provider answered with, or `nil` when no
      response came back.
    * `:retryable` — `true` when sending the same request again may succeed: a
      408, 425, 429 or 5xx status, or a connection that closed, timed out or
      was refused. A language-model request changes nothing outside the
      provider, so repeating it is safe; it may be billed again.
    * `:context_window_exceeded` — `true` when the provider refused the
      request because its input is longer than the model accepts. Sending it
      again unchanged will fail again; a shorter input may not.

  `:reason` keeps the provider library's error unchanged for diagnostics.
  `Imp.Errors.retryable?/1` and `Imp.Errors.context_window_exceeded?/1` read
  these fields through the wrappers Imp puts around an LM error.

  A client that raises instead of returning is not an `Imp.LMError`: `Imp.LM`
  returns `{:lm_failed, client, exception}`, because a crash in the client says
  nothing about the provider.
  """

  defexception [:message, :status, :reason, retryable: false, context_window_exceeded: false]

  @type t :: %__MODULE__{
          message: String.t() | nil,
          status: non_neg_integer() | nil,
          reason: term(),
          retryable: boolean(),
          context_window_exceeded: boolean()
        }
end

defmodule Imp.AdapterParseError do
  @moduledoc """
  A completion that could not be read as the signature's outputs.

  Adapters return `{:error, %Imp.AdapterParseError{}}` from `parse/3`, and
  `Imp.Predict.Predict` returns the same struct when no completion could be
  parsed, after any fallback it tried. `:kind` says what was wrong:

    * `:malformed` — the completion is not in the adapter's format at all: no
      JSON object for the JSON adapter, XML that does not parse, a one-field
      answer that is not the exact value the field allows.
    * `:missing_fields` — required output fields are absent. `:reason` is the
      list of their names.
    * `:invalid_fields` — every field is present but some value does not fit
      its declared type. `:reason` is the fields that were read.
    * `:unsupported_output` — the LM returned something no adapter reads as a
      completion (not text or a map), or no completion at all.
    * `:other` — a custom adapter returned an error that is not this struct;
      `:reason` is that error.

  An adapter that sends a request of its own, such as `Imp.Adapter.TwoStep`,
  does not report that request's failure as a parse error: the call returns
  the `Imp.LMError` (or `{:lm_failed, client, reason}`) itself.

  `:message` is the feedback a retry shows the model. `Imp.Predict.Predict`
  also fills `:trace` (the redacted messages, the raw completion, and which
  output fields were read) and, for an `n > 1` call, `:completion_index`, the
  position of the first completion that failed.

  A parse failure is not retryable in the sense of `Imp.Errors.retryable?/1`:
  sending the same request again is not what fixes it.
  """

  defexception [:kind, :message, :reason, :completion_index, :trace]

  @type kind :: :malformed | :missing_fields | :invalid_fields | :unsupported_output | :other

  @type t :: %__MODULE__{
          kind: kind() | nil,
          message: String.t() | nil,
          reason: term(),
          completion_index: non_neg_integer() | nil,
          trace: map() | nil
        }

  @doc false
  def missing_fields(names) do
    %__MODULE__{
      kind: :missing_fields,
      message:
        "The response is missing required output fields: " <>
          Enum.map_join(names, ", ", &to_string/1) <> ".",
      reason: names
    }
  end

  @doc false
  def unsupported_output(raw) do
    %__MODULE__{
      kind: :unsupported_output,
      message: "The LM returned #{shape(raw)}, which is not a completion.",
      reason: raw
    }
  end

  defp shape(raw) when is_list(raw), do: "a list"
  defp shape(raw) when is_tuple(raw), do: "a tuple"
  defp shape(nil), do: "nothing"
  defp shape(_raw), do: "a value"
end

defmodule Imp.Errors do
  @moduledoc """
  Reads the failure classes callers act on, through the wrappers Imp puts
  around an error.

  An LM error reaches a caller directly (`{:error, %Imp.LMError{}}`), or from
  a client that raised (`{:lm_failed, client, exception}`). These functions
  accept either, with or without the `{:error, _}` around it.
  """

  @doc """
  Whether sending the same request again may succeed.

      iex> Imp.Errors.retryable?(%Imp.LMError{status: 429, retryable: true})
      true

      iex> Imp.Errors.retryable?({:error, %Imp.LMError{status: 400}})
      false

      iex> Imp.Errors.retryable?(%Imp.AdapterParseError{kind: :malformed})
      false

  """
  @spec retryable?(term()) :: boolean()
  def retryable?(error), do: match?(%Imp.LMError{retryable: true}, lm_error(error))

  @doc """
  Whether the provider refused the request because its input is longer than
  the model accepts.

      iex> Imp.Errors.context_window_exceeded?(%Imp.LMError{status: 400, context_window_exceeded: true})
      true

      iex> Imp.Errors.context_window_exceeded?({:error, %Imp.LMError{status: 500}})
      false

  """
  @spec context_window_exceeded?(term()) :: boolean()
  def context_window_exceeded?(error),
    do: match?(%Imp.LMError{context_window_exceeded: true}, lm_error(error))

  @doc false
  # Whether `reason` is a language-model request's failure rather than
  # anything else a caller could be handed.
  @spec lm_failure?(term()) :: boolean()
  def lm_failure?(reason), do: lm_error(reason) != nil

  defp lm_error({:error, reason}), do: lm_error(reason)
  defp lm_error({:lm_failed, _client, reason}), do: lm_error(reason)
  defp lm_error(%Imp.LMError{} = error), do: error
  defp lm_error(_other), do: nil
end
