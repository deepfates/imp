defmodule DSEx.BenchmarkTruth.IFBenchFeedback do
  @moduledoc false

  alias DSEx.Optimizer.GEPA.ComponentFeedback

  @type metric ::
          (DSEx.Example.t(), DSEx.Prediction.t() -> term())
          | (DSEx.Example.t(), DSEx.Prediction.t(), [map()] -> term())

  @spec callbacks(metric()) :: %{
          generate_response_module: ComponentFeedback.callback(),
          ensure_correct_response_module: ComponentFeedback.callback()
        }
  def callbacks(metric) when is_function(metric, 2) or is_function(metric, 3) do
    %{
      generate_response_module: feedback_callback(metric, :response),
      ensure_correct_response_module: feedback_callback(metric, :final_response)
    }
  end

  def callbacks(metric) do
    raise ArgumentError,
          "IFBench component feedback expects an arity-2 or arity-3 metric, got: #{inspect(metric)}"
  end

  defp feedback_callback(metric, output_key) do
    fn %ComponentFeedback{} = context ->
      prediction =
        DSEx.Prediction.new(response: fetch_output!(context.predictor_output, output_key))

      result =
        if is_function(metric, 3),
          do: metric.(context.example, prediction, context.trace),
          else: metric.(context.example, prediction)

      %{feedback_text: feedback_text!(result, output_key)}
    end
  end

  defp fetch_output!(outputs, key) when is_map(outputs) do
    case Map.fetch(outputs, key) do
      {:ok, value} ->
        value

      :error ->
        case Map.fetch(outputs, Atom.to_string(key)) do
          {:ok, value} -> value
          :error -> raise KeyError, key: key, term: outputs
        end
    end
  end

  defp feedback_text!(result, output_key) do
    case DSEx.Metrics.feedback(result) do
      feedback when is_binary(feedback) and feedback != "" ->
        feedback

      feedback ->
        raise ArgumentError,
              "IFBench metric-with-feedback returned invalid feedback for #{inspect(output_key)}: #{inspect(feedback)}"
    end
  end
end
