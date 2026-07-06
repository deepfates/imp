defmodule DSEx.Optimizer.KNNFewShot.Program do
  @moduledoc false
  @behaviour DSEx.Module

  defstruct [:student, :optimizer]

  @impl true
  def call(%__MODULE__{} = program, inputs) do
    demos = DSEx.Predict.KNN.call(program.optimizer.knn, inputs)

    compiled =
      DSEx.Optimizer.LabeledFewShot.compile(
        program.optimizer.bootstrap,
        program.student,
        demos
      )

    compiled.__struct__.call(compiled, inputs)
  end
end

defmodule DSEx.Optimizer.KNNFewShot do
  @moduledoc "Attach nearest training examples as demonstrations at call time."

  defstruct [:knn, :bootstrap]

  def new(k, trainset, opts \\ []) do
    %__MODULE__{
      knn: DSEx.Predict.KNN.new(k, trainset, field: Keyword.get(opts, :field, :question)),
      bootstrap: DSEx.Optimizer.LabeledFewShot.new(k: k)
    }
  end

  def compile(%__MODULE__{} = optimizer, student),
    do: %DSEx.Optimizer.KNNFewShot.Program{student: student, optimizer: optimizer}
end
