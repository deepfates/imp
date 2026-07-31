defmodule Imp.Optimizer.GEPA.ComponentFeedback do
  @moduledoc """
  Context and validation for named, component-specific GEPA feedback.

  A callback receives the selected predictor invocation together with the full
  example, program output, metric result, and captured trace. It returns
  feedback text directly or a map containing `:feedback`/`:feedback_text`.
  """

  @enforce_keys [
    :component,
    :predictor_inputs,
    :predictor_output,
    :example,
    :program_output,
    :trace,
    :score,
    :metric_feedback,
    :metric_metadata
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          component: atom(),
          predictor_inputs: map(),
          predictor_output: map(),
          example: Imp.Example.t(),
          program_output: Imp.Prediction.t() | nil,
          trace: [map()],
          score: number(),
          metric_feedback: term(),
          metric_metadata: map()
        }

  @type callback :: (t() -> term())

  @doc false
  def validate(nil), do: {:ok, %{}}

  def validate(callbacks) when is_map(callbacks) do
    if Enum.all?(callbacks, fn {name, callback} ->
         is_atom(name) and is_function(callback, 1)
       end) do
      {:ok, callbacks}
    else
      {:error, "expected a map of atom component names to arity-1 callbacks"}
    end
  end

  def validate(_callbacks),
    do: {:error, "expected nil or a map of atom component names to arity-1 callbacks"}

  @doc false
  def feedback!(callback, %__MODULE__{} = context) when is_function(callback, 1) do
    context
    |> callback.()
    |> normalize!()
  rescue
    safety in Imp.OperationalSafetyError ->
      raise safety

    error ->
      raise RuntimeError,
            "GEPA component feedback failed for #{inspect(context.component)}: #{Exception.message(error)}"
  catch
    kind, reason ->
      case Imp.OperationalSafetyError.find({kind, reason}) do
        %Imp.OperationalSafetyError{} = safety ->
          raise safety

        nil ->
          raise RuntimeError,
                "GEPA component feedback failed for #{inspect(context.component)}: #{inspect({kind, reason})}"
      end
  end

  defp normalize!(%{feedback_text: feedback}), do: normalize_text!(feedback)
  defp normalize!(%{"feedback_text" => feedback}), do: normalize_text!(feedback)
  defp normalize!(%{feedback: feedback}), do: normalize_text!(feedback)
  defp normalize!(%{"feedback" => feedback}), do: normalize_text!(feedback)
  defp normalize!(feedback), do: normalize_text!(feedback)

  defp normalize_text!(feedback) when is_binary(feedback) and feedback != "", do: feedback

  defp normalize_text!(feedback) do
    raise ArgumentError,
          "component feedback callback must return non-empty text or a feedback map, got: #{inspect(feedback)}"
  end
end
