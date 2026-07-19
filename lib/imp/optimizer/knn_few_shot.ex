defmodule Imp.Optimizer.KNNFewShot.Program do
  @moduledoc false
  @behaviour Imp.Module

  defstruct [:student, :optimizer, :teacher]

  # DSPy KNNFewShot's patched forward: retrieve the k nearest trainset
  # examples for THIS call, run a full BootstrapFewShot compilation of the
  # student over those neighbors (teacher threaded through), then execute the
  # freshly compiled program on the call's inputs.
  @impl true
  def call(%__MODULE__{} = program, inputs) do
    with {:ok, demos} <- retrieve_neighbors(program.optimizer.knn, inputs),
         {:ok, compiled} <- bootstrap_student(program, demos),
         {:ok, prediction} <- call_compiled(compiled, inputs, demos) do
      {:ok, attach_knn_metadata(prediction, demos)}
    end
  end

  defp retrieve_neighbors(knn, inputs) do
    case Imp.Predict.KNN.call(knn, inputs) do
      demos when is_list(demos) -> {:ok, demos}
      other -> {:error, {:knn_few_shot_invalid_demos, inspect(other)}}
    end
  rescue
    error -> {:error, {:knn_few_shot_retrieval_failed, error_message(error)}}
  catch
    kind, reason -> {:error, {:knn_few_shot_retrieval_failed, error_message({kind, reason})}}
  end

  defp bootstrap_student(program, demos) do
    {:ok,
     Imp.Optimizer.BootstrapFewShot.compile(
       program.optimizer.bootstrap,
       program.student,
       demos,
       teacher: program.teacher
     )}
  rescue
    error ->
      {:error,
       {:knn_few_shot_bootstrap_failed, error_message(error), %{demo_count: length(demos)}}}
  catch
    kind, reason ->
      {:error,
       {:knn_few_shot_bootstrap_failed, error_message({kind, reason}),
        %{demo_count: length(demos)}}}
  end

  defp call_compiled(compiled, inputs, demos) do
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
  Faithful port of DSPy 3.2.1 `KNNFewShot` (dspy/teleprompt/knn_fewshot.py).

  Construction embeds the trainset once through the required `:vectorizer`
  (via `Imp.Predict.KNN`, the DSPy `KNN` port). The compiled program then, on
  EVERY forward call, retrieves the `k` nearest trainset examples for that
  call's inputs and runs a full `Imp.Optimizer.BootstrapFewShot` compilation
  of the student over those neighbors — metric/teacher-driven bootstrapped
  demonstrations, not raw attached neighbors — before executing the compiled
  student on the inputs (upstream `KNNFewShot.compile`'s patched
  `forward_pass`).

  `few_shot_bootstrap_args` maps DSPy's `**few_shot_bootstrap_args` onto
  `Imp.Optimizer.BootstrapFewShot.new/2`: pass `:metric` plus any
  BootstrapFewShot options (`:max_bootstrapped_demos`, `:max_labeled_demos`,
  `:max_rounds`, ...). A teacher passes to `compile/3` as `teacher:`, mirroring
  upstream's `compile(student, teacher=...)`.

  Successful predictions are annotated with the retrieved neighbors under
  `prediction.metadata.knn_few_shot` (an Imp observability extension; the
  prompt-visible behavior is upstream's).

  ## Example

      knn_few_shot =
        Imp.Optimizer.KNNFewShot.new(3, trainset,
          vectorizer: Imp.Embeddings.BagOfWords,
          few_shot_bootstrap_args: [metric: metric]
        )

      program = Imp.Optimizer.KNNFewShot.compile(knn_few_shot, student)
  """

  defstruct [:knn, :bootstrap]

  @option_schema [
    vectorizer: [
      type: {:custom, Imp.Predict.KNN, :validate_vectorizer, []},
      required: true
    ],
    few_shot_bootstrap_args: [type: :keyword_list, default: []]
  ]

  @doc """
  Builds the optimizer (DSPy `KNNFewShot.__init__`): a `KNN` retriever over
  the trainset plus stored BootstrapFewShot arguments.
  """
  def new(k, trainset, opts \\ []) do
    opts = Imp.Options.validate!(opts, @option_schema, "Imp.Optimizer.KNNFewShot.new/3")

    {metric, bootstrap_opts} = Keyword.pop(opts[:few_shot_bootstrap_args], :metric)

    %__MODULE__{
      knn: Imp.Predict.KNN.new(k, trainset, vectorizer: opts[:vectorizer]),
      bootstrap: Imp.Optimizer.BootstrapFewShot.new(metric, bootstrap_opts)
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
    invocation = Imp.Optimizer.invocation_options(opts)
    {teacher, invocation} = Keyword.pop(invocation, :teacher)

    with :ok <- Imp.Optimizer.reject_options(invocation) do
      {:ok, compile(optimizer, student, teacher: teacher)}
    end
  end

  @doc """
  Returns the compiled program (DSPy `KNNFewShot.compile(student, teacher=...)`):
  per-call neighbor retrieval + BootstrapFewShot compilation of the student.
  """
  def compile(%__MODULE__{} = optimizer, student, opts \\ []) do
    teacher = Keyword.get(opts, :teacher)

    %Imp.Optimizer.KNNFewShot.Program{student: student, optimizer: optimizer, teacher: teacher}
  end
end
