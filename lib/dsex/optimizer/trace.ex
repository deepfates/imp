defmodule DSEx.Optimizer.Trace do
  @moduledoc false

  @key {__MODULE__, :steps}

  def start do
    Process.put(@key, [])
    :ok
  end

  def capture(%DSEx.Predict.Predict{metadata: metadata}, inputs, prediction) do
    case {Process.get(@key), Map.get(metadata, :optimizer_predictor_name)} do
      {steps, name} when is_list(steps) and not is_nil(name) ->
        step = %{
          predictor: name,
          inputs: Map.new(inputs),
          outputs: DSEx.Prediction.to_map(prediction)
        }

        Process.put(@key, [step | steps])

      _ ->
        :ok
    end
  end

  def finish do
    steps = Process.get(@key, []) |> Enum.reverse()
    Process.delete(@key)
    steps
  end
end
