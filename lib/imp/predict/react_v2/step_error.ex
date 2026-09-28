defmodule Imp.Predict.ReActV2.StepError do
  @moduledoc """
  An `Imp.Predict.ReActV2` turn that stopped because it could not get a model
  response.

  `Imp.Predict.ReActV2` returns `{:error, %StepError{}}` when a request of the
  turn failed and no further request could answer it: the last request of an
  interrupted turn failed, or a step failed with an
  `Imp.OperationalSafetyError`, which ends the turn at once. Two fields carry
  what a caller acts on:

    * `:reason` — the failed request's error, unchanged, as `Imp.Predict`
      returns it: an `Imp.LMError`, `{:lm_failed, client, exception}` for a
      client that raised, `{:adapter_format_failed, adapter, exception}` for a
      renderer that raised, or an `Imp.OperationalSafetyError`.
      `Imp.Errors.retryable?/1` and `Imp.Errors.context_window_exceeded?/1`
      read it through this struct, and `Imp.OperationalSafetyError` guards
      find a safety error inside it.
    * `:history` — the turn's `Imp.History` as far as it got: the history a
      finished turn returns in its prediction's `:history` metadata, with
      every step that ran, its tool calls and their results, and the
      provider's reasoning continuation. The tools those steps called have
      run, so a host that keeps a conversation stores it as it stores a
      finished turn's.

  `Imp.Errors.retryable?/1` on this error answers whether the last model
  request may be sent again, not whether the turn may: the tools in
  `:history` have already run, and running the turn again from its inputs
  runs them again. A host that continues continues from `:history`.

  No partial prediction exists: a turn that stopped here has no outputs.

  Inspecting the error shows the reason and how many messages the history
  holds, not the history: a host that logs or records an inspected error does
  not write the trajectory, with its provider reasoning continuation, there.
  """

  defexception [:message, :reason, :history]

  @type t :: %__MODULE__{
          message: String.t(),
          reason: term(),
          history: Imp.History.t()
        }

  @impl true
  def exception(opts) do
    reason = Keyword.fetch!(opts, :reason)

    %__MODULE__{
      message: "ReActV2 turn got no model response: " <> describe(reason),
      reason: reason,
      history: Keyword.fetch!(opts, :history)
    }
  end

  defp describe({:lm_failed, client, exception}),
    do: "#{inspect(client)} raised: #{describe(exception)}"

  defp describe({:adapter_format_failed, adapter, exception}),
    do: "#{inspect(adapter)} could not format the request: #{describe(exception)}"

  defp describe(exception) when is_exception(exception), do: Exception.message(exception)
  defp describe(reason), do: inspect(reason, limit: 20, printable_limit: 500)
end

defimpl Inspect, for: Imp.Predict.ReActV2.StepError do
  import Inspect.Algebra

  def inspect(%{reason: reason, history: history}, opts) do
    count =
      case history do
        %Imp.History{messages: messages} -> length(messages)
        _none -> 0
      end

    concat([
      "#Imp.Predict.ReActV2.StepError<reason: ",
      to_doc(reason, opts),
      ", history: #{count} #{if count == 1, do: "message", else: "messages"}>"
    ])
  end
end
