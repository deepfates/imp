defmodule DSPy.Teleprompt.KNNFewShot.Program do
  @moduledoc false
  @behaviour DSPy.Module

  defstruct [:student, :optimizer]

  @impl true
  def call(%__MODULE__{} = program, inputs) do
    demos = DSPy.Predict.KNN.call(program.optimizer.knn, inputs)

    compiled =
      DSPy.Teleprompt.LabeledFewShot.compile(program.optimizer.bootstrap, program.student, demos)

    compiled.__struct__.call(compiled, inputs)
  end
end

defmodule DSPy.Teleprompt.KNNFewShot do
  @moduledoc "Attach nearest training examples as demonstrations at call time."

  defstruct [:knn, :bootstrap]

  def new(k, trainset, opts \\ []) do
    %__MODULE__{
      knn: DSPy.Predict.KNN.new(k, trainset, field: Keyword.get(opts, :field, :question)),
      bootstrap: DSPy.Teleprompt.LabeledFewShot.new(k: k)
    }
  end

  def compile(%__MODULE__{} = optimizer, student),
    do: %DSPy.Teleprompt.KNNFewShot.Program{student: student, optimizer: optimizer}
end
