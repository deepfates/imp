defmodule Dachshund.Optimizer.KNNFewShot.Program do
  @moduledoc false
  @behaviour Dachshund.Module

  defstruct [:student, :optimizer]

  @impl true
  def call(%__MODULE__{} = program, inputs) do
    demos = Dachshund.Predict.KNN.call(program.optimizer.knn, inputs)

    compiled =
      Dachshund.Optimizer.LabeledFewShot.compile(
        program.optimizer.bootstrap,
        program.student,
        demos
      )

    compiled.__struct__.call(compiled, inputs)
  end
end

defmodule Dachshund.Optimizer.KNNFewShot do
  @moduledoc "Attach nearest training examples as demonstrations at call time."

  defstruct [:knn, :bootstrap]

  def new(k, trainset, opts \\ []) do
    %__MODULE__{
      knn: Dachshund.Predict.KNN.new(k, trainset, field: Keyword.get(opts, :field, :question)),
      bootstrap: Dachshund.Optimizer.LabeledFewShot.new(k: k)
    }
  end

  def compile(%__MODULE__{} = optimizer, student),
    do: %Dachshund.Optimizer.KNNFewShot.Program{student: student, optimizer: optimizer}
end
