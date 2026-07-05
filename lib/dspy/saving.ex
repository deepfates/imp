defmodule DSPy.Saving do
  @moduledoc "JSON save/load helpers for portable program state."

  def save!(program, path) do
    path
    |> Path.dirname()
    |> File.mkdir_p!()

    File.write!(path, Jason.encode!(dump(program), pretty: true))
    :ok
  end

  def load!(path) do
    path
    |> File.read!()
    |> Jason.decode!()
    |> load()
  end

  def dump(%DSPy.Predict.Predict{} = program),
    do: Map.put(DSPy.Predict.Predict.dump(program), "type", "predict")

  def dump(%DSPy.Predict.ChainOfThought{predict: predict}) do
    predict |> dump() |> Map.put("type", "chain_of_thought")
  end

  def load(%{
        "type" => "predict",
        "signature" => signature,
        "demos" => demos,
        "config" => config,
        "metadata" => metadata
      }) do
    DSPy.Predict.Predict.new(DSPy.Signature.load(signature),
      demos: Enum.map(demos, &DSPy.Example.new/1),
      config: Enum.map(config, fn {k, v} -> {String.to_atom(k), v} end),
      metadata: metadata
    )
  end

  def load(%{"type" => "chain_of_thought"} = state) do
    predict = state |> Map.put("type", "predict") |> load()
    %DSPy.Predict.ChainOfThought{predict: predict}
  end

  def load(%{"type" => type}) do
    raise ArgumentError, "unsupported saved DSPy program type: #{inspect(type)}"
  end
end
