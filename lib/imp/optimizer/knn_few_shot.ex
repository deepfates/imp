defmodule Imp.Optimizer.KNNFewShot.Program do
  @moduledoc false
  @behaviour Imp.Module

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
      Imp.Optimizer.LabeledFewShot.compile(
        program.optimizer.bootstrap,
        program.student,
        demos
      )

    case Imp.Module.call(compiled, inputs) do
      {:ok, %Imp.Prediction{} = prediction} ->
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
    case Imp.Predict.KNN.call(knn, inputs) do
      demos when is_list(demos) -> {:ok, demos}
      other -> {:error, {:knn_few_shot_invalid_demos, inspect(other)}}
    end
  rescue
    error -> {:error, {:knn_few_shot_retrieval_failed, error_message(error)}}
  catch
    kind, reason -> {:error, {:knn_few_shot_retrieval_failed, error_message({kind, reason})}}
  end

  defp attach_knn_metadata(%Imp.Prediction{metadata: metadata} = prediction, demos) do
    %{
      prediction
      | metadata: Map.put(metadata, :knn_few_shot, %{demo_count: length(demos), demos: demos})
    }
  end

  defp error_message(%_{} = exception), do: Exception.message(exception)
  defp error_message(error), do: inspect(error)
end

defmodule Imp.Optimizer.KNNFewShot do
  @behaviour Imp.Optimizer
  @moduledoc """
  Attach nearest training examples as demonstrations at call time.

  The compiled program retrieves neighbors for each input, temporarily compiles
  the student with those demos, and annotates successful predictions with the
  demos used under `prediction.metadata.knn_few_shot`.
  """

  defstruct [:knn, :bootstrap]

  @option_schema [
    field: [
      type: {:custom, Imp.FieldSelector, :validate_selector, []},
      default: :question
    ]
  ]

  def new(k, trainset, opts \\ []) do
    k = validate_k!(k)
    opts = Imp.Options.validate!(opts, @option_schema, "Imp.Optimizer.KNNFewShot.new/3")

    %__MODULE__{
      knn: Imp.Predict.KNN.new(k, trainset, field: opts[:field]),
      bootstrap: Imp.Optimizer.LabeledFewShot.new(k: k)
    }
  end

  @impl true
  def __optimizer__,
    do: %{
      kind: :constructor,
      datasets: %{trainset: :unsupported, validation: :unsupported},
      result: :constructed_program
    }

  @impl true
  def run(%__MODULE__{} = optimizer, student, opts) do
    with :ok <- Imp.Optimizer.reject_options(Imp.Optimizer.invocation_options(opts)) do
      {:ok, compile(optimizer, student)}
    end
  end

  def compile(%__MODULE__{} = optimizer, student),
    do: %Imp.Optimizer.KNNFewShot.Program{student: student, optimizer: optimizer}

  defp validate_k!(value) when is_integer(value) and value >= 0, do: value

  defp validate_k!(value) do
    raise ArgumentError,
          "Imp.Optimizer.KNNFewShot.new/3 expects k to be a non-negative integer; got: #{inspect(value)}"
  end
end
