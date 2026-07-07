defmodule DSEx.Optimizer.KNNFewShot.Program do
  @moduledoc false
  @behaviour DSEx.Module

  defstruct [:student, :optimizer]

  @impl true
  def call(%__MODULE__{} = program, inputs) do
    with {:ok, demos} <- retrieve_demos(program.optimizer.knn, inputs),
         {:ok, prediction} <- call_student(program, inputs, demos) do
      {:ok, attach_knn_metadata(prediction, demos)}
    end
  end

  defp call_student(program, inputs, demos) do
    compiled =
      DSEx.Optimizer.LabeledFewShot.compile(
        program.optimizer.bootstrap,
        program.student,
        demos
      )

    case DSEx.Module.call(compiled, inputs) do
      {:ok, %DSEx.Prediction{} = prediction} ->
        {:ok, prediction}

      {:ok, other} ->
        {:error, {:knn_few_shot_invalid_prediction, inspect(other)}}

      {:error, reason} ->
        {:error, {:knn_few_shot_student_failed, reason, %{demo_count: length(demos)}}}

      other ->
        {:error, {:knn_few_shot_invalid_result, inspect(other)}}
    end
  rescue
    error ->
      {:error, {:knn_few_shot_student_failed, error_message(error), %{demo_count: length(demos)}}}
  catch
    kind, reason ->
      {:error,
       {:knn_few_shot_student_failed, error_message({kind, reason}), %{demo_count: length(demos)}}}
  end

  defp retrieve_demos(knn, inputs) do
    case DSEx.Predict.KNN.call(knn, inputs) do
      demos when is_list(demos) -> {:ok, demos}
      other -> {:error, {:knn_few_shot_invalid_demos, inspect(other)}}
    end
  rescue
    error -> {:error, {:knn_few_shot_retrieval_failed, error_message(error)}}
  catch
    kind, reason -> {:error, {:knn_few_shot_retrieval_failed, error_message({kind, reason})}}
  end

  defp attach_knn_metadata(%DSEx.Prediction{metadata: metadata} = prediction, demos) do
    %{
      prediction
      | metadata: Map.put(metadata, :knn_few_shot, %{demo_count: length(demos), demos: demos})
    }
  end

  defp error_message(%_{} = exception), do: Exception.message(exception)
  defp error_message(error), do: inspect(error)
end

defmodule DSEx.Optimizer.KNNFewShot do
  @moduledoc """
  Attach nearest training examples as demonstrations at call time.

  The compiled program retrieves neighbors for each input, temporarily compiles
  the student with those demos, and annotates successful predictions with the
  demos used under `prediction.metadata.knn_few_shot`.
  """

  defstruct [:knn, :bootstrap]

  def new(k, trainset, opts \\ []) do
    k = non_negative_integer(k)

    %__MODULE__{
      knn: DSEx.Predict.KNN.new(k, trainset, field: Keyword.get(opts, :field, :question)),
      bootstrap: DSEx.Optimizer.LabeledFewShot.new(k: k)
    }
  end

  def compile(%__MODULE__{} = optimizer, student),
    do: %DSEx.Optimizer.KNNFewShot.Program{student: student, optimizer: optimizer}

  defp non_negative_integer(value) when is_integer(value) and value > 0, do: value
  defp non_negative_integer(_value), do: 0
end
