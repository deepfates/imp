defmodule Imp.Evaluate.SemanticF1 do
  @moduledoc """
  LM-backed semantic precision/recall metric with deterministic F1 scoring.

  This is a BEAM-native adaptation of DSPy `SemanticF1`: the LM judges
  precision and recall, while Imp clamps both values and computes the harmonic
  mean locally. Passing a non-nil `:trace` returns threshold truth, matching the
  optimizer-facing upstream contract.
  """

  @behaviour Imp.Module

  defstruct [:predict, threshold: 0.66, decompositional: false]

  @metric_options [
    threshold: [type: {:or, [:integer, :float]}, default: 0.66],
    decompositional: [type: :boolean, default: false]
  ]

  def new(opts \\ []) do
    {metric_opts, predict_opts} = split_options!(opts, [:threshold, :decompositional])
    metric_opts = Imp.Options.validate!(metric_opts, @metric_options, "SemanticF1.new/1")
    decompositional = metric_opts[:decompositional]

    %__MODULE__{
      predict: Imp.Predict.ChainOfThought.new(signature(decompositional), predict_opts),
      threshold: metric_opts[:threshold] * 1.0,
      decompositional: decompositional
    }
  end

  @impl true
  def call(%__MODULE__{predict: predict} = evaluator, inputs) do
    with {:ok, judge_inputs, trace} <- semantic_inputs(inputs),
         {:ok, judgment} <- Imp.Predict.ChainOfThought.call(predict, judge_inputs),
         {:ok, score} <-
           f1_score(
             Imp.Prediction.get(judgment, :precision),
             Imp.Prediction.get(judgment, :recall)
           ) do
      result = if(is_nil(trace), do: score, else: score >= evaluator.threshold)

      {:ok,
       judgment
       |> Imp.Prediction.put(:f1, score)
       |> Imp.Prediction.put(:score, result)
       |> Map.put(:score, result)}
    end
  end

  @doc false
  def f1_score(precision, recall) when is_number(precision) and is_number(recall) do
    precision = precision |> max(0.0) |> min(1.0)
    recall = recall |> max(0.0) |> min(1.0)

    score =
      if precision + recall == 0,
        do: 0.0,
        else: 2 * precision * recall / (precision + recall)

    {:ok, score}
  end

  def f1_score(precision, recall),
    do: {:error, {:invalid_semantic_precision_recall, precision, recall}}

  defp signature(false) do
    Imp.signature(
      "question, ground_truth, system_response -> precision: number, recall: number",
      "Compare the system response with the ground truth. Estimate the fraction of the system response covered by the ground truth as precision and the fraction of the ground truth covered by the system response as recall. Return each as a number from 0 to 1."
    )
  end

  defp signature(true) do
    Imp.signature(
      "question, ground_truth, system_response -> ground_truth_key_ideas, system_response_key_ideas, discussion, precision: number, recall: number",
      "Enumerate key ideas in the ground truth and system response, discuss their overlap, then estimate semantic precision and recall as numbers from 0 to 1."
    )
  end

  defp semantic_inputs(inputs) when is_map(inputs) do
    case {fetch(inputs, :example), fetch(inputs, :pred)} do
      {{:ok, example}, {:ok, prediction}} ->
        with {:ok, question} <- value(example, :question),
             {:ok, ground_truth} <- value(example, :response),
             {:ok, system_response} <- value(prediction, :response) do
          {:ok,
           %{question: question, ground_truth: ground_truth, system_response: system_response},
           optional(inputs, :trace)}
        end

      _ ->
        with {:ok, question} <- value(inputs, :question),
             {:ok, ground_truth} <- value(inputs, :ground_truth),
             {:ok, system_response} <- value(inputs, :system_response) do
          {:ok,
           %{question: question, ground_truth: ground_truth, system_response: system_response},
           optional(inputs, :trace)}
        end
    end
  end

  defp semantic_inputs(inputs), do: {:error, {:invalid_semantic_f1_inputs, inputs}}

  defp split_options!(opts, keys) do
    unless Keyword.keyword?(opts),
      do: raise(ArgumentError, "auto-evaluation options must be a keyword list")

    Keyword.split(opts, keys)
  end

  defp value(%Imp.Example{} = example, key), do: value(Imp.Example.to_map(example), key)
  defp value(%Imp.Prediction{} = prediction, key), do: fetch(prediction.fields, key)
  defp value(map, key) when is_map(map), do: fetch(map, key)
  defp value(other, key), do: {:error, {:missing_auto_evaluation_field, key, other}}

  defp fetch(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(map, Atom.to_string(key))
    end
  end

  defp optional(map, key) do
    case fetch(map, key) do
      {:ok, value} -> value
      :error -> nil
    end
  end
end

defmodule Imp.Evaluate.CompleteAndGrounded do
  @moduledoc """
  LM-backed completeness and groundedness metric.

  Completeness and groundedness are judged independently, then combined with
  the same clamped harmonic mean used by `Imp.Evaluate.SemanticF1`.
  """

  @behaviour Imp.Module

  defstruct [:predict, :completeness, :groundedness, threshold: 0.66]

  @metric_options [threshold: [type: {:or, [:integer, :float]}, default: 0.66]]

  def new(opts \\ []) do
    {metric_opts, predict_opts} = split_options!(opts)

    metric_opts =
      Imp.Options.validate!(metric_opts, @metric_options, "CompleteAndGrounded.new/1")

    %__MODULE__{
      completeness:
        Imp.Predict.ChainOfThought.new(
          Imp.signature(
            "question, ground_truth, system_response -> ground_truth_key_ideas, system_response_key_ideas, discussion, completeness: number",
            "Estimate completeness against the ground truth. Enumerate key ideas in both responses, discuss their overlap, and return the fraction of ground-truth content covered by the system response as a number from 0 to 1."
          ),
          predict_opts
        ),
      groundedness:
        Imp.Predict.ChainOfThought.new(
          Imp.signature(
            "question, retrieved_context, system_response -> system_response_claims, discussion, groundedness: number",
            "Estimate groundedness against retrieved context. Enumerate check-worthy claims in the system response, discuss their support in the context, and return the supported fraction as a number from 0 to 1."
          ),
          predict_opts
        ),
      threshold: metric_opts[:threshold] * 1.0
    }
  end

  @impl true
  def call(%__MODULE__{completeness: nil, groundedness: nil, predict: predict}, inputs)
      when not is_nil(predict),
      do: Imp.Predict.ChainOfThought.call(predict, inputs)

  def call(%__MODULE__{} = evaluator, inputs) do
    with {:ok, normalized, trace} <- complete_and_grounded_inputs(inputs),
         {:ok, completeness} <-
           Imp.Predict.ChainOfThought.call(evaluator.completeness, %{
             question: normalized.question,
             ground_truth: normalized.ground_truth,
             system_response: normalized.system_response
           }),
         {:ok, groundedness} <-
           Imp.Predict.ChainOfThought.call(evaluator.groundedness, %{
             question: normalized.question,
             retrieved_context: normalized.retrieved_context,
             system_response: normalized.system_response
           }),
         {:ok, score} <-
           Imp.Evaluate.SemanticF1.f1_score(
             Imp.Prediction.get(groundedness, :groundedness),
             Imp.Prediction.get(completeness, :completeness)
           ) do
      result = if(is_nil(trace), do: score, else: score >= evaluator.threshold)

      fields =
        completeness
        |> Imp.Prediction.to_map()
        |> Map.merge(Imp.Prediction.to_map(groundedness))
        |> Map.put(:f1, score)
        |> Map.put(:score, result)

      {:ok, Imp.Prediction.new(fields, score: result)}
    end
  end

  defp complete_and_grounded_inputs(inputs) when is_map(inputs) do
    case {fetch(inputs, :example), fetch(inputs, :pred)} do
      {{:ok, example}, {:ok, prediction}} ->
        build_inputs(
          inputs,
          value(example, :question),
          value(example, :response),
          value(prediction, :response),
          value(prediction, :context)
        )

      _ ->
        system_response = first_value(inputs, [:system_response, :answer])
        ground_truth = first_value(inputs, [:ground_truth, :response, :answer])
        retrieved_context = first_value(inputs, [:retrieved_context, :context])

        build_inputs(
          inputs,
          value(inputs, :question),
          ground_truth,
          system_response,
          retrieved_context
        )
    end
  end

  defp complete_and_grounded_inputs(inputs),
    do: {:error, {:invalid_complete_and_grounded_inputs, inputs}}

  defp build_inputs(source, question, ground_truth, system_response, retrieved_context) do
    with {:ok, question} <- question,
         {:ok, ground_truth} <- ground_truth,
         {:ok, system_response} <- system_response,
         {:ok, retrieved_context} <- retrieved_context do
      {:ok,
       %{
         question: question,
         ground_truth: ground_truth,
         system_response: system_response,
         retrieved_context: retrieved_context
       }, optional(source, :trace)}
    end
  end

  defp split_options!(opts) do
    unless Keyword.keyword?(opts),
      do: raise(ArgumentError, "auto-evaluation options must be a keyword list")

    Keyword.split(opts, [:threshold])
  end

  defp first_value(map, keys) do
    Enum.find_value(keys, :error, fn key ->
      case value(map, key) do
        {:ok, value} -> {:ok, value}
        :error -> nil
      end
    end)
  end

  defp value(%Imp.Example{} = example, key), do: value(Imp.Example.to_map(example), key)
  defp value(%Imp.Prediction{} = prediction, key), do: fetch(prediction.fields, key)
  defp value(map, key) when is_map(map), do: fetch(map, key)
  defp value(_other, _key), do: :error

  defp fetch(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(map, Atom.to_string(key))
    end
  end

  defp optional(map, key) do
    case fetch(map, key) do
      {:ok, value} -> value
      :error -> nil
    end
  end
end
