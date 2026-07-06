defmodule Dachshund.Predict.ReAct do
  @moduledoc "Small ReAct-inspired module that gives the LM tool descriptions and returns parsed outputs."

  @behaviour Dachshund.Module

  defstruct [:predict, tools: []]

  def new(signature, tools, opts \\ []) do
    tool_text =
      tools
      |> Enum.map(fn tool -> "#{tool.name}: #{tool.description}" end)
      |> Enum.join("\n")

    signature = Dachshund.Signature.ensure(signature)
    instructions = signature.instructions <> "\nYou may use these tools:\n" <> tool_text

    signature =
      signature
      |> Dachshund.Signature.extend(
        [
          %{name: :tool, metadata: %{optional: true}},
          %{name: :tool_input, metadata: %{optional: true}}
        ],
        :output
      )
      |> Map.put(:instructions, instructions)

    %__MODULE__{predict: Dachshund.Predict.Predict.new(signature, opts), tools: tools}
  end

  @impl true
  def call(%__MODULE__{} = react, inputs) do
    case Dachshund.Predict.Predict.call(react.predict, inputs) do
      {:ok, prediction} -> maybe_call_tool(react, prediction)
      error -> error
    end
  end

  defp maybe_call_tool(%__MODULE__{tools: tools}, %Dachshund.Prediction{} = prediction) do
    tool_name = Dachshund.Prediction.get(prediction, :tool)
    tool_input = Dachshund.Prediction.get(prediction, :tool_input)

    if tool_name do
      tool = Enum.find(tools, &(to_string(&1.name) == to_string(tool_name)))

      case tool do
        nil ->
          {:error, {:unknown_tool, tool_name}}

        tool ->
          {:ok,
           Dachshund.Prediction.put(
             prediction,
             :observation,
             Dachshund.Tool.call(tool, tool_input)
           )}
      end
    else
      {:ok, prediction}
    end
  end
end
